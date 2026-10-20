//! The household's money page and bank link. It holds the Plaid keys and
//! each bank login's access token, pulls accounts, transactions, holdings
//! and card statements into `finance.db` on a timer, and serves the page:
//! net worth, spending by category, investments, and the Banks tab where we
//! link a bank or log in to one again. Nothing here can move money: the
//! products are read-only.
//!
//! Environment:
//! - `MONEY_LISTEN`: address to bind, e.g. `127.0.0.1:8975`.
//! - `MONEY_ENV`: `sandbox` (fake banks) or `production`.
//! - `MONEY_KEYS_FILE`: `KEY=value` lines with `PLAID_CLIENT_ID` and
//!   `PLAID_SECRET` (production) or `PLAID_SANDBOX_SECRET`.
//! - `MONEY_STATE`: directory for `finance.db` and `vault/vault.db`.
//!
//! systemd may also hand over a listening Unix socket (`money.socket`):
//! the same API for the household assistants, so they can file, budget and
//! keep accounts by hand. The socket's group is who may.

mod api;
mod money;
mod store;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use axum::Router;
use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::{Html, IntoResponse, Json, Response};
use axum::routing::{get, post, put};
use serde::Deserialize;
use serde_json::json;
use tokio::sync::Mutex;

use api::{Failure, Kind, Plaid};
use store::Store;

/// Plaid refreshes transactions a few times a day and holdings about daily.
const EVERY: Duration = Duration::from_secs(6 * 3600);
/// Bank logins the Trial plan allows for the life of the team; removing an
/// Item does not give its slot back.
const SLOTS: i64 = 10;

struct App {
    plaid: Plaid,
    sandbox: bool,
    state: PathBuf,
    /// One sync at a time; SQLite and Plaid's cursors both want that.
    syncing: Mutex<()>,
}

fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("{name} is not set"))
}

fn keys(file: &str) -> Vec<(String, String)> {
    std::fs::read_to_string(file)
        .unwrap_or_else(|e| panic!("{file}: {e}"))
        .lines()
        .filter_map(|l| l.split_once('='))
        .map(|(k, v)| (k.trim().to_owned(), unquote(v.trim()).to_owned()))
        .collect()
}

/// Env files often quote values; the quotes are not part of the key.
fn unquote(v: &str) -> &str {
    ['"', '\'']
        .iter()
        .find_map(|q| v.strip_prefix(*q).and_then(|v| v.strip_suffix(*q)))
        .unwrap_or(v)
}

fn found(list: &[(String, String)], name: &str) -> Option<String> {
    list.iter()
        .find(|(k, v)| k == name && !v.is_empty())
        .map(|(_, v)| v.clone())
}

/// Codes after which a product is simply absent for this Item, not broken.
const ABSENT: &[&str] = &[
    "PRODUCTS_NOT_SUPPORTED",
    "PRODUCT_NOT_ENABLED",
    "NO_INVESTMENT_ACCOUNTS",
    "NO_INVESTMENT_AUTH_ACCOUNTS",
    "NO_LIABILITY_ACCOUNTS",
    "NO_ACCOUNTS",
];
/// Codes that mean the bank wants us to log in again, through update mode.
const LOGIN: &[&str] = &[
    "ITEM_LOGIN_REQUIRED",
    "PENDING_EXPIRATION",
    "PENDING_DISCONNECT",
    "OAUTH_CONSENT_EXPIRED",
    "OAUTH_USER_REVOKED",
    "ACCESS_NOT_GRANTED",
];

fn absent(f: &Failure) -> bool {
    let skip = ABSENT.contains(&f.code.as_str()) || f.code == "PRODUCT_NOT_READY";
    if skip {
        // Skipped quietly, a missing product looks like an empty one; the
        // journal keeps which it was.
        eprintln!("money: skipped: {} {}", f.code, f.message);
    }
    skip
}

