//! The wall frame's page: a slideshow of one Immich album with the time
//! over it. The frame itself holds no credentials; this server keeps the
//! Immich key and hands the page only photo ids and preview-sized images.
//!
//! Environment:
//! - `FRAME_LISTEN`: address to bind, e.g. `0.0.0.0:8970`.
//! - `FRAME_IMMICH`: Immich's base URL, e.g. `http://127.0.0.1:2283`.
//! - `FRAME_IMMICH_KEY_FILE`: an API key with album.read, asset.read and
//!   asset.view.
//! - `FRAME_ALBUM`: the album's name.
//! - `FRAME_TZ`: the house's time zone, e.g. `America/New_York`.
//! - `FRAME_CALDAV_FILE` (optional): yeoman's CalDAV accounts file.
//! - `FRAME_WEATHER` (optional): `latitude,longitude` for the forecast.
//! - `FRAME_AIR` (optional): the AirGradient monitor's address.
//! - `FRAME_CAMERAS` (optional): a JSON list of `{"id", "name", "turns"}`,
//!   the go2rtc streams the page may show live, by their name, a label and
//!   whether Frigate can pan and tilt them.
//! - `FRAME_GO2RTC` (with cameras): go2rtc's API, e.g. `http://127.0.0.1:1984`.
//! - `FRAME_FRIGATE` (with a camera that turns): Frigate's unauthenticated
//!   internal websocket, e.g. `ws://127.0.0.1:5000/ws`, to pan and tilt.

mod air;
mod calendar;
mod weather;

use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use axum::Router;
use axum::body::{Body, Bytes};
use axum::extract::{Path, State};
use axum::http::{StatusCode, header};
use axum::response::{Html, IntoResponse, Json, Response};
use axum::routing::get;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::Mutex;

use air::Air;
use calendar::Calendar;
use weather::Weather;

/// How long an album listing is reused before asking Immich again.
const FRESH: Duration = Duration::from_secs(600);
/// Immich's largest search page.
const PAGE: u32 = 1000;
/// How long the calendar and the forecast are reused.
const CALENDAR_FRESH: Duration = Duration::from_secs(300);
const WEATHER_FRESH: Duration = Duration::from_secs(900);
/// The monitor itself updates about once a minute.
const AIR_FRESH: Duration = Duration::from_secs(60);
/// Days of calendar the board shows, today first.
const AHEAD: i64 = 7;

struct Immich {
    base: String,
    key: String,
    album: String,
    agent: ureq::Agent,
}

/// A live camera: its go2rtc stream name, the label the page shows, and
/// whether it pans and tilts.
#[derive(Clone, Deserialize, Serialize)]
struct Camera {
    id: String,
    name: String,
    #[serde(default)]
    turns: bool,
}

struct Cameras {
    base: String,
    list: Vec<Camera>,
    frigate: Option<String>,
    /// Bumped by each move, so only the latest move's timer stops the camera.
    moves: std::sync::atomic::AtomicU64,
    /// Connects with a timeout but reads forever: a live stream never ends.
    agent: ureq::Agent,
}

struct App {
    immich: Immich,
    cameras: Option<Cameras>,
    photos: Mutex<Option<(Instant, Vec<String>)>>,
    calendar: Option<Calendar>,
    weather: Option<Weather>,
    air: Option<Air>,
    /// The last good answer of each, kept through outages.
    events: Mutex<Option<(Instant, Value)>>,
    forecast: Mutex<Option<(Instant, Value)>>,
    indoors: Mutex<Option<(Instant, Value)>>,
    /// When this server started; the page reloads when it changes, so a
    /// deploy reaches the wall without anyone touching the frame.
    boot: u64,
}

/// A cached answer: fresh as is, else fetched again; on failure the last
/// good one, however old, or null.
async fn cached<F>(slot: &Mutex<Option<(Instant, Value)>>, fresh: Duration, fetch: F) -> Value
where
    F: FnOnce() -> Result<Value, String> + Send + 'static,
{
    let mut held = slot.lock().await;
    if let Some((at, v)) = held.as_ref()
        && at.elapsed() < fresh
    {
        return v.clone();
    }
    match tokio::task::spawn_blocking(fetch).await {
        Ok(Ok(v)) => {
            *held = Some((Instant::now(), v.clone()));
            v
        }
        Ok(Err(e)) => {
            eprintln!("{e}");
            held.as_ref().map_or(Value::Null, |(_, v)| v.clone())
        }
        Err(e) => {
            eprintln!("{e}");
            held.as_ref().map_or(Value::Null, |(_, v)| v.clone())
        }
    }
}

#[derive(Deserialize)]
struct Album {
    id: String,
    #[serde(rename = "albumName")]
    name: String,
}

