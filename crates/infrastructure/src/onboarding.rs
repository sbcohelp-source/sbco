use crate::db_error;
use sbco_domain::{Actor, Error, Result, Role};
use serde_json::{Value, json};
use sqlx::{PgPool, Postgres, Row, Transaction};

fn allowed_steps(role: &Role) -> &'static [&'static str] {
    match role {
        Role::Administrator => &[
            "welcome",
            "offices",
            "team",
            "preferences",
            "import",
            "ready",
        ],
        Role::Pa | Role::Supervisor => &["welcome", "work", "review", "ready"],
    }
}

fn role_name(role: &Role) -> &'static str {
    match role {
        Role::Administrator => "Administrator",
        Role::Supervisor => "Supervisor",
        Role::Pa => "Pa",
    }
}

pub(crate) async fn read(pool: &PgPool, actor: &Actor) -> Result<Value> {
    // One statement gives all progress counts the same database snapshot. The PA condition
    // deliberately scopes both office and transaction counts through current pool allocation.
    let row = sqlx::query(
        r#"
        WITH assigned AS (
            SELECT po.office_id FROM pool_offices po
            JOIN pools p ON p.id = po.pool_id
            WHERE p.pa_user IS NOT NULL AND ($2 OR p.pa_user = $1)
        )
        SELECT
            (SELECT role FROM user_onboarding WHERE user_id = $1) AS saved_role,
            coalesce((SELECT step FROM user_onboarding WHERE user_id = $1), 'welcome') AS step,
            coalesce((SELECT completed FROM user_onboarding WHERE user_id = $1), false) AS completed,
            (SELECT count(*) FROM offices WHERE $2 OR id IN (SELECT office_id FROM assigned)) AS office_count,
            (SELECT count(*) FROM assigned) AS assigned_office_count,
            CASE WHEN $2 THEN (SELECT count(*) FROM users WHERE active) ELSE NULL END AS user_count,
            CASE WHEN $2 THEN (SELECT count(*) FROM imports) ELSE NULL END AS import_count,
            (SELECT count(*) FROM transactions WHERE $2 OR office_id IN (SELECT office_id FROM assigned)) AS transaction_count
        "#,
    )
    .bind(actor.id)
    .bind(actor.role != Role::Pa)
    .fetch_one(pool)
    .await
    .map_err(db_error)?;
    let stored_step: String = row.get("step");
    let saved_role: Option<String> = row.get("saved_role");
    let step_is_allowed = saved_role.as_deref() == Some(role_name(&actor.role))
        && allowed_steps(&actor.role).contains(&stored_step.as_str());
    // A role change must not skip the new role's guide, even if the previous one was completed.
    let step = if step_is_allowed {
        stored_step.as_str()
    } else {
        "welcome"
    };
    Ok(json!({
        "step": step,
        "completed": step_is_allowed && row.get::<bool, _>("completed"),
        "office_count": row.get::<i64, _>("office_count"),
        "assigned_office_count": row.get::<i64, _>("assigned_office_count"),
        "user_count": row.get::<Option<i64>, _>("user_count"),
        "import_count": row.get::<Option<i64>, _>("import_count"),
        "transaction_count": row.get::<i64, _>("transaction_count"),
    }))
}

pub(crate) async fn save(
    tx: &mut Transaction<'_, Postgres>,
    actor: &Actor,
    step: &str,
    completed: bool,
) -> Result<Value> {
    if !allowed_steps(&actor.role).contains(&step) {
        return Err(Error::Validation(
            "This onboarding step is not available for your role".into(),
        ));
    }
    if completed && step != "ready" {
        return Err(Error::Validation(
            "Finish onboarding from the ready step".into(),
        ));
    }
    if completed && actor.role == Role::Administrator {
        let has_office: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM offices)")
            .fetch_one(&mut **tx)
            .await
            .map_err(db_error)?;
        if !has_office {
            return Err(Error::Validation(
                "Create at least one office before completing setup".into(),
            ));
        }
    }
    sqlx::query(
        "INSERT INTO user_onboarding(user_id,role,step,completed) VALUES($1,$2,$3,$4) \
         ON CONFLICT(user_id) DO UPDATE SET role=excluded.role,step=excluded.step,completed=excluded.completed,updated_at=now()",
    )
    .bind(actor.id)
    .bind(role_name(&actor.role))
    .bind(step)
    .bind(completed)
    .execute(&mut **tx)
    .await
    .map_err(db_error)?;
    Ok(json!({"step": step, "completed": completed}))
}