/// Pulls everything Plaid has for one Item. Errors that concern one product
/// skip that product; an Item-level error stops and is recorded.
fn sync_item(plaid: &Plaid, store: &mut Store, item: &str) -> Result<(), Failure> {
    let local = |e: String| Failure {
        code: "LOCAL".into(),
        message: e,
    };
    let (token, mut cursor) = store.token(item).map_err(local)?;
    let at = json!({ "access_token": token });

    let got = plaid.call("/item/get", at.clone())?;
    let products: Vec<String> = got["item"]["products"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|p| p.as_str().map(str::to_owned))
        .collect();
    let institution = match store.known_institution(item) {
        Some(name) => name,
        None => {
            let id = got["item"]["institution_id"].as_str().unwrap_or_default();
            plaid
                .call(
                    "/institutions/get_by_id",
                    json!({ "institution_id": id, "country_codes": ["US"] }),
                )
                .ok()
                .and_then(|r| r["institution"]["name"].as_str().map(str::to_owned))
                .unwrap_or_else(|| id.to_owned())
        }
    };
    store
        .describe(item, &institution, &products.join(","))
        .map_err(local)?;

    let accounts = plaid.call("/accounts/get", at.clone())?;
    store
        .accounts(
            item,
            accounts["accounts"].as_array().map_or(&[], Vec::as_slice),
        )
        .map_err(local)?;
    let has = |p: &str| products.iter().any(|x| x == p);

    if has("transactions") {
        // Plaid's documented loop: page until has_more is false, and start
        // over from the saved cursor if the data moved underneath us.
        let start = cursor.clone();
        let (mut changed, mut removed) = (Vec::new(), Vec::new());
        loop {
            let mut body = at.clone();
            body["count"] = json!(500);
            if let Some(c) = &cursor {
                body["cursor"] = json!(c);
            }
            match plaid.call("/transactions/sync", body) {
                Ok(page) => {
                    for k in ["added", "modified"] {
                        changed.extend(page[k].as_array().cloned().unwrap_or_default());
                    }
                    removed.extend(page["removed"].as_array().cloned().unwrap_or_default());
                    cursor = page["next_cursor"].as_str().map(str::to_owned);
                    if !page["has_more"].as_bool().unwrap_or(false) {
                        break;
                    }
                }
                Err(f) if f.code == "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION" => {
                    cursor = start.clone();
                    changed.clear();
                    removed.clear();
                }
                Err(f) if absent(&f) => break,
                Err(f) => return Err(f),
            }
        }
        if let Some(c) = &cursor {
            store
                .transactions(item, &changed, &removed, c)
                .map_err(local)?;
        }
    }

    if has("investments") {
        match plaid.call("/investments/holdings/get", at.clone()) {
            Ok(r) => {
                let list = |k: &str| r[k].as_array().cloned().unwrap_or_default();
                eprintln!(
                    "money: {item}: {} holdings over {} accounts",
                    list("holdings").len(),
                    list("accounts").len()
                );
                store.accounts(item, &list("accounts")).map_err(local)?;
                store
                    .holdings(item, &list("holdings"), &list("securities"))
                    .map_err(local)?;
            }
            Err(f) if absent(&f) => {}
            Err(f) => return Err(f),
        }
    }

    if has("liabilities") {
        match plaid.call("/liabilities/get", at) {
            Ok(r) => store
                .credit(
                    r["liabilities"]["credit"]
                        .as_array()
                        .map_or(&[], Vec::as_slice),
                )
                .map_err(local)?,
            Err(f) if absent(&f) => {}
            Err(f) => return Err(f),
        }
    }
    Ok(())
}

/// Syncs every Item and records how each went.
async fn sync_all(app: Arc<App>) {
    let _one = app.syncing.lock().await;
    let a = app.clone();
    let done = tokio::task::spawn_blocking(move || -> Result<(), String> {
        let mut store = Store::open(&a.state)?;
        for item in store.items()? {
            let (status, error) = match sync_item(&a.plaid, &mut store, &item) {
                Ok(()) => ("ok", None),
                Err(f) if LOGIN.contains(&f.code.as_str()) => ("login", Some(f.to_string())),
                Err(f) => ("error", Some(f.to_string())),
            };
            if let Some(e) = &error {
                eprintln!("sync {item}: {e}");
            }
            store.status(&item, status, error.as_deref())?;
        }
        Ok(())
    })
    .await;
    match done {
        Ok(Ok(())) => {}
        Ok(Err(e)) => eprintln!("sync: {e}"),
        Err(e) => eprintln!("sync: {e}"),
    }
}

/// A fresh Item's history arrives over the next minutes, and without
/// webhooks (the server is not reachable from the internet) we ask again.
fn follow_up(app: Arc<App>) {
    tokio::spawn(async move {
        for wait in [0, 60, 300, 1800] {
            tokio::time::sleep(Duration::from_secs(wait)).await;
            sync_all(app.clone()).await;
        }
    });
}

fn fail(status: StatusCode, message: impl ToString) -> Response {
    (status, Json(json!({ "error": message.to_string() }))).into_response()
}

