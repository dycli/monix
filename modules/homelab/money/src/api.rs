//! Plaid's REST API: every call is a POST of JSON carrying the client id and
//! secret, answered with JSON or with an error object.

use std::time::Duration;

use serde_json::{Value, json};

/// Plaid's answer to a failed call, by its stable `error_code`.
#[derive(Debug)]
pub struct Failure {
    pub code: String,
    pub message: String,
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

pub struct Plaid {
    base: &'static str,
    id: String,
    secret: String,
    agent: ureq::Agent,
}

/// What a new link is for: Link lists only institutions that support the
/// required product, so a brokerage asks for investments and a bank for
/// transactions; the other products ride along where the institution has them.
#[derive(Clone, Copy)]
pub enum Kind {
    Bank,
    Brokerage,
}

impl Plaid {
    pub fn new(sandbox: bool, id: String, secret: String) -> Self {
        Self {
            base: if sandbox {
                "https://sandbox.plaid.com"
            } else {
                "https://production.plaid.com"
            },
            id,
            secret,
            agent: ureq::Agent::config_builder()
                .http_status_as_error(false)
                .timeout_global(Some(Duration::from_secs(60)))
                .build()
                .into(),
        }
    }

    pub fn call(&self, path: &str, mut body: Value) -> Result<Value, Failure> {
        body["client_id"] = json!(self.id);
        body["secret"] = json!(self.secret);
        let failed = |code: &str, message: String| Failure {
            code: code.to_owned(),
            message,
        };
        let mut reply = self
            .agent
            .post(format!("{}{path}", self.base))
            .send_json(&body)
            .map_err(|e| failed("NETWORK", e.to_string()))?;
        let ok = reply.status().is_success();
        let value: Value = reply
            .body_mut()
            .read_json()
            .map_err(|e| failed("BAD_REPLY", e.to_string()))?;
        if ok {
            Ok(value)
        } else {
            let text = |k: &str| value[k].as_str().unwrap_or_default().to_owned();
            Err(Failure {
                code: text("error_code"),
                message: text("error_message"),
            })
        }
    }

    /// A token that opens Link: for a new Item of `kind`, or in update mode
    /// for an existing one, which logs in again without taking a new slot.
    pub fn link_token(&self, kind: Kind, update: Option<&str>) -> Result<String, Failure> {
        let mut body = json!({
            "client_name": "Kestrel",
            "language": "en",
            "country_codes": ["US"],
            "user": { "client_user_id": "household" },
        });
        match update {
            Some(token) => body["access_token"] = json!(token),
            None => {
                let (required, optional) = match kind {
                    Kind::Bank => ("transactions", json!(["liabilities", "investments"])),
                    Kind::Brokerage => ("investments", json!(["transactions"])),
                };
                body["products"] = json!([required]);
                body["optional_products"] = optional;
                // The most Plaid gives, and fixed once the Item has transactions.
                body["transactions"] = json!({ "days_requested": 730 });
            }
        }
        let reply = self.call("/link/token/create", body)?;
        Ok(reply["link_token"].as_str().unwrap_or_default().to_owned())
    }

    /// Trades Link's public token for the Item's id and lasting access token.
    pub fn exchange(&self, public: &str) -> Result<(String, String), Failure> {
        let reply = self.call(
            "/item/public_token/exchange",
            json!({ "public_token": public }),
        )?;
        let text = |k: &str| reply[k].as_str().unwrap_or_default().to_owned();
        Ok((text("item_id"), text("access_token")))
    }
}
