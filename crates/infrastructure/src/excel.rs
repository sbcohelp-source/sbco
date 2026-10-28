use calamine::{Data, DataType, Reader, open_workbook_auto_from_rs};
use chrono::NaiveDate;
use rust_decimal::Decimal;
use sbco_domain::{Error, Result, money};
use serde::Serialize;
use std::{collections::HashMap, io::Cursor};

#[derive(Debug, Serialize)]
pub(crate) struct Entry {
    pub row: i32,
    pub account: String,
    pub scheme: String,
    pub transaction_id: String,
    pub reference: String,
    pub user: String,
    pub kind: String,
    pub description: String,
    pub credit: String,
    pub debit: String,
    pub value_date: NaiveDate,
    pub agent: bool,
    pub rd_default: bool,
}
#[derive(Debug)]
pub(crate) struct Workbook {
    pub office: String,
    pub office_name: String,
    pub parent: Option<(String, String)>,
    pub report_type: String,
    pub date: NaiveDate,
    pub sheet: String,
    pub rows: Vec<Entry>,
}
fn text(v: &Data) -> String {
    match v {
        Data::Empty => String::new(),
        Data::Float(n) if n.fract() == 0.0 => format!("{n:.0}"),
        _ => v.to_string().trim().to_owned(),
    }
}
fn label(s: &str) -> String {
    s.trim()
        .trim_end_matches(':')
        .trim()
        .to_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}
fn parse_date(v: &Data) -> Result<NaiveDate> {
    if let Some(d) = v.as_date() {
        return Ok(d);
    }
    let s = text(v);
    for format in [
        "%Y-%m-%d",
        "%d-%m-%Y",
        "%d/%m/%Y",
        "%d.%m.%Y",
        "%Y-%m-%d %H:%M:%S",
    ] {
        if let Ok(d) = NaiveDate::parse_from_str(&s, format) {
            return Ok(d);
        }
    }
    Err(Error::Validation(format!(
        "Unrecognized report/value date: {s}"
    )))
}
fn amount(v: Option<&Data>) -> Result<Decimal> {
    match v {
        None | Some(Data::Empty) => Ok(Decimal::ZERO),
        Some(v) => {
            let s = text(v);
            if s.is_empty() {
                Ok(Decimal::ZERO)
            } else {
                money(&s)
            }
        }
    }
}
pub(crate) fn parse(content: Vec<u8>) -> Result<Workbook> {
    let mut book = open_workbook_auto_from_rs(Cursor::new(content))
        .map_err(|e| Error::Validation(format!("Cannot read workbook: {e}")))?;
    let sheet = book
        .sheet_names()
        .first()
        .cloned()
        .ok_or_else(|| Error::Validation("Workbook has no worksheets".into()))?;
    let range = book
        .worksheet_range(&sheet)
        .map_err(|e| Error::Validation(format!("Cannot read worksheet: {e}")))?;
    if range.height() > 200_000 || range.width() > 200 {
        return Err(Error::Validation(
            "Workbook exceeds 200000 rows or 200 columns".into(),
        ));
    }
    let rows: Vec<_> = range.rows().collect();
    let header = rows
        .iter()
        .position(|r| r.iter().any(|v| label(&text(v)) == "account number"))
        .ok_or_else(|| Error::Validation("Account Number header was not found".into()))?;
    let headers: HashMap<String, usize> = rows[header]
        .iter()
        .enumerate()
        .map(|(i, v)| (label(&text(v)), i))
        .collect();
    let mut meta = HashMap::new();
    for row in &rows[..header] {
        for (i, v) in row.iter().enumerate() {
            let key = label(&text(v));
            if ["sol id", "bo id", "date", "sol id name", "bo id name"].contains(&key.as_str()) {
                let values: Vec<&Data> = row
                    .iter()
                    .skip(i + 1)
                    .filter(|v| !text(v).is_empty())
                    .take_while(|v| {
                        !["sol id", "bo id", "date"].contains(&label(&text(v)).as_str())
                    })
                    .collect();
                if let Some(v) = values.first() {
                    meta.insert(key.clone(), (*v).clone());
                }
                if (key == "sol id" || key == "bo id") && values.len() > 1 {
                    meta.entry(format!("{key} name"))
                        .or_insert_with(|| values[1].clone());
                }
            }
        }
    }
    let bo = meta.contains_key("bo id");
    let key = if bo { "bo id" } else { "sol id" };
    let office = text(
        meta.get(key)
            .ok_or_else(|| Error::Validation("Office/SOL ID is missing".into()))?,
    );
    let office_name = meta
        .get(&format!("{key} name"))
        .map(text)
        .unwrap_or_else(|| office.clone());
    let date = parse_date(
        meta.get("date")
            .ok_or_else(|| Error::Validation("Report date is missing".into()))?,
    )?;
    let parent = if bo {
        meta.get("sol id").map(|v| {
            let id = text(v);
            let name = meta
                .get("sol id name")
                .map(text)
                .unwrap_or_else(|| id.clone());
            (id, name)
        })
    } else {
        None
    };
    let credit_col = *headers
        .get("credit")
        .ok_or_else(|| Error::Validation("Credit header missing".into()))?;
    let debit_col = *headers
        .get("debit")
        .ok_or_else(|| Error::Validation("Debit header missing".into()))?;
    if !bo && debit_col <= credit_col {
        return Err(Error::Validation(
            "Credit/debit column order is invalid".into(),
        ));
    }
    let mut entries = Vec::new();
    for (index, row) in rows.iter().enumerate().skip(header + 1) {
        let value = |names: &[&str]| -> String {
            names
                .iter()
                .find_map(|n| headers.get(*n).and_then(|i| row.get(*i)))
                .map(text)
                .unwrap_or_default()
        };
        let serial = value(&["sl no", "s.no", "sl. no."]);
        if serial.parse::<u64>().is_err() {
            continue;
        }
        let account = value(&["account number"]);
        if account.is_empty() {
            return Err(Error::Validation(format!(
                "Account missing at row {}",
                index + 1
            )));
        }
        let credit = if bo {
            amount(row.get(credit_col))?
        } else {
            (credit_col..debit_col)
                .try_fold(Decimal::ZERO, |sum, c| amount(row.get(c)).map(|n| sum + n))?
        };
        let debit = if bo {
            amount(row.get(debit_col))?
        } else {
            (debit_col..row.len())
                .try_fold(Decimal::ZERO, |sum, c| amount(row.get(c)).map(|n| sum + n))?
        };
        let value_date = match headers.get("value date").and_then(|i| row.get(*i)) {
            Some(v) if !text(v).is_empty() => parse_date(v)?,
            _ => date,
        };
        let description = value(&["tran part", "remarks"]);
        let scheme = value(&["scheme code", "schme code"]);
        let (agent, rd_default) = classify(&scheme, &description);
        let mut kind = value(&["type"]);
        if kind.is_empty() {
            kind = if credit != Decimal::ZERO && debit == Decimal::ZERO {
                "Credit"
            } else if debit != Decimal::ZERO && credit == Decimal::ZERO {
                "Debit"
            } else {
                "Transfer"
            }
            .into();
        }
        entries.push(Entry {
            row: index as i32 + 1,
            account,
            scheme,
            transaction_id: value(&["tran id"]),
            reference: value(&["ref num"]),
            user: value(&["entry user id"]),
            kind,
            description,
            credit: credit.to_string(),
            debit: debit.to_string(),
            value_date,
            agent,
            rd_default,
        });
    }
    Ok(Workbook {
        office,
        office_name,
        parent,
        report_type: if bo { "BO/AO" } else { "SO" }.into(),
        date,
        sheet,
        rows: entries,
    })
}

