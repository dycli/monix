//! The household's money over MCP, for the household's assistant: what the
//! page shows, as reads, and the four changes the page makes (filing a
//! transaction, a budget line, a hand-kept account, a bill that isn't one).
//! Nothing here links or removes a bank, syncs, or reads a key or token;
//! those stay with the page and the vault.
//!
//! Streamable HTTP at `/mcp`, stateless, as Hob does it: each POST is one
//! JSON-RPC message answered as JSON, which the transport allows in place
//! of an event stream, so there are no sessions to keep. The surface used
//! (initialize, tools, ping) is small enough to write out rather than take
//! an SDK and its dependencies.
//!
//! It has its own listener (`MONEY_MCP_LISTEN`, loopback), apart from the
//! page's: nginx proxies the page's port to the tailnet from loopback, so a
//! peer check there could not tell a tailnet browser from a local agent. A
//! request carrying an Origin is a browser's, which MCP clients are not,
//! and is refused, so no web page can rebind a name onto it.

use std::path::Path;
use std::sync::Arc;

use axum::body::Bytes;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Json, Response};
use serde_json::{Value, json};

use crate::App;
use crate::money;
use crate::store::Store;

/// The protocol versions this server speaks, newest last.
const VERSIONS: &[&str] = &["2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"];

/// The most transactions one listing returns unless asked for fewer.
const MOST: u64 = 500;

pub async fn post(State(app): State<Arc<App>>, headers: HeaderMap, body: Bytes) -> Response {
    if headers.contains_key(header::ORIGIN) {
        return StatusCode::FORBIDDEN.into_response();
    }
    let Ok(msg) = serde_json::from_slice::<Value>(&body) else {
        return Json(error(Value::Null, -32700, "parse error")).into_response();
    };
    let state = app.state.clone();
    match tokio::task::spawn_blocking(move || answer(&state, &msg)).await {
        Ok(Some(v)) => Json(v).into_response(),
        Ok(None) => StatusCode::ACCEPTED.into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

/// One JSON-RPC message's answer; none for a notification or a response.
pub fn answer(state: &Path, msg: &Value) -> Option<Value> {
    let id = msg.get("id").cloned()?;
    let method = msg["method"].as_str()?;
    let params = &msg["params"];
    let result = match method {
        "initialize" => Ok(initialize(params)),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({ "tools": tools() })),
        "tools/call" => Ok(call(state, params)),
        _ => Err(format!("no method {method}")),
    };
    Some(match result {
        Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
        Err(m) => error(id, -32601, &m),
    })
}

fn error(id: Value, code: i64, message: &str) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } })
}

fn initialize(params: &Value) -> Value {
    let asked = params["protocolVersion"].as_str().unwrap_or_default();
    let version = VERSIONS
        .iter()
        .find(|v| **v == asked)
        .unwrap_or(VERSIONS.last().expect("versions"));
    json!({
        "protocolVersion": version,
        "capabilities": { "tools": {} },
        "serverInfo": { "name": "money", "title": "Money", "version": env!("CARGO_PKG_VERSION") },
        "instructions": "The household's money, from the banks Plaid links (synced every six hours) and accounts kept by hand: net worth, accounts, spending by category against the budget, transactions, investments and recurring bills. Amounts are US dollars. In transactions, positive is money out and negative is money in. Changes here reach only how the money page files and plans things; nothing can move money.",
    })
}

fn month() -> Value {
    json!({ "type": "string", "description": "YYYY-MM; this month when left out." })
}

fn read(name: &str, title: &str, description: &str, properties: Value) -> Value {
    json!({
        "name": name,
        "title": title,
        "description": description,
        "inputSchema": { "type": "object", "properties": properties },
        "annotations": { "readOnlyHint": true },
    })
}

fn change(
    name: &str,
    title: &str,
    description: &str,
    properties: Value,
    required: &[&str],
) -> Value {
    json!({
        "name": name,
        "title": title,
        "description": description,
        "inputSchema": { "type": "object", "properties": properties, "required": required },
        "annotations": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true },
    })
}