#[derive(Deserialize)]
struct Search {
    assets: Page,
}

#[derive(Deserialize)]
struct Page {
    items: Vec<Item>,
    #[serde(rename = "nextCursor")]
    next: Option<String>,
}

#[derive(Deserialize)]
struct Item {
    id: String,
}

impl Immich {
    /// The album's image ids, oldest page first as Immich returns them.
    fn photos(&self) -> Result<Vec<String>, String> {
        let albums: Vec<Album> = self
            .agent
            .get(format!("{}/api/albums", self.base))
            .header("x-api-key", &self.key)
            .call()
            .and_then(|mut r| r.body_mut().read_json())
            .map_err(|e| format!("albums: {e}"))?;
        let album = albums
            .into_iter()
            .find(|a| a.name == self.album)
            .ok_or_else(|| format!("no album named {:?}", self.album))?;

        let mut ids = Vec::new();
        let mut cursor: Option<String> = None;
        loop {
            let mut body = json!({
                "filter": {
                    "albumIds": { "any": [album.id] },
                    "type": { "eq": "IMAGE" },
                },
                "size": PAGE,
            });
            if let Some(c) = &cursor {
                body["cursor"] = json!(c);
            }
            let search: Search = self
                .agent
                .post(format!("{}/api/search/metadata", self.base))
                .header("x-api-key", &self.key)
                .send_json(&body)
                .and_then(|mut r| r.body_mut().read_json())
                .map_err(|e| format!("search: {e}"))?;
            ids.extend(search.assets.items.into_iter().map(|i| i.id));
            match search.assets.next {
                Some(c) => cursor = Some(c),
                None => return Ok(ids),
            }
        }
    }

    /// One photo at Immich's preview size, with its content type.
    fn preview(&self, id: &str) -> Result<(String, Vec<u8>), String> {
        let mut r = self
            .agent
            .get(format!("{}/api/assets/{id}/thumbnail", self.base))
            .query("size", "preview")
            .header("x-api-key", &self.key)
            .call()
            .map_err(|e| format!("preview: {e}"))?;
        let kind = r
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("image/jpeg")
            .to_owned();
        let bytes = r
            .body_mut()
            .with_config()
            .limit(32 << 20)
            .read_to_vec()
            .map_err(|e| format!("preview: {e}"))?;
        Ok((kind, bytes))
    }
}

/// Immich ids are UUIDs; anything else never reaches its URL.
fn is_id(s: &str) -> bool {
    s.len() == 36
        && s.char_indices().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => c == '-',
            _ => c.is_ascii_hexdigit(),
        })
}

fn failed(e: String) -> Response {
    eprintln!("{e}");
    (StatusCode::BAD_GATEWAY, "Immich is unavailable").into_response()
}

async fn page() -> impl IntoResponse {
    (
        [(header::CACHE_CONTROL, "no-cache")],
        Html(include_str!("page.html")),
    )
}

async fn photos(State(app): State<Arc<App>>) -> Response {
    let mut held = app.photos.lock().await;
    if let Some((at, ids)) = held.as_ref()
        && at.elapsed() < FRESH
    {
        return Json(ids.clone()).into_response();
    }
    let a = app.clone();
    match tokio::task::spawn_blocking(move || a.immich.photos()).await {
        Ok(Ok(ids)) => {
            *held = Some((Instant::now(), ids.clone()));
            Json(ids).into_response()
        }
        Ok(Err(e)) => failed(e),
        Err(e) => failed(e.to_string()),
    }
}

async fn photo(State(app): State<Arc<App>>, Path(id): Path<String>) -> Response {
    if !is_id(&id) {
        return StatusCode::NOT_FOUND.into_response();
    }
    match tokio::task::spawn_blocking(move || app.immich.preview(&id)).await {
        Ok(Ok((kind, bytes))) => (
            [
                (header::CONTENT_TYPE, kind),
                (header::CACHE_CONTROL, "max-age=86400".to_owned()),
            ],
            bytes,
        )
            .into_response(),
        Ok(Err(e)) => failed(e),
        Err(e) => failed(e.to_string()),
    }
}

