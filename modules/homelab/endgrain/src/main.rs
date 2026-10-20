//! Endgrain's staff schedule: the manager lays out each week's shifts and
//! posts the week when it's ready, and staff ask for time off, which the
//! manager approves or denies. A usual week fills the weeks ahead, and days
//! with fewer people than the rules ask show red until covered or let go.
//! Staff also ask to work a day; once approved it becomes a shift.
//!
//! Two shared passwords: staff sign in with one and see only the posted
//! weeks, where they ask for days off or to work a day; the team is
//! small and trusted, so no one signs in as themselves. The manager signs
//! in with the other and sees everything. Until the manager's password is
//! set, the site is open.
//!
//! Environment:
//! - `ENDGRAIN_LISTEN`: address to bind, e.g. `127.0.0.1:8980`.
//! - `ENDGRAIN_STATE`: directory for `endgrain.db`.

mod store;

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use axum::Router;
use axum::extract::{Form, Path, Query, Request, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::{Html, IntoResponse, Json, Redirect, Response};
use axum::routing::{get, post, put};
use serde::{Deserialize, Serialize};
use serde_json::json;

use store::{CoverIn, DefaultIn, Error, OffIn, PersonIn, Role, Rules, ShiftIn, Store};

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

/// The one page, told whose it is; signed-out browsers get the sign-in.
async fn page(State(app): State<App>, headers: HeaderMap) -> Response {
    match role(&app, &headers) {
        Ok(Some(r)) => {
            Html(PAGE.replace("'admin'; // ROLE", &format!("'{}';", r.as_str()))).into_response()
        }
        Ok(None) => login_page(false).into_response(),
        Err(e) => reply::<()>(&app, |_| Err(e)),
    }
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

async fn approve_week(State(app): State<App>, Json(b): Json<Monday>) -> Response {
    reply(&app, |s| {
        s.approve_week(&b.monday).map(|n| json!({ "approved": n }))
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

async fn withdraw(State(app): State<App>, Path(id): Path<i64>) -> Response {
    reply(&app, |s| s.withdraw(id))
}

async fn board(State(app): State<App>, Query(q): Query<Monday>) -> Response {
    reply(&app, |s| s.board(&q.monday))
}

async fn team_off(State(app): State<App>) -> Response {
    reply(&app, |s| s.team_off())
}

async fn ask_off(State(app): State<App>, Json(b): Json<AddOff>) -> Response {
    reply(&app, |s| {
        s.ask_off(b.staff, &b.off).map(|id| json!({ "id": id }))
    })
}

#[derive(Deserialize)]
struct AskCover {
    staff: i64,
    #[serde(flatten)]
    cover: CoverIn,
}

async fn ask_cover(State(app): State<App>, Json(b): Json<AskCover>) -> Response {
    reply(&app, |s| {
        s.ask_cover(b.staff, &b.cover).map(|id| json!({ "id": id }))
    })
}

const LOGIN: &str = include_str!("login.html");
const COOKIE: &str = "endgrain";
/// A year: people sign in once on their phone and stay signed in.
const STAY: u32 = 365 * 24 * 3600;

fn session(headers: &HeaderMap) -> Option<String> {
    headers
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(';'))
        .find_map(|c| c.trim().strip_prefix(COOKIE)?.strip_prefix('='))
        .map(str::to_owned)
}

fn login_page(wrong: bool) -> Html<String> {
    Html(LOGIN.replace(
        "<!--wrong-->",
        if wrong {
            "<p class=\"wrong\">That's not it. Try again.</p>"
        } else {
            ""
        },
    ))
}

fn signed(token: &str) -> [(header::HeaderName, String); 1] {
    [(
        header::SET_COOKIE,
        format!("{COOKIE}={token}; Path=/; Max-Age={STAY}; HttpOnly; Secure; SameSite=Lax"),
    )]
}

#[derive(Deserialize)]
struct Password {
    password: String,
}

async fn sign_in(State(app): State<App>, Form(f): Form<Password>) -> Response {
    let t = app
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .sign_in(&f.password);
    match t {
        Ok(Some((t, _))) => (signed(&t), Redirect::to("/")).into_response(),
        Ok(None) => {
            // Slows guessing; the lock is not held while waiting.
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            (StatusCode::UNAUTHORIZED, login_page(true)).into_response()
        }
        Err(e) => reply::<()>(&app, |_| Err(e)),
    }
}

#[derive(Deserialize)]
struct NewPassword {
    role: Role,
    password: String,
}

/// Sets one of the two passwords. The manager who changed their own stays
/// signed in.
async fn set_password(State(app): State<App>, Json(b): Json<NewPassword>) -> Response {
    let store = app.lock().unwrap_or_else(|p| p.into_inner());
    let done = store.set_password(b.role, &b.password).and_then(|()| {
        if b.role == Role::Admin {
            store.sign_in(&b.password)
        } else {
            Ok(None)
        }
    });
    match done {
        Ok(Some((t, _))) => (signed(&t), StatusCode::NO_CONTENT).into_response(),
        Ok(None) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => {
            drop(store);
            reply::<()>(&app, |_| Err(e))
        }
    }
}

async fn passwords(State(app): State<App>) -> Response {
    reply(&app, |s| s.passwords())
}

fn role(app: &App, headers: &HeaderMap) -> Result<Option<Role>, Error> {
    app.lock()
        .unwrap_or_else(|p| p.into_inner())
        .role(session(headers).as_deref())
}

async fn let_in(app: &App, req: Request, next: Next, manager: bool) -> Response {
    match role(app, req.headers()) {
        Ok(Some(Role::Admin)) => next.run(req).await,
        Ok(Some(Role::Staff)) if !manager => next.run(req).await,
        Ok(Some(Role::Staff)) => (StatusCode::FORBIDDEN, "for the manager").into_response(),
        Ok(None) => (StatusCode::UNAUTHORIZED, "sign in again").into_response(),
        Err(e) => reply::<()>(app, |_| Err(e)),
    }
}

async fn anyone(State(app): State<App>, req: Request, next: Next) -> Response {
    let_in(&app, req, next, false).await
}

async fn manager(State(app): State<App>, req: Request, next: Next) -> Response {
    let_in(&app, req, next, true).await
}

#[tokio::main]
async fn main() {
    let state = PathBuf::from(env("ENDGRAIN_STATE"));
    std::fs::create_dir_all(&state).unwrap_or_else(|e| panic!("{}: {e}", state.display()));
    let store = Store::open(&state.join("endgrain.db")).unwrap_or_else(|e| panic!("{e:?}"));
    let app: App = Arc::new(Mutex::new(store));

    let board_routes = Router::new()
        .route("/api/board", get(board))
        .route("/api/board/off", post(ask_off))
        .route("/api/board/cover", post(ask_cover))
        .route("/api/board/requests", get(team_off))
        .route("/api/board/requests/{id}", axum::routing::delete(withdraw))
        .route_layer(middleware::from_fn_with_state(app.clone(), anyone));
    let routes = Router::new()
        .route("/api/week", get(week))
        .route("/api/week/copy", post(copy_week))
        .route("/api/week/publish", post(publish))
        .route("/api/week/usual", post(use_usual))
        .route("/api/week/approve", post(approve_week))
        .route("/api/week/short", post(short_ok))
        .route("/api/usual", get(usual).put(save_default))
        .route("/api/usual/{id}", axum::routing::delete(delete_default))
        .route("/api/rules", put(rules))
        .route("/api/shift", put(save_shift))
        .route("/api/shift/{id}", axum::routing::delete(delete_shift))
        .route("/api/staff", get(staff).put(save_person))
        .route("/api/requests", get(requests).post(add_off))
        .route("/api/requests/{id}", post(decide).delete(delete_off))
        .route("/api/password", get(passwords).put(set_password))
        .route_layer(middleware::from_fn_with_state(app.clone(), manager))
        .merge(board_routes)
        .route("/", get(page))
        .route("/login", post(sign_in))
        .with_state(app);
    let listen = env("ENDGRAIN_LISTEN");
    let socket = tokio::net::TcpListener::bind(&listen)
        .await
        .unwrap_or_else(|e| panic!("{listen}: {e}"));
    axum::serve(socket, routes).await.expect("serve");
}
