use sbco_infrastructure::Database;
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt().init();
    let db = Database::connect(&std::env::var("DATABASE_URL")?).await?;
    loop {
        if let Err(e) = db.mark_overdue().await {
            tracing::error!(%e,"Overdue update failed");
        }
        let live_work = match db.tick().await {
            Ok(work) => work,
            Err(e) => {
                tracing::error!(%e,"Worker failed");
                false
            }
        };
        let training_work = match db.training_tick().await {
            Ok(work) => work,
            Err(e) => {
                tracing::error!(%e,"Training worker failed");
                false
            }
        };
        if live_work || training_work {
            continue;
        }
        tokio::select! {_ = tokio::signal::ctrl_c()=>break,_ = tokio::time::sleep(std::time::Duration::from_secs(5))=>{}}
    }
    Ok(())
}