async fn page() -> Html<&'static str> {
    Html(include_str!("money.html"))
}

#[derive(Deserialize)]
struct Month {
    /// `YYYY-MM`; this month when left out.
    month: Option<String>,
}

fn is_month(m: &str) -> bool {
    let b = m.as_bytes();
    b.len() == 7
        && b[4] == b'-'
        && b.iter()
            .enumerate()
            .all(|(i, c)| i == 4 || c.is_ascii_digit())
}

async fn money_page(State(app): State<Arc<App>>, Query(q): Query<Month>) -> Response {
    if q.month.as_deref().is_some_and(|m| !is_month(m)) {
        return fail(StatusCode::BAD_REQUEST, "month is YYYY-MM");
    }
    let a = app.clone();
    match tokio::task::spawn_blocking(move || {
        let store = Store::open(&a.state)?;
        let month = match q.month {
            Some(m) => m,
            None => store
                .finance
                .query_row("SELECT strftime('%Y-%m', 'now', 'localtime')", [], |r| {
                    r.get(0)
                })
                .map_err(|e| e.to_string())?,
        };
        money::page(&store.finance, &month)
    })
    .await
    {
        Ok(Ok(v)) => Json(v).into_response(),
        Ok(Err(e)) => fail(StatusCode::INTERNAL_SERVER_ERROR, e),
        Err(e) => fail(StatusCode::INTERNAL_SERVER_ERROR, e),
    }
}

#[derive(Deserialize)]
struct Filing {
    transaction: String,
    category: String,
    scope: money::Scope,
}

async fn categorize(State(app): State<Arc<App>>, Json(f): Json<Filing>) -> Response {
    let a = app.clone();
    match tokio::task::spawn_blocking(move || {
        let store = Store::open(&a.state)?;
        money::categorize(&store.finance, &f.transaction, &f.category, f.scope)
    })
    .await
    {
        Ok(Ok(())) => StatusCode::NO_CONTENT.into_response(),
        Ok(Err(e)) => fail(StatusCode::BAD_REQUEST, e),
        Err(e) => fail(StatusCode::INTERNAL_SERVER_ERROR, e),
    }
}

async fn budget(State(app): State<Arc<App>>, Json(lines): Json<Vec<money::Line>>) -> Response {
    let a = app.clone();
    match tokio::task::spawn_blocking(move || {
        let store = Store::open(&a.state)?;
        money::set_budget(&store.finance, &lines)
    })
    .await
    {
        Ok(Ok(())) => StatusCode::NO_CONTENT.into_response(),
        Ok(Err(e)) => fail(StatusCode::BAD_REQUEST, e),
        Err(e) => fail(StatusCode::INTERNAL_SERVER_ERROR, e),
    }
}

#[derive(Deserialize)]
struct LineChange {
    #[serde(flatten)]
    line: money::Line,
    #[serde(default)]
    remove: bool,
}

async fn budget_line(State(app): State<Arc<App>>, Json(b): Json<LineChange>) -> Response {
    write(app, move |c| {
        money::budget_line(c, &b.line, b.remove).map(|()| json!({}))
    })
    .await
}

async fn manual(State(app): State<Arc<App>>, Json(m): Json<money::Manual>) -> Response {
    write(app, move |c| {
        money::manual(c, &m).map(|id| json!({ "id": id }))
    })
    .await
}

#[derive(Deserialize)]
struct NotRecurring {
    merchant: String,
    account: Option<String>,
    /// False puts it back.
    #[serde(default = "yes")]
    not: bool,
}

fn yes() -> bool {
    true
}

async fn not_recurring(State(app): State<Arc<App>>, Json(n): Json<NotRecurring>) -> Response {
    write(app, move |c| {
        money::not_recurring(c, &n.merchant, n.account.as_deref(), n.not).map(|()| json!({}))
    })
    .await
}

/// One change to finance.db, answered as JSON; a refusal is a 400 with why.
async fn write(
    app: Arc<App>,
    f: impl FnOnce(&rusqlite::Connection) -> Result<serde_json::Value, String> + Send + 'static,
) -> Response {
    match tokio::task::spawn_blocking(move || f(&Store::open(&app.state)?.finance)).await {
        Ok(Ok(v)) => Json(v).into_response(),
        Ok(Err(e)) => fail(StatusCode::BAD_REQUEST, e),
        Err(e) => fail(StatusCode::INTERNAL_SERVER_ERROR, e),
    }
}

