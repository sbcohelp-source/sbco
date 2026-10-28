//! Strict, additive setup import. A savepoint makes preview and failed imports non-mutating.
use crate::{auth::password_hash, db_error, role};
use calamine::{Data, Reader, open_workbook_auto_from_rs};
use sbco_domain::{Error, Result};
use serde_json::{Value, json};
use sqlx::{Acquire, Postgres, Row, Transaction};
use std::{
    collections::{BTreeMap, HashSet},
    io::Cursor,
};
use uuid::Uuid;

pub(crate) struct Setup {
    users: Vec<Vec<String>>,
    offices: Vec<Vec<String>>,
    pools: Vec<Vec<String>>,
}
fn invalid(message: impl Into<String>) -> Error {
    Error::Validation(message.into())
}

pub(crate) fn parse(content: Vec<u8>) -> Result<Setup> {
    let mut book = open_workbook_auto_from_rs(Cursor::new(content))
        .map_err(|e| invalid(format!("Cannot read setup workbook: {e}")))?;
    let mut read = |name: &str, headers: &[&str], limit: usize| -> Result<Vec<Vec<String>>> {
        let range = book
            .worksheet_range(name)
            .map_err(|_| invalid(format!("Missing {name} worksheet")))?;
        if range.height() > 10_001
            || range.width() > headers.len()
            || range.start().is_none_or(|s| s != (0, 0))
        {
            return Err(invalid(format!(
                "{name}: keep the template headers in row 1 and remove extra columns"
            )));
        }
        let mut rows = range.rows();
        let header = rows
            .next()
            .ok_or_else(|| invalid(format!("{name}: missing headers")))?;
        if header.len() != headers.len()
            || header
                .iter()
                .zip(headers)
                .any(|(a, b)| a.to_string().trim() != *b)
        {
            return Err(invalid(format!(
                "{name}: expected columns {}",
                headers.join(", ")
            )));
        }
        let mut output = Vec::new();
        for (i, row) in rows.enumerate() {
            if row
                .iter()
                .all(|c| matches!(c, Data::Empty) || c.to_string().trim().is_empty())
            {
                continue;
            }
            let mut values = Vec::new();
            for c in 0..headers.len() {
                let value = row
                    .get(c)
                    .map(|v| match v {
                        Data::Float(n) if n.fract() == 0.0 => format!("{n:.0}"),
                        _ => v.to_string().trim().to_owned(),
                    })
                    .unwrap_or_default();
                if value.len() > 4096 {
                    return Err(invalid(format!("{name} row {}: value too long", i + 2)));
                }
                values.push(value);
            }
            output.push(values);
        }
        if output.len() > limit {
            return Err(invalid(format!("{name}: maximum {limit} records")));
        }
        Ok(output)
    };
    let setup = Setup {
        users: read("Users", &["Full Name", "Email", "Role"], 200)?,
        offices: read(
            "Offices",
            &["Office ID", "Office Name", "Office Type", "Parent SO ID"],
            10_000,
        )?,
        pools: read(
            "Pools",
            &["Pool Name", "PA Email", "Office ID", "Random Percent"],
            10_000,
        )?,
    };
    if setup.users.is_empty() && setup.offices.is_empty() && setup.pools.is_empty() {
        return Err(invalid(
            "Enter setup data in Users, Offices or Pools before importing",
        ));
    }
    Ok(setup)
}

