//! Endgrain's staff schedule: the manager lays out each week's shifts and
//! posts the week when it's ready, and staff ask for time off, which the
//! manager approves or denies. A usual week fills the weeks ahead, and days
//! with fewer people than the rules ask show red until covered or let go.
//! The manager's page is `/`; each person has a page of their own at
//! `/s/<token>` showing their shifts and the posted team schedule, where
//! they ask for days off. Everything staff can reach
//! sits under `/s/`, so a public door can admit that path alone.
//!
//! Environment:
//! - `ENDGRAIN_LISTEN`: address to bind, e.g. `127.0.0.1:8980`.
//! - `ENDGRAIN_STATE`: directory for `endgrain.db`.

mod store;

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use axum::Router;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::{Html, IntoResponse, Json, Response};
use axum::routing::{get, post, put};
use serde::{Deserialize, Serialize};
use serde_json::json;

use store::{DefaultIn, Error, OffIn, PersonIn, Rules, ShiftIn, Store};

/// One connection behind a lock: a handful of people use this, and every
/// request is a few small queries.
type App = Arc<Mutex<Store>>;

fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("{name} is not set"))
}

fn reply<T: Serialize>(app: &App, f: impl FnOnce(&Store) -> Result<T, Error>) -> Response {
    let store = app.lock().unwrap_or_else(|p| p.into_inner());
    match f(&store) {
        Ok(v) => Json(v).into_response(),
        Err(Error::Bad(why)) => (StatusCode::BAD_REQUEST, why).into_response(),
        Err(Error::Missing) => (StatusCode::NOT_FOUND, "not found").into_response(),
        Err(Error::Db(e)) => {
            eprintln!("endgrain: {e}");
            (StatusCode::INTERNAL_SERVER_ERROR, "database error").into_response()
        }
    }
}

const PAGE: &str = include_str!("page.html");

async fn page() -> Html<&'static str> {
    Html(PAGE)
}

#[derive(Deserialize)]
struct Monday {
    monday: String,
}

async fn week(State(app): State<App>, Query(q): Query<Monday>) -> Response {
    reply(&app, |s| s.week(&q.monday))
}

async fn save_shift(State(app): State<App>, Json(b): Json<ShiftIn>) -> Response {
    reply(&app, |s| s.save_shift(&b).map(|id| json!({ "id": id })))
}

async fn delete_shift(State(app): State<App>, Path(id): Path<i64>) -> Response {
    reply(&app, |s| s.delete_shift(id))
}

async fn copy_week(State(app): State<App>, Json(b): Json<Monday>) -> Response {
    reply(&app, |s| {
        s.copy_week(&b.monday).map(|n| json!({ "copied": n }))
    })
}

async fn use_usual(State(app): State<App>, Json(b): Json<Monday>) -> Response {
    reply(&app, |s| {
        s.use_usual(&b.monday).map(|n| json!({ "filled": n }))
    })
}

async fn usual(State(app): State<App>) -> Response {
    reply(&app, |s| s.usual_week())
}

async fn save_default(State(app): State<App>, Json(b): Json<DefaultIn>) -> Response {
    reply(&app, |s| s.save_default(&b).map(|id| json!({ "id": id })))
}

async fn delete_default(State(app): State<App>, Path(id): Path<i64>) -> Response {
    reply(&app, |s| s.delete_default(id))
}

async fn rules(State(app): State<App>, Json(b): Json<Rules>) -> Response {
    reply(&app, |s| s.set_rules(&b))
}

#[derive(Deserialize)]
struct Short {
    day: String,
    ok: bool,
}

async fn short_ok(State(app): State<App>, Json(b): Json<Short>) -> Response {
    reply(&app, |s| s.short_ok(&b.day, b.ok))
}

async fn publish(State(app): State<App>, Json(b): Json<Monday>) -> Response {
    reply(&app, |s| s.publish(&b.monday))
}

async fn staff(State(app): State<App>) -> Response {
    reply(&app, |s| s.staff())
}

