use super::{Database, db_error, role};
use argon2::{
    Argon2, PasswordHash, PasswordHasher, PasswordVerifier,
    password_hash::{SaltString, rand_core::OsRng},
};
use sbco_contracts::Login;
use sbco_domain::{Actor, Error, Result};
use sha2::{Digest, Sha256};
use sqlx::Row;
use uuid::Uuid;

pub(crate) fn hash(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
pub(crate) async fn password_hash(password: String) -> Result<String> {
    if password.len() < 12 || password.len() > 1024 {
        return Err(Error::Validation(
            "Password must contain 12–1024 bytes".into(),
        ));
    }
    tokio::task::spawn_blocking(move || {
        Argon2::default()
            .hash_password(password.as_bytes(), &SaltString::generate(&mut OsRng))
            .map(|h| h.to_string())
            .map_err(|_| Error::Internal)
    })
    .await
    .map_err(|_| Error::Internal)?
}
pub(crate) async fn password_matches(password: String, hash: String) -> bool {
    tokio::task::spawn_blocking(move || {
        PasswordHash::new(&hash).is_ok_and(|h| {
            Argon2::default()
                .verify_password(password.as_bytes(), &h)
                .is_ok()
        })
    })
    .await
    .unwrap_or(false)
}
impl Database {
    pub async fn needs_setup(&self) -> Result<bool> {
        sqlx::query_scalar("SELECT NOT EXISTS(SELECT 1 FROM users)")
            .fetch_one(&self.pool)
            .await
            .map_err(db_error)
    }
    pub async fn bootstrap(&self, name: &str, email: &str, password: String) -> Result<()> {
        let hash = password_hash(password).await?;
        let mut tx = self.pool.begin().await.map_err(db_error)?;
        sqlx::query("SELECT pg_advisory_xact_lock(741293)")
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;
        let count: i64 = sqlx::query_scalar("SELECT count(*) FROM users")
            .fetch_one(&mut *tx)
            .await
            .map_err(db_error)?;
        if count != 0 {
            return Err(Error::Conflict(
                "Administrator setup has already been completed".into(),
            ));
        }
        sqlx::query("INSERT INTO users(id,name,email,password_hash,role) VALUES($1,$2,$3,$4,'Administrator')")
            .bind(Uuid::new_v4()).bind(name.trim()).bind(email.trim().to_lowercase()).bind(hash).execute(&mut *tx).await.map_err(db_error)?;
        tx.commit().await.map_err(db_error)
    }
    /// Local operator recovery only: no HTTP or desktop IPC endpoint exposes this operation.
    pub async fn recover_admin(&self, email: &str, password: String) -> Result<()> {
        let hash = password_hash(password).await?;
        let email = email.trim().to_lowercase();
        let mut tx = self.pool.begin().await.map_err(db_error)?;
        let id: Uuid = sqlx::query_scalar(
            "SELECT id FROM users WHERE email=$1 AND role='Administrator' AND active FOR UPDATE",
        )
        .bind(&email)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_error)?
        .ok_or(Error::NotFound)?;
        sqlx::query("UPDATE users SET password_hash=$2 WHERE id=$1")
            .bind(id)
            .bind(hash)
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;
        sqlx::query("DELETE FROM sessions WHERE user_id=$1")
            .bind(id)
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;
        sqlx::query("DELETE FROM login_attempts WHERE email=$1")
            .bind(email)
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;
        sqlx::query("INSERT INTO audit(action,entity_id,detail) VALUES('operator_admin_recovery',$1,'{\"sessions_revoked\":true}')").bind(id.to_string()).execute(&mut *tx).await.map_err(db_error)?;
        tx.commit().await.map_err(db_error)
    }
    pub(crate) async fn sign_in(&self, login: Login) -> Result<(String, Actor)> {
        if login.email.len() > 255 || login.password.len() > 1024 {
            return Err(Error::Unauthorized);
        }
        let email = login.email.trim().to_lowercase();
        let blocked: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM login_attempts WHERE email=$1 AND failures>=5 AND blocked_until>now())").bind(&email).fetch_one(&self.pool).await.map_err(db_error)?;
        if blocked {
            return Err(Error::Validation(
                "Too many login attempts. Try again in 15 minutes.".into(),
            ));
        }
        let row =
            sqlx::query("SELECT id,name,role,password_hash FROM users WHERE email=$1 AND active")
                .bind(&email)
                .fetch_optional(&self.pool)
                .await
                .map_err(db_error)?;
        let valid = if let Some(r) = &row {
            password_matches(login.password, r.get("password_hash")).await
        } else {
            let _ = password_hash("invalid-login-placeholder".into()).await;
            false
        };
        if !valid {
            sqlx::query("INSERT INTO login_attempts VALUES($1,1,now()+interval '15 minutes') ON CONFLICT(email) DO UPDATE SET failures=CASE WHEN login_attempts.blocked_until<now() THEN 1 ELSE login_attempts.failures+1 END, blocked_until=now()+interval '15 minutes'").bind(email).execute(&self.pool).await.map_err(db_error)?;
            return Err(Error::Unauthorized);
        }
        let row = row.ok_or(Error::Unauthorized)?;
        let actor = Actor {
            id: row.get("id"),
            name: row.get("name"),
            role: role(row.get("role"))?,
        };
        let token = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
        let mut tx = self.pool.begin().await.map_err(db_error)?;
        sqlx::query("DELETE FROM login_attempts WHERE email=$1")
            .bind(email)
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;
        sqlx::query("DELETE FROM sessions WHERE expires_at<now()")
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;
        sqlx::query("INSERT INTO sessions VALUES($1,$2,now()+interval '8 hours')")
            .bind(hash(token.as_bytes()))
            .bind(actor.id)
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;
        tx.commit().await.map_err(db_error)?;
        Ok((token, actor))
    }
    pub(crate) async fn session(&self, token: &str) -> Result<Actor> {
        let row = sqlx::query("SELECT u.id,u.name,u.role FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=$1 AND s.expires_at>now() AND u.active").bind(hash(token.as_bytes())).fetch_optional(&self.pool).await.map_err(db_error)?.ok_or(Error::Unauthorized)?;
        Ok(Actor {
            id: row.get("id"),
            name: row.get("name"),
            role: role(row.get("role"))?,
        })
    }
}