fn classify(scheme: &str, description: &str) -> (bool, bool) {
    use std::sync::LazyLock;
    static AGENT: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(r"(?i)^SDP_BO\d+_[A-Z0-9-]{4,}_|\bAGENT\s*(?:ID|NO|CODE)\s*[:#-]?\s*[A-Z0-9][A-Z0-9/-]{3,}\b").expect("constant regex")
    });
    if !matches!(scheme.trim().to_uppercase().as_str(), "RD" | "RDIPN") {
        return (false, false);
    }
    let remark = description.trim();
    let default = remark
        .to_uppercase()
        .split(|c: char| !c.is_ascii_alphabetic())
        .any(|s| matches!(s, "DEF" | "DEFAULT"));
    (AGENT.is_match(remark), default)
}
#[cfg(test)]
mod tests {
    use super::classify;
    #[test]
    fn classification_preserves_legacy_id_requirements() {
        assert_eq!(classify("RD", "SDP_BO123_ABCD_ payment"), (true, false));
        assert_eq!(
            classify(" rdipn ", "Agent code: A123 default fee"),
            (true, true)
        );
        assert_eq!(classify("RD", "SDP_BO not an agent ID"), (false, false));
        assert_eq!(classify("RD", "Agent ID: A12"), (false, false));
        assert_eq!(classify("SB", "Agent ID A123 DEFAULT"), (false, false));
        assert_eq!(classify("RD", "DEFAULTED"), (false, false));
    }
}