async fn save_person(State(app): State<App>, Json(b): Json<PersonIn>) -> Response {
    reply(&app, |s| s.save_person(&b).map(|id| json!({ "id": id })))
}

async fn relink(State(app): State<App>, Path(id): Path<i64>) -> Response {
    reply(&app, |s| {
        s.relink(id).map(|token| json!({ "token": token }))
    })
}

async fn requests(State(app): State<App>) -> Response {
    reply(&app, |s| s.requests())
}

#[derive(Deserialize)]
struct AddOff {
    staff: i64,
    #[serde(flatten)]
    off: OffIn,
}

async fn add_off(State(app): State<App>, Json(b): Json<AddOff>) -> Response {
    reply(&app, |s| {
        s.add_off(b.staff, &b.off).map(|id| json!({ "id": id }))
    })
}

#[derive(Deserialize)]
struct Decision {
    status: String,
}

async fn decide(State(app): State<App>, Path(id): Path<i64>, Json(b): Json<Decision>) -> Response {
    reply(&app, |s| s.decide(id, &b.status))
}

async fn delete_off(State(app): State<App>, Path(id): Path<i64>) -> Response {
    reply(&app, |s| s.delete_off(id))
}

/// A person's page; an unknown or archived link is a plain 404.
async fn my_page(State(app): State<App>, Path(token): Path<String>) -> Response {
    let known = app
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .me(&token)
        .is_ok();
    if known {
        Html(PAGE).into_response()
    } else {
        (
            StatusCode::NOT_FOUND,
            "This link no longer works. Ask for a new one.",
        )
            .into_response()
    }
}

async fn mine(
    State(app): State<App>,
    Path(token): Path<String>,
    Query(q): Query<Monday>,
) -> Response {
    reply(&app, |s| s.mine(&token, &q.monday))
}

async fn ask_off(
    State(app): State<App>,
    Path(token): Path<String>,
    Json(b): Json<OffIn>,
) -> Response {
    reply(&app, |s| {
        s.ask_off(&token, &b).map(|id| json!({ "id": id }))
    })
}

async fn withdraw(State(app): State<App>, Path((token, id)): Path<(String, i64)>) -> Response {
    reply(&app, |s| s.withdraw(&token, id))
}

#[tokio::main]
async fn main() {
    let state = PathBuf::from(env("ENDGRAIN_STATE"));
    std::fs::create_dir_all(&state).unwrap_or_else(|e| panic!("{}: {e}", state.display()));
    let store = Store::open(&state.join("endgrain.db")).unwrap_or_else(|e| panic!("{e:?}"));
    let app: App = Arc::new(Mutex::new(store));

    let routes = Router::new()
        .route("/", get(page))
        .route("/api/week", get(week))
        .route("/api/week/copy", post(copy_week))
        .route("/api/week/publish", post(publish))
        .route("/api/week/usual", post(use_usual))
        .route("/api/week/short", post(short_ok))
        .route("/api/usual", get(usual).put(save_default))
        .route("/api/usual/{id}", axum::routing::delete(delete_default))
        .route("/api/rules", put(rules))
        .route("/api/shift", put(save_shift))
        .route("/api/shift/{id}", axum::routing::delete(delete_shift))
        .route("/api/staff", get(staff).put(save_person))
        .route("/api/staff/{id}/link", post(relink))
        .route("/api/requests", get(requests).post(add_off))
        .route("/api/requests/{id}", post(decide).delete(delete_off))
        .route("/s/{token}", get(my_page))
        .route("/s/{token}/api", get(mine))
        .route("/s/{token}/api/requests", post(ask_off))
        .route(
            "/s/{token}/api/requests/{id}",
            axum::routing::delete(withdraw),
        )
        .with_state(app);
    let listen = env("ENDGRAIN_LISTEN");
    let socket = tokio::net::TcpListener::bind(&listen)
        .await
        .unwrap_or_else(|e| panic!("{listen}: {e}"));
    axum::serve(socket, routes).await.expect("serve");
}
