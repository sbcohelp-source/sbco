//! Report reads share one PostgreSQL snapshot. Aggregates never use the preview limit.
use super::{Database, db_error, queries::scope};
use chrono::{Days, FixedOffset, NaiveDate, Utc};
use sbco_contracts::Filter;
use sbco_documents::{Document, Section};
use sbco_domain::{Actor, Error, Result};
use serde::Serialize;
use serde_json::Value;
use sqlx::{Postgres, QueryBuilder, Transaction};

#[derive(Serialize)]
pub(crate) struct ReportData {
    pub totals: Value,
    pub rows: Vec<Value>,
    pub document: Document,
    pub effective_filter: Filter,
    pub preview_limit: usize,
}
fn value(row: &Value, key: &str) -> String {
    match &row[key] {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}
fn cells(row: &Value, keys: &[&str]) -> Vec<String> {
    keys.iter().map(|key| value(row, key)).collect()
}
fn date(s: &str) -> Result<NaiveDate> {
    NaiveDate::parse_from_str(s, "%Y-%m-%d")
        .map_err(|_| Error::Validation("Invalid report date".into()))
}
fn period(filter: &Filter, report: &str) -> Result<Filter> {
    let mut filter = filter.clone();
    if matches!(report, "DPR" | "Daily Detail" | "MPR") {
        let today = Utc::now()
            .with_timezone(&FixedOffset::east_opt(19800).unwrap())
            .date_naive();
        let end = filter
            .to_date
            .as_deref()
            .filter(|s| !s.is_empty())
            .map(date)
            .transpose()?
            .unwrap_or(today);
        let start = filter
            .from_date
            .as_deref()
            .filter(|s| !s.is_empty())
            .map(date)
            .transpose()?
            .unwrap_or(end - Days::new(30));
        if start > end || (end - start).num_days() > 365 {
            return Err(Error::Validation(
                "Choose a progress-report period of 1 to 366 days".into(),
            ));
        }
        filter.from_date = Some(start.to_string());
        filter.to_date = Some(end.to_string());
    }
    Ok(filter)
}
async fn rows(
    q: &mut QueryBuilder<Postgres>,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<Vec<Value>> {
    q.build_query_scalar()
        .fetch_all(&mut **tx)
        .await
        .map_err(db_error)
}
impl Database {
    pub(crate) async fn report_data(
        &self,
        actor: &Actor,
        filter: &Filter,
        report: &str,
        export: bool,
    ) -> Result<ReportData> {
        let filter = period(filter, report)?;
        let mut tx = self.pool.begin().await.map_err(db_error)?;
        sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;
        let mut totals = QueryBuilder::new(
            "SELECT jsonb_build_object('total',count(*),'matched',count(*) FILTER(WHERE t.final_status='Matched'),'mismatch',count(*) FILTER(WHERE t.final_status='Mismatch'),'pending',count(*) FILTER(WHERE t.final_status='Pending'),'credit',coalesce(sum(t.credit),0)::text,'debit',coalesce(sum(t.debit),0)::text) FROM transactions t WHERE true",
        );
        self.report_filter(&mut totals, actor, &filter, report)?;
        let totals: Value = totals
            .build_query_scalar()
            .fetch_one(&mut *tx)
            .await
            .map_err(db_error)?;
        let limit = if export && !matches!(report, "DPR" | "MPR") {
            20000
        } else {
            100
        };
        let mut q = QueryBuilder::new(
            "SELECT to_jsonb(t)||jsonb_build_object('credit',t.credit::text,'debit',t.debit::text,'office_name',o.name,'staff',coalesce(u.name,'Unrecorded'),'staff_role',coalesce(u.role,''),'checked_at',to_char(t.finalized_at AT TIME ZONE 'Asia/Kolkata','YYYY-MM-DD HH24:MI'),'high_value',CASE WHEN t.debit>=50000 OR t.credit>=100000 THEN 'Yes' ELSE 'No' END) FROM transactions t JOIN offices o ON o.id=t.office_id LEFT JOIN users u ON u.id=t.finalized_by WHERE true",
        );
        self.report_filter(&mut q, actor, &filter, report)?;
        q.push(" ORDER BY t.office_id,t.report_date,t.id LIMIT ")
            .push_bind((limit + 1) as i64);
        let mut detail = rows(&mut q, &mut tx).await?;
        if export && limit == 20000 && detail.len() > 20000 {
            return Err(Error::Validation("PDF exceeds 20000 transactions. Choose a narrower office/date range; totals remain complete.".into()));
        }
        detail.truncate(limit as usize);
        let settings: Value = sqlx::query_scalar("SELECT value FROM settings")
            .fetch_one(&mut *tx)
            .await
            .map_err(db_error)?;
        let mut document = Document {
            title: match report {
                "DPR" => "Daily Progress Register",
                "MPR" => "Monthly Progress Report",
                "Daily Detail" => "Detailed Daily Progress",
                other => other,
            }
            .into(),
            subtitle: format!(
                "{} to {} | Office: {} | India time",
                filter
                    .from_date
                    .as_deref()
                    .filter(|s| !s.is_empty())
                    .unwrap_or("All dates"),
                filter
                    .to_date
                    .as_deref()
                    .filter(|s| !s.is_empty())
                    .unwrap_or("All dates"),
                filter
                    .office
                    .as_deref()
                    .filter(|s| !s.is_empty())
                    .unwrap_or("All assigned offices")
            ),
            landscape: !matches!(report, "DPR" | "MPR"),
            sections: vec![],
            notes: vec![],
            signatory: value(&settings, "signatory"),
            designation: value(&settings, "designation"),
        };
        if document.designation.is_empty() {
            document.designation = "SBCO Incharge".into();
        }
        if report == "DPR" {
            let mut q = QueryBuilder::new(
                "SELECT jsonb_build_object('date',(t.finalized_at AT TIME ZONE 'Asia/Kolkata')::date,'checked',count(*),'matched',count(*) FILTER(WHERE t.final_status='Matched'),'mismatch',count(*) FILTER(WHERE t.final_status='Mismatch'),'staff',CASE WHEN count(DISTINCT t.finalized_by)=1 THEN min(u.name) ELSE 'All SBCO verification staff' END) FROM transactions t LEFT JOIN users u ON u.id=t.finalized_by WHERE true",
            );
            self.report_filter(&mut q, actor, &filter, report)?;
            q.push(" GROUP BY (t.finalized_at AT TIME ZONE 'Asia/Kolkata')::date ORDER BY 1");
            let days = rows(&mut q, &mut tx).await?;
            document.sections.push(daily_register(&filter, &days)?);
        }
        if report == "MPR" {
            let mut q = QueryBuilder::new(
                "SELECT jsonb_build_object('stream',CASE WHEN t.report_type='BO/AO' THEN 'BO/AO' ELSE 'SO' END,'received',max(t.report_date),'checked',max(t.report_date) FILTER(WHERE t.final_status<>'Pending')) FROM transactions t WHERE true",
            );
            // Preserve the reference report's stream scope: finalized work within this period.
            self.report_filter(&mut q, actor, &filter, report)?;
            q.push(
                " GROUP BY CASE WHEN t.report_type='BO/AO' THEN 'BO/AO' ELSE 'SO' END ORDER BY 1",
            );
            let streams = rows(&mut q, &mut tx).await?;
            document.sections.push(Section::new(
                "1. Returns represented in this period's finalized work",
                &["Stream", "Latest return date", "Checked up to"],
                &[1, 2, 2],
                ["BO/AO", "SO"]
                    .iter()
                    .map(|stream| {
                        streams
                            .iter()
                            .find(|r| r["stream"] == *stream)
                            .map(|r| cells(r, &["stream", "received", "checked"]))
                            .unwrap_or_else(|| {
                                vec![(*stream).into(), "No work".into(), "No work".into()]
                            })
                    })
                    .collect(),
            ));
            self.objection_balances(actor, &filter, &mut tx, &mut document)
                .await?;
        }
        if matches!(report, "MPR" | "Daily Detail") {
            let mut q = QueryBuilder::new(
                "SELECT jsonb_build_object('staff',coalesce(u.name,'Unrecorded'),'role',coalesce(u.role,''),'checked',count(*),'matched',count(*) FILTER(WHERE t.final_status='Matched'),'mismatch',count(*) FILTER(WHERE t.final_status='Mismatch'),'high',count(*) FILTER(WHERE t.debit>=50000 OR t.credit>=100000),'first',min((t.finalized_at AT TIME ZONE 'Asia/Kolkata')::date),'last',max((t.finalized_at AT TIME ZONE 'Asia/Kolkata')::date)) FROM transactions t LEFT JOIN users u ON u.id=t.finalized_by WHERE true",
            );
            self.report_filter(&mut q, actor, &filter, report)?;
            q.push(" GROUP BY t.finalized_by,u.name,u.role ORDER BY u.name,t.finalized_by");
            let staff = rows(&mut q, &mut tx).await?;
            document.sections.push(Section::new(
                if report == "MPR" {
                    "3. Staff work"
                } else {
                    "Staff contribution"
                },
                &[
                    "Staff / role",
                    "Checked",
                    "Matched",
                    "Objections",
                    "High value",
                    "Activity dates",
                ],
                &[4, 2, 2, 3, 2, 5],
                staff
                    .iter()
                    .map(|r| {
                        vec![
                            format!("{}\n{}", value(r, "staff"), value(r, "role")),
                            value(r, "checked"),
                            value(r, "matched"),
                            value(r, "mismatch"),
                            value(r, "high"),
                            format!("{} to {}", value(r, "first"), value(r, "last")),
                        ]
                    })
                    .collect(),
            ));
            if report == "MPR" {
                document.notes.push(format!("4. Staff with finalized work: {}. Sanctioned staff strength is not configured.",staff.len()));
            }
        }
        if !matches!(report, "DPR" | "MPR") {
            let mut q = QueryBuilder::new(
                "SELECT jsonb_build_object('office',t.office_id || ' - ' || o.name,'count',count(*),'credit',sum(t.credit)::text,'debit',sum(t.debit)::text) FROM transactions t JOIN offices o ON o.id=t.office_id WHERE true",
            );
            self.report_filter(&mut q, actor, &filter, report)?;
            q.push(" GROUP BY t.office_id,o.name ORDER BY t.office_id");
            let office_totals = rows(&mut q, &mut tx).await?;
            document.sections.push(Section::new(
                "Office totals (complete result)",
                &["Office", "Transactions", "Credit INR", "Debit INR"],
                &[4, 2, 2, 2],
                office_totals
                    .iter()
                    .map(|r| cells(r, &["office", "count", "credit", "debit"]))
                    .collect(),
            ));
            for row in &detail {
                let office = format!(
                    "{} - {}",
                    value(row, "office_id"),
                    value(row, "office_name")
                );
                if document.sections.last().is_none_or(|s| s.title != office) {
                    document.sections.push(if report == "Daily Detail" {
                        Section::new(
                            &office,
                            &[
                                "Checked / staff",
                                "Report / transaction",
                                "Account / reference",
                                "Credit INR",
                                "Debit INR",
                                "Result / high value",
                                "Reason / notes",
                            ],
                            &[3, 3, 3, 4, 4, 3, 4],
                            vec![],
                        )
                    } else {
                        Section::new(
                            &office,
                            &[
                                "Report date",
                                "Transaction / reference",
                                "Account",
                                "Credit INR",
                                "Debit INR",
                                "Result",
                                "Reason / notes",
                            ],
                            &[2, 3, 3, 4, 4, 2, 4],
                            vec![],
                        )
                    });
                }
                let mut c = if report == "Daily Detail" {
                    vec![
                        format!(
                            "{}\n{} ({})",
                            value(row, "checked_at"),
                            value(row, "staff"),
                            value(row, "staff_role")
                        ),
                        format!(
                            "{}\n{}",
                            value(row, "report_date"),
                            value(row, "transaction_id")
                        ),
                        format!(
                            "{}\n{}",
                            value(row, "account_number"),
                            value(row, "reference_id")
                        ),
                    ]
                } else {
                    vec![
                        value(row, "report_date"),
                        format!(
                            "{}\n{}",
                            value(row, "transaction_id"),
                            value(row, "reference_id")
                        ),
                        value(row, "account_number"),
                    ]
                };
                c.extend([
                    value(row, "credit"),
                    value(row, "debit"),
                    if report == "Daily Detail" {
                        format!(
                            "{}\nHigh: {}",
                            value(row, "final_status"),
                            value(row, "high_value")
                        )
                    } else {
                        value(row, "final_status")
                    },
                    format!(
                        "{}\n{}",
                        value(row, "final_reason"),
                        value(row, "final_notes")
                    ),
                ]);
                document.sections.last_mut().unwrap().rows.push(c);
            }
            if !export && totals["total"].as_i64().unwrap_or(0) > 100 {
                document.notes.push("Transaction detail previews the first 100 rows. Totals cover the complete result.".into());
            }
        }
        document.notes.push(format!("Complete totals: {} transactions | Matched: {} | Objections: {} | Credit INR {} | Debit INR {}",value(&totals,"total"),value(&totals,"matched"),value(&totals,"mismatch"),value(&totals,"credit"),value(&totals,"debit")));
        if totals["total"] == 0 {
            document
                .notes
                .push("No finalized work / transactions match the selected filters.".into());
        }
        tx.commit().await.map_err(db_error)?;
        Ok(ReportData {
            totals,
            rows: detail,
            document,
            effective_filter: filter,
            preview_limit: 100,
        })
    }

    async fn objection_balances(
        &self,
        actor: &Actor,
        filter: &Filter,
        tx: &mut Transaction<'_, Postgres>,
        document: &mut Document,
    ) -> Result<()> {
        let start = date(filter.from_date.as_deref().unwrap())?;
        let end = date(filter.to_date.as_deref().unwrap())?;
        let mut q = QueryBuilder::new("WITH bounds AS (SELECT ");
        q.push_bind(start).push("::date AS start_date,").push_bind(end).push("::date AS end_date), scoped AS (SELECT i.id FROM incidents i JOIN transactions t ON t.id=i.transaction_id WHERE true");
        scope(&mut q, actor, "t.office_id");
        let mut without_dates = filter.clone();
        without_dates.from_date = None;
        without_dates.to_date = None;
        super::queries::filters(&mut q, &without_dates, "t.report_date")?;
        q.push(include_str!("objection_balances.sql"));
        let balances = rows(&mut q, tx).await?;
        document.sections.push(Section::new(
            "2. Irregularities",
            &[
                "Category",
                "Opening",
                "Raised / reopened",
                "Settled / closed",
                "Closing",
            ],
            &[3, 1, 2, 2, 1],
            balances
                .iter()
                .map(|r| cells(r, &["category", "opening", "raised", "settled", "closing"]))
                .collect(),
        ));
        document.sections.push(Section::new(
            "2a. Age of outstanding objections at period end",
            &["Category", "Under 90 days", "90-179 days", "180+ days"],
            &[3, 2, 2, 2],
            balances
                .iter()
                .map(|r| cells(r, &["category", "under90", "under180", "over180"]))
                .collect(),
        ));
        let unknown = balances
            .first()
            .and_then(|v| v["unknown"].as_i64())
            .unwrap_or(0);
        if unknown > 0 {
            document.notes.push(format!("History warning: {unknown} objection(s) lack a recorded creation event and are excluded from historical balances and ageing. Reconcile these records before using this report for an official return."));
        }
        document.notes.push("Objection balances follow recorded changes in India time. Reopening counts as raised; category transfers count as settlement in the old category and raising in the new. Age starts at the latest opening in each category. Staff work reflects the current final verification record.".into());
        Ok(())
    }
}
fn daily_register(filter: &Filter, days: &[Value]) -> Result<Section> {
    let start = date(filter.from_date.as_deref().unwrap())?;
    let end = date(filter.to_date.as_deref().unwrap())?;
    let rows = start
        .iter_days()
        .take_while(|d| *d <= end)
        .map(|day| {
            let d = day.to_string();
            let work = days
                .iter()
                .find(|r| r["date"] == d)
                .map(|r| {
                    format!(
                        "Checked {} vouchers - {} matched, {} objection(s).\n{}",
                        value(r, "checked"),
                        value(r, "matched"),
                        value(r, "mismatch"),
                        value(r, "staff")
                    )
                })
                .unwrap_or_default();
            vec![d, work, String::new(), String::new()]
        })
        .collect();
    Ok(Section::new(
        "",
        &["Date", "Work done", "Signature", "Remarks"],
        &[2, 6, 2, 2],
        rows,
    ))
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn register_includes_blank_days_and_bounds_period() {
        let f: Filter =
            serde_json::from_value(json!({"from_date":"2026-01-01","to_date":"2026-01-03"}))
                .unwrap();
        let s=daily_register(&f,&[json!({"date":"2026-01-02","checked":251,"matched":250,"mismatch":1,"staff":"अनिता"})]).unwrap();
        assert_eq!(s.rows.len(), 3);
        assert!(s.rows[0][1].is_empty());
        assert!(s.rows[1][1].contains("251"));
        assert!(s.rows[1][1].contains("अनिता"));
        let mut f = f;
        f.to_date = Some("2027-01-03".into());
        assert!(period(&f, "DPR").is_err());
    }
    #[tokio::test]
    #[ignore = "Requires DATABASE_URL; uses rollback-only temporary fixture tables"]
    async fn historical_balances_handle_reopening_transfers_scope_and_india_boundaries() {
        use sbco_domain::Role;
        use uuid::Uuid;
        let pool = sqlx::PgPool::connect(&std::env::var("DATABASE_URL").expect("DATABASE_URL"))
            .await
            .unwrap();
        let db = Database { pool };
        let mut tx = db.pool.begin().await.unwrap();
        sqlx::raw_sql("CREATE TEMP TABLE transactions(id uuid,office_id text); CREATE TEMP TABLE incidents(id uuid,transaction_id uuid); CREATE TEMP TABLE change_history(id bigserial,entity text,entity_id uuid,before_value jsonb,after_value jsonb,created_at timestamptz); CREATE TEMP TABLE pools(id uuid,pa_user uuid); CREATE TEMP TABLE pool_offices(pool_id uuid,office_id text);").execute(&mut *tx).await.unwrap();
        let actor = Actor {
            id: Uuid::new_v4(),
            name: "PA".into(),
            role: Role::Pa,
        };
        let pool_id = Uuid::new_v4();
        sqlx::query("INSERT INTO pools VALUES($1,$2)")
            .bind(pool_id)
            .bind(actor.id)
            .execute(&mut *tx)
            .await
            .unwrap();
        sqlx::query("INSERT INTO pool_offices VALUES($1,'A')")
            .bind(pool_id)
            .execute(&mut *tx)
            .await
            .unwrap();
        type State = (&'static str, &'static str);
        type Event = (&'static str, Option<State>, State);
        let events: Vec<(&str, Vec<Event>)> = vec![
            (
                "A",
                vec![
                    (
                        "2026-01-01T00:00:00+05:30",
                        None,
                        ("Open", "Voucher Follow-up"),
                    ),
                    (
                        "2026-02-05T00:00:00+05:30",
                        Some(("Open", "Voucher Follow-up")),
                        ("Complied", "Voucher Follow-up"),
                    ),
                    (
                        "2026-02-10T00:00:00+05:30",
                        Some(("Complied", "Voucher Follow-up")),
                        ("Open", "Voucher Follow-up"),
                    ),
                    (
                        "2026-03-01T00:00:00+05:30",
                        Some(("Open", "Voucher Follow-up")),
                        ("Closed", "Voucher Follow-up"),
                    ),
                ],
            ),
            (
                "A",
                vec![
                    ("2026-02-01T00:00:00+05:30", None, ("Open", "MAP")),
                    (
                        "2026-02-15T00:00:00+05:30",
                        Some(("Open", "MAP")),
                        ("Open", "Voucher Follow-up"),
                    ),
                    (
                        "2026-02-20T00:00:00+05:30",
                        Some(("Open", "Voucher Follow-up")),
                        ("Closed", "Voucher Follow-up"),
                    ),
                ],
            ),
            (
                "A",
                vec![("2025-08-01T00:00:00+05:30", None, ("Open", "MAP"))],
            ),
            (
                "A",
                vec![("2026-01-31T19:00:00Z", None, ("Open", "Voucher Follow-up"))],
            ),
            ("A", vec![("2026-02-28T19:00:00Z", None, ("Open", "MAP"))]),
            (
                "A",
                vec![(
                    "2026-02-01T00:00:00+05:30",
                    Some(("Open", "MAP")),
                    ("Closed", "MAP"),
                )],
            ),
            (
                "B",
                vec![("2026-02-01T00:00:00+05:30", None, ("Open", "MAP"))],
            ),
        ];
        for (office, events) in events {
            let id = Uuid::new_v4();
            sqlx::query("INSERT INTO transactions VALUES($1,$2)")
                .bind(id)
                .bind(office)
                .execute(&mut *tx)
                .await
                .unwrap();
            sqlx::query("INSERT INTO incidents VALUES($1,$1)")
                .bind(id)
                .execute(&mut *tx)
                .await
                .unwrap();
            for (when, before, after) in events {
                let snapshot =
                    |(status, kind): (&str, &str)| json!({"status":status,"incident_type":kind});
                sqlx::query("INSERT INTO change_history(entity,entity_id,before_value,after_value,created_at) VALUES('incidents',$1,$2,$3,$4)")
                    .bind(id).bind(before.map(snapshot)).bind(snapshot(after)).bind(chrono::DateTime::parse_from_rfc3339(when).unwrap()).execute(&mut *tx).await.unwrap();
            }
        }
        let f = Filter {
            from_date: Some("2026-02-01".into()),
            to_date: Some("2026-02-28".into()),
            ..Default::default()
        };
        let mut doc = Document {
            title: "".into(),
            subtitle: "".into(),
            landscape: false,
            sections: vec![],
            notes: vec![],
            signatory: "".into(),
            designation: "".into(),
        };
        db.objection_balances(&actor, &f, &mut tx, &mut doc)
            .await
            .unwrap();
        assert_eq!(
            doc.sections[0].rows,
            vec![
                vec!["All", "2", "3", "2", "3"],
                vec!["MAP", "1", "1", "1", "1"],
                vec!["Voucher Follow-up", "1", "3", "2", "2"]
            ]
        );
        assert_eq!(doc.sections[1].rows[0], vec!["All", "2", "0", "1"]);
        assert!(doc.notes[0].contains("1 objection(s)"));
        tx.rollback().await.unwrap();
    }
}
