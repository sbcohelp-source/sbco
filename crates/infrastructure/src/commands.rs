use super::{
    Database,
    auth::{hash, password_hash, password_matches},
    db_error,
    queries::{assert_letter, assert_office, locked_transaction},
    role,
};
use base64::{Engine, engine::general_purpose::STANDARD};
use chrono::NaiveDate;
use rand::Rng;
use rust_decimal::Decimal;
use sbco_contracts::{Command, CommandRequest};
use sbco_domain::{
    Actor, Error, Result, Role, Status, ensure_revision, primary_outcome, validate_decision,
    validate_review,
};
use serde_json::{Value, json};
use sqlx::{Postgres, Row, Transaction};
use uuid::Uuid;
type Tx<'a> = Transaction<'a, Postgres>;
fn required(s: &str, field: &str) -> Result<()> {
    if s.trim().is_empty() || s.len() > 4096 {
        Err(Error::Validation(format!(
            "{field} is required and must be at most 4096 bytes"
        )))
    } else {
        Ok(())
    }
}
fn date(s: &str) -> Result<NaiveDate> {
    NaiveDate::parse_from_str(s, "%Y-%m-%d")
        .map_err(|_| Error::Validation("Invalid due date".into()))
}

impl Database {
    pub(crate) async fn execute(&self, actor: &Actor, request: CommandRequest) -> Result<Value> {
        let bytes = serde_json::to_vec(&request.command).map_err(|_| Error::Internal)?;
        let digest = hash(&bytes);
        let action = serde_json::to_value(&request.command).map_err(|_| Error::Internal)?["kind"]
            .as_str()
            .unwrap_or("unknown")
            .to_owned();
        let mut tx = self.pool.begin().await.map_err(db_error)?;
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))")
            .bind(request.request_id.to_string())
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;
        if let Some(r) = sqlx::query(
            "SELECT actor_id,command_hash,result FROM command_receipts WHERE request_id=$1",
        )
        .bind(request.request_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_error)?
        {
            if r.get::<Uuid, _>("actor_id") != actor.id
                || r.get::<String, _>("command_hash") != digest
            {
                return Err(Error::Conflict(
                    "Request identifier was reused with different content".into(),
                ));
            }
            return Ok(r.get("result"));
        }
        sqlx::query(
            "SELECT set_config('sbco.actor_id',$1,true),set_config('sbco.request_id',$2,true)",
        )
        .bind(actor.id.to_string())
        .bind(request.request_id.to_string())
        .execute(&mut *tx)
        .await
        .map_err(db_error)?;
        let mut detail = serde_json::to_value(&request.command).map_err(|_| Error::Internal)?;
        if let Some(fields) = detail.as_object_mut() {
            for secret in [
                "password",
                "current_password",
                "new_password",
                "content_base64",
            ] {
                fields.remove(secret);
            }
        }
        let result = self.mutate(&mut tx, actor, request.command).await?;
        // Audit references/results, never passwords, raw files, tokens or full request payloads.
        sqlx::query("INSERT INTO audit(actor_id,action,entity_id,detail) VALUES($1,$2,$3,$4)")
            .bind(actor.id)
            .bind(&action)
            .bind(result["id"].as_str())
            .bind(json!({"request": detail, "result": result, "request_id":request.request_id}))
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;
        sqlx::query("INSERT INTO command_receipts VALUES($1,$2,$3,$4,now())")
            .bind(request.request_id)
            .bind(actor.id)
            .bind(digest)
            .bind(&result)
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;
        tx.commit().await.map_err(db_error)?;
        Ok(result)
    }
    async fn mutate(&self, tx: &mut Tx<'_>, actor: &Actor, cmd: Command) -> Result<Value> {
        match cmd {
            Command::SaveOnboarding { step, completed } => {
                super::onboarding::save(tx, actor, &step, completed).await
            }
            Command::ImportSetup {
                filename,
                content_base64,
                preview,
            } => {
                actor.require_admin()?;
                if !filename.to_lowercase().ends_with(".xlsx") || content_base64.len() > 7_000_000 {
                    return Err(Error::Validation(
                        "Choose a setup XLSX workbook up to 5 MB".into(),
                    ));
                }
                let content = STANDARD
                    .decode(content_base64)
                    .map_err(|_| Error::Validation("Invalid file encoding".into()))?;
                if content.len() > 5_000_000 {
                    return Err(Error::Validation("Setup workbook exceeds 5 MB".into()));
                }
                let setup =
                    tokio::task::spawn_blocking(move || super::setup_import::parse(content))
                        .await
                        .map_err(|_| Error::Internal)??;
                super::setup_import::apply(tx, setup, preview).await
            }
            Command::CreateUser {
                name,
                email,
                password,
                role: role_name,
            } => {
                actor.require_admin()?;
                required(&name, "Name")?;
                required(&email, "Email")?;
                role(&role_name)?;
                if !email.contains('@') {
                    return Err(Error::Validation("Enter an email address".into()));
                }
                let password = password_hash(password).await?;
                let id = Uuid::new_v4();
                sqlx::query(
                    "INSERT INTO users(id,name,email,password_hash,role) VALUES($1,$2,$3,$4,$5)",
                )
                .bind(id)
                .bind(name.trim())
                .bind(email.trim().to_lowercase())
                .bind(password)
                .bind(role_name)
                .execute(&mut **tx)
                .await
                .map_err(db_error)?;
                Ok(json!({"id":id}))
            }
            Command::UpdateUser {
                user_id,
                name,
                role: role_name,
                active,
            } => {
                actor.require_admin()?;
                required(&name, "Name")?;
                let next_role = role(&role_name)?;
                sqlx::query("SELECT pg_advisory_xact_lock(741294)")
                    .execute(&mut **tx)
                    .await
                    .map_err(db_error)?;
                let current = sqlx::query("SELECT role,active FROM users WHERE id=$1 FOR UPDATE")
                    .bind(user_id)
                    .fetch_optional(&mut **tx)
                    .await
                    .map_err(db_error)?
                    .ok_or(Error::NotFound)?;
                if current.get::<String, _>("role") == "Administrator"
                    && current.get::<bool, _>("active")
                    && (!active || next_role != Role::Administrator)
                {
                    let count: i64 = sqlx::query_scalar(
                        "SELECT count(*) FROM users WHERE role='Administrator' AND active",
                    )
                    .fetch_one(&mut **tx)
                    .await
                    .map_err(db_error)?;
                    if count <= 1 {
                        return Err(Error::Validation(
                            "Keep at least one active administrator".into(),
                        ));
                    }
                }
                sqlx::query("UPDATE users SET name=$2,role=$3,active=$4 WHERE id=$1")
                    .bind(user_id)
                    .bind(name.trim())
                    .bind(role_name)
                    .bind(active)
                    .execute(&mut **tx)
                    .await
                    .map_err(db_error)?;
                sqlx::query("DELETE FROM sessions WHERE user_id=$1")
                    .bind(user_id)
                    .execute(&mut **tx)
                    .await
                    .map_err(db_error)?;
                if !active || next_role != Role::Pa {
                    sqlx::query("UPDATE pools SET pa_user=NULL WHERE pa_user=$1")
                        .bind(user_id)
                        .execute(&mut **tx)
                        .await
                        .map_err(db_error)?;
                }
                Ok(json!({"id":user_id,"sessions_revoked":true}))
            }
            Command::ChangePassword {
                current_password,
                new_password,
            } => {
                let old: String =
                    sqlx::query_scalar("SELECT password_hash FROM users WHERE id=$1 FOR UPDATE")
                        .bind(actor.id)
                        .fetch_one(&mut **tx)
                        .await
                        .map_err(db_error)?;
                if !password_matches(current_password, old).await {
                    return Err(Error::Unauthorized);
                }
                set_password(tx, actor.id, new_password).await?;
                Ok(json!({"id":actor.id,"signed_out":true}))
            }
            Command::ResetPassword { user_id, password } => {
                actor.require_admin()?;
                set_password(tx, user_id, password).await?;
                Ok(json!({"id":user_id,"sessions_revoked":true}))
            }
            Command::SaveOffice {
                id,
                name,
                office_type,
                parent_id,
            } => {
                actor.require_manager()?;
                required(&id, "Office ID")?;
                required(&name, "Office name")?;
                if !matches!(office_type.as_str(), "SO" | "BO") {
                    return Err(Error::Validation("Office type must be SO or BO".into()));
                }
                if let Some(parent) = &parent_id {
                    let valid: bool = sqlx::query_scalar(
                        "SELECT EXISTS(SELECT 1 FROM offices WHERE id=$1 AND office_type='SO')",
                    )
                    .bind(parent)
                    .fetch_one(&mut **tx)
                    .await
                    .map_err(db_error)?;
                    if !valid || office_type != "BO" {
                        return Err(Error::Validation(
                            "A BO parent must be an existing SO".into(),
                        ));
                    }
                }
                sqlx::query("INSERT INTO offices VALUES($1,$2,$3,$4) ON CONFLICT(id) DO UPDATE SET name=excluded.name,office_type=excluded.office_type,parent_id=excluded.parent_id").bind(&id).bind(name).bind(office_type).bind(parent_id).execute(&mut **tx).await.map_err(db_error)?;
                Ok(json!({"id":id}))
            }
            Command::SavePool {
                id,
                name,
                offices,
                pa_user,
                random_percent,
            } => {
                actor.require_manager()?;
                required(&name, "Pool name")?;
                if random_percent > 100 || offices.is_empty() {
                    return Err(Error::Validation(
                        "Select offices and a sampling percentage from 0 to 100".into(),
                    ));
                }
                if let Some(pa) = pa_user {
                    let valid: bool = sqlx::query_scalar(
                        "SELECT EXISTS(SELECT 1 FROM users WHERE id=$1 AND role='Pa' AND active)",
                    )
                    .bind(pa)
                    .fetch_one(&mut **tx)
                    .await
                    .map_err(db_error)?;
                    if !valid {
                        return Err(Error::Validation("Assign an active PA user".into()));
                    }
                }
                let id = id.unwrap_or_else(Uuid::new_v4);
                sqlx::query("INSERT INTO pools VALUES($1,$2,$3,$4) ON CONFLICT(id) DO UPDATE SET name=excluded.name,pa_user=excluded.pa_user,random_percent=excluded.random_percent").bind(id).bind(name).bind(pa_user).bind(random_percent as i32).execute(&mut **tx).await.map_err(db_error)?;
                sqlx::query("DELETE FROM pool_offices WHERE pool_id=$1")
                    .bind(id)
                    .execute(&mut **tx)
                    .await
                    .map_err(db_error)?;
                for office in offices {
                    sqlx::query("INSERT INTO pool_offices VALUES($1,$2)")
                        .bind(office)
                        .bind(id)
                        .execute(&mut **tx)
                        .await
                        .map_err(db_error)?;
                }
                Ok(json!({"id":id}))
            }
            Command::Import {
                filename,
                content_base64,
            } => {
                actor.require_manager()?;
                required(&filename, "Filename")?;
                let filename = filename
                    .rsplit(['/', '\\'])
                    .next()
                    .unwrap_or("workbook")
                    .to_owned();
                if ![".xls", ".xlsx", ".xlsm"]
                    .iter()
                    .any(|ext| filename.to_lowercase().ends_with(ext))
                {
                    return Err(Error::Validation(
                        "Choose an XLS, XLSX or XLSM workbook".into(),
                    ));
                }
                if content_base64.len() > 28_000_000 {
                    return Err(Error::Validation("Workbook exceeds 20 MB".into()));
                }
                let content = STANDARD
                    .decode(content_base64)
                    .map_err(|_| Error::Validation("Invalid file encoding".into()))?;
                if content.len() > 20_000_000 {
                    return Err(Error::Validation("Workbook exceeds 20 MB".into()));
                }
                let digest = hash(&content);
                if let Some(id) =
                    sqlx::query_scalar::<_, Uuid>("SELECT id FROM imports WHERE file_hash=$1")
                        .bind(&digest)
                        .fetch_optional(&mut **tx)
                        .await
                        .map_err(db_error)?
                {
                    return Ok(json!({"id":id,"duplicate":true}));
                }
                let id = Uuid::new_v4();
                let inserted = sqlx::query_scalar::<_, Uuid>("INSERT INTO imports(id,filename,file_hash,content,imported_by) VALUES($1,$2,$3,$4,$5) ON CONFLICT(file_hash) DO NOTHING RETURNING id")
                    .bind(id).bind(filename).bind(&digest).bind(content).bind(actor.id)
                    .fetch_optional(&mut **tx).await.map_err(db_error)?;
                if inserted.is_none() {
                    // A concurrent upload may have committed after the earlier lookup.
                    // Return its batch without adding a second processing job.
                    let existing =
                        sqlx::query_scalar::<_, Uuid>("SELECT id FROM imports WHERE file_hash=$1")
                            .bind(&digest)
                            .fetch_one(&mut **tx)
                            .await
                            .map_err(db_error)?;
                    return Ok(json!({"id":existing,"duplicate":true}));
                }
                sqlx::query("INSERT INTO jobs(id,import_id) VALUES($1,$2)")
                    .bind(Uuid::new_v4())
                    .bind(id)
                    .execute(&mut **tx)
                    .await
                    .map_err(db_error)?;
                Ok(json!({"id":id,"status":"Queued"}))
            }
            Command::RetryImport { id } => {
                actor.require_manager()?;
                let count=sqlx::query("UPDATE jobs SET status='Queued',lease_id=NULL,lease_until=NULL,error=NULL,attempts=0 WHERE import_id=$1 AND status='Failed'").bind(id).execute(&mut **tx).await.map_err(db_error)?.rows_affected();
                if count == 0 {
                    return Err(Error::Conflict("Only failed imports can be retried".into()));
                }
                sqlx::query("UPDATE imports SET status='Queued',error=NULL WHERE id=$1")
                    .bind(id)
                    .execute(&mut **tx)
                    .await
                    .map_err(db_error)?;
                Ok(json!({"id":id}))
            }
            Command::Verify {
                id,
                revision,
                status,
                reason,
                notes,
            } => {
                if actor.role != Role::Pa {
                    return Err(Error::Forbidden);
                }
                let row = locked_transaction(tx, actor, id).await?;
                ensure_revision(row.get("revision"), revision)?;
                if row.get::<String, _>("primary_status") != "Pending" {
                    return Err(Error::Conflict(
                        "Request a correction for an already verified transaction".into(),
                    ));
                }
                let status = Status::parse(&status)?;
                validate_decision(&status, &reason)?;
                check_reason(tx, &status, &reason).await?;
                apply_primary(tx, actor, &row, status, &reason, &notes, revision).await?;
                Ok(json!({"id":id,"revision":revision,"status":"Verified"}))
            }
            Command::Reverify {
                id,
                revision,
                status,
                reason,
                notes,
            } => {
                actor.require_manager()?;
                let review = sqlx::query("SELECT * FROM reviews WHERE id=$1 FOR UPDATE")
                    .bind(id)
                    .fetch_optional(&mut **tx)
                    .await
                    .map_err(db_error)?
                    .ok_or(Error::NotFound)?;
                let tid: Uuid = review.get("transaction_id");
                let row = locked_transaction(tx, actor, tid).await?;
                ensure_revision(row.get("revision"), revision)?;
                ensure_revision(review.get("revision"), revision)?;
                if review.get::<String, _>("status") != "Pending" {
                    return Err(Error::Conflict("Review already completed".into()));
                }
                let status = Status::parse(&status)?;
                validate_decision(&status, &reason)?;
                validate_review(review.get("pa_status"), &status, &notes)?;
                check_reason(tx, &status, &reason).await?;
                let review_status = if review.get::<String, _>("pa_status") == status.label() {
                    "Confirmed"
                } else {
                    "Disagreement"
                };
                sqlx::query("UPDATE reviews SET status=$2,supervisor_status=$3,reason=$4,notes=$5,reviewed_by=$6,reviewed_at=now() WHERE id=$1").bind(id).bind(review_status).bind(status.label()).bind(&reason).bind(&notes).bind(actor.id).execute(&mut **tx).await.map_err(db_error)?;
                sqlx::query("UPDATE transactions SET final_status=$2,final_reason=$3,final_notes=$4,finalized_by=$5,finalized_at=now() WHERE id=$1").bind(tid).bind(status.label()).bind(if status==Status::Mismatch{&reason}else{""}).bind(notes).bind(actor.id).execute(&mut **tx).await.map_err(db_error)?;
                sync_incident(tx, actor, tid, &status, &reason).await?;
                Ok(json!({"id":id,"status":review_status}))
            }
            Command::RequestCorrection {
                id,
                revision,
                status,
                reason,
                notes,
                request_reason,
            } => {
                let row = locked_transaction(tx, actor, id).await?;
                ensure_revision(row.get("revision"), revision)?;
                required(&request_reason, "Correction explanation")?;
                if row.get::<String, _>("primary_status") == "Pending" {
                    return Err(Error::Conflict(
                        "Verify pending transactions directly".into(),
                    ));
                }
                let status = Status::parse(&status)?;
                if status != Status::Pending {
                    validate_decision(&status, &reason)?;
                    check_reason(tx, &status, &reason).await?;
                }
                let cid = Uuid::new_v4();
                sqlx::query("INSERT INTO corrections(id,transaction_id,revision,proposed_status,reason,notes,request_reason,requested_by) VALUES($1,$2,$3,$4,$5,$6,$7,$8)").bind(cid).bind(id).bind(revision).bind(status.label()).bind(reason).bind(notes).bind(request_reason).bind(actor.id).execute(&mut **tx).await.map_err(db_error)?;
                Ok(json!({"id":cid}))
            }
            Command::ReviewCorrection { id, approve, notes } => {
                actor.require_manager()?;
                if !approve {
                    required(&notes, "Rejection explanation")?;
                }
                let c = sqlx::query("SELECT * FROM corrections WHERE id=$1 FOR UPDATE")
                    .bind(id)
                    .fetch_optional(&mut **tx)
                    .await
                    .map_err(db_error)?
                    .ok_or(Error::NotFound)?;
                if c.get::<String, _>("status") != "Pending Approval" {
                    return Err(Error::Conflict("Correction already reviewed".into()));
                }
                if approve {
                    let tid = c.get("transaction_id");
                    let row = locked_transaction(tx, actor, tid).await?;
                    ensure_revision(row.get("revision"), c.get("revision"))?;
                    sqlx::query("UPDATE reviews SET status='Superseded' WHERE transaction_id=$1 AND status='Pending'").bind(tid).execute(&mut **tx).await.map_err(db_error)?;
                    let status = Status::parse(c.get("proposed_status"))?;
                    let requester = Actor {
                        id: c.get("requested_by"),
                        name: String::new(),
                        role: Role::Pa,
                    };
                    apply_primary(
                        tx,
                        &requester,
                        &row,
                        status,
                        c.get("reason"),
                        c.get("notes"),
                        row.get::<i32, _>("revision") + 1,
                    )
                    .await?;
                }
                let status = if approve { "Approved" } else { "Rejected" };
                sqlx::query("UPDATE corrections SET status=$2,reviewed_by=$3,reviewed_at=now(),review_notes=$4 WHERE id=$1").bind(id).bind(status).bind(actor.id).bind(notes).execute(&mut **tx).await.map_err(db_error)?;
                Ok(json!({"id":id,"status":status}))
            }
            Command::CreateLetter {
                incident_ids,
                due_date,
            } => create_letter(tx, actor, incident_ids, date(&due_date)?, None).await,
            Command::CreateReminder {
                letter_id,
                due_date,
            } => {
                let letter = sqlx::query("SELECT * FROM letters WHERE id=$1 FOR UPDATE")
                    .bind(letter_id)
                    .fetch_optional(&mut **tx)
                    .await
                    .map_err(db_error)?
                    .ok_or(Error::NotFound)?;
                assert_letter(tx, actor, letter.get("id")).await?;
                if letter
                    .get::<Option<chrono::DateTime<chrono::Utc>>, _>("issued_at")
                    .is_none()
                {
                    return Err(Error::Conflict("Issue the original letter first".into()));
                }
                let ids=sqlx::query_scalar("SELECT i.id FROM incidents i JOIN letter_items li ON li.incident_id=i.id WHERE li.letter_id=$1 AND i.status NOT IN ('Closed','Complied')").bind(letter_id).fetch_all(&mut **tx).await.map_err(db_error)?;
                let root: Uuid = letter
                    .get::<Option<Uuid>, _>("parent_id")
                    .unwrap_or(letter_id);
                create_letter(tx, actor, ids, date(&due_date)?, Some(root)).await
            }
            Command::IssueLetter { id } => {
                let letter = sqlx::query("SELECT * FROM letters WHERE id=$1 FOR UPDATE")
                    .bind(id)
                    .fetch_optional(&mut **tx)
                    .await
                    .map_err(db_error)?
                    .ok_or(Error::NotFound)?;
                assert_letter(tx, actor, letter.get("id")).await?;
                if letter.get::<String, _>("status") != "Draft" {
                    return Err(Error::Conflict("Only draft letters can be issued".into()));
                }
                sqlx::query("UPDATE letters SET status='Issued',issued_by=$2,issued_at=now(),template_version=2 WHERE id=$1").bind(id).bind(actor.id).execute(&mut **tx).await.map_err(db_error)?;
                let pdf = super::pdf::letter_pdf(tx, id).await?;
                sqlx::query("UPDATE letters SET status='Issued',issued_by=$2,issued_at=now(),pdf=$3,pdf_hash=$4 WHERE id=$1").bind(id).bind(actor.id).bind(&pdf).bind(hash(&pdf)).execute(&mut **tx).await.map_err(db_error)?;
                sqlx::query("UPDATE incidents SET status='Issued',due_date=$2 WHERE id IN (SELECT incident_id FROM letter_items WHERE letter_id=$1) AND status NOT IN ('Closed','Complied')").bind(id).bind(letter.get::<NaiveDate,_>("due_date")).execute(&mut **tx).await.map_err(db_error)?;
                Ok(json!({"id":id,"status":"Issued"}))
            }
            Command::Comply {
                id,
                reference,
                notes,
            } => {
                required(&reference, "Reply/voucher reference")?;
                let row =
                    sqlx::query("SELECT office_id,status FROM incidents WHERE id=$1 FOR UPDATE")
                        .bind(id)
                        .fetch_optional(&mut **tx)
                        .await
                        .map_err(db_error)?
                        .ok_or(Error::NotFound)?;
                assert_office(tx, actor, row.get("office_id")).await?;
                if matches!(row.get::<&str, _>("status"), "Closed" | "Complied") {
                    return Err(Error::Conflict("Compliance already recorded".into()));
                }
                sqlx::query("UPDATE incidents SET status='Complied',compliance_reference=$2,compliance_notes=$3,complied_by=$4,complied_at=now() WHERE id=$1").bind(id).bind(reference).bind(notes).bind(actor.id).execute(&mut **tx).await.map_err(db_error)?;
                rollup_letters(tx).await?;
                Ok(json!({"id":id,"status":"Complied"}))
            }
            Command::SaveSettings {
                random_percent,
                reminder_days,
                signatory,
                designation,
                reasons,
            } => {
                actor.require_manager()?;
                if random_percent > 100
                    || reminder_days == 0
                    || reminder_days > 365
                    || reasons.is_empty()
                    || reasons.iter().any(|r| r.trim().is_empty())
                {
                    return Err(Error::Validation(
                        "Provide reasons, a 0–100 percentage and 1–365 reminder days".into(),
                    ));
                }
                let value = json!({"random_percent":random_percent,"reminder_days":reminder_days,"signatory":signatory,"designation":designation,"reasons":reasons});
                sqlx::query("UPDATE settings SET value=$1")
                    .bind(value)
                    .execute(&mut **tx)
                    .await
                    .map_err(db_error)?;
                Ok(json!({"saved":true}))
            }
        }
    }
}
async fn set_password(tx: &mut Tx<'_>, id: Uuid, password: String) -> Result<()> {
    let hash = password_hash(password).await?;
    let count = sqlx::query("UPDATE users SET password_hash=$2 WHERE id=$1")
        .bind(id)
        .bind(hash)
        .execute(&mut **tx)
        .await
        .map_err(db_error)?
        .rows_affected();
    if count == 0 {
        return Err(Error::NotFound);
    }
    sqlx::query("DELETE FROM sessions WHERE user_id=$1")
        .bind(id)
        .execute(&mut **tx)
        .await
        .map_err(db_error)?;
    Ok(())
}
async fn check_reason(tx: &mut Tx<'_>, status: &Status, reason: &str) -> Result<()> {
    if *status != Status::Mismatch {
        return Ok(());
    }
    let exists: bool = sqlx::query_scalar("SELECT value->'reasons' ? $1 FROM settings")
        .bind(reason)
        .fetch_one(&mut **tx)
        .await
        .map_err(db_error)?;
    if exists {
        Ok(())
    } else {
        Err(Error::Validation(
            "Choose a configured mismatch reason".into(),
        ))
    }
}
pub(crate) async fn apply_primary(
    tx: &mut Tx<'_>,
    actor: &Actor,
    row: &sqlx::postgres::PgRow,
    status: Status,
    reason: &str,
    notes: &str,
    revision: i32,
) -> Result<()> {
    let id: Uuid = row.get("id");
    let percentage:Option<i32>=sqlx::query_scalar("SELECT p.random_percent FROM pools p JOIN pool_offices po ON po.pool_id=p.id WHERE po.office_id=$1").bind(row.get::<&str,_>("office_id")).fetch_optional(&mut **tx).await.map_err(db_error)?;
    let percentage = percentage.ok_or_else(|| {
        Error::Validation("Assign the office to a pool before verification".into())
    })? as u32;
    let sample = rand::thread_rng().gen_range(0..10000);
    let outcome = if status == Status::Pending {
        sbco_domain::Outcome {
            final_status: Status::Pending,
            basis: None,
        }
    } else {
        primary_outcome(
            row.get::<Decimal, _>("credit"),
            row.get::<Decimal, _>("debit"),
            status.clone(),
            percentage,
            sample,
        )
    };
    let final_user = if outcome.final_status != Status::Pending {
        Some(actor.id)
    } else {
        None
    };
    sqlx::query("UPDATE transactions SET primary_status=$2,reason=$3,notes=$4,verified_by=$5,verified_at=CASE WHEN $2='Pending' THEN NULL ELSE now() END,revision=$6,final_status=$7,final_reason=$8,final_notes=$9,finalized_by=$10,finalized_at=CASE WHEN $10::uuid IS NULL THEN NULL ELSE now() END WHERE id=$1")
        .bind(id).bind(status.label()).bind(if status==Status::Mismatch{reason}else{""}).bind(notes).bind(if status==Status::Pending{None}else{Some(actor.id)}).bind(revision).bind(outcome.final_status.label()).bind(if outcome.final_status==Status::Mismatch{reason}else{""}).bind(if final_user.is_some(){notes}else{""}).bind(final_user).execute(&mut **tx).await.map_err(db_error)?;
    if let Some(basis) = outcome.basis {
        sqlx::query("INSERT INTO reviews(id,transaction_id,revision,basis,sample,percentage,pa_status,pa_reason) VALUES($1,$2,$3,$4,$5,$6,$7,$8)").bind(Uuid::new_v4()).bind(id).bind(revision).bind(basis).bind(sample as i32).bind(percentage as i32).bind(status.label()).bind(reason).execute(&mut **tx).await.map_err(db_error)?;
    }
    sync_incident(tx, actor, id, &outcome.final_status, reason).await
}
async fn sync_incident(
    tx: &mut Tx<'_>,
    actor: &Actor,
    id: Uuid,
    status: &Status,
    reason: &str,
) -> Result<()> {
    if *status == Status::Mismatch {
        sqlx::query("INSERT INTO incidents(id,transaction_id,office_id,incident_type,issue) SELECT $1,id,office_id,$3,$4 FROM transactions WHERE id=$2 ON CONFLICT(transaction_id) DO UPDATE SET issue=excluded.issue,incident_type=excluded.incident_type,status=CASE WHEN incidents.status='Closed' THEN 'Open' ELSE incidents.status END")
            .bind(Uuid::new_v4()).bind(id).bind(if reason.eq_ignore_ascii_case("Voucher missing"){"Voucher Follow-up"}else{"MAP"}).bind(reason).execute(&mut **tx).await.map_err(db_error)?;
    } else if *status == Status::Matched {
        sqlx::query("UPDATE incidents SET status='Closed',complied_by=$2,complied_at=now(),compliance_notes='Closed after final verification matched' WHERE transaction_id=$1 AND status NOT IN ('Closed','Complied')").bind(id).bind(actor.id).execute(&mut **tx).await.map_err(db_error)?;
        rollup_letters(tx).await?;
    }
    Ok(())
}
async fn rollup_letters(tx: &mut Tx<'_>) -> Result<()> {
    sqlx::query("UPDATE letters l SET status=CASE WHEN NOT EXISTS(SELECT 1 FROM letter_items li JOIN incidents i ON i.id=li.incident_id WHERE li.letter_id=l.id AND i.status NOT IN ('Closed','Complied')) THEN 'Complied' ELSE 'Partially Complied' END WHERE l.issued_at IS NOT NULL AND EXISTS(SELECT 1 FROM letter_items li JOIN incidents i ON i.id=li.incident_id WHERE li.letter_id=l.id AND i.status IN ('Closed','Complied'))").execute(&mut **tx).await.map_err(db_error)?;
    Ok(())
}
pub(crate) async fn create_letter(
    tx: &mut Tx<'_>,
    actor: &Actor,
    ids: Vec<Uuid>,
    due: NaiveDate,
    parent: Option<Uuid>,
) -> Result<Value> {
    if ids.is_empty() || ids.len() > 10000 {
        return Err(Error::Validation(
            "Select between 1 and 10000 incidents".into(),
        ));
    }
    let mut office = None;
    let mut sorted = ids.clone();
    sorted.sort();
    sorted.dedup();
    if sorted.len() != ids.len() {
        return Err(Error::Validation(
            "An incident was selected more than once".into(),
        ));
    }
    for id in &sorted {
        let row=sqlx::query("SELECT i.office_id,i.status,coalesce(o.parent_id,o.id) destination FROM incidents i JOIN offices o ON o.id=i.office_id WHERE i.id=$1 FOR UPDATE OF i").bind(id).fetch_optional(&mut **tx).await.map_err(db_error)?.ok_or(Error::NotFound)?;
        assert_office(tx, actor, row.get("office_id")).await?;
        let status: &str = row.get("status");
        if matches!(status, "Closed" | "Complied") || (parent.is_none() && status != "Open") {
            return Err(Error::Conflict(
                "Selected incidents cannot be included in this letter".into(),
            ));
        }
        let dest: String = row.get("destination");
        if office.as_ref().is_some_and(|o| o != &dest) {
            return Err(Error::Validation(
                "All incidents must route to the same SO".into(),
            ));
        }
        office = Some(dest);
    }
    // The enclosed incidents were authorized above; the SO is the postal destination.
    let destination = office.ok_or(Error::NotFound)?;
    let id = Uuid::new_v4();
    let sequence: i64 = sqlx::query_scalar("SELECT nextval('letter_number')")
        .fetch_one(&mut **tx)
        .await
        .map_err(db_error)?;
    let round: i32 = if let Some(p) = parent {
        sqlx::query("SELECT id FROM letters WHERE id=$1 FOR UPDATE")
            .bind(p)
            .execute(&mut **tx)
            .await
            .map_err(db_error)?;
        sqlx::query_scalar("SELECT coalesce(max(round),0)+1 FROM letters WHERE parent_id=$1")
            .bind(p)
            .fetch_one(&mut **tx)
            .await
            .map_err(db_error)?
    } else {
        0
    };
    let number = format!("SBCO-{sequence:06}");
    sqlx::query("INSERT INTO letters(id,number,office_id,kind,parent_id,round,due_date) VALUES($1,$2,$3,$4,$5,$6,$7)").bind(id).bind(&number).bind(destination).bind(if parent.is_some(){"Reminder"}else{"Initial"}).bind(parent).bind(round).bind(due).execute(&mut **tx).await.map_err(db_error)?;
    for incident in ids {
        sqlx::query("INSERT INTO letter_items VALUES($1,$2,$3)")
            .bind(id)
            .bind(incident)
            .bind(parent.is_none())
            .execute(&mut **tx)
            .await
            .map_err(db_error)?;
        if parent.is_none() {
            sqlx::query("UPDATE incidents SET status='Letter Drafted' WHERE id=$1")
                .bind(incident)
                .execute(&mut **tx)
                .await
                .map_err(db_error)?;
        }
    }
    Ok(json!({"id":id,"number":number,"status":"Draft"}))
}
