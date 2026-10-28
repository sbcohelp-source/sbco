use super::{Database, db_error};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::NaiveDate;
use sbco_contracts::{Filter, Query};
use sbco_domain::{Actor, Error, Result, Role};
use serde_json::{Value, json};
use sqlx::{Postgres, QueryBuilder, Row};
use uuid::Uuid;

pub(crate) fn scope(q: &mut QueryBuilder<Postgres>, actor: &Actor, column: &str) {
    if actor.role == Role::Pa {
        q.push(" AND ").push(column).push(" IN (SELECT po.office_id FROM pool_offices po JOIN pools p ON p.id=po.pool_id WHERE p.pa_user=").push_bind(actor.id).push(")");
    }
}
pub(crate) fn filters(
    q: &mut QueryBuilder<Postgres>,
    filter: &Filter,
    date_column: &str,
) -> Result<()> {
    if let Some(s) = &filter.office
        && !s.is_empty()
    {
        q.push(" AND t.office_id=").push_bind(s.clone());
    }
    if let Some(s) = &filter.status
        && !s.is_empty()
    {
        q.push(" AND t.primary_status=").push_bind(s.clone());
    }
    if let Some(s) = &filter.search
        && !s.is_empty()
    {
        let pattern = format!(
            "%{}%",
            s.replace('\\', "\\\\")
                .replace('%', "\\%")
                .replace('_', "\\_")
        );
        q.push(" AND (t.account_number ILIKE ")
            .push_bind(pattern.clone())
            .push(" OR t.transaction_id ILIKE ")
            .push_bind(pattern.clone())
            .push(" OR t.reference_id ILIKE ")
            .push_bind(pattern)
            .push(")");
    }
    for (date, op) in [(&filter.from_date, ">="), (&filter.to_date, "<=")] {
        if let Some(date) = date
            && !date.is_empty()
        {
            let d = NaiveDate::parse_from_str(date, "%Y-%m-%d")
                .map_err(|_| Error::Validation("Invalid date".into()))?;
            q.push(" AND ").push(date_column).push(op).push_bind(d);
        }
    }
    if let (Some(a), Some(b)) = (&filter.from_date, &filter.to_date)
        && !a.is_empty()
        && !b.is_empty()
        && a > b
    {
        return Err(Error::Validation("From date must precede To date".into()));
    }
    match filter.queue.as_deref() {
        Some("agent") => {
            q.push(" AND t.agent");
        }
        Some("rd_default") => {
            q.push(" AND t.rd_default");
        }
        Some("bo") => {
            q.push(" AND t.report_type='BO/AO' AND NOT t.agent AND NOT t.rd_default");
        }
        Some("standard") => {
            q.push(" AND NOT t.agent AND NOT t.rd_default");
        }
        Some("all") | None => {}
        _ => return Err(Error::Validation("Unknown transaction queue".into())),
    }
    Ok(())
}
pub(crate) async fn json_rows(
    q: &mut QueryBuilder<Postgres>,
    pool: &sqlx::PgPool,
) -> Result<Value> {
    let rows: Vec<Value> = q
        .build_query_scalar()
        .fetch_all(pool)
        .await
        .map_err(db_error)?;
    Ok(json!(rows))
}
impl Database {
    pub(crate) async fn read(&self, actor: &Actor, query: Query) -> Result<Value> {
        match query {
            Query::Onboarding => super::onboarding::read(&self.pool, actor).await,
            Query::Transactions {
                filter,
                cursor,
                limit,
            } => self.transactions(actor, &filter, cursor, limit).await,
            Query::Dashboard { filter } => self.totals(actor, &filter, "Transactions").await,
            Query::Report { report, filter } => {
                serde_json::to_value(self.report_data(actor, &filter, &report, false).await?)
                    .map_err(|_| Error::Internal)
            }
            Query::History { id } => {
                let mut tx = self.pool.begin().await.map_err(db_error)?;
                locked_transaction(&mut tx, actor, id).await?;
                let rows: Vec<Value> = sqlx::query_scalar("SELECT to_jsonb(h)||jsonb_build_object('actor_name',u.name) FROM change_history h LEFT JOIN users u ON u.id=h.actor_id WHERE h.entity='transactions' AND h.entity_id=$1 ORDER BY h.id")
                    .bind(id).fetch_all(&mut *tx).await.map_err(db_error)?;
                Ok(json!(rows))
            }
            Query::Settings => sqlx::query_scalar("SELECT value FROM settings")
                .fetch_one(&self.pool)
                .await
                .map_err(db_error),
            other => {
                let (sql, col) = match other {
                    Query::Offices => {
                        ("SELECT to_jsonb(o) FROM offices o WHERE true", Some("o.id"))
                    }
                    Query::Pools => {
                        actor.require_manager()?;
                        (
                            "SELECT to_jsonb(p)||jsonb_build_object('offices',coalesce((SELECT jsonb_agg(po.office_id) FROM pool_offices po WHERE po.pool_id=p.id),'[]'::jsonb)) FROM pools p WHERE true",
                            None,
                        )
                    }
                    Query::Users => {
                        actor.require_manager()?;
                        (
                            "SELECT jsonb_build_object('id',id,'name',name,'email',email,'role',role,'active',active) FROM users WHERE true",
                            None,
                        )
                    }
                    Query::Imports => {
                        actor.require_manager()?;
                        (
                            "SELECT jsonb_build_object('id',id,'filename',filename,'status',status,'total',total,'inserted',inserted,'duplicates',duplicates,'failed',failed,'error',error,'created_at',created_at) FROM imports WHERE true",
                            None,
                        )
                    }
                    Query::Reviews => {
                        actor.require_manager()?;
                        (
                            "SELECT to_jsonb(r)||jsonb_build_object('account_number',t.account_number,'office_id',t.office_id,'credit',t.credit::text,'debit',t.debit::text) FROM reviews r JOIN transactions t ON t.id=r.transaction_id WHERE r.status='Pending' AND r.revision=t.revision",
                            None,
                        )
                    }
                    Query::Corrections => (
                        "SELECT to_jsonb(c)||jsonb_build_object('account_number',t.account_number,'office_id',t.office_id) FROM corrections c JOIN transactions t ON t.id=c.transaction_id WHERE true",
                        Some("t.office_id"),
                    ),
                    Query::Incidents => (
                        "SELECT to_jsonb(i)||jsonb_build_object('account_number',t.account_number,'report_date',t.report_date) FROM incidents i JOIN transactions t ON t.id=i.transaction_id WHERE true",
                        Some("i.office_id"),
                    ),
                    Query::Letters => (
                        "SELECT to_jsonb(l)-'pdf' FROM letters l WHERE true",
                        Some("letter_items"),
                    ),
                    Query::Audit => {
                        actor.require_manager()?;
                        (
                            "SELECT to_jsonb(a) FROM (SELECT id,actor_id,action,entity_id,detail,created_at FROM audit ORDER BY id DESC LIMIT 500) a WHERE true",
                            None,
                        )
                    }
                    _ => return Err(Error::Validation("Unsupported query".into())),
                };
                let mut q = QueryBuilder::new(sql);
                if let Some(col) = col {
                    if col == "letter_items" {
                        letter_scope(&mut q, actor);
                    } else {
                        scope(&mut q, actor, col);
                    }
                }
                // Lists are bounded; queue and reports have independent full-dataset queries.
                q.push(" LIMIT 10000");
                json_rows(&mut q, &self.pool).await
            }
        }
    }
    async fn transactions(
        &self,
        actor: &Actor,
        filter: &Filter,
        cursor: Option<String>,
        limit: u32,
    ) -> Result<Value> {
        if !(1..=200).contains(&limit) {
            return Err(Error::Validation(
                "Page size must be between 1 and 200".into(),
            ));
        }
        let mut q = QueryBuilder::new(
            "SELECT to_jsonb(t)||jsonb_build_object('credit',t.credit::text,'debit',t.debit::text,'office_name',o.name) FROM transactions t JOIN offices o ON o.id=t.office_id WHERE true",
        );
        scope(&mut q, actor, "t.office_id");
        filters(&mut q, filter, "t.report_date")?;
        if let Some(c) = cursor {
            let raw = URL_SAFE_NO_PAD
                .decode(c)
                .map_err(|_| Error::Validation("Invalid page cursor".into()))?;
            let (account, id): (String, Uuid) = serde_json::from_slice(&raw)
                .map_err(|_| Error::Validation("Invalid page cursor".into()))?;
            q.push(" AND (t.account_number,t.id) > (")
                .push_bind(account)
                .push(",")
                .push_bind(id)
                .push(")");
        }
        q.push(" ORDER BY t.account_number,t.id LIMIT ")
            .push_bind(i64::from(limit) + 1);
        let mut rows: Vec<Value> = q
            .build_query_scalar()
            .fetch_all(&self.pool)
            .await
            .map_err(db_error)?;
        let has_more = rows.len() > limit as usize;
        rows.truncate(limit as usize);
        let cursor = if has_more {
            rows.last().map(|r| {
                URL_SAFE_NO_PAD.encode(
                    serde_json::to_vec(&(
                        r["account_number"].as_str().unwrap_or(""),
                        r["id"].as_str().unwrap_or(""),
                    ))
                    .unwrap_or_default(),
                )
            })
        } else {
            None
        };
        Ok(json!({"rows":rows,"next_cursor":cursor}))
    }
    pub(crate) fn report_filter(
        &self,
        q: &mut QueryBuilder<Postgres>,
        actor: &Actor,
        filter: &Filter,
        report: &str,
    ) -> Result<()> {
        scope(q, actor, "t.office_id");
        let date = if matches!(report, "DPR" | "Daily Detail" | "MPR") {
            "(t.finalized_at AT TIME ZONE 'Asia/Kolkata')::date"
        } else {
            "t.report_date"
        };
        filters(q, filter, date)?;
        match report {
            "DPR" | "Daily Detail" | "MPR" => {
                q.push(" AND t.final_status<>'Pending'");
            }
            "Mismatch" => {
                q.push(" AND t.final_status='Mismatch'");
            }
            "MAP" | "Pending Voucher" => {
                q.push(" AND t.final_status='Mismatch' AND EXISTS(SELECT 1 FROM incidents i WHERE i.transaction_id=t.id AND i.status NOT IN ('Closed','Complied') AND i.incident_type=").push_bind(if report=="MAP" {"MAP"} else {"Voucher Follow-up"}).push(")");
            }
            "Transactions" => {}
            _ => return Err(Error::Validation("Unsupported report".into())),
        }
        Ok(())
    }
    pub(crate) async fn totals(
        &self,
        actor: &Actor,
        filter: &Filter,
        report: &str,
    ) -> Result<Value> {
        let mut q = QueryBuilder::new(
            "SELECT jsonb_build_object('total',count(*),'matched',count(*) FILTER(WHERE t.final_status='Matched'),'mismatch',count(*) FILTER(WHERE t.final_status='Mismatch'),'pending',count(*) FILTER(WHERE t.final_status='Pending'),'credit',coalesce(sum(t.credit),0)::text,'debit',coalesce(sum(t.debit),0)::text) FROM transactions t WHERE true",
        );
        self.report_filter(&mut q, actor, filter, report)?;
        q.build_query_scalar()
            .fetch_one(&self.pool)
            .await
            .map_err(db_error)
    }
}
pub(crate) async fn assert_office(
    tx: &mut sqlx::Transaction<'_, Postgres>,
    actor: &Actor,
    office: &str,
) -> Result<()> {
    if actor.role != Role::Pa {
        return Ok(());
    }
    let allowed:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pool_offices po JOIN pools p ON p.id=po.pool_id WHERE po.office_id=$1 AND p.pa_user=$2)").bind(office).bind(actor.id).fetch_one(&mut **tx).await.map_err(db_error)?;
    if allowed {
        Ok(())
    } else {
        Err(Error::Forbidden)
    }
}
pub(crate) async fn locked_transaction(
    tx: &mut sqlx::Transaction<'_, Postgres>,
    actor: &Actor,
    id: Uuid,
) -> Result<sqlx::postgres::PgRow> {
    let row = sqlx::query("SELECT * FROM transactions WHERE id=$1 FOR UPDATE")
        .bind(id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(db_error)?
        .ok_or(Error::NotFound)?;
    assert_office(tx, actor, row.get("office_id")).await?;
    Ok(row)
}

// A BO letter is addressed to its SO, but access follows every enclosed incident.
fn letter_scope(q: &mut QueryBuilder<Postgres>, actor: &Actor) {
    if actor.role == Role::Pa {
        q.push(" AND EXISTS(SELECT 1 FROM letter_items li WHERE li.letter_id=l.id) AND NOT EXISTS(SELECT 1 FROM letter_items li JOIN incidents i ON i.id=li.incident_id WHERE li.letter_id=l.id AND NOT EXISTS(SELECT 1 FROM pool_offices po JOIN pools p ON p.id=po.pool_id WHERE po.office_id=i.office_id AND p.pa_user=")
            .push_bind(actor.id).push("))");
    }
}
pub(crate) async fn assert_letter(
    tx: &mut sqlx::Transaction<'_, Postgres>,
    actor: &Actor,
    id: Uuid,
) -> Result<()> {
    let mut q = QueryBuilder::new("SELECT l.id FROM letters l WHERE l.id=");
    q.push_bind(id);
    letter_scope(&mut q, actor);
    if q.build_query_scalar::<Uuid>()
        .fetch_optional(&mut **tx)
        .await
        .map_err(db_error)?
        .is_some()
    {
        Ok(())
    } else {
        Err(Error::Forbidden)
    }
}
