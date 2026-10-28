//! Synthetic practice data only; no live business records or secrets are copied.
use super::{
    auth::password_hash,
    commands::{apply_primary, create_letter},
    db_error,
};
use chrono::{Datelike, Duration, FixedOffset, Utc};
use sbco_domain::{Actor, Result, Role, Status};
use sqlx::{Postgres, Row, Transaction};
use uuid::Uuid;

pub(crate) async fn seed(
    tx: &mut Transaction<'_, Postgres>,
    owner: &Actor,
    pa: Uuid,
    supervisor: Uuid,
) -> Result<()> {
    for (id, name, email, role) in [
        (
            owner.id,
            format!("{} (Training)", owner.name),
            "administrator@training.invalid",
            "Administrator",
        ),
        (
            pa,
            "DEMO Postal Assistant".into(),
            "pa@training.invalid",
            "Pa",
        ),
        (
            supervisor,
            "DEMO Supervisor".into(),
            "supervisor@training.invalid",
            "Supervisor",
        ),
    ] {
        let hash = password_hash(format!("{}{}", Uuid::new_v4(), Uuid::new_v4())).await?;
        sqlx::query("INSERT INTO users(id,name,email,password_hash,role) VALUES($1,$2,$3,$4,$5)")
            .bind(id)
            .bind(name)
            .bind(email)
            .bind(hash)
            .bind(role)
            .execute(&mut **tx)
            .await
            .map_err(db_error)?;
    }
    sqlx::query("INSERT INTO offices(id,name,office_type,parent_id) VALUES('DEMO-SO1','DEMO Central Sub Office','SO',NULL),('DEMO-SO2','DEMO Garden Sub Office','SO',NULL),('DEMO-BO1','DEMO Riverside Branch Office','BO','DEMO-SO1')").execute(&mut **tx).await.map_err(db_error)?;
    let pool = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO pools(id,name,pa_user,random_percent) VALUES($1,'DEMO Practice Pool',$2,0)",
    )
    .bind(pool)
    .bind(pa)
    .execute(&mut **tx)
    .await
    .map_err(db_error)?;
    sqlx::query("INSERT INTO pool_offices(office_id,pool_id) SELECT id,$1 FROM offices")
        .bind(pool)
        .execute(&mut **tx)
        .await
        .map_err(db_error)?;
    let import = Uuid::new_v4();
    sqlx::query("INSERT INTO imports(id,filename,file_hash,content,status,total,inserted,imported_by) VALUES($1,'DEMO synthetic practice vouchers.xlsx',$2,''::bytea,'Completed',24,24,$3)").bind(import).bind(format!("training-{import}")).bind(owner.id).execute(&mut **tx).await.map_err(db_error)?;
    let date = Utc::now()
        .with_timezone(&FixedOffset::east_opt(19800).expect("India offset"))
        .date_naive();
    let first = date.with_day(1).expect("First day");
    let actor = Actor {
        id: pa,
        name: "DEMO Postal Assistant".into(),
        role: Role::Pa,
    };
    sqlx::query("SELECT set_config('sbco.actor_id',$1,true),set_config('sbco.request_id',$2,true)")
        .bind(pa.to_string())
        .bind(Uuid::new_v4().to_string())
        .execute(&mut **tx)
        .await
        .map_err(db_error)?;
    for i in 0..24i32 {
        let id = Uuid::new_v4();
        let office = ["DEMO-SO1", "DEMO-SO2", "DEMO-BO1"][(i % 3) as usize];
        let day = first + Duration::days(i64::from(i % date.day() as i32));
        let credit = if i == 9 {
            150000
        } else if i % 2 == 0 && i != 10 {
            2500 + i * 100
        } else {
            0
        };
        let debit = if i == 10 {
            65000
        } else if i % 2 == 1 && i != 9 {
            1000 + i * 50
        } else {
            0
        };
        sqlx::query("INSERT INTO transactions(id,office_id,report_type,report_date,value_date,account_number,scheme,transaction_id,reference_id,transaction_type,description,credit,debit,agent,rd_default,import_id,source_sheet,source_row,fingerprint) VALUES($1,$2,CASE WHEN $2='DEMO-BO1' THEN 'BO' ELSE 'SO' END,$3,$3,$4,$5,$6,$7,$8,'DEMO synthetic training transaction',$9::int,$10::int,$11,$12,$13,'Practice', $14,$15)")
            .bind(id).bind(office).bind(day).bind(format!("900000{:06}",i+1)).bind(if i%4==0{"RD"}else{"SB"}).bind(format!("DEMO-TXN-{:03}",i+1)).bind(format!("DEMO-REF-{:03}",i+1)).bind(if credit>0{"Deposit"}else{"Withdrawal"}).bind(credit).bind(debit).bind(i%6==0).bind(i%8==0).bind(import).bind(i+2).bind(format!("training-{id}")).execute(&mut **tx).await.map_err(db_error)?;
        if i < 12 {
            let row = sqlx::query("SELECT * FROM transactions WHERE id=$1")
                .bind(id)
                .fetch_one(&mut **tx)
                .await
                .map_err(db_error)?;
            let mismatch = i % 3 == 0;
            apply_primary(
                tx,
                &actor,
                &row,
                if mismatch {
                    Status::Mismatch
                } else {
                    Status::Matched
                },
                if mismatch { "Voucher missing" } else { "" },
                "DEMO practice verification",
                1,
            )
            .await?;
        }
    }
    let incidents: Vec<Uuid> =
        sqlx::query("SELECT id FROM incidents WHERE office_id='DEMO-SO1' ORDER BY id LIMIT 2")
            .fetch_all(&mut **tx)
            .await
            .map_err(db_error)?
            .iter()
            .map(|row| row.get("id"))
            .collect();
    create_letter(tx, &actor, incidents, date + Duration::days(7), None).await?;
    sqlx::query("INSERT INTO audit(actor_id,action,detail) VALUES($1,'SeedTraining','{\"synthetic_records\":true}'::jsonb)").bind(owner.id).execute(&mut **tx).await.map_err(db_error)?;
    Ok(())
}
