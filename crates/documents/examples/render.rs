//! Render a serialized Document for deterministic visual QA, without a running database.
use std::{env, fs};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = env::args().collect();
    if args.len() != 3 {
        return Err("Usage: render document.json output.pdf".into());
    }
    let document: sbco_documents::Document = serde_json::from_slice(&fs::read(&args[1])?)?;
    fs::write(&args[2], sbco_documents::render(&document)?)?;
    Ok(())
}