pub(crate) async fn apply(
    tx: &mut Transaction<'_, Postgres>,
    mut setup: Setup,
    preview: bool,
) -> Result<Value> {
    let mut tx = tx.begin().await.map_err(db_error)?;
    // Prevent setup previews and simultaneous administrative edits from racing validation.
    sqlx::query("LOCK TABLE users, offices, pools, pool_offices IN SHARE ROW EXCLUSIVE MODE")
        .execute(&mut *tx)
        .await
        .map_err(db_error)?;
    let mut created = [0u32; 3];
    let mut existing = [0u32; 3];
    let mut seen = HashSet::new();
    for row in &setup.users {
        let (name, email, role_name) = (&row[0], row[1].to_lowercase(), &row[2]);
        role(role_name)?;
        if name.is_empty()
            || !email.contains('@')
            || email.contains(char::is_whitespace)
            || !seen.insert(email.clone())
        {
            return Err(invalid(format!(
                "Users: missing name, invalid or duplicate email {email}"
            )));
        }
        if let Some(user) = sqlx::query("SELECT name,role,active FROM users WHERE email=$1")
            .bind(&email)
            .fetch_optional(&mut *tx)
            .await
            .map_err(db_error)?
        {
            if user.get::<String, _>("name") != *name
                || user.get::<String, _>("role") != *role_name
                || !user.get::<bool, _>("active")
            {
                return Err(invalid(format!(
                    "Users: {email} already exists with different details. Use Users to edit access."
                )));
            }
            existing[0] += 1;
        } else {
            // No spreadsheet passwords. Each account receives an unknown, unique random secret.
            let hash = password_hash(format!("{}{}", Uuid::new_v4(), Uuid::new_v4())).await?;
            sqlx::query(
                "INSERT INTO users(id,name,email,role,password_hash) VALUES($1,$2,$3,$4,$5)",
            )
            .bind(Uuid::new_v4())
            .bind(name)
            .bind(email)
            .bind(role_name)
            .bind(hash)
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;
            created[0] += 1;
        }
    }
    seen.clear();
    setup.offices.sort_by_key(|r| r[2] != "SO");
    for row in &setup.offices {
        let (id, name, kind, parent) = (&row[0], &row[1], &row[2], &row[3]);
        if id.is_empty()
            || name.is_empty()
            || !matches!(kind.as_str(), "SO" | "BO")
            || !seen.insert(id.clone())
        {
            return Err(invalid(format!(
                "Offices: invalid or duplicate office {id}"
            )));
        }
        if (kind == "SO" && !parent.is_empty()) || (kind == "BO" && parent.is_empty()) {
            return Err(invalid(format!(
                "Offices: {id} must have a parent SO only when its type is BO"
            )));
        }
        let parent = if parent.is_empty() {
            None
        } else {
            Some(parent)
        };
        if let Some(parent) = parent {
            let valid: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM offices WHERE id=$1 AND office_type='SO')",
            )
            .bind(parent)
            .fetch_one(&mut *tx)
            .await
            .map_err(db_error)?;
            if !valid {
                return Err(invalid(format!(
                    "Offices: parent SO {parent} does not exist"
                )));
            }
        }
        if let Some(old) = sqlx::query("SELECT name,office_type,parent_id FROM offices WHERE id=$1")
            .bind(id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(db_error)?
        {
            if old.get::<String, _>("name") != *name
                || old.get::<String, _>("office_type") != *kind
                || old.get::<Option<String>, _>("parent_id").as_ref() != parent
            {
                return Err(invalid(format!(
                    "Offices: {id} already exists with different details. Use Offices to edit it."
                )));
            }
            existing[1] += 1;
        } else {
            sqlx::query("INSERT INTO offices(id,name,office_type,parent_id) VALUES($1,$2,$3,$4)")
                .bind(id)
                .bind(name)
                .bind(kind)
                .bind(parent)
                .execute(&mut *tx)
                .await
                .map_err(db_error)?;
            created[1] += 1;
        }
    }
    let mut groups: BTreeMap<String, (String, i32, Vec<String>)> = BTreeMap::new();
    seen.clear();
    for row in &setup.pools {
        let (name, email, office) = (&row[0], row[1].to_lowercase(), &row[2]);
        let percent = row[3]
            .parse::<i32>()
            .ok()
            .filter(|p| (0..=100).contains(p))
            .ok_or_else(|| {
                invalid(format!(
                    "Pools: {name} needs a whole Random Percent from 0 to 100"
                ))
            })?;
        if name.is_empty() || office.is_empty() || !seen.insert(office.clone()) {
            return Err(invalid(format!(
                "Pools: missing pool name or invalid/duplicate office {office}"
            )));
        }
        let group = groups
            .entry(name.clone())
            .or_insert_with(|| (email.clone(), percent, vec![]));
        if group.0 != email || group.1 != percent {
            return Err(invalid(format!(
                "Pools: repeat the same PA Email and Random Percent for {name}"
            )));
        }
        group.2.push(office.clone());
    }
    for (name, (email, percent, mut offices)) in groups {
        let pa: Option<Uuid> = if email.is_empty() {
            None
        } else {
            Some(
                sqlx::query_scalar("SELECT id FROM users WHERE email=$1 AND active AND role='Pa'")
                    .bind(&email)
                    .fetch_optional(&mut *tx)
                    .await
                    .map_err(db_error)?
                    .ok_or_else(|| invalid(format!("Pools: {email} must be an active PA user")))?,
            )
        };
        offices.sort();
        if let Some(old) = sqlx::query("SELECT id,pa_user,random_percent FROM pools WHERE name=$1")
            .bind(&name)
            .fetch_optional(&mut *tx)
            .await
            .map_err(db_error)?
        {
            let prior: Vec<String> = sqlx::query_scalar(
                "SELECT office_id FROM pool_offices WHERE pool_id=$1 ORDER BY office_id",
            )
            .bind(old.get::<Uuid, _>("id"))
            .fetch_all(&mut *tx)
            .await
            .map_err(db_error)?;
            if old.get::<Option<Uuid>, _>("pa_user") != pa
                || old.get::<i32, _>("random_percent") != percent
                || prior != offices
            {
                return Err(invalid(format!(
                    "Pools: {name} already exists with different details. Use Pools to edit it."
                )));
            }
            existing[2] += 1;
            continue;
        }
        let id = Uuid::new_v4();
        sqlx::query("INSERT INTO pools(id,name,pa_user,random_percent) VALUES($1,$2,$3,$4)")
            .bind(id)
            .bind(&name)
            .bind(pa)
            .bind(percent)
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;
        for office in offices {
            let valid: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM offices WHERE id=$1) AND NOT EXISTS(SELECT 1 FROM pool_offices WHERE office_id=$1)")
                .bind(&office).fetch_one(&mut *tx).await.map_err(db_error)?;
            if !valid {
                return Err(invalid(format!(
                    "Pools: office {office} is missing or already assigned to a pool"
                )));
            }
            sqlx::query("INSERT INTO pool_offices(office_id,pool_id) VALUES($1,$2)")
                .bind(office)
                .bind(id)
                .execute(&mut *tx)
                .await
                .map_err(db_error)?;
        }
        created[2] += 1;
    }
    if preview {
        tx.rollback().await.map_err(db_error)?;
    } else {
        tx.commit().await.map_err(db_error)?;
    }
    Ok(
        json!({"preview":preview,"created":{"users":created[0],"offices":created[1],"pools":created[2]},"existing":{"users":existing[0],"offices":existing[1],"pools":existing[2]}}),
    )
}
