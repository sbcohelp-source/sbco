use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{0}")]
    Validation(String),
    #[error("Sign in to continue")]
    Unauthorized,
    #[error("You do not have permission for this action")]
    Forbidden,
    #[error("{0}")]
    Conflict(String),
    #[error("Record not found")]
    NotFound,
    #[error("The operation could not be completed")]
    Internal,
}
pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum Role {
    Pa,
    Supervisor,
    Administrator,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Actor {
    pub id: Uuid,
    pub name: String,
    pub role: Role,
}
impl Actor {
    pub fn require_manager(&self) -> Result<()> {
        if self.role == Role::Pa {
            Err(Error::Forbidden)
        } else {
            Ok(())
        }
    }
    pub fn require_admin(&self) -> Result<()> {
        if self.role == Role::Administrator {
            Ok(())
        } else {
            Err(Error::Forbidden)
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum Status {
    Pending,
    Matched,
    Mismatch,
}
impl Status {
    pub fn parse(s: &str) -> Result<Self> {
        match s {
            "Pending" => Ok(Self::Pending),
            "Matched" => Ok(Self::Matched),
            "Mismatch" => Ok(Self::Mismatch),
            _ => Err(Error::Validation("Invalid verification status".into())),
        }
    }
    pub fn label(&self) -> &'static str {
        match self {
            Self::Pending => "Pending",
            Self::Matched => "Matched",
            Self::Mismatch => "Mismatch",
        }
    }
}
#[derive(Debug, Clone)]
pub struct Outcome {
    pub final_status: Status,
    pub basis: Option<&'static str>,
}

pub fn money(value: &str) -> Result<Decimal> {
    let result: Decimal = value
        .trim()
        .replace(',', "")
        .parse()
        .map_err(|_| Error::Validation(format!("Invalid amount: {value}")))?;
    if result.scale() > 2 && result != result.round_dp(2) {
        return Err(Error::Validation(
            "Amounts must have at most two decimal places".into(),
        ));
    }
    if result.abs() >= Decimal::from(1_000_000_000_000_000_000u64) {
        return Err(Error::Validation(
            "Amount exceeds supported precision".into(),
        ));
    }
    let mut fixed = result.round_dp(2);
    fixed.rescale(2);
    Ok(fixed)
}
pub fn validate_decision(status: &Status, reason: &str) -> Result<()> {
    if *status == Status::Pending {
        return Err(Error::Validation("Choose Matched or Mismatch".into()));
    }
    if *status == Status::Mismatch && reason.trim().is_empty() {
        return Err(Error::Validation("A mismatch reason is required".into()));
    }
    Ok(())
}
pub fn primary_outcome(
    credit: Decimal,
    debit: Decimal,
    status: Status,
    percentage: u32,
    sample: u32,
) -> Outcome {
    let basis = if debit >= Decimal::from(50_000) || credit >= Decimal::from(100_000) {
        Some("High Value")
    } else if sample < percentage.min(100) * 100 {
        Some("Random")
    } else {
        None
    };
    Outcome {
        final_status: if basis.is_some() {
            Status::Pending
        } else {
            status
        },
        basis,
    }
}
pub fn ensure_revision(actual: i32, expected: i32) -> Result<()> {
    if actual != expected {
        Err(Error::Conflict(
            "This record changed. Refresh before trying again.".into(),
        ))
    } else {
        Ok(())
    }
}
pub fn validate_review(pa_status: &str, status: &Status, notes: &str) -> Result<()> {
    if pa_status != status.label() && notes.trim().is_empty() {
        return Err(Error::Validation(
            "Explain why the supervisor result differs from the PA result".into(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exact_money_and_precision() {
        assert_eq!(
            money("0.10").unwrap() + money("0.20").unwrap(),
            money("0.30").unwrap()
        );
        assert!(money("1.001").is_err());
        assert!(money("NaN").is_err());
    }
    #[test]
    fn inclusive_thresholds() {
        assert_eq!(
            primary_outcome(
                money("100000").unwrap(),
                Decimal::ZERO,
                Status::Matched,
                0,
                9999
            )
            .basis,
            Some("High Value")
        );
        assert_eq!(
            primary_outcome(
                Decimal::ZERO,
                money("50000").unwrap(),
                Status::Mismatch,
                0,
                9999
            )
            .final_status,
            Status::Pending
        );
    }
    #[test]
    fn sampling_boundary() {
        assert_eq!(
            primary_outcome(Decimal::ZERO, Decimal::ZERO, Status::Matched, 5, 499).basis,
            Some("Random")
        );
        assert_eq!(
            primary_outcome(Decimal::ZERO, Decimal::ZERO, Status::Matched, 5, 500).final_status,
            Status::Matched
        );
    }
    #[test]
    fn stale_and_invalid_decisions() {
        assert!(ensure_revision(2, 1).is_err());
        assert!(validate_decision(&Status::Mismatch, " ").is_err());
        assert!(validate_review("Matched", &Status::Mismatch, "").is_err());
    }
}