async fn overview(State(app): State<Arc<App>>) -> Response {
    let a = app.clone();
    match tokio::task::spawn_blocking(move || {
        let store = Store::open(&a.state)?;
        Ok::<_, String>(json!({
            "sandbox": a.sandbox,
            "slots": { "used": store.slots()?, "of": SLOTS },
            "items": store.overview()?,
        }))
    })
    .await
    {
        Ok(Ok(v)) => Json(v).into_response(),
        Ok(Err(e)) => fail(StatusCode::INTERNAL_SERVER_ERROR, e),
        Err(e) => fail(StatusCode::INTERNAL_SERVER_ERROR, e),
    }
}

#[derive(Deserialize)]
struct LinkAsk {
    /// `bank` or `brokerage`, for a new Item.
    kind: Option<String>,
    /// An existing Item to log in to again.
    item: Option<String>,
}

fn kind(name: Option<&str>) -> Option<Kind> {
    match name {
        Some("bank") => Some(Kind::Bank),
        Some("brokerage") => Some(Kind::Brokerage),
        _ => None,
    }
}

const NO_KIND: &str = "kind is bank or brokerage";

async fn link(State(app): State<Arc<App>>, Json(ask): Json<LinkAsk>) -> Response {
    let k = match &ask.item {
        Some(_) => Kind::Bank,
        None => match kind(ask.kind.as_deref()) {
            Some(k) => k,
            None => return fail(StatusCode::BAD_REQUEST, NO_KIND),
        },
    };
    let a = app.clone();
    let made = tokio::task::spawn_blocking(move || -> Result<String, (StatusCode, String)> {
        let store = Store::open(&a.state).map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;
        let token = match &ask.item {
            Some(item) => Some(store.token(item).map_err(|e| (StatusCode::NOT_FOUND, e))?.0),
            None => {
                let used = store
                    .slots()
                    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;
                if !a.sandbox && used >= SLOTS {
                    return Err((
                        StatusCode::CONFLICT,
                        format!("all {SLOTS} Trial slots are used"),
                    ));
                }
                None
            }
        };
        a.plaid
            .link_token(k, token.as_deref())
            .map_err(|f| (StatusCode::BAD_GATEWAY, f.to_string()))
    })
    .await;
    match made {
        Ok(Ok(t)) => Json(json!({ "link_token": t })).into_response(),
        Ok(Err((s, e))) => fail(s, e),
        Err(e) => fail(StatusCode::INTERNAL_SERVER_ERROR, e),
    }
}

#[derive(Deserialize)]
struct Linked {
    public_token: String,
}

/// Link succeeded with a new Item: keep its token and start pulling.
async fn linked(State(app): State<Arc<App>>, Json(l): Json<Linked>) -> Response {
    let a = app.clone();
    let kept = tokio::task::spawn_blocking(move || -> Result<String, String> {
        let (item, token) = a
            .plaid
            .exchange(&l.public_token)
            .map_err(|f| f.to_string())?;
        Store::open(&a.state)?.add(&item, &token)?;
        Ok(item)
    })
    .await;
    match kept {
        Ok(Ok(item)) => {
            follow_up(app);
            Json(json!({ "item": item })).into_response()
        }
        Ok(Err(e)) => fail(StatusCode::BAD_GATEWAY, e),
        Err(e) => fail(StatusCode::INTERNAL_SERVER_ERROR, e),
    }
}

async fn sync_now(State(app): State<Arc<App>>) -> StatusCode {
    sync_all(app).await;
    StatusCode::NO_CONTENT
}

#[derive(Deserialize)]
struct Fake {
    kind: String,
}

/// Sandbox only: a test Item at Plaid's fake bank, without opening Link.
async fn sandbox_item(State(app): State<Arc<App>>, Json(f): Json<Fake>) -> Response {
    if !app.sandbox {
        return fail(StatusCode::NOT_FOUND, "sandbox only");
    }
    let products = match kind(Some(&f.kind)) {
        Some(Kind::Bank) => json!(["transactions", "liabilities"]),
        Some(Kind::Brokerage) => json!(["investments", "transactions"]),
        None => return fail(StatusCode::BAD_REQUEST, NO_KIND),
    };
    let a = app.clone();
    let made = tokio::task::spawn_blocking(move || -> Result<String, String> {
        // First Platypus Bank, Plaid's test institution with every product.
        let r = a
            .plaid
            .call(
                "/sandbox/public_token/create",
                json!({ "institution_id": "ins_109508", "initial_products": products }),
            )
            .map_err(|f| f.to_string())?;
        let public = r["public_token"].as_str().unwrap_or_default();
        let (item, token) = a.plaid.exchange(public).map_err(|f| f.to_string())?;
        Store::open(&a.state)?.add(&item, &token)?;
        Ok(item)
    })
    .await;
    match made {
        Ok(Ok(item)) => {
            follow_up(app);
            Json(json!({ "item": item })).into_response()
        }
        Ok(Err(e)) => fail(StatusCode::BAD_GATEWAY, e),
        Err(e) => fail(StatusCode::INTERNAL_SERVER_ERROR, e),
    }
}