fn tools() -> Vec<Value> {
    vec![
        read(
            "accounts",
            "Accounts and net worth",
            "Net worth now (assets, debts), every account with its balance, and for cards the credit limit, statement balance, minimum payment, due date and purchase APR. Also when the banks last synced.",
            json!({}),
        ),
        read(
            "spending",
            "Spending and budget",
            "One month's income and spending by category (the category names `categorize` takes), the twelve months before it in total, and the budget's lines (monthly, and yearly with the last renewal date).",
            json!({ "month": month() }),
        ),
        read(
            "transactions",
            "Transactions",
            "One month's transactions, newest first: id, date, merchant, amount (positive is money out), category, account, and whether it is still pending. Narrow by merchant or category (either matches part of the name, any case).",
            json!({
                "month": month(),
                "merchant": { "type": "string" },
                "category": { "type": "string" },
                "limit": { "type": "integer", "minimum": 1, "maximum": MOST },
            }),
        ),
        read(
            "holdings",
            "Investments",
            "What the investment accounts hold: ticker, name, quantity, price, value and cost basis, largest first.",
            json!({}),
        ),
        read(
            "recurring",
            "Recurring bills",
            "Recurring payments found in the history (subscriptions, bills, loans), biggest monthly cost first, with how often each comes and when the next is due.",
            json!({}),
        ),
        change(
            "categorize",
            "File a transaction",
            "Files a transaction under a category. Scope `one` files just it; `merchant` files every transaction from its merchant, now and later; `amount` every one from its merchant at exactly this amount, now and later.",
            json!({
                "transaction": { "type": "string", "description": "A transaction's id, from `transactions`." },
                "category": { "type": "string", "description": "A category's name, from `spending`." },
                "scope": { "type": "string", "enum": ["one", "merchant", "amount"] },
            }),
            &["transaction", "category", "scope"],
        ),
        change(
            "budget_line",
            "Change the budget",
            "Adds or changes one budget line, found by category and item, or removes it. A monthly line gives `monthly`; a yearly charge gives `annual` and the date it last renewed.",
            json!({
                "category": { "type": "string", "description": "A spending category's name, from `spending`." },
                "item": { "type": "string", "description": "What the line is for, such as Rent or Netflix." },
                "monthly": { "type": "number" },
                "annual": { "type": "number" },
                "renews": { "type": "string", "description": "YYYY-MM-DD the yearly charge last renewed." },
                "remove": { "type": "boolean" },
            }),
            &["category", "item"],
        ),
        change(
            "manual_account",
            "Keep an account by hand",
            "Adds an account no bank reports (an unlinked 401(k), the house, a family loan), changes its name or balance, or removes it. Leave out `id` to add one; answers its id. Only hand-kept accounts can be changed here.",
            json!({
                "id": { "type": "string" },
                "name": { "type": "string" },
                "kind": { "type": "string", "enum": ["investment", "cash", "property", "loan"] },
                "balance": { "type": "number", "description": "Dollars; a loan's is what is owed." },
                "remove": { "type": "boolean" },
            }),
            &[],
        ),
        change(
            "not_recurring",
            "Not a bill",
            "Marks a merchant found as recurring as not a bill, at one account or (no account) at all of them; `not: false` puts it back.",
            json!({
                "merchant": { "type": "string" },
                "account": { "type": "string", "description": "An account's id, from `accounts`." },
                "not": { "type": "boolean" },
            }),
            &["merchant"],
        ),
    ]
}

fn call(state: &Path, params: &Value) -> Value {
    let args = &params["arguments"];
    match run(state, params["name"].as_str().unwrap_or_default(), args) {
        Ok(v) => json!({
            "content": [{ "type": "text", "text": v.to_string() }],
            "structuredContent": v,
        }),
        Err(e) => json!({ "content": [{ "type": "text", "text": e }], "isError": true }),
    }
}

