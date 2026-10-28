mod auth;
mod commands;
mod excel;
mod jobs;
mod onboarding;
mod pdf;
mod queries;
mod reports;
mod setup_import;
mod training;
mod training_seed;

use async_trait::async_trait;
use sbco_application::Backend;
use sbco_contracts::{CommandRequest, ExportRequest, Login, Query};
use sbco_domain::{Actor, Error, Result};
use serde_json::Value;
use sqlx::{PgPool, postgres::PgPoolOptions};

#[derive(Clone)]
pub struct Database {
    pub pool: PgPool,
}
pub(crate) fn db_error(error: sqlx::Error) -> Error {
    if let Some(db) = error.as_database_error() {
        if db.is_unique_violation() {
            return Error::Conflict(
                "This record already exists or has already been processed".into(),
            );
        }
        if db.is_foreign_key_violation() || db.is_check_violation() {
            return Error::Validation(
                "The operation violates a data relationship or constraint".into(),
            );
        }
    }
    tracing::error!(error = %error, "Database operation failed");
    Error::Internal
}
pub(crate) fn role(s: &str) -> Result<sbco_domain::Role> {
    match s {
        "Pa" => Ok(sbco_domain::Role::Pa),
        "Supervisor" => Ok(sbco_domain::Role::Supervisor),
        "Administrator" => Ok(sbco_domain::Role::Administrator),
        _ => Err(Error::Validation("Invalid role".into())),
    }
}
impl Database {
    pub async fn connect(url: &str) -> Result<Self> {
        let pool = PgPoolOptions::new()
            .max_connections(8)
            .acquire_timeout(std::time::Duration::from_secs(10))
            .connect(url)
            .await
            .map_err(db_error)?;
        sqlx::migrate!("../../migrations")
            .run(&pool)
            .await
            .map_err(|e| {
                tracing::error!(%e, "Migration failed");
                Error::Internal
            })?;
        Ok(Self { pool })
    }
}
#[async_trait]
impl Backend for Database {
    async fn login(&self, credentials: Login) -> Result<(String, Actor)> {
        self.sign_in(credentials).await
    }
    async fn authenticate(&self, token: &str) -> Result<Actor> {
        self.session(token).await
    }
    async fn logout(&self, token: &str) -> Result<()> {
        sqlx::query("DELETE FROM sessions WHERE token_hash=$1")
            .bind(auth::hash(token.as_bytes()))
            .execute(&self.pool)
            .await
            .map_err(db_error)?;
        Ok(())
    }
    async fn query(&self, actor: &Actor, query: Query) -> Result<Value> {
        self.read(actor, query).await
    }
    async fn command(&self, actor: &Actor, request: CommandRequest) -> Result<Value> {
        self.execute(actor, request).await
    }
    async fn export(&self, actor: &Actor, request: ExportRequest) -> Result<Vec<u8>> {
        self.render_export(actor, request).await
    }
}