/// Everything around the photos: the calendar from today, the forecast
/// and the air indoors.
async fn board(State(app): State<Arc<App>>) -> Response {
    let a = app.clone();
    let events = match &app.calendar {
        Some(_) => {
            cached(&app.events, CALENDAR_FRESH, move || {
                let cal = a.calendar.as_ref().expect("checked above");
                let today = chrono::Utc::now().with_timezone(&cal.zone).date_naive();
                cal.events(today, AHEAD)
                    .map(|e| serde_json::to_value(e).unwrap_or_default())
            })
            .await
        }
        None => Value::Null,
    };
    let a = app.clone();
    let forecast = match &app.weather {
        Some(_) => {
            cached(&app.forecast, WEATHER_FRESH, move || {
                let w = a.weather.as_ref().expect("checked above");
                w.report()
                    .map(|r| serde_json::to_value(r).unwrap_or_default())
            })
            .await
        }
        None => Value::Null,
    };
    let a = app.clone();
    let air = match &app.air {
        Some(_) => {
            cached(&app.indoors, AIR_FRESH, move || {
                let air = a.air.as_ref().expect("checked above");
                air.reading()
                    .map(|r| serde_json::to_value(r).unwrap_or_default())
            })
            .await
        }
        None => Value::Null,
    };
    (
        [(header::CACHE_CONTROL, "no-cache")],
        Json(json!({ "boot": app.boot, "events": events, "weather": forecast, "air": air })),
    )
        .into_response()
}

async fn cameras(State(app): State<Arc<App>>) -> Response {
    let list = app.cameras.as_ref().map_or(&[][..], |c| &c.list);
    ([(header::CACHE_CONTROL, "no-cache")], Json(list)).into_response()
}

/// One camera's sub-stream as fragmented MP4, relayed from go2rtc for as
/// long as the page keeps the connection open.
async fn camera(State(app): State<Arc<App>>, Path(id): Path<String>) -> Response {
    let Some(cams) = &app.cameras else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if !cams.list.iter().any(|c| c.id == id) {
        return StatusCode::NOT_FOUND.into_response();
    }
    let url = format!("{}/api/stream.mp4", cams.base);
    let agent = cams.agent.clone();
    let opened = tokio::task::spawn_blocking(move || {
        agent
            .get(url)
            .query("src", format!("{id}_sub"))
            .call()
            .map_err(|e| format!("camera {id}: {e}"))
    })
    .await;
    let r = match opened {
        Ok(Ok(r)) => r,
        Ok(Err(e)) => return gone(e),
        Err(e) => return gone(e.to_string()),
    };

    // The read blocks, so it runs on its own thread and hands chunks over;
    // when the page goes away the receiver drops, the send fails and the
    // thread lets go of go2rtc.
    let (tx, rx) = tokio::sync::mpsc::channel::<Result<Bytes, std::io::Error>>(8);
    tokio::task::spawn_blocking(move || {
        use std::io::Read;
        let mut body = r.into_body().into_reader();
        let mut buf = vec![0; 64 << 10];
        loop {
            let chunk = match body.read(&mut buf) {
                Ok(0) => return,
                Ok(n) => Ok(Bytes::copy_from_slice(&buf[..n])),
                Err(e) => Err(e),
            };
            let end = chunk.is_err();
            if tx.blocking_send(chunk).is_err() || end {
                return;
            }
        }
    });
    let stream =
        futures_util::stream::unfold(rx, |mut rx| async { rx.recv().await.map(|c| (c, rx)) });
    (
        [
            (header::CONTENT_TYPE, "video/mp4"),
            (header::CACHE_CONTROL, "no-store"),
        ],
        Body::from_stream(stream),
    )
        .into_response()
}

/// How long a camera turns after one move. The page repeats the move while
/// an arrow is held, so the server always sends the stop itself and a
/// dropped connection cannot leave a camera turning.
const NUDGE: Duration = Duration::from_millis(500);

/// Sends Frigate one PTZ command for a camera over its websocket, as its own
/// UI does; Frigate has no HTTP route for continuous moves.
fn ptz(url: &str, camera: &str, command: &str) -> Result<(), String> {
    let (mut ws, _) = tungstenite::connect(url).map_err(|e| format!("frigate: {e}"))?;
    let msg = json!({ "topic": format!("{camera}/ptz"), "payload": command, "retain": false });
    ws.send(tungstenite::Message::text(msg.to_string()))
        .and_then(|()| ws.close(None))
        .map_err(|e| format!("frigate: {e}"))?;
    // Read until Frigate answers the close, so the command is not cut off.
    while ws.read().is_ok() {}
    Ok(())
}

