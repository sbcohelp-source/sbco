//! Personal practice workspaces. Never fall back to public when a workspace is
//! absent or stale. Lifecycle row locks cover every operation, including jobs.
use super::{Database, db_error, role};
use sbco_application::Backend;
use sbco_contracts::{Command, CommandRequest, ExportRequest, Query, TrainingContext};
use sbco_domain::{Actor, Error, Result};
use serde_json::{Value, json};
use sqlx::{
    Postgres, Row, Transaction,
    postgres::{PgPoolOptions, PgRow},
};
use uuid::Uuid;

fn empty_status() -> Value {
    json!({"available":false,"generation":null,"counts":{"offices":0,"users":0,"pools":0,"imports":0,"transactions":0,"incidents":0,"letters":0}})
}
fn stale() -> Error {
    Error::Conflict("This training workspace was reset or is unavailable. Return to Live and enable training again.".into())
}
fn schema_name(generation: Uuid) -> String {
    format!("sbco_training_{}", generation.simple())
}
async fn owner_lock(tx: &mut Transaction<'_, Postgres>, owner: &Actor) -> Result<()> {
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 912047))")
        .bind(owner.id.to_string())
        .execute(&mut **tx)
        .await
        .map_err(db_error)?;
    live_owner(tx, owner).await
}
async fn live_owner(tx: &mut Transaction<'_, Postgres>, owner: &Actor) -> Result<()> {
    let active: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM public.users WHERE id=$1 AND active)")
            .bind(owner.id)
            .fetch_one(&mut **tx)
            .await
            .map_err(db_error)?;
    if active {
        Ok(())
    } else {
        Err(Error::Forbidden)
    }
}
impl Database {
    async fn practice_database(&self, row: &PgRow) -> Result<Self> {
        let generation: Uuid = row.get("generation");
        let schema: String = row.get("schema_name");
        if schema != schema_name(generation) {
            return Err(stale());
        }
        let options = (*self.pool.connect_options()).clone();
        let pool = PgPoolOptions::new().max_connections(2)
            .acquire_timeout(std::time::Duration::from_secs(10))
            .after_connect(move |connection, _| {
                let schema = schema.clone();
                Box::pin(async move {
                    sqlx::query("SELECT set_config('search_path',$1,false),set_config('sbco.training','1',false)").bind(schema).execute(connection).await?;
                    Ok(())
                })
            }).connect_with(options).await.map_err(db_error)?;
        sqlx::migrate!("../../migrations")
            .run(&pool)
            .await
            .map_err(|error| {
                tracing::error!(%error,"Training migration failed");
                Error::Internal
            })?;
        Ok(Self { pool })
    }
    async fn training_lock(
        &self,
        owner: &Actor,
        generation: Uuid,
    ) -> Result<(Transaction<'_, Postgres>, PgRow)> {
        let mut tx = self.pool.begin().await.map_err(db_error)?;
        live_owner(&mut tx, owner).await?;
        let row = sqlx::query("SELECT * FROM public.training_workspaces WHERE owner_id=$1 AND generation=$2 FOR SHARE")
            .bind(owner.id).bind(generation).fetch_optional(&mut *tx).await.map_err(db_error)?.ok_or_else(stale)?;
        Ok((tx, row))
    }
    async fn practice_actor(
        &self,
        owner: &Actor,
        context: &TrainingContext,
        row: &PgRow,
    ) -> Result<Actor> {
        let selected = role(&context.role)?;
        let id = match selected {
            sbco_domain::Role::Administrator => owner.id,
            sbco_domain::Role::Pa => row.get("pa_id"),
            sbco_domain::Role::Supervisor => row.get("supervisor_id"),
        };
        let user = sqlx::query("SELECT name FROM users WHERE id=$1 AND role=$2 AND active")
            .bind(id)
            .bind(&context.role)
            .fetch_optional(&self.pool)
            .await
            .map_err(db_error)?
            .ok_or_else(stale)?;
        Ok(Actor {
            id,
            name: user.get("name"),
            role: selected,
        })
    }
    async fn practice_status(&self, generation: Uuid) -> Result<Value> {
        let counts: Value = sqlx::query_scalar("SELECT jsonb_build_object('offices',(SELECT count(*) FROM offices),'users',(SELECT count(*) FROM users),'pools',(SELECT count(*) FROM pools),'imports',(SELECT count(*) FROM imports),'transactions',(SELECT count(*) FROM transactions),'incidents',(SELECT count(*) FROM incidents),'letters',(SELECT count(*) FROM letters))").fetch_one(&self.pool).await.map_err(db_error)?;
        Ok(json!({"available":true,"generation":generation,"counts":counts}))
    }
    pub async fn training_status(&self, owner: &Actor) -> Result<Value> {
        let mut tx = self.pool.begin().await.map_err(db_error)?;
        live_owner(&mut tx, owner).await?;
        let row =
            sqlx::query("SELECT * FROM public.training_workspaces WHERE owner_id=$1 FOR SHARE")
                .bind(owner.id)
                .fetch_optional(&mut *tx)
                .await
                .map_err(db_error)?;
        let Some(row) = row else {
            return Ok(empty_status());
        };
        let db = self.practice_database(&row).await?;
        let result = db.practice_status(row.get("generation")).await;
        db.pool.close().await;
        tx.commit().await.map_err(db_error)?;
        result
    }
    pub async fn enable_training(&self, owner: &Actor) -> Result<Value> {
        let mut tx = self.pool.begin().await.map_err(db_error)?;
        owner_lock(&mut tx, owner).await?;
        if let Some(row) =
            sqlx::query("SELECT * FROM public.training_workspaces WHERE owner_id=$1 FOR SHARE")
                .bind(owner.id)
                .fetch_optional(&mut *tx)
                .await
                .map_err(db_error)?
        {
            let db = self.practice_database(&row).await?;
            let result = db.practice_status(row.get("generation")).await;
            db.pool.close().await;
            return result;
        }
        let generation = Uuid::new_v4();
        let schema = schema_name(generation);
        let pa = Uuid::new_v4();
        let supervisor = Uuid::new_v4();
        // Provision with an unpublished metadata row; transactional DDL below
        // makes initialization and publication atomic, including cancellation.
        sqlx::query(sqlx::AssertSqlSafe(format!("CREATE SCHEMA {schema}")))
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;
        sqlx::query(
            "SELECT set_config('search_path',$1,true),set_config('sbco.training','1',true)",
        )
        .bind(&schema)
        .execute(&mut *tx)
        .await
        .map_err(db_error)?;
        let mut migrator = sqlx::migrate!("../../migrations");
        migrator.set_locking(false); // Owner advisory lock protects unpublished schema.
        migrator
            .run_direct(None, &mut *tx, false)
            .await
            .map_err(|error| {
                tracing::error!(%error,"Training initialization failed");
                Error::Internal
            })?;
        super::training_seed::seed(&mut tx, owner, pa, supervisor).await?;
        sqlx::query("INSERT INTO public.training_workspaces(owner_id,generation,schema_name,pa_id,supervisor_id) VALUES($1,$2,$3,$4,$5)").bind(owner.id).bind(generation).bind(&schema).bind(pa).bind(supervisor).execute(&mut *tx).await.map_err(db_error)?;
        sqlx::query("INSERT INTO public.audit(actor_id,action,entity_id,detail) VALUES($1,'EnableTraining',$2,$3)").bind(owner.id).bind(generation.to_string()).bind(json!({"generation":generation})).execute(&mut *tx).await.map_err(db_error)?;
        tx.commit().await.map_err(db_error)?;
        self.training_status(owner).await
    }
    pub async fn reset_training(
        &self,
        owner: &Actor,
        generation: Uuid,
        confirmation: &str,
    ) -> Result<Value> {
        if confirmation != "DELETE TRAINING" {
            return Err(Error::Validation(
                "Type DELETE TRAINING to remove all of your training records and training history."
                    .into(),
            ));
        }
        let mut tx = self.pool.begin().await.map_err(db_error)?;
        owner_lock(&mut tx, owner).await?;
        let row = sqlx::query("SELECT * FROM public.training_workspaces WHERE owner_id=$1 AND generation=$2 FOR UPDATE").bind(owner.id).bind(generation).fetch_optional(&mut *tx).await.map_err(db_error)?.ok_or_else(stale)?;
        let schema: String = row.get("schema_name");
        if schema != schema_name(generation) {
            return Err(stale());
        }
        sqlx::query(sqlx::AssertSqlSafe(format!("DROP SCHEMA {schema} CASCADE")))
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;
        sqlx::query("DELETE FROM public.training_workspaces WHERE owner_id=$1")
            .bind(owner.id)
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;
        sqlx::query("INSERT INTO public.audit(actor_id,action,entity_id,detail) VALUES($1,'ResetTraining',$2,$3)").bind(owner.id).bind(generation.to_string()).bind(json!({"generation":generation,"training_history_removed":true})).execute(&mut *tx).await.map_err(db_error)?;
        tx.commit().await.map_err(db_error)?;
        Ok(empty_status())
    }
    pub async fn training_actor(&self, owner: &Actor, context: &TrainingContext) -> Result<Actor> {
        let (tx, row) = self.training_lock(owner, context.generation).await?;
        let db = self.practice_database(&row).await?;
        let result = db.practice_actor(owner, context, &row).await;
        db.pool.close().await;
        tx.commit().await.map_err(db_error)?;
        result
    }
    pub async fn training_query(
        &self,
        owner: &Actor,
        context: &TrainingContext,
        query: Query,
    ) -> Result<Value> {
        let (tx, row) = self.training_lock(owner, context.generation).await?;
        let db = self.practice_database(&row).await?;
        let result = async {
            let actor = db.practice_actor(owner, context, &row).await?;
            db.query(&actor, query).await
        }
        .await;
        db.pool.close().await;
        tx.commit().await.map_err(db_error)?;
        result
    }
    pub async fn training_command(
        &self,
        owner: &Actor,
        context: &TrainingContext,
        request: CommandRequest,
    ) -> Result<Value> {
        let (tx, row) = self.training_lock(owner, context.generation).await?;
        if matches!(request.command, Command::ChangePassword { .. }) {
            return Err(Error::Validation("Password changes are unavailable in training. Return to Live to change your account password.".into()));
        }
        let db = self.practice_database(&row).await?;
        let result = async {
            let actor = db.practice_actor(owner, context, &row).await?;
            if let Command::UpdateUser { user_id, role, active, .. } = &request.command {
                actor.require_admin()?;
                // These identities make the role switcher and recovery controls
                // reachable. Setup imports are additive and cannot edit users.
                let expected = if *user_id == owner.id {
                    Some("Administrator")
                } else if *user_id == row.get::<Uuid, _>("pa_id") {
                    Some("Pa")
                } else if *user_id == row.get::<Uuid, _>("supervisor_id") {
                    Some("Supervisor")
                } else {
                    None
                };
                if expected.is_some_and(|expected| role != expected || !active) {
                    return Err(Error::Validation("The three built-in training accounts must keep their roles and remain active. Create another training user to practise changing access.".into()));
                }
            }
            db.command(&actor, request).await
        }
        .await;
        db.pool.close().await;
        tx.commit().await.map_err(db_error)?;
        result
    }
    pub async fn training_export(
        &self,
        owner: &Actor,
        context: &TrainingContext,
        request: ExportRequest,
    ) -> Result<Vec<u8>> {
        let (tx, row) = self.training_lock(owner, context.generation).await?;
        let db = self.practice_database(&row).await?;
        let result = async {
            let actor = db.practice_actor(owner, context, &row).await?;
            db.export(&actor, request).await
        }
        .await;
        db.pool.close().await;
        tx.commit().await.map_err(db_error)?;
        result
    }
    pub async fn training_tick(&self) -> Result<bool> {
        let owners = sqlx::query("SELECT owner_id,generation FROM public.training_workspaces")
            .fetch_all(&self.pool)
            .await
            .map_err(db_error)?;
        let mut worked = false;
        for owner in owners {
            let mut tx = self.pool.begin().await.map_err(db_error)?;
            let row = sqlx::query("SELECT w.* FROM public.training_workspaces w JOIN public.users u ON u.id=w.owner_id WHERE w.owner_id=$1 AND w.generation=$2 AND u.active FOR SHARE OF w").bind(owner.get::<Uuid,_>("owner_id")).bind(owner.get::<Uuid,_>("generation")).fetch_optional(&mut *tx).await.map_err(db_error)?;
            if let Some(row) = row {
                let db = self.practice_database(&row).await?;
                let result = async {
                    db.mark_overdue().await?;
                    db.tick().await
                }
                .await;
                db.pool.close().await;
                match result {
                    Ok(value) => worked |= value,
                    Err(error) => tracing::error!(%error,"Training worker failed"),
                }
            }
            tx.commit().await.map_err(db_error)?;
        }
        Ok(worked)
    }
}

#[allow(dead_code)]
fn assert_training_send(db: &Database, actor: &Actor) {
    fn send(_: impl Send) {}
    send(db.enable_training(actor));
}
