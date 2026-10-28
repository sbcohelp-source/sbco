use serde::{Deserialize, Serialize};
use ts_rs::TS;
use utoipa::ToSchema;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, TS, ToSchema)]
#[serde(deny_unknown_fields)]
pub struct TrainingContext {
    pub generation: Uuid,
    pub role: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, TS, ToSchema)]
#[serde(deny_unknown_fields)]
pub struct Login {
    pub email: String,
    pub password: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, TS, ToSchema, Default)]
#[serde(deny_unknown_fields)]
pub struct Filter {
    pub office: Option<String>,
    pub status: Option<String>,
    pub search: Option<String>,
    pub from_date: Option<String>,
    pub to_date: Option<String>,
    pub queue: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, TS, ToSchema)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Query {
    Onboarding,
    Dashboard {
        filter: Filter,
    },
    Transactions {
        filter: Filter,
        cursor: Option<String>,
        limit: u32,
    },
    Offices,
    Pools,
    Users,
    Imports,
    Reviews,
    Corrections,
    Incidents,
    Letters,
    Settings,
    Audit,
    History {
        id: Uuid,
    },
    Report {
        report: String,
        filter: Filter,
    },
}
#[derive(Debug, Clone, Serialize, Deserialize, TS, ToSchema)]
#[serde(deny_unknown_fields)]
pub struct CommandRequest {
    pub request_id: Uuid,
    pub command: Command,
}
#[derive(Debug, Clone, Serialize, Deserialize, TS, ToSchema)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    SaveOnboarding {
        step: String,
        completed: bool,
    },
    CreateUser {
        name: String,
        email: String,
        password: String,
        role: String,
    },
    UpdateUser {
        user_id: Uuid,
        name: String,
        role: String,
        active: bool,
    },
    ChangePassword {
        current_password: String,
        new_password: String,
    },
    ResetPassword {
        user_id: Uuid,
        password: String,
    },
    SaveOffice {
        id: String,
        name: String,
        office_type: String,
        parent_id: Option<String>,
    },
    SavePool {
        id: Option<Uuid>,
        name: String,
        offices: Vec<String>,
        pa_user: Option<Uuid>,
        random_percent: u32,
    },
    Import {
        filename: String,
        content_base64: String,
    },
    ImportSetup {
        filename: String,
        content_base64: String,
        preview: bool,
    },
    RetryImport {
        id: Uuid,
    },
    Verify {
        id: Uuid,
        revision: i32,
        status: String,
        reason: String,
        notes: String,
    },
    Reverify {
        id: Uuid,
        revision: i32,
        status: String,
        reason: String,
        notes: String,
    },
    RequestCorrection {
        id: Uuid,
        revision: i32,
        status: String,
        reason: String,
        notes: String,
        request_reason: String,
    },
    ReviewCorrection {
        id: Uuid,
        approve: bool,
        notes: String,
    },
    CreateLetter {
        incident_ids: Vec<Uuid>,
        due_date: String,
    },
    CreateReminder {
        letter_id: Uuid,
        due_date: String,
    },
    IssueLetter {
        id: Uuid,
    },
    Comply {
        id: Uuid,
        reference: String,
        notes: String,
    },
    SaveSettings {
        random_percent: u32,
        reminder_days: u32,
        signatory: String,
        designation: String,
        reasons: Vec<String>,
    },
}
#[derive(Debug, Clone, Serialize, Deserialize, TS, ToSchema)]
pub struct ExportRequest {
    pub report: String,
    pub filter: Filter,
    pub letter_id: Option<Uuid>,
}

pub fn typescript() -> String {
    format!(
        "// Generated from sbco-contracts. Do not edit.\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n",
        TrainingContext::decl(),
        Login::decl(),
        Filter::decl(),
        Query::decl(),
        CommandRequest::decl(),
        Command::decl(),
        ExportRequest::decl()
    )
    .replace("type ", "export type ")
}