async fn turn(State(app): State<Arc<App>>, Path((id, way)): Path<(String, String)>) -> Response {
    use std::sync::atomic::Ordering;
    let command = match way.as_str() {
        "left" => "MOVE_LEFT",
        "right" => "MOVE_RIGHT",
        "up" => "MOVE_UP",
        "down" => "MOVE_DOWN",
        _ => return StatusCode::NOT_FOUND.into_response(),
    };
    let Some(cams) = &app.cameras else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let Some(url) = cams.frigate.clone() else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if !cams.list.iter().any(|c| c.id == id && c.turns) {
        return StatusCode::NOT_FOUND.into_response();
    }
    let this = cams.moves.fetch_add(1, Ordering::SeqCst) + 1;
    let (u, i) = (url.clone(), id.clone());
    match tokio::task::spawn_blocking(move || ptz(&u, &i, command)).await {
        Ok(Ok(())) => {}
        Ok(Err(e)) => return gone(e),
        Err(e) => return gone(e.to_string()),
    }
    let a = app.clone();
    tokio::spawn(async move {
        tokio::time::sleep(NUDGE).await;
        let cams = a.cameras.as_ref().expect("checked above");
        if cams.moves.load(Ordering::SeqCst) == this {
            match tokio::task::spawn_blocking(move || ptz(&url, &id, "STOP")).await {
                Ok(Err(e)) => eprintln!("{e}"),
                Err(e) => eprintln!("{e}"),
                Ok(Ok(())) => {}
            }
        }
    });
    StatusCode::NO_CONTENT.into_response()
}

fn gone(e: String) -> Response {
    eprintln!("{e}");
    (StatusCode::BAD_GATEWAY, "camera is unavailable").into_response()
}

fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("{name} is not set"))
}

#[tokio::main]
async fn main() {
    let key_file = env("FRAME_IMMICH_KEY_FILE");
    let key = std::fs::read_to_string(&key_file)
        .unwrap_or_else(|e| panic!("{key_file}: {e}"))
        .trim()
        .to_owned();
    let zone = env("FRAME_TZ");
    let app = Arc::new(App {
        immich: Immich {
            base: env("FRAME_IMMICH").trim_end_matches('/').to_owned(),
            key,
            album: env("FRAME_ALBUM"),
            agent: ureq::Agent::config_builder()
                .timeout_global(Some(Duration::from_secs(30)))
                .build()
                .into(),
        },
        cameras: std::env::var("FRAME_CAMERAS").ok().map(|list| Cameras {
            base: env("FRAME_GO2RTC").trim_end_matches('/').to_owned(),
            list: serde_json::from_str(&list).unwrap_or_else(|e| panic!("FRAME_CAMERAS: {e}")),
            frigate: std::env::var("FRAME_FRIGATE").ok(),
            moves: std::sync::atomic::AtomicU64::new(0),
            agent: ureq::Agent::config_builder()
                .timeout_connect(Some(Duration::from_secs(5)))
                .timeout_recv_response(Some(Duration::from_secs(15)))
                .build()
                .into(),
        }),
        photos: Mutex::new(None),
        calendar: std::env::var("FRAME_CALDAV_FILE").ok().map(|f| {
            let accounts = std::fs::read_to_string(&f).unwrap_or_else(|e| panic!("{f}: {e}"));
            Calendar::new(&accounts, &zone).unwrap_or_else(|e| panic!("{e}"))
        }),
        weather: std::env::var("FRAME_WEATHER")
            .ok()
            .map(|p| Weather::new(&p, &zone).unwrap_or_else(|e| panic!("{e}"))),
        air: std::env::var("FRAME_AIR").ok().map(|host| Air::new(&host)),
        events: Mutex::new(None),
        forecast: Mutex::new(None),
        indoors: Mutex::new(None),
        boot: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_secs()),
    });
    let routes = Router::new()
        .route("/", get(page))
        .route("/api/photos", get(photos))
        .route("/api/board", get(board))
        .route("/photo/{id}", get(photo))
        .route("/api/cameras", get(cameras))
        .route("/camera/{id}", get(camera))
        .route("/camera/{id}/{way}", axum::routing::post(turn))
        .with_state(app);
    let listen = env("FRAME_LISTEN");
    let socket = tokio::net::TcpListener::bind(&listen)
        .await
        .unwrap_or_else(|e| panic!("{listen}: {e}"));
    axum::serve(socket, routes).await.expect("serve");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_uuids_are_ids() {
        assert!(is_id("0b6e5f0e-3c1a-4d2b-9f8e-7a6b5c4d3e2f"));
        assert!(!is_id("../../api/users"));
        assert!(!is_id("0b6e5f0e-3c1a-4d2b-9f8e-7a6b5c4d3e2"));
        assert!(!is_id("0b6e5f0e/3c1a-4d2b-9f8e-7a6b5c4d3e2f"));
    }

    #[test]
    fn a_search_page_reads_ids_and_cursor() {
        let s: Search = serde_json::from_str(
            r#"{"albums":{},"assets":{"total":2,"count":2,"items":[{"id":"a","type":"IMAGE"},{"id":"b"}],"nextCursor":"c2"}}"#,
        )
        .unwrap();
        let ids: Vec<_> = s.assets.items.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(ids, ["a", "b"]);
        assert_eq!(s.assets.next.as_deref(), Some("c2"));
    }
}