#[tokio::main]
async fn main() {
    let sandbox = match env("MONEY_ENV").as_str() {
        "sandbox" => true,
        "production" => false,
        other => panic!("MONEY_ENV is sandbox or production, not {other}"),
    };
    let file = env("MONEY_KEYS_FILE");
    let list = keys(&file);
    let secret_name = if sandbox {
        "PLAID_SANDBOX_SECRET"
    } else {
        "PLAID_SECRET"
    };
    let id =
        found(&list, "PLAID_CLIENT_ID").unwrap_or_else(|| panic!("{file}: no PLAID_CLIENT_ID"));
    let secret = found(&list, secret_name).unwrap_or_else(|| panic!("{file}: no {secret_name}"));
    // Lengths only: Plaid client ids are 24 characters and secrets 30, so a
    // mangled paste shows here without the keys reaching the journal.
    eprintln!(
        "money: {} keys, client id {} chars, {secret_name} {} chars",
        if sandbox { "sandbox" } else { "production" },
        id.len(),
        secret.len()
    );
    let state = PathBuf::from(env("MONEY_STATE"));
    // A subdirectory per environment, so test banks never mix with real ones.
    std::fs::create_dir_all(&state).unwrap_or_else(|e| panic!("{}: {e}", state.display()));
    Store::prepare(&state).unwrap_or_else(|e| panic!("{e}"));
    let app = Arc::new(App {
        plaid: Plaid::new(sandbox, id, secret),
        sandbox,
        state,
        syncing: Mutex::new(()),
    });

    let timer = app.clone();
    tokio::spawn(async move {
        loop {
            sync_all(timer.clone()).await;
            tokio::time::sleep(EVERY).await;
        }
    });

    let routes = Router::new()
        .route("/", get(page))
        .route("/api/overview", get(overview))
        .route("/api/money", get(money_page))
        .route("/api/category", post(categorize))
        .route("/api/budget", put(budget))
        .route("/api/budget/line", post(budget_line))
        .route("/api/manual", post(manual))
        .route("/api/recurring", post(not_recurring))
        .route("/api/link", post(link))
        .route("/api/linked", post(linked))
        .route("/api/sync", post(sync_now))
        .route("/api/sandbox/item", post(sandbox_item))
        .with_state(app);
    if let Some(unix) = handed_socket() {
        tokio::spawn(axum::serve(unix, routes.clone()).into_future());
    }
    let listen = env("MONEY_LISTEN");
    let socket = tokio::net::TcpListener::bind(&listen)
        .await
        .unwrap_or_else(|e| panic!("{listen}: {e}"));
    axum::serve(socket, routes).await.expect("serve");
}

/// The Unix socket systemd passed (`LISTEN_FDS`, first fd 3), if any.
fn handed_socket() -> Option<tokio::net::UnixListener> {
    use std::os::fd::FromRawFd;
    let ours = std::env::var("LISTEN_PID").ok()? == std::process::id().to_string();
    if !ours || std::env::var("LISTEN_FDS").ok()? != "1" {
        return None;
    }
    // SAFETY: systemd's protocol gives this process fd 3 as a listening
    // socket, and nothing else here takes it.
    let std = unsafe { std::os::unix::net::UnixListener::from_raw_fd(3) };
    std.set_nonblocking(true).expect("socket");
    Some(tokio::net::UnixListener::from_std(std).expect("socket"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_file_skips_blank_values() {
        let list = vec![
            ("PLAID_CLIENT_ID".to_owned(), "abc".to_owned()),
            ("PLAID_SANDBOX_SECRET".to_owned(), String::new()),
        ];
        assert_eq!(found(&list, "PLAID_CLIENT_ID").as_deref(), Some("abc"));
        assert_eq!(found(&list, "PLAID_SANDBOX_SECRET"), None);
        assert_eq!(unquote("\"abc\""), "abc");
        assert_eq!(unquote("'abc'"), "abc");
        assert_eq!(unquote("\"abc"), "\"abc");
    }
}
