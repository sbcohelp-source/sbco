use super::{Database, auth::hash, db_error, excel};
use sbco_domain::{Error, Result, money};
use sqlx::Row;
use uuid::Uuid;

impl Database {
    pub async fn tick(&self) -> Result<bool> {
        // A repeatedly interrupted job must become retryable instead of remaining Processing forever.
        sqlx::query("WITH expired AS (UPDATE jobs SET status='Failed',error='Retry limit reached after interrupted processing',lease_until=NULL WHERE status='Processing' AND lease_until<now() AND attempts>=5 RETURNING import_id) UPDATE imports SET status='Failed',error='Retry limit reached after interrupted processing',updated_at=now() WHERE id IN (SELECT import_id FROM expired)")
            .execute(&self.pool).await.map_err(db_error)?;
        let lease = Uuid::new_v4();
        let job=sqlx::query("UPDATE jobs SET status='Processing',lease_id=$1,lease_until=now()+interval '5 minutes',attempts=attempts+1 WHERE id=(SELECT id FROM jobs WHERE (status='Queued' OR (status='Processing' AND lease_until<now())) AND attempts<5 ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING id,import_id")
            .bind(lease).fetch_optional(&self.pool).await.map_err(db_error)?;
        let Some(job) = job else { return Ok(false) };
        let id: Uuid = job.get("id");
        let import: Uuid = job.get("import_id");
        let result = self.process_import(import, id, lease).await;
        if let Err(e) = result {
            let mut tx = self.pool.begin().await.map_err(db_error)?;
            let updated=sqlx::query("UPDATE jobs SET status='Failed',error=$3,lease_until=NULL WHERE id=$1 AND lease_id=$2").bind(id).bind(lease).bind(e.to_string()).execute(&mut *tx).await.map_err(db_error)?.rows_affected();
            if updated > 0 {
                sqlx::query(
                    "UPDATE imports SET status='Failed',error=$2,updated_at=now() WHERE id=$1",
                )
                .bind(import)
                .bind(e.to_string())
                .execute(&mut *tx)
                .await
                .map_err(db_error)?;
            }
            tx.commit().await.map_err(db_error)?;
        }
        Ok(true)
    }
    async fn process_import(&self, import: Uuid, job: Uuid, lease: Uuid) -> Result<()> {
        let content: Vec<u8> = sqlx::query_scalar("SELECT content FROM imports WHERE id=$1")
            .bind(import)
            .fetch_one(&self.pool)
            .await
            .map_err(db_error)?;
        sqlx::query("UPDATE imports SET status='Processing',error=NULL WHERE id=$1")
            .bind(import)
            .execute(&self.pool)
            .await
            .map_err(db_error)?;
        let book = tokio::task::spawn_blocking(move || excel::parse(content))
            .await
            .map_err(|_| Error::Internal)??;
        for chunk in book.rows.chunks(100) {
            let mut tx = self.pool.begin().await.map_err(db_error)?;
            // Lock and validate together: an expired worker cannot commit after another worker claims it.
            let active = sqlx::query_scalar::<_, Uuid>(
                "SELECT id FROM jobs WHERE id=$1 AND lease_id=$2 AND status='Processing' FOR UPDATE",
            ).bind(job).bind(lease).fetch_optional(&mut *tx).await.map_err(db_error)?;
            if active.is_none() {
                return Err(Error::Conflict("Import lease was replaced".into()));
            }
            if let Some((id, name)) = &book.parent {
                sqlx::query(
                    "INSERT INTO offices VALUES($1,$2,'SO',NULL) ON CONFLICT(id) DO NOTHING",
                )
                .bind(id)
                .bind(name)
                .execute(&mut *tx)
                .await
                .map_err(db_error)?;
            }
            sqlx::query("INSERT INTO offices VALUES($1,$2,$3,$4) ON CONFLICT(id) DO NOTHING")
                .bind(&book.office)
                .bind(&book.office_name)
                .bind(if book.report_type == "SO" { "SO" } else { "BO" })
                .bind(book.parent.as_ref().map(|p| &p.0))
                .execute(&mut *tx)
                .await
                .map_err(db_error)?;
            for entry in chunk {
                let canonical = serde_json::json!([
                    "v1",
                    book.office,
                    book.report_type,
                    book.date,
                    entry.value_date,
                    entry.account,
                    entry.scheme,
                    entry.transaction_id,
                    entry.reference,
                    entry.user,
                    entry.kind,
                    entry.description,
                    entry.credit,
                    entry.debit
                ]);
                let fingerprint = hash(canonical.to_string().to_lowercase().as_bytes());
                let id = Uuid::new_v4();
                let inserted=sqlx::query("INSERT INTO transactions(id,office_id,report_type,report_date,value_date,account_number,scheme,transaction_id,reference_id,entry_user_id,transaction_type,description,credit,debit,agent,rd_default,import_id,source_sheet,source_row,fingerprint) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20) ON CONFLICT DO NOTHING")
                    .bind(id).bind(&book.office).bind(&book.report_type).bind(book.date).bind(entry.value_date).bind(&entry.account).bind(&entry.scheme).bind(&entry.transaction_id).bind(&entry.reference).bind(&entry.user).bind(&entry.kind).bind(&entry.description).bind(money(&entry.credit)?).bind(money(&entry.debit)?).bind(entry.agent).bind(entry.rd_default).bind(import).bind(&book.sheet).bind(entry.row).bind(&fingerprint).execute(&mut *tx).await.map_err(db_error)?.rows_affected();
                if inserted == 0 {
                    let existing = sqlx::query(
                        "SELECT id,import_id,source_row FROM transactions WHERE fingerprint=$1",
                    )
                    .bind(fingerprint)
                    .fetch_optional(&mut *tx)
                    .await
                    .map_err(db_error)?;
                    if let Some(existing) = existing
                        && (existing.get::<Uuid, _>("import_id") != import
                            || existing.get::<i32, _>("source_row") != entry.row)
                    {
                        sqlx::query("INSERT INTO import_duplicates VALUES($1,$2,$3,$4) ON CONFLICT(import_id,source_row) DO NOTHING").bind(Uuid::new_v4()).bind(import).bind(entry.row).bind(existing.get::<Uuid,_>("id")).execute(&mut *tx).await.map_err(db_error)?;
                    }
                }
            }
            sqlx::query("UPDATE jobs SET lease_until=now()+interval '5 minutes' WHERE id=$1 AND lease_id=$2").bind(job).bind(lease).execute(&mut *tx).await.map_err(db_error)?;
            sqlx::query("UPDATE imports SET total=$2,inserted=(SELECT count(*) FROM transactions WHERE import_id=$1),duplicates=(SELECT count(*) FROM import_duplicates WHERE import_id=$1),updated_at=now() WHERE id=$1").bind(import).bind(book.rows.len() as i32).execute(&mut *tx).await.map_err(db_error)?;
            tx.commit().await.map_err(db_error)?;
        }
        let mut tx = self.pool.begin().await.map_err(db_error)?;
        let changed = sqlx::query(
            "UPDATE jobs SET status='Completed',lease_until=NULL WHERE id=$1 AND lease_id=$2",
        )
        .bind(job)
        .bind(lease)
        .execute(&mut *tx)
        .await
        .map_err(db_error)?
        .rows_affected();
        if changed > 0 {
            sqlx::query("UPDATE imports SET status=$2,total=$3,updated_at=now() WHERE id=$1")
                .bind(import)
                .bind(if book.rows.is_empty() {
                    "No Data"
                } else {
                    "Completed"
                })
                .bind(book.rows.len() as i32)
                .execute(&mut *tx)
                .await
                .map_err(db_error)?;
            sqlx::query(
                "INSERT INTO audit(action,entity_id,detail) VALUES('import_completed',$1,$2)",
            )
            .bind(import.to_string())
            .bind(serde_json::json!({"rows":book.rows.len()}))
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;
        }
        tx.commit().await.map_err(db_error)
    }
    pub async fn mark_overdue(&self) -> Result<()> {
        let mut tx = self.pool.begin().await.map_err(db_error)?;
        sqlx::query("UPDATE incidents SET status='Overdue' WHERE status IN ('Issued','Partially Complied') AND due_date<(now() AT TIME ZONE 'Asia/Kolkata')::date").execute(&mut *tx).await.map_err(db_error)?;
        sqlx::query("UPDATE letters SET status='Overdue' WHERE status IN ('Issued','Partially Complied') AND due_date<(now() AT TIME ZONE 'Asia/Kolkata')::date").execute(&mut *tx).await.map_err(db_error)?;
        tx.commit().await.map_err(db_error)
    }
}
