use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, State},
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use sbco_application::Backend;
use sbco_contracts::{CommandRequest, ExportRequest, Login, Query, TrainingContext};
use sbco_domain::Error;
use sbco_infrastructure::Database;
use serde_json::{Value, json};
use utoipa::OpenApi;

#[derive(OpenApi)]
#[openapi(
    paths(
        server_info,
        login,
        read,
        execute,
        export,
        training_status,
        enable_training,
        reset_training
    ),
    components(schemas(
        Login,
        Query,
        CommandRequest,
        sbco_contracts::Command,
        sbco_contracts::Filter,
        ExportRequest,
        TrainingContext,
        ResetTraining
    ))
)]
struct ApiDoc;
struct ApiError(Error);
impl From<Error> for ApiError {
    fn from(e: Error) -> Self {
        Self(e)
    }
}
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let code = match self.0 {
            Error::Unauthorized => StatusCode::UNAUTHORIZED,
            Error::Forbidden => StatusCode::FORBIDDEN,
            Error::NotFound => StatusCode::NOT_FOUND,
            Error::Conflict(_) => StatusCode::CONFLICT,
            Error::Validation(_) => StatusCode::BAD_REQUEST,
            Error::Internal => StatusCode::INTERNAL_SERVER_ERROR,
        };
        (code, Json(json!({"error":self.0.to_string()}))).into_response()
    }
}
#[utoipa::path(get,path="/api/v1/server-info",responses((status=200,description="SBCO client compatibility information")))]
async fn server_info() -> Json<Value> {
    Json(json!({
        "application": "SBCO",
        "api_version": 1,
        "version": env!("CARGO_PKG_VERSION"),
        "capabilities": ["training", "templates"]
    }))
}

