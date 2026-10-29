use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::File,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Output},
    sync::Arc,
};
use uuid::Uuid;

const RETAIN_AUTOMATIC_BACKUPS: usize = 14;

#[derive(Default, Serialize, Deserialize)]
pub struct BackupStatus {
    pub enabled: bool,
    pub directory: Option<String>,
    pub retention_days: usize,
    pub last_attempt: Option<String>,
    pub last_success: Option<String>,
    pub last_backup: Option<String>,
    pub last_error: Option<String>,
}

impl BackupStatus {
    pub fn disabled() -> Self {
        Self {
            retention_days: RETAIN_AUTOMATIC_BACKUPS,
            ..Self::default()
        }
    }
}

fn checksum(path: &Path) -> Result<String, String> {
    let mut file = File::open(path).map_err(|e| e.to_string())?;
    let mut digest = Sha256::new();
    let mut buffer = [0; 65_536];
    loop {
        let count = file.read(&mut buffer).map_err(|e| e.to_string())?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
    }
    Ok(format!("{:x}", digest.finalize()))
}

fn verify_checksum(path: &Path) -> Result<(), String> {
    let expected = std::fs::read_to_string(path.with_extension("sha256"))
        .map_err(|e| format!("Backup checksum is unavailable: {e}"))?;
    if checksum(path)? != expected.trim() {
        return Err("Backup checksum does not match; the file may be damaged".into());
    }
    Ok(())
}

fn private_directory(path: &Path) -> Result<(), String> {
    std::fs::create_dir_all(path).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn automatic_backup_name(name: &str) -> bool {
    let Some(date) = name
        .strip_prefix("auto-")
        .and_then(|name| name.strip_suffix(".dump"))
    else {
        return false;
    };
    date.len() == 10 && chrono::NaiveDate::parse_from_str(date, "%Y-%m-%d").is_ok()
}

fn prune_automatic_backups(directory: &Path) -> Result<(), String> {
    let mut backups = std::fs::read_dir(directory)
        .map_err(|e| e.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?
        .into_iter()
        .filter(|entry| {
            entry.file_type().is_ok_and(|kind| kind.is_file())
                && automatic_backup_name(&entry.file_name().to_string_lossy())
        })
        .map(|entry| entry.path())
        .collect::<Vec<_>>();
    backups.sort_unstable();
    let excess = backups.len().saturating_sub(RETAIN_AUTOMATIC_BACKUPS);
    for path in backups.into_iter().take(excess) {
        std::fs::remove_file(&path).map_err(|e| e.to_string())?;
        match std::fs::remove_file(path.with_extension("sha256")) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.to_string()),
        }
    }
    Ok(())
}

#[derive(Serialize, Deserialize)]
struct Config {
    password: String,
    port: u16,
    #[serde(default = "default_database")]
    database: String,
}
fn default_database() -> String {
    "postgres".into()
}
#[derive(Clone)]
pub struct LocalPostgres {
    bin: PathBuf,
    data: PathBuf,
    lib: PathBuf,
    root: PathBuf,
    _lock: Arc<File>,
    config: Arc<Config>,
    pub url: String,
}
fn executable(bin: &Path, name: &str) -> PathBuf {
    bin.join(if cfg!(windows) {
        format!("{name}.exe")
    } else {
        name.into()
    })
}
fn checked(output: std::io::Result<Output>, name: &str) -> Result<(), String> {
    let output = output.map_err(|e| format!("Cannot start {name}: {e}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(format!(
            "{name} failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ))
    }
}
fn run(bin: &Path, lib: &Path, name: &str, args: &[&str]) -> Result<(), String> {
    #[cfg(test)]
    eprintln!(
        "lifecycle tool begin: {name} {}",
        if name == "pg_ctl" {
            args.last().copied().unwrap_or("")
        } else {
            ""
        }
    );
    let mut command = Command::new(executable(bin, name));
    command.args(args).env("LD_LIBRARY_PATH", lib);
    #[cfg(windows)]
    if name == "pg_ctl" && args.last() == Some(&"start") {
        // pg_ctl's persistent Windows CMD child inherits capture pipes even with -l.
        // Wait for pg_ctl itself; PostgreSQL diagnostics already go to postgres.log.
        command
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
    }
    let output = command.output();
    #[cfg(test)]
    eprintln!(
        "lifecycle tool end: {name}, success={}",
        output.as_ref().is_ok_and(|result| result.status.success())
    );
    checked(output, name)
}
fn private_file(path: &Path, bytes: &[u8]) -> Result<(), String> {
    std::fs::write(path, bytes).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}
fn initdb_locale_arguments(windows: bool) -> &'static [&'static str] {
    if windows {
        &[
            "--encoding=UTF8",
            "--locale=C",
            "--locale-provider=builtin",
            "--builtin-locale=C.UTF-8",
        ]
    } else {
        &["--encoding=UTF8", "--locale=C.UTF-8"]
    }
}