fn run(state: &Path, name: &str, args: &Value) -> Result<Value, String> {
    let store = Store::open(state)?;
    let c = &store.finance;
    let text = |k: &str| args[k].as_str().map(str::to_owned);
    let page = || -> Result<Value, String> {
        let month = match text("month") {
            Some(m) if crate::is_month(&m) => m,
            Some(_) => return Err("month is YYYY-MM".into()),
            None => c
                .query_row("SELECT strftime('%Y-%m', 'now', 'localtime')", [], |r| {
                    r.get(0)
                })
                .map_err(|e| e.to_string())?,
        };
        money::page(c, &month)
    };
    match name {
        "accounts" => {
            let p = page()?;
            let worth = p["worth"].as_array().and_then(|w| w.last()).cloned();
            Ok(json!({
                "synced": p["synced"],
                "worth": worth.map(|w| json!({
                    "date": w["date"],
                    "assets": w["assets"],
                    "debts": w["debts"],
                    "net": w["assets"].as_f64().unwrap_or(0.0) - w["debts"].as_f64().unwrap_or(0.0),
                })),
                "accounts": p["accounts"],
            }))
        }
        "spending" => {
            let p = page()?;
            let used: Vec<&Value> = p["categories"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|c| c["count"].as_i64().unwrap_or(0) > 0)
                .collect();
            let names: Vec<&Value> = p["categories"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|c| &c["name"])
                .collect();
            Ok(json!({
                "month": p["month"],
                "categories": used,
                "every_category": names,
                "months": p["months"],
                "budget": p["budget"],
            }))
        }
        "transactions" => {
            let p = page()?;
            let has = |field: &Value, k: &str| match text(k) {
                Some(want) => field
                    .as_str()
                    .is_some_and(|f| f.to_lowercase().contains(&want.to_lowercase())),
                None => true,
            };
            let limit = args["limit"].as_u64().unwrap_or(MOST).min(MOST) as usize;
            let list: Vec<&Value> = p["transactions"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|t| {
                    (has(&t["merchant"], "merchant") || has(&t["name"], "merchant"))
                        && has(&t["category"], "category")
                })
                .take(limit)
                .collect();
            Ok(json!({ "month": p["month"], "transactions": list }))
        }
        "holdings" => Ok(json!({ "holdings": page()?["holdings"] })),
        "recurring" => Ok(json!({ "recurring": money::recurring(c)? })),
        "categorize" => {
            let scope: money::Scope = serde_json::from_value(args["scope"].clone())
                .map_err(|_| "scope is one, merchant or amount".to_owned())?;
            let need = |k: &str| text(k).ok_or(format!("{k} is required"));
            money::categorize(c, &need("transaction")?, &need("category")?, scope)?;
            Ok(json!({ "done": true }))
        }
        "budget_line" => {
            let line: money::Line =
                serde_json::from_value(args.clone()).map_err(|e| e.to_string())?;
            money::budget_line(c, &line, args["remove"].as_bool().unwrap_or(false))?;
            Ok(json!({ "done": true }))
        }
        "manual_account" => {
            let m: money::Manual =
                serde_json::from_value(args.clone()).map_err(|e| e.to_string())?;
            Ok(json!({ "id": money::manual(c, &m)? }))
        }
        "not_recurring" => {
            let merchant = text("merchant").ok_or("merchant is required")?;
            let not = args["not"].as_bool().unwrap_or(true);
            money::not_recurring(c, &merchant, text("account").as_deref(), not)?;
            Ok(json!({ "done": true }))
        }
        other => Err(format!("no tool {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ask(state: &Path, method: &str, params: Value) -> Value {
        answer(
            state,
            &json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params }),
        )
        .expect("an answer")
    }

    fn tool(state: &Path, name: &str, arguments: Value) -> Value {
        ask(
            state,
            "tools/call",
            json!({ "name": name, "arguments": arguments }),
        )["result"]
            .clone()
    }

    #[test]
    fn reads_and_changes_go_through_the_page_rules() {
        let dir = std::env::temp_dir().join(format!("money-mcp-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut s = Store::prepare(&dir).unwrap();
        s.add("i1", "tok").unwrap();
        s.describe("i1", "Amex", "transactions").unwrap();
        let card = json!({"account_id": "a1", "name": "Blue Cash", "type": "credit",
            "balances": {"current": 300.0}});
        s.accounts("i1", &[card]).unwrap();
        let t = json!({"transaction_id": "t1", "account_id": "a1", "date": "2026-10-05",
            "merchant_name": "Wegmans", "amount": 80.0, "pending": false,
            "personal_finance_category": {"primary": "FOOD_AND_DRINK", "detailed": "FOOD_AND_DRINK_GROCERIES"}});
        s.transactions("i1", &[t], &[], "c1").unwrap();
        drop(s);

        let init = ask(
            &dir,
            "initialize",
            json!({ "protocolVersion": "2025-06-18" }),
        );
        assert_eq!(init["result"]["protocolVersion"], "2025-06-18");
        assert!(
            answer(
                &dir,
                &json!({ "jsonrpc": "2.0", "method": "notifications/initialized" })
            )
            .is_none()
        );

        let names: Vec<String> = ask(&dir, "tools/list", json!({}))["result"]["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap().to_owned())
            .collect();
        for gone in ["link", "linked", "remove", "sync", "sandbox_item"] {
            assert!(
                !names.iter().any(|n| n == gone),
                "{gone} must not be a tool"
            );
        }

        let a = tool(&dir, "accounts", json!({}));
        assert_eq!(a["structuredContent"]["accounts"][0]["name"], "Blue Cash");
        assert_eq!(a["structuredContent"]["accounts"][0]["balance"], 300.0);

        let list = tool(
            &dir,
            "transactions",
            json!({ "month": "2026-10", "merchant": "wegm" }),
        );
        let first = &list["structuredContent"]["transactions"][0];
        assert_eq!(first["id"], "t1");
        let other = first["category"].as_str().unwrap().to_owned();
        let none = tool(
            &dir,
            "transactions",
            json!({ "month": "2026-10", "merchant": "shell" }),
        );
        assert_eq!(none["structuredContent"]["transactions"], json!([]));

        let spend = tool(&dir, "spending", json!({ "month": "2026-10" }));
        let every = spend["structuredContent"]["every_category"]
            .as_array()
            .unwrap()
            .clone();
        let target = every
            .iter()
            .map(|n| n.as_str().unwrap())
            .find(|n| *n != other && *n != "Income")
            .unwrap()
            .to_owned();

        let filed = tool(
            &dir,
            "categorize",
            json!({ "transaction": "t1", "category": target, "scope": "one" }),
        );
        assert_eq!(filed["isError"], Value::Null, "{filed}");
        let after = tool(&dir, "transactions", json!({ "month": "2026-10" }));
        assert_eq!(
            after["structuredContent"]["transactions"][0]["category"],
            json!(target)
        );

        let refused = tool(
            &dir,
            "categorize",
            json!({ "transaction": "t1", "category": "Nope", "scope": "one" }),
        );
        assert_eq!(refused["isError"], true);
        assert_eq!(
            tool(
                &dir,
                "categorize",
                json!({ "transaction": "t1", "category": target, "scope": "all" })
            )["isError"],
            true
        );

        let made = tool(
            &dir,
            "manual_account",
            json!({ "name": "House", "kind": "property", "balance": 250000.0 }),
        );
        let id = made["structuredContent"]["id"].as_str().unwrap().to_owned();
        let worth = tool(&dir, "accounts", json!({}));
        assert!(
            worth["structuredContent"]["accounts"]
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a["id"] == json!(id))
        );
        // A linked account is not the hand-kept kind.
        assert_eq!(
            tool(
                &dir,
                "manual_account",
                json!({ "id": "a1", "balance": 0.0 })
            )["isError"],
            true
        );

        assert_eq!(
            tool(&dir, "not_recurring", json!({ "merchant": "Wegmans" }))["isError"],
            Value::Null
        );
        assert_eq!(
            tool(&dir, "transactions", json!({ "month": "October" }))["isError"],
            true
        );
        assert_eq!(tool(&dir, "link", json!({}))["isError"], true);
        std::fs::remove_dir_all(&dir).ok();
    }
}