fn token(headers: &HeaderMap) -> Result<String, ApiError> {
    headers
        .get(header::COOKIE)
        .and_then(|v| v.to_str().ok())
        .and_then(|cookies| {
            cookies
                .split(';')
                .find_map(|s| s.trim().strip_prefix("sbco_session="))
        })
        .map(str::to_owned)
        .ok_or(ApiError(Error::Unauthorized))
}
fn training_context(headers: &HeaderMap) -> Result<Option<TrainingContext>, ApiError> {
    let mut values = headers.get_all("x-sbco-training").iter();
    let Some(value) = values.next() else {
        return Ok(None);
    };
    if values.next().is_some() {
        return Err(ApiError(Error::Validation(
            "Provide one training context".into(),
        )));
    }
    let context: TrainingContext = value
        .to_str()
        .ok()
        .and_then(|value| serde_json::from_str(value).ok())
        .ok_or_else(|| ApiError(Error::Validation("Invalid training context".into())))?;
    if !matches!(context.role.as_str(), "Administrator" | "Supervisor" | "Pa") {
        return Err(ApiError(Error::Validation("Invalid training role".into())));
    }
    Ok(Some(context))
}
fn csrf(headers: &HeaderMap) -> Result<(), ApiError> {
    if headers.get("x-sbco-request").and_then(|v| v.to_str().ok()) != Some("1") {
        return Err(ApiError(Error::Forbidden));
    }
    if headers.get("sec-fetch-site").and_then(|v| v.to_str().ok()) == Some("cross-site") {
        return Err(ApiError(Error::Forbidden));
    }
    Ok(())
}
#[utoipa::path(post,path="/api/v1/login",request_body=Login,responses((status=200,description="Signed-in identity; HttpOnly session cookie")))]
async fn login(
    State(db): State<Database>,
    headers: HeaderMap,
    Json(input): Json<Login>,
) -> Result<Response, ApiError> {
    csrf(&headers)?;
    let (token, actor) = db.login(input).await?;
    let secure = if std::env::var("SBCO_INSECURE_LOCAL_HTTP").as_deref() == Ok("1") {
        ""
    } else {
        "; Secure"
    };
    let cookie =
        format!("sbco_session={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age=28800{secure}");
    Ok(([(header::SET_COOKIE, cookie)], Json(actor)).into_response())
}
async fn me(
    State(db): State<Database>,
    headers: HeaderMap,
) -> Result<Json<sbco_domain::Actor>, ApiError> {
    let actor = db.authenticate(&token(&headers)?).await?;
    Ok(Json(match training_context(&headers)? {
        Some(context) => db.training_actor(&actor, &context).await?,
        None => actor,
    }))
}
async fn logout(State(db): State<Database>, headers: HeaderMap) -> Result<Response, ApiError> {
    csrf(&headers)?;
    db.logout(&token(&headers)?).await?;
    Ok((
        [(
            header::SET_COOKIE,
            "sbco_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0",
        )],
        Json(json!({"ok":true})),
    )
        .into_response())
}
#[utoipa::path(post,path="/api/v1/query",request_body=Query,responses((status=200,description="Office-scoped query result")))]
async fn read(
    State(db): State<Database>,
    headers: HeaderMap,
    Json(query): Json<Query>,
) -> Result<Json<Value>, ApiError> {
    csrf(&headers)?;
    let actor = db.authenticate(&token(&headers)?).await?;
    Ok(Json(match training_context(&headers)? {
        Some(context) => db.training_query(&actor, &context, query).await?,
        None => db.query(&actor, query).await?,
    }))
}
#[utoipa::path(post,path="/api/v1/command",request_body=CommandRequest,responses((status=200,description="Idempotent command result"),(status=409,description="Revision or uniqueness conflict")))]
async fn execute(
    State(db): State<Database>,
    headers: HeaderMap,
    Json(command): Json<CommandRequest>,
) -> Result<Json<Value>, ApiError> {
    csrf(&headers)?;
    let actor = db.authenticate(&token(&headers)?).await?;
    Ok(Json(match training_context(&headers)? {
        Some(context) => db.training_command(&actor, &context, command).await?,
        None => db.command(&actor, command).await?,
    }))
}
#[utoipa::path(post,path="/api/v1/export",request_body=ExportRequest,responses((status=200,description="PDF file",content_type="application/pdf")))]
async fn export(
    State(db): State<Database>,
    headers: HeaderMap,
    Json(request): Json<ExportRequest>,
) -> Result<Response, ApiError> {
    csrf(&headers)?;
    let actor = db.authenticate(&token(&headers)?).await?;
    let context = training_context(&headers)?;
    let bytes = match &context {
        Some(context) => db.training_export(&actor, context, request).await?,
        None => db.export(&actor, request).await?,
    };
    let filename = if context.is_some() {
        "attachment; filename=SBCO-TRAINING-report.pdf"
    } else {
        "attachment; filename=sbco-report.pdf"
    };
    Ok((
        [
            (header::CONTENT_TYPE, "application/pdf"),
            (header::CONTENT_DISPOSITION, filename),
        ],
        bytes,
    )
        .into_response())
}
#[utoipa::path(get,path="/api/v1/training",responses((status=200,description="Current signed-in user training workspace")))]
async fn training_status(
    State(db): State<Database>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let actor = db.authenticate(&token(&headers)?).await?;
    Ok(Json(db.training_status(&actor).await?))
}
#[utoipa::path(post,path="/api/v1/training/enable",responses((status=200,description="Create or resume the signed-in user training workspace")))]
async fn enable_training(
    State(db): State<Database>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    csrf(&headers)?;
    let actor = db.authenticate(&token(&headers)?).await?;
    fn ensure_send<T: Send>(future: T) -> T {
        future
    }
    Ok(Json(ensure_send(db.enable_training(&actor)).await?))
}
#[derive(serde::Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
struct ResetTraining {
    generation: uuid::Uuid,
    confirmation: String,
}
#[utoipa::path(post,path="/api/v1/training/reset",request_body=ResetTraining,responses((status=200,description="Remove all data in this training generation"),(status=409,description="Training generation has changed")))]
async fn reset_training(
    State(db): State<Database>,
    headers: HeaderMap,
    Json(input): Json<ResetTraining>,
) -> Result<Json<Value>, ApiError> {
    csrf(&headers)?;
    let actor = db.authenticate(&token(&headers)?).await?;
    Ok(Json(
        db.reset_training(&actor, input.generation, &input.confirmation)
            .await?,
    ))
}
async fn health(State(db): State<Database>) -> Result<Json<Value>, ApiError> {
    sqlx_check(&db).await?;
    Ok(Json(
        json!({"status":"ok","version":env!("CARGO_PKG_VERSION")}),
    ))
}
async fn sqlx_check(db: &Database) -> Result<(), Error> {
    db.pool
        .acquire()
        .await
        .map(|_| ())
        .map_err(|_| Error::Internal)
}
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--export-types") {
        print!("{}", sbco_contracts::typescript());
        return Ok(());
    }
    if args.iter().any(|a| a == "--openapi") {
        println!("{}", ApiDoc::openapi().to_pretty_json()?);
        return Ok(());
    }
    let db = Database::connect(&std::env::var("DATABASE_URL")?).await?;
    if args.iter().any(|a| a == "--bootstrap") {
        db.bootstrap(
            &std::env::var("SBCO_ADMIN_NAME")?,
            &std::env::var("SBCO_ADMIN_EMAIL")?,
            std::env::var("SBCO_ADMIN_PASSWORD")?,
        )
        .await?;
        println!("Administrator created. Sign in and create PA and supervisor accounts.");
        return Ok(());
    }
    if args.iter().any(|a| a == "--recover-admin") {
        db.recover_admin(
            &std::env::var("SBCO_RECOVERY_EMAIL")?,
            std::env::var("SBCO_RECOVERY_PASSWORD")?,
        )
        .await?;
        println!("Administrator password replaced and sessions revoked.");
        return Ok(());
    }
    let router = Router::new()
        .route("/health", get(health))
        .route("/api/v1/server-info", get(server_info))
        .route("/api/v1/login", post(login))
        .route("/api/v1/me", get(me))
        .route("/api/v1/logout", post(logout))
        .route("/api/v1/query", post(read))
        .route("/api/v1/command", post(execute))
        .route("/api/v1/export", post(export))
        .route("/api/v1/training", get(training_status))
        .route("/api/v1/training/enable", post(enable_training))
        .route("/api/v1/training/reset", post(reset_training))
        .route(
            "/api/v1/openapi.json",
            get(|| async { Json(ApiDoc::openapi()) }),
        )
        .layer(DefaultBodyLimit::max(29_000_000))
        .with_state(db);
    let bind = std::env::var("SBCO_BIND").unwrap_or_else(|_| "127.0.0.1:8091".into());
    let listener = tokio::net::TcpListener::bind(&bind).await?;
    tracing::info!(%bind,"SBCO API ready");
    axum::serve(listener, router)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn training_header_is_explicit_and_rejects_invalid_contexts() {
        assert!(matches!(training_context(&HeaderMap::new()), Ok(None)));
        let generation = uuid::Uuid::new_v4();
        for role in ["Administrator", "Supervisor", "Pa"] {
            let mut headers = HeaderMap::new();
            headers.insert(
                "x-sbco-training",
                json!({"generation":generation,"role":role})
                    .to_string()
                    .parse()
                    .unwrap(),
            );
            let Ok(Some(context)) = training_context(&headers) else {
                panic!("valid context rejected")
            };
            assert_eq!(context.generation, generation);
            assert_eq!(context.role, role);
        }
        for invalid in [
            String::new(),
            "null".into(),
            "{}".into(),
            json!({"generation":"bad","role":"Pa"}).to_string(),
            json!({"generation":generation,"role":"admin"}).to_string(),
            json!({"generation":generation,"role":"Pa","schema":"public"}).to_string(),
        ] {
            let mut headers = HeaderMap::new();
            headers.insert("x-sbco-training", invalid.parse().unwrap());
            assert!(matches!(
                training_context(&headers),
                Err(ApiError(Error::Validation(_)))
            ));
        }
        let mut duplicates = HeaderMap::new();
        let value = json!({"generation":generation,"role":"Pa"}).to_string();
        duplicates.append("x-sbco-training", value.parse().unwrap());
        duplicates.append("x-sbco-training", value.parse().unwrap());
        assert!(matches!(
            training_context(&duplicates),
            Err(ApiError(Error::Validation(_)))
        ));
    }
}