impl LocalPostgres {
    fn tool(&self, name: &str) -> Command {
        let mut command = Command::new(executable(&self.bin, name));
        command
            .env("PGHOST", "127.0.0.1")
            .env("PGPORT", self.config.port.to_string())
            .env("PGUSER", "sbco")
            .env("PGPASSWORD", &self.config.password)
            .env("PGDATABASE", &self.config.database)
            .env("LD_LIBRARY_PATH", &self.lib);
        command
    }

    pub fn start(root: &Path, resources: &Path) -> Result<Self, String> {
        private_directory(root)?;
        let lock = File::options()
            .create(true)
            .truncate(false)
            .write(true)
            .open(root.join("desktop.lock"))
            .map_err(|e| e.to_string())?;
        lock.try_lock()
            .map_err(|_| "This local SBCO installation is already running".to_owned())?;
        let bin = std::env::var_os("SBCO_POSTGRES_BIN")
            .map(PathBuf::from)
            .unwrap_or_else(|| resources.join("postgres/bin"));
        let share = std::env::var_os("SBCO_POSTGRES_SHARE")
            .map(PathBuf::from)
            .unwrap_or_else(|| resources.join("postgres/share"));
        let lib = resources.join("postgres/lib");
        let data = root.join("postgres");
        // Refuse a different major version before writing configuration or invoking any tools.
        if data.join("PG_VERSION").exists() {
            let major =
                std::fs::read_to_string(data.join("PG_VERSION")).map_err(|e| e.to_string())?;
            if major.trim() != "18" {
                return Err("Local database needs an explicit PostgreSQL major-version upgrade; the existing cluster has not been changed".into());
            }
        }
        let config_path = root.join("database.json");
        let config: Config = if config_path.exists() {
            serde_json::from_slice(&std::fs::read(&config_path).map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?
        } else {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
            let c = Config {
                password: format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple()),
                port: listener.local_addr().map_err(|e| e.to_string())?.port(),
                database: default_database(),
            };
            private_file(
                &config_path,
                &serde_json::to_vec(&c).map_err(|e| e.to_string())?,
            )?;
            c
        };
        if !data.join("PG_VERSION").exists() {
            let password_file = root.join("init-password");
            private_file(&password_file, config.password.as_bytes())?;
            let data_argument = data.to_string_lossy();
            let share_argument = share.to_string_lossy();
            let password_argument = password_file.to_string_lossy();
            let mut arguments = vec![
                "-D",
                data_argument.as_ref(),
                "-L",
                share_argument.as_ref(),
                "-U",
                "sbco",
                "--auth=scram-sha-256",
                "--pwfile",
                password_argument.as_ref(),
            ];
            arguments.extend_from_slice(initdb_locale_arguments(cfg!(windows)));
            let result = run(&bin, &lib, "initdb", &arguments);
            let _ = std::fs::remove_file(password_file);
            result?;
            let settings = format!(
                "\nlisten_addresses='127.0.0.1'\nport={}\nmax_connections=20\nshared_buffers='64MB'\nunix_socket_directories=''\n",
                config.port
            );
            use std::io::Write;
            std::fs::OpenOptions::new()
                .append(true)
                .open(data.join("postgresql.conf"))
                .map_err(|e| e.to_string())?
                .write_all(settings.as_bytes())
                .map_err(|e| e.to_string())?;
        }
        if run(
            &bin,
            &lib,
            "pg_ctl",
            &["-D", &data.to_string_lossy(), "status"],
        )
        .is_err()
        {
            run(
                &bin,
                &lib,
                "pg_ctl",
                &[
                    "-D",
                    &data.to_string_lossy(),
                    "-l",
                    &root.join("postgres.log").to_string_lossy(),
                    "-w",
                    "start",
                ],
            )?;
        }
        Ok(Self {
            bin,
            data,
            lib,
            root: root.into(),
            _lock: Arc::new(lock),
            url: format!(
                "postgresql://sbco:{}@127.0.0.1:{}/{}",
                config.password, config.port, config.database
            ),
            config: Arc::new(config),
        })
    }
    pub fn stop(&self) {
        let _ = run(
            &self.bin,
            &self.lib,
            "pg_ctl",
            &[
                "-D",
                &self.data.to_string_lossy(),
                "-w",
                "-m",
                "fast",
                "stop",
            ],
        );
    }
    pub fn backup(&self, path: &Path) -> Result<(), String> {
        let temporary = path.with_extension(format!("{}.partial", Uuid::new_v4()));
        private_file(&temporary, b"")?;
        let result = checked(
            self.tool("pg_dump")
                .args(["--format=custom", "--file", &temporary.to_string_lossy()])
                .env("LD_LIBRARY_PATH", &self.lib)
                .output(),
            "pg_dump",
        );
        if let Err(e) = result {
            let _ = std::fs::remove_file(&temporary);
            return Err(e);
        }
        if let Err(error) = checked(
            self.tool("pg_restore")
                .arg("--list")
                .arg(&temporary)
                .output(),
            "pg_restore validation",
        ) {
            let _ = std::fs::remove_file(&temporary);
            return Err(error);
        }
        File::open(&temporary)
            .and_then(|file| file.sync_all())
            .map_err(|e| e.to_string())?;
        std::fs::rename(temporary, path).map_err(|e| e.to_string())
    }

