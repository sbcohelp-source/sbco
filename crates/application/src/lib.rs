use async_trait::async_trait;
use sbco_contracts::{CommandRequest, ExportRequest, Login, Query};
use sbco_domain::{Actor, Result};
use serde_json::Value;

/// Boundary implemented by transactional storage. Both HTTP and desktop use it.
#[async_trait]
pub trait Backend: Send + Sync {
    async fn login(&self, credentials: Login) -> Result<(String, Actor)>;
    async fn authenticate(&self, token: &str) -> Result<Actor>;
    async fn logout(&self, token: &str) -> Result<()>;
    async fn query(&self, actor: &Actor, query: Query) -> Result<Value>;
    async fn command(&self, actor: &Actor, request: CommandRequest) -> Result<Value>;
    async fn export(&self, actor: &Actor, request: ExportRequest) -> Result<Vec<u8>>;
}
