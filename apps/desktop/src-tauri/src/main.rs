mod postgres;
mod transport;
use sbco_application::Backend;
use sbco_contracts::{CommandRequest, ExportRequest, Login, Query, TrainingContext};
use sbco_domain::Actor;
use sbco_infrastructure::Database;
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
use tauri::{Manager, State};
use tauri_plugin_dialog::DialogExt;
struct Desktop {
    db: Option<Database>,
    remote: Option<transport::Remote>,
    token: Mutex<Option<String>>,
    postgres: Option<postgres::LocalPostgres>,
    maintenance: Arc<tokio::sync::RwLock<()>>,
    backup_error: Arc<Mutex<Option<String>>>,
}
impl Desktop {
    fn local_db(&self) -> Result<&Database, String> {
        self.db
            .as_ref()
            .ok_or_else(|| "This server-connected client has no local database".into())
    }
    async fn actor(&self) -> Result<Actor, String> {
        if let Some(remote) = &self.remote {
            return remote.json("/api/v1/me", None, None).await;
        }
        let token = self
            .token
            .lock()
            .map_err(|_| "Session unavailable")?
            .clone()
            .ok_or("Sign in to continue")?;
        self.local_db()?
            .authenticate(&token)
            .await
            .map_err(|e| e.to_string())
    }
}
#[tauri::command]
async fn login(state: State<'_, Arc<Desktop>>, credentials: Login) -> Result<Actor, String> {
    let _operation = state.maintenance.read().await;
    if let Some(remote) = &state.remote {
        return remote.login(credentials).await;
    }
    let (token, actor) = state
        .local_db()?
        .login(credentials)
        .await
        .map_err(|e| e.to_string())?;
    *state.token.lock().map_err(|_| "Session unavailable")? = Some(token);
    Ok(actor)
}
#[tauri::command]
async fn me(
    state: State<'_, Arc<Desktop>>,
    training: Option<TrainingContext>,
) -> Result<Actor, String> {
    let _operation = state.maintenance.read().await;
    if let Some(remote) = &state.remote {
        return remote.json("/api/v1/me", None, training.as_ref()).await;
    }
    let actor = state.actor().await?;
    match training {
        Some(context) => state
            .local_db()?
            .training_actor(&actor, &context)
            .await
            .map_err(|e| e.to_string()),
        None => Ok(actor),
    }
}
#[tauri::command]
async fn logout(state: State<'_, Arc<Desktop>>) -> Result<(), String> {
    let _operation = state.maintenance.read().await;
    if let Some(remote) = &state.remote {
        return remote.logout().await;
    }
    let token = state
        .token
        .lock()
        .map_err(|_| "Session unavailable")?
        .take();
    if let Some(token) = token {
        state
            .local_db()?
            .logout(&token)
            .await
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}
#[tauri::command]
async fn query(
    state: State<'_, Arc<Desktop>>,
    query: Query,
    training: Option<TrainingContext>,
) -> Result<Value, String> {
    let _operation = state.maintenance.read().await;
    if let Some(remote) = &state.remote {
        return remote
            .json("/api/v1/query", Some(json!(query)), training.as_ref())
            .await;
    }
    let actor = state.actor().await?;
    match training {
        Some(context) => {
            state
                .local_db()?
                .training_query(&actor, &context, query)
                .await
        }
        None => state.local_db()?.query(&actor, query).await,
    }
    .map_err(|e| e.to_string())
}
#[tauri::command]
async fn command(
    state: State<'_, Arc<Desktop>>,
    request: CommandRequest,
    training: Option<TrainingContext>,
) -> Result<Value, String> {
    let _operation = state.maintenance.read().await;
    if let Some(remote) = &state.remote {
        return remote
            .json("/api/v1/command", Some(json!(request)), training.as_ref())
            .await;
    }
    let actor = state.actor().await?;
    match training {
        Some(context) => {
            state
                .local_db()?
                .training_command(&actor, &context, request)
                .await
        }
        None => state.local_db()?.command(&actor, request).await,
    }
    .map_err(|e| e.to_string())
}
#[tauri::command]
async fn save_template(
    app: tauri::AppHandle,
    state: State<'_, Arc<Desktop>>,
    name: String,
    training: Option<TrainingContext>,
) -> Result<(), String> {
    let _operation = state.maintenance.read().await;
    let live_actor = state.actor().await?;
    let actor = if let Some(remote) = &state.remote {
        remote.json("/api/v1/me", None, training.as_ref()).await?
    } else {
        match training {
            Some(context) => state
                .local_db()?
                .training_actor(&live_actor, &context)
                .await
                .map_err(|e| e.to_string())?,
            None => live_actor,
        }
    };
    actor.require_manager().map_err(|e| e.to_string())?;
    let bytes: &[u8] = match name.as_str() {
        "SBCO_Setup_Template" => {
            actor.require_admin().map_err(|e| e.to_string())?;
            include_bytes!("../../../web/public/templates/SBCO_Setup_Template.xlsx")
        }
        "SBCO_SO_Transactions_Template" => {
            include_bytes!("../../../web/public/templates/SBCO_SO_Transactions_Template.xlsx")
        }
        "SBCO_BO_Transactions_Template" => {
            include_bytes!("../../../web/public/templates/SBCO_BO_Transactions_Template.xlsx")
        }
        _ => return Err("Unknown import template".into()),
    };
    let downloaded;
    let bytes = if let Some(remote) = &state.remote {
        downloaded = remote
            .download(&format!("/templates/{name}.xlsx"), None, None)
            .await?;
        if !downloaded.starts_with(b"PK") {
            return Err("The server did not return an Excel template".into());
        }
        downloaded.as_slice()
    } else {
        bytes
    };
    let (send, receive) = tokio::sync::oneshot::channel();
    app.dialog()
        .file()
        .add_filter("Excel workbook", &["xlsx"])
        .set_file_name(format!("{name}.xlsx"))
        .save_file(move |path| {
            let _ = send.send(path);
        });
    if let Some(path) = receive.await.map_err(|e| e.to_string())? {
        tokio::fs::write(path.into_path().map_err(|e| e.to_string())?, bytes)
            .await
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}
#[tauri::command]
async fn save_pdf(
    app: tauri::AppHandle,
    state: State<'_, Arc<Desktop>>,
    request: ExportRequest,
    training: Option<TrainingContext>,
) -> Result<(), String> {
    let _operation = state.maintenance.read().await;
    let actor = state.actor().await?;
    let bytes = if let Some(remote) = &state.remote {
        remote
            .download("/api/v1/export", Some(json!(request)), training.as_ref())
            .await?
    } else {
        match &training {
            Some(context) => {
                state
                    .local_db()?
                    .training_export(&actor, context, request)
                    .await
            }
            None => state.local_db()?.export(&actor, request).await,
        }
        .map_err(|e| e.to_string())?
    };
    if !bytes.starts_with(b"%PDF") {
        return Err("The server did not return a PDF document".into());
    }
    let (send, receive) = tokio::sync::oneshot::channel();
    app.dialog()
        .file()
        .add_filter("PDF", &["pdf"])
        .set_file_name(if training.is_some() {
            "SBCO-TRAINING-report.pdf"
        } else {
            "sbco-report.pdf"
        })
        .save_file(move |path| {
            let _ = send.send(path);
        });
    if let Some(path) = receive.await.map_err(|e| e.to_string())? {
        tokio::fs::write(path.into_path().map_err(|e| e.to_string())?, bytes)
            .await
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}
#[tauri::command]
async fn setup_needed(state: State<'_, Arc<Desktop>>) -> Result<bool, String> {
    let _operation = state.maintenance.read().await;
    if state.remote.is_some() {
        return Ok(false);
    }
    state
        .local_db()?
        .needs_setup()
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
async fn setup(
    state: State<'_, Arc<Desktop>>,
    name: String,
    credentials: Login,
) -> Result<(), String> {
    let _operation = state.maintenance.read().await;
    if state.remote.is_some() {
        return Err("Ask your server administrator to create an account".into());
    }
    state
        .local_db()?
        .bootstrap(&name, &credentials.email, credentials.password)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
async fn backup_status(
    state: State<'_, Arc<Desktop>>,
    training: Option<TrainingContext>,
) -> Result<postgres::BackupStatus, String> {
    if state.remote.is_some() {
        return Ok(postgres::BackupStatus::disabled());
    }
    require_live_backup(&training)?;
    let _operation = state.maintenance.read().await;
    state
        .actor()
        .await?
        .require_admin()
        .map_err(|e| e.to_string())?;
    let mut status = match &state.postgres {
        Some(pg) => pg.backup_status()?,
        None => postgres::BackupStatus::disabled(),
    };
    if let Some(error) = state
        .backup_error
        .lock()
        .map_err(|_| "Backup status unavailable")?
        .as_ref()
    {
        status.last_error = Some(error.clone());
    }
    Ok(status)
}
#[tauri::command]
async fn backup(
    app: tauri::AppHandle,
    state: State<'_, Arc<Desktop>>,
    training: Option<TrainingContext>,
) -> Result<(), String> {
    if state.remote.is_some() {
        return Err("Backups are managed on the SBCO server".into());
    }
    require_live_backup(&training)?;
    state
        .actor()
        .await?
        .require_admin()
        .map_err(|e| e.to_string())?;
    let (send, receive) = tokio::sync::oneshot::channel();
    app.dialog()
        .file()
        .add_filter("PostgreSQL backup", &["dump"])
        .set_file_name("sbco-backup.dump")
        .save_file(move |path| {
            let _ = send.send(path);
        });
    if let Some(path) = receive.await.map_err(|e| e.to_string())? {
        let pg = state
            .postgres
            .as_ref()
            .ok_or("Use the server backup tools for a connected database")?
            .clone();
        let path = path.into_path().map_err(|e| e.to_string())?;
        let _operation = state.maintenance.read().await;
        tokio::task::spawn_blocking(move || pg.backup(&path))
            .await
            .map_err(|e| e.to_string())??;
    }
    Ok(())
}
#[tauri::command]
async fn restore(
    app: tauri::AppHandle,
    state: State<'_, Arc<Desktop>>,
    training: Option<TrainingContext>,
) -> Result<(), String> {
    if state.remote.is_some() {
        return Err("Recovery is managed on the SBCO server".into());
    }
    require_live_backup(&training)?;
    state
        .actor()
        .await?
        .require_admin()
        .map_err(|e| e.to_string())?;
    let pg = state
        .postgres
        .as_ref()
        .ok_or("Use the server recovery procedure for a connected database")?;
    let (send, receive) = tokio::sync::oneshot::channel();
    app.dialog()
        .file()
        .add_filter("PostgreSQL backup", &["dump"])
        .pick_file(move |path| {
            let _ = send.send(path);
        });
    let Some(path) = receive.await.map_err(|e| e.to_string())? else {
        return Ok(());
    };
    let (send, receive) = tokio::sync::oneshot::channel();
    app.dialog().message("Restore this SBCO backup and restart? A safety backup will be saved first. The current database is retained; restored accounts and passwords will apply.")
        .buttons(tauri_plugin_dialog::MessageDialogButtons::OkCancel).show(move |yes| { let _=send.send(yes); });
    if !receive.await.map_err(|e| e.to_string())? {
        return Ok(());
    }
    let _exclusive = state.maintenance.write().await;
    state
        .actor()
        .await?
        .require_admin()
        .map_err(|e| e.to_string())?;
    pg.restore(path.into_path().map_err(|e| e.to_string())?)
        .await?;
    app.restart();
}
fn require_live_backup(training: &Option<TrainingContext>) -> Result<(), String> {
    if training.is_some() {
        return Err("Leave training mode to manage backups of the real workspace".into());
    }
    Ok(())
}
#[tauri::command]
async fn training_status(state: State<'_, Arc<Desktop>>) -> Result<Value, String> {
    let _operation = state.maintenance.read().await;
    if let Some(remote) = &state.remote {
        return remote.json("/api/v1/training", None, None).await;
    }
    let actor = state.actor().await?;
    state
        .local_db()?
        .training_status(&actor)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
async fn enable_training(state: State<'_, Arc<Desktop>>) -> Result<Value, String> {
    let _operation = state.maintenance.read().await;
    if let Some(remote) = &state.remote {
        return remote
            .json("/api/v1/training/enable", Some(json!({})), None)
            .await;
    }
    let actor = state.actor().await?;
    state
        .local_db()?
        .enable_training(&actor)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
async fn reset_training(
    state: State<'_, Arc<Desktop>>,
    generation: uuid::Uuid,
    confirmation: String,
) -> Result<Value, String> {
    // Keep schema deletion separate from whole-database backup snapshots.
    let _operation = state.maintenance.write().await;
    if let Some(remote) = &state.remote {
        return remote
            .json(
                "/api/v1/training/reset",
                Some(json!({"generation":generation,"confirmation":confirmation})),
                None,
            )
            .await;
    }
    let actor = state.actor().await?;
    state
        .local_db()?
        .reset_training(&actor, generation, &confirmation)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
async fn connection_status(
    state: State<'_, Arc<Desktop>>,
) -> Result<transport::ConnectionStatus, String> {
    Ok(match &state.remote {
        Some(remote) => remote.status().await,
        None => transport::ConnectionStatus {
            mode: "offline",
            server_url: None,
            configured: true,
        },
    })
}
#[tauri::command]
async fn configure_connection(
    state: State<'_, Arc<Desktop>>,
    server_url: String,
) -> Result<transport::ConnectionStatus, String> {
    let _exclusive = state.maintenance.write().await;
    state
        .remote
        .as_ref()
        .ok_or("This is the standalone offline application")?
        .configure(&server_url)
        .await
}
fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let root = app.path().app_data_dir()?;
            if cfg!(feature = "connected-client") {
                app.manage(Arc::new(Desktop {
                    db: None,
                    remote: Some(transport::Remote::load(root).map_err(std::io::Error::other)?),
                    token: Mutex::new(None),
                    postgres: None,
                    maintenance: Arc::new(tokio::sync::RwLock::new(())),
                    backup_error: Arc::new(Mutex::new(None)),
                }));
                return Ok(());
            }
            let resources = app.path().resource_dir()?;
            let local = if std::env::var("DATABASE_URL").is_ok() {
                None
            } else {
                Some(
                    postgres::LocalPostgres::start(&root, &resources)
                        .map_err(std::io::Error::other)?,
                )
            };
            let url = std::env::var("DATABASE_URL")
                .ok()
                .or_else(|| local.as_ref().map(|pg| pg.url.clone()))
                .ok_or("Database unavailable")?;
            let db = tauri::async_runtime::block_on(Database::connect(&url))?;
            let worker = db.clone();
            let maintenance = Arc::new(tokio::sync::RwLock::new(()));
            let worker_gate = maintenance.clone();
            let backup_error = Arc::new(Mutex::new(None));
            if let Some(pg) = local.clone() {
                let backup_db = db.clone();
                let backup_gate = maintenance.clone();
                let error_state = backup_error.clone();
                tauri::async_runtime::spawn(async move {
                    loop {
                        let delay = {
                            let _operation = backup_gate.read().await;
                            match backup_db.needs_setup().await {
                                Ok(true) => 60,
                                Ok(false) => {
                                    let pg = pg.clone();
                                    let result =
                                        tokio::task::spawn_blocking(move || pg.scheduled_backup())
                                            .await
                                            .map_err(|e| e.to_string())
                                            .and_then(|result| result);
                                    let delay = if result.is_ok() { 3600 } else { 300 };
                                    if let Ok(mut last_error) = error_state.lock() {
                                        *last_error = result.err();
                                    }
                                    delay
                                }
                                Err(error) => {
                                    if let Ok(mut last_error) = error_state.lock() {
                                        *last_error =
                                            Some(format!("Cannot check backup readiness: {error}"));
                                    }
                                    300
                                }
                            }
                        };
                        tokio::time::sleep(std::time::Duration::from_secs(delay)).await;
                    }
                });
            }
            tauri::async_runtime::spawn(async move {
                loop {
                    {
                        let _operation = worker_gate.read().await;
                        if let Err(error) = worker.mark_overdue().await {
                            eprintln!("Overdue processing: {error}");
                        }
                        if let Err(error) = worker.tick().await {
                            eprintln!("Import processing: {error}");
                        }
                        if let Err(error) = worker.training_tick().await {
                            eprintln!("Training processing: {error}");
                        }
                    }
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                }
            });
            app.manage(Arc::new(Desktop {
                db: Some(db),
                remote: None,
                token: Mutex::new(None),
                postgres: local,
                maintenance,
                backup_error,
            }));
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            login,
            me,
            logout,
            query,
            command,
            save_pdf,
            save_template,
            setup_needed,
            setup,
            backup,
            backup_status,
            restore,
            training_status,
            enable_training,
            reset_training,
            connection_status,
            configure_connection
        ])
        .build(tauri::generate_context!())
        .expect("SBCO desktop startup failed")
        .run(|app, event| {
            if let tauri::RunEvent::Exit = event
                && let Some(state) = app.try_state::<Arc<Desktop>>()
                && let Some(pg) = &state.postgres
            {
                pg.stop();
            }
        });
}

#[cfg(test)]
mod training_boundary_tests {
    use super::*;

    #[test]
    fn backup_controls_reject_training_context_for_every_practice_role() {
        assert!(require_live_backup(&None).is_ok());
        for role in ["Administrator", "Supervisor", "Pa"] {
            let context = Some(TrainingContext {
                generation: uuid::Uuid::new_v4(),
                role: role.into(),
            });
            assert!(require_live_backup(&context).is_err());
        }
    }
}
