use super::{Database, db_error, queries::assert_letter};
use sbco_contracts::ExportRequest;
use sbco_documents::{Document, RenderError, Section};
use sbco_domain::{Actor, Error, Result};
use serde_json::Value;
use sqlx::Row;
use tokio::sync::Semaphore;
use uuid::Uuid;

static RENDER_SLOTS: Semaphore = Semaphore::const_new(2);
async fn render(document: Document) -> Result<Vec<u8>> {
    let permit = RENDER_SLOTS.acquire().await.map_err(|_| Error::Internal)?;
    tokio::task::spawn_blocking(move || {
        // Keep the slot until rendering finishes, even if the HTTP client disconnects.
        let _permit = permit;
        sbco_documents::render(&document).map_err(|e| match e {
            RenderError::UnsupportedText | RenderError::TooLarge => {
                Error::Validation(e.to_string())
            }
            other => {
                tracing::error!(error = %other, "PDF rendering failed");
                Error::Internal
            }
        })
    })
    .await
    .map_err(|_| Error::Internal)?
}
fn required_action(issue: &str) -> &'static str {
    let issue = issue.to_lowercase();
    if issue.contains("voucher") || issue.contains("document") {
        "Forward the voucher and supporting documents."
    } else if issue.contains("amount") {
        "Reconcile the amount and provide supporting records."
    } else if issue.contains("account") {
        "Confirm the account details with supporting records."
    } else if issue.contains("date") {
        "Confirm the transaction date with supporting records."
    } else if issue.contains("reference") {
        "Provide the correct transaction reference."
    } else {
        "Investigate the discrepancy and provide a written reply."
    }
}
pub(crate) async fn letter_pdf(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    id: Uuid,
) -> Result<Vec<u8>> {
    let l=sqlx::query("SELECT l.number,l.kind,l.due_date,coalesce(l.issued_at,l.created_at) AT TIME ZONE 'Asia/Kolkata' AS letter_date,l.status,o.name FROM letters l JOIN offices o ON o.id=l.office_id WHERE l.id=$1").bind(id).fetch_one(&mut **tx).await.map_err(db_error)?;
    let rows=sqlx::query("SELECT t.report_date,t.reference_id,t.account_number,t.transaction_id,i.incident_type,i.issue,t.credit::text credit,t.debit::text debit,o.name AS office FROM letter_items li JOIN incidents i ON i.id=li.incident_id JOIN transactions t ON t.id=i.transaction_id JOIN offices o ON o.id=t.office_id WHERE li.letter_id=$1 ORDER BY t.office_id,t.report_date,t.account_number").bind(id).fetch_all(&mut **tx).await.map_err(db_error)?;
    let settings: Value = sqlx::query_scalar("SELECT value FROM settings")
        .fetch_one(&mut **tx)
        .await
        .map_err(db_error)?;
    let subject = if rows
        .iter()
        .all(|r| r.get::<String, _>("incident_type") == "Voucher Follow-up")
    {
        "Voucher Follow-up"
    } else if rows
        .iter()
        .all(|r| r.get::<String, _>("incident_type") == "MAP")
    {
        "Mistake Advice"
    } else {
        "Voucher Verification Objections"
    };
    let draft = if l.get::<String, _>("status") == "Draft" {
        "DRAFT - "
    } else {
        ""
    };
    let reminder = if l.get::<String, _>("kind") == "Reminder" {
        "Reminder - "
    } else {
        ""
    };
    let details = rows
        .iter()
        .map(|r| {
            let issue = r.get::<String, _>("issue");
            vec![
                format!(
                    "{}\n{}",
                    r.get::<String, _>("office"),
                    r.get::<chrono::NaiveDate, _>("report_date")
                ),
                format!(
                    "{}\nAccount: {}\nRef: {}",
                    r.get::<String, _>("transaction_id"),
                    r.get::<String, _>("account_number"),
                    r.get::<String, _>("reference_id")
                ),
                format!(
                    "Credit: {}\nDebit: {}",
                    r.get::<String, _>("credit"),
                    r.get::<String, _>("debit")
                ),
                format!("{issue}\n{}", required_action(&issue)),
            ]
        })
        .collect();
    let training: bool =
        sqlx::query_scalar("SELECT coalesce(current_setting('sbco.training',true),'')='1'")
            .fetch_one(&mut **tx)
            .await
            .map_err(db_error)?;
    let marker = if training {
        "TRAINING - NOT FOR OFFICIAL USE - "
    } else {
        ""
    };
    let document = Document {
        title: format!("{marker}{draft}{reminder}SBCO {subject}"),
        subtitle: format!(
            "Letter {} | Date {} | Reply due {}",
            l.get::<String, _>("number"),
            l.get::<chrono::NaiveDateTime, _>("letter_date").date(),
            l.get::<chrono::NaiveDate, _>("due_date"),
        ),
        landscape: false,
        sections: vec![
            Section::new(
                "Addressee", &["To", "Subject"], &[1, 2],
                vec![vec![
                    format!("The Sub Postmaster\n{}", l.get::<String, _>("name")),
                    "Voucher verification objections - please investigate and reply by the due date.".into(),
                ]],
            ),
            Section::new(
                "Transactions requiring action",
                &["Office / date", "Transaction / account / reference", "Credit / debit INR", "Objection / required action"],
                &[2, 3, 4, 4], details,
            ),
        ],
        notes: vec!["Quote the letter number in your reply and enclose the relevant vouchers and supporting records.".into()],
        signatory: settings["signatory"].as_str().unwrap_or("").into(),
        designation: settings["designation"].as_str().filter(|s| !s.is_empty()).unwrap_or("SBCO Incharge").into(),
    };
    render(document).await
}
impl Database {
    pub(crate) async fn render_export(
        &self,
        actor: &Actor,
        request: ExportRequest,
    ) -> Result<Vec<u8>> {
        if let Some(id) = request.letter_id {
            let mut tx = self.pool.begin().await.map_err(db_error)?;
            let row = sqlx::query("SELECT office_id,pdf FROM letters WHERE id=$1")
                .bind(id)
                .fetch_optional(&mut *tx)
                .await
                .map_err(db_error)?
                .ok_or(Error::NotFound)?;
            assert_letter(&mut tx, actor, id).await?;
            return if let Some(bytes) = row.get::<Option<Vec<u8>>, _>("pdf") {
                Ok(bytes)
            } else {
                letter_pdf(&mut tx, id).await
            };
        }
        let mut data = self
            .report_data(actor, &request.filter, &request.report, true)
            .await?;
        let training: bool =
            sqlx::query_scalar("SELECT coalesce(current_setting('sbco.training',true),'')='1'")
                .fetch_one(&self.pool)
                .await
                .map_err(db_error)?;
        if training {
            data.document.title =
                format!("TRAINING - NOT FOR OFFICIAL USE - {}", data.document.title);
        }
        render(data.document).await
    }
}