    pub fn backup_status(&self) -> Result<BackupStatus, String> {
        let path = self.root.join("backup-status.json");
        let mut status = match std::fs::read(path) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| e.to_string())?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => BackupStatus::default(),
            Err(error) => return Err(error.to_string()),
        };
        status.enabled = true;
        status.directory = Some(self.root.join("backups").to_string_lossy().into_owned());
        status.retention_days = RETAIN_AUTOMATIC_BACKUPS;
        Ok(status)
    }

    /// Called only after first setup. A successful dump is checked before old automatic copies are pruned.
    pub fn scheduled_backup(&self) -> Result<(), String> {
        let now = chrono::Utc::now();
        let date = now
            .with_timezone(&chrono::FixedOffset::east_opt(19_800).expect("India offset"))
            .format("%Y-%m-%d")
            .to_string();
        self.scheduled_backup_for_date(&date, &now.to_rfc3339())
    }

    fn scheduled_backup_for_date(&self, date: &str, attempted_at: &str) -> Result<(), String> {
        let mut status = self.backup_status().unwrap_or_else(|error| BackupStatus {
            enabled: true,
            directory: Some(self.root.join("backups").to_string_lossy().into_owned()),
            retention_days: RETAIN_AUTOMATIC_BACKUPS,
            last_error: Some(format!("Previous backup status could not be read: {error}")),
            ..BackupStatus::default()
        });
        status.last_attempt = Some(attempted_at.into());
        let directory = self.root.join("backups");
        let path = directory.join(format!("auto-{date}.dump"));
        let mut created = false;
        let result = (|| {
            if !automatic_backup_name(&format!("auto-{date}.dump")) {
                return Err("Invalid automatic backup date".into());
            }
            private_directory(&directory)?;
            if verify_checksum(&path).is_err() {
                self.backup(&path)?;
                created = true;
                let pending = path.with_extension("sha256.partial");
                private_file(&pending, checksum(&path)?.as_bytes())?;
                std::fs::rename(pending, path.with_extension("sha256"))
                    .map_err(|e| e.to_string())?;
            }
            verify_checksum(&path)?;
            prune_automatic_backups(&directory)?;
            Ok::<_, String>(())
        })();
        match &result {
            Ok(()) => {
                // Preserve the original dump time on hourly checks of the same day's file.
                let backup = path.to_string_lossy().into_owned();
                if created
                    || status.last_backup.as_deref() != Some(&backup)
                    || status.last_error.is_some()
                {
                    status.last_success = Some(attempted_at.into());
                }
                status.last_backup = Some(backup);
                status.last_error = None;
            }
            Err(error) => status.last_error = Some(error.clone()),
        }
        let pending = self.root.join("backup-status.pending.json");
        private_file(
            &pending,
            &serde_json::to_vec(&status).map_err(|e| e.to_string())?,
        )?;
        std::fs::rename(pending, self.root.join("backup-status.json"))
            .map_err(|e| e.to_string())?;
        result
    }
    /// Restore to a new database. Never overwrite the current database or activate an unvalidated restore.
    pub async fn restore(&self, path: PathBuf) -> Result<(), String> {
        let pg = self.clone();
        let database = format!("restore_{}", Uuid::new_v4().simple());
        let target = database.clone();
        let restored_url = tokio::task::spawn_blocking(move || {
            if path.with_extension("sha256").exists() {
                verify_checksum(&path)?;
            }
            checked(
                pg.tool("pg_restore").arg("--list").arg(&path).output(),
                "pg_restore validation",
            )?;
            let backups = pg.root.join("backups");
            private_directory(&backups)?;
            pg.backup(&backups.join(format!("before-{target}.dump")))?;
            checked(
                pg.tool("createdb")
                    .arg(&target)
                    .env("LD_LIBRARY_PATH", &pg.lib)
                    .output(),
                "createdb",
            )?;
            let (base, _) = pg
                .url
                .rsplit_once('/')
                .ok_or("Invalid local database address")?;
            let url = format!("{base}/{target}");
            checked(
                pg.tool("pg_restore")
                    .args([
                        "--no-owner",
                        "--no-acl",
                        "--exit-on-error",
                        "--single-transaction",
                        "--dbname",
                        &target,
                    ])
                    .arg(&path)
                    .env("LD_LIBRARY_PATH", &pg.lib)
                    .output(),
                "pg_restore",
            )?;
            Ok::<_, String>(url)
        })
        .await
        .map_err(|e| e.to_string())??;
        let restored = sbco_infrastructure::Database::connect(&restored_url)
            .await
            .map_err(|e| e.to_string())?;
        if restored.needs_setup().await.map_err(|e| e.to_string())? {
            return Err("Backup contains no SBCO accounts; current database is unchanged".into());
        }
        sqlx::query("DELETE FROM sessions")
            .execute(&restored.pool)
            .await
            .map_err(|e| e.to_string())?;
        restored.pool.close().await;
        let config_path = self.root.join("database.json");
        let mut config: Config =
            serde_json::from_slice(&std::fs::read(&config_path).map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?;
        config.database = database;
        let pending = self.root.join("database.pending.json");
        private_file(
            &pending,
            &serde_json::to_vec(&config).map_err(|e| e.to_string())?,
        )?;
        std::fs::rename(pending, config_path).map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sbco_application::Backend;

    #[test]
    fn windows_initialization_uses_postgresql_builtin_unicode_locale() {
        assert_eq!(
            initdb_locale_arguments(true),
            &[
                "--encoding=UTF8",
                "--locale=C",
                "--locale-provider=builtin",
                "--builtin-locale=C.UTF-8"
            ]
        );
        assert_eq!(
            initdb_locale_arguments(false),
            &["--encoding=UTF8", "--locale=C.UTF-8"]
        );
    }

    #[test]
    fn incompatible_clusters_are_rejected_before_configuration_or_tools_are_touched() {
        for version in ["17", "19", "invalid"] {
            let root = std::env::temp_dir().join(format!("sbco-version-{}", Uuid::new_v4()));
            let data = root.join("postgres");
            std::fs::create_dir_all(&data).unwrap();
            std::fs::write(data.join("PG_VERSION"), version).unwrap();
            std::fs::write(data.join("preserve.txt"), b"existing data").unwrap();
            let result = LocalPostgres::start(&root, &root.join("missing-tools"));
            assert!(matches!(result, Err(error) if error.contains("major-version upgrade")));
            assert!(!root.join("database.json").exists());
            assert_eq!(
                std::fs::read_to_string(data.join("PG_VERSION")).unwrap(),
                version
            );
            assert_eq!(
                std::fs::read(data.join("preserve.txt")).unwrap(),
                b"existing data"
            );
            std::fs::remove_dir_all(root).unwrap();
        }
    }

    #[test]
    fn retention_only_removes_the_oldest_automatic_backups() {
        let root = std::env::temp_dir().join(format!("sbco-retention-{}", Uuid::new_v4()));
        private_directory(&root).unwrap();
        for day in 1..=16 {
            let path = root.join(format!("auto-2026-10-{day:02}.dump"));
            private_file(&path, b"backup").unwrap();
            private_file(
                &path.with_extension("sha256"),
                checksum(&path).unwrap().as_bytes(),
            )
            .unwrap();
        }
        for name in [
            "manual.dump",
            "before-restore.dump",
            "auto-2026-10-99.dump",
            "auto-2026-10-01.dump.partial",
        ] {
            private_file(&root.join(name), b"preserve").unwrap();
        }
        prune_automatic_backups(&root).unwrap();
        assert!(!root.join("auto-2026-10-01.dump").exists());
        assert!(!root.join("auto-2026-10-02.sha256").exists());
        assert!(root.join("auto-2026-10-03.dump").exists());
        assert!(root.join("auto-2026-10-16.dump").exists());
        for name in [
            "manual.dump",
            "before-restore.dump",
            "auto-2026-10-99.dump",
            "auto-2026-10-01.dump.partial",
        ] {
            assert!(root.join(name).exists());
        }
        let path = root.join("auto-2026-10-16.dump");
        verify_checksum(&path).unwrap();
        private_file(&path, b"corrupt").unwrap();
        assert!(
            verify_checksum(&path)
                .unwrap_err()
                .contains("does not match")
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    #[ignore = "requires bundled PostgreSQL tools and an unprivileged OS account"]
    async fn local_database_survives_restart_and_restores_to_a_new_database() {
        let root = std::env::temp_dir().join(format!("sbco-lifecycle-{}", Uuid::new_v4()));
        let resources =
            PathBuf::from(std::env::var("SBCO_TEST_RESOURCES").expect("resource directory"));
        eprintln!("lifecycle stage: initialize PostgreSQL");
        let pg = LocalPostgres::start(&root, &resources).expect("initialize local PostgreSQL");
        eprintln!("lifecycle stage: reject second instance");
        assert!(
            LocalPostgres::start(&root, &resources).is_err(),
            "second instance must be rejected"
        );
        eprintln!("lifecycle stage: connect and migrate");
        let db = sbco_infrastructure::Database::connect(&pg.url)
            .await
            .unwrap();
        let empty_backup = root.join("empty.dump");
        eprintln!("lifecycle stage: empty backup");
        pg.backup(&empty_backup).unwrap();
        eprintln!("lifecycle stage: bootstrap and login");
        db.bootstrap(
            "Test Administrator",
            "local@example.test",
            "Temporary-test-password-9384".into(),
        )
        .await
        .unwrap();
        db.login(sbco_contracts::Login {
            email: "local@example.test".into(),
            password: "Temporary-test-password-9384".into(),
        })
        .await
        .unwrap();
        let backup = root.join("test.dump");
        eprintln!("lifecycle stage: manual and automatic backups");
        pg.backup(&backup).unwrap();
        pg.scheduled_backup_for_date("2026-10-28", "2026-10-28T01:00:00Z")
            .unwrap();
        let automatic = root.join("backups/auto-2026-10-28.dump");
        let hash = checksum(&automatic).unwrap();
        pg.scheduled_backup_for_date("2026-10-28", "2026-10-28T02:00:00Z")
            .unwrap();
        assert_eq!(checksum(&automatic).unwrap(), hash);
        assert_eq!(
            pg.backup_status().unwrap().last_success.as_deref(),
            Some("2026-10-28T01:00:00Z")
        );
        eprintln!("lifecycle stage: damaged backup rejection and repair");
        let original_config = std::fs::read(root.join("database.json")).unwrap();
        private_file(&automatic, b"damaged archive").unwrap();
        assert!(
            pg.restore(automatic.clone())
                .await
                .unwrap_err()
                .contains("checksum")
        );
        assert_eq!(
            std::fs::read(root.join("database.json")).unwrap(),
            original_config
        );
        pg.scheduled_backup_for_date("2026-10-28", "2026-10-28T03:00:00Z")
            .unwrap();
        verify_checksum(&automatic).unwrap();
        assert_eq!(
            pg.backup_status().unwrap().last_success.as_deref(),
            Some("2026-10-28T03:00:00Z")
        );
        std::fs::rename(root.join("backups"), root.join("saved-backups")).unwrap();
        private_file(&root.join("backups"), b"cannot create directory here").unwrap();
        assert!(
            pg.scheduled_backup_for_date("2026-10-29", "2026-10-29T01:00:00Z")
                .is_err()
        );
        let status = pg.backup_status().unwrap();
        assert!(status.last_error.is_some());
        assert_eq!(status.last_success.as_deref(), Some("2026-10-28T03:00:00Z"));
        std::fs::remove_file(root.join("backups")).unwrap();
        std::fs::rename(root.join("saved-backups"), root.join("backups")).unwrap();
        pg.scheduled_backup_for_date("2026-10-29", "2026-10-29T02:00:00Z")
            .unwrap();
        assert!(pg.backup_status().unwrap().last_error.is_none());
        eprintln!("lifecycle stage: invalid archive rejection");
        let invalid = root.join("invalid.dump");
        private_file(&invalid, b"not a PostgreSQL archive").unwrap();
        assert!(pg.restore(invalid).await.is_err());
        assert_eq!(
            std::fs::read(root.join("database.json")).unwrap(),
            original_config
        );
        eprintln!("lifecycle stage: empty-account archive rejection");
        assert!(
            pg.restore(empty_backup)
                .await
                .unwrap_err()
                .contains("no SBCO accounts")
        );
        assert_eq!(
            std::fs::read(root.join("database.json")).unwrap(),
            original_config
        );
        sqlx::query("UPDATE users SET name='Changed after backup'")
            .execute(&db.pool)
            .await
            .unwrap();
        eprintln!("lifecycle stage: restore valid backup");
        pg.restore(backup).await.unwrap();
        db.pool.close().await;
        eprintln!("lifecycle stage: stop PostgreSQL");
        pg.stop();
        drop(pg);
        eprintln!("lifecycle stage: restart restored database");
        let pg = LocalPostgres::start(&root, &resources).unwrap();
        eprintln!("lifecycle stage: connect and migrate");
        let db = sbco_infrastructure::Database::connect(&pg.url)
            .await
            .unwrap();
        let name: String = sqlx::query_scalar("SELECT name FROM users")
            .fetch_one(&db.pool)
            .await
            .unwrap();
        assert_eq!(name, "Test Administrator");
        assert!(pg.url.contains("/restore_"));
        let sessions: i64 = sqlx::query_scalar("SELECT count(*) FROM sessions")
            .fetch_one(&db.pool)
            .await
            .unwrap();
        assert_eq!(sessions, 0);
        let original_exists: bool =
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='postgres')")
                .fetch_one(&db.pool)
                .await
                .unwrap();
        assert!(original_exists);
        db.pool.close().await;
        eprintln!("lifecycle stage: stop PostgreSQL");
        pg.stop();
        drop(pg);
        std::fs::remove_dir_all(root).unwrap();
        eprintln!("lifecycle stage: complete");
    }
}
