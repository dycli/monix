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
//! - `FRAME_CALDAV_FILE` (optional): a CalDAV accounts file, `[{"name","url","username","password"}]`.
//! - `FRAME_WEATHER` (optional): `latitude,longitude` for the forecast.
//! - `CACHE_DIRECTORY` (optional, set by systemd): where fitted photos
//!   are kept between requests and restarts.
//! - `FRAME_AIR` (optional): the AirGradient monitor's address.
//! - `FRAME_CAMERAS` (optional): a JSON list of `{"id", "name", "turns"}`,
//!   the cameras shown, by their Frigate and go2rtc name, a label and
//!   whether Frigate can pan and tilt them.
//! - `FRAME_GO2RTC` (with cameras): go2rtc's API, e.g. `http://127.0.0.1:1984`.
//! - `FRAME_FRIGATE` (with cameras): Frigate's unauthenticated internal
//!   API, e.g. `http://127.0.0.1:5000`.
//! - `FRAME_PUBLIC` (optional): the address the tailnet reaches this server
//!   at, e.g. `https://home.su.is`, where Libri's camera card loads
//!   pictures and video from.
//!
//! The server is the house's backend, one module per domain (cameras.rs;
//! the photos, calendar, forecast and air move into the same shape next),
//! each reached by every UI through the versioned HTTP API (api.rs) and by
//! agents through MCP (mcp.rs). The pages (page.html, home/, ui/) are
//! clients of those and hold no logic of the house's.

mod air;
mod api;
mod calendar;
mod cameras;
mod home;
mod mcp;
mod photo;
mod weather;

use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use axum::Router;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{Html, IntoResponse, Json, Response};
use axum::routing::{get, post};
use serde::Deserialize;
use serde_json::{Value, json};
use std::net::SocketAddr;
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

struct App {
    immich: Immich,
    cameras: Option<cameras::Cameras>,
    /// The house's time zone, for what is said in words.
    zone: chrono_tz::Tz,
    /// Where the tailnet reaches this server (FRAME_PUBLIC).
    public: Option<String>,
    photos: Mutex<Option<(Instant, Vec<String>)>>,
    cache: Option<photo::Cache>,
    calendar: Option<Calendar>,
    weather: Option<Weather>,
    air: Option<Air>,
    home: home::Home,
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

    /// One photo at Immich's preview size.
    fn preview(&self, id: &str) -> Result<Vec<u8>, String> {
        self.agent
            .get(format!("{}/api/assets/{id}/thumbnail", self.base))
            .query("size", "preview")
            .header("x-api-key", &self.key)
            .call()
            .and_then(|mut r| r.body_mut().with_config().limit(32 << 20).read_to_vec())
            .map_err(|e| format!("preview: {e}"))
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

async fn page(headers: HeaderMap) -> Response {
    if home::is_home(&headers) {
        return home::page();
    }
    (
        [(header::CACHE_CONTROL, "no-cache")],
        Html(include_str!("page.html")),
    )
        .into_response()
}

async fn photos(State(app): State<Arc<App>>) -> Response {
    let mut held = app.photos.lock().await;
    if let Some((at, ids)) = held.as_ref()
        && at.elapsed() < FRESH
    {
        return Json(ids.clone()).into_response();
    }
    let a = app.clone();
    let listed = tokio::task::spawn_blocking(move || {
        let ids = a.immich.photos()?;
        if let Some(cache) = &a.cache {
            cache.keep(&ids);
        }
        Ok::<_, String>(ids)
    });
    match listed.await {
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
    let fitted = tokio::task::spawn_blocking(move || {
        if let Some(bytes) = app.cache.as_ref().and_then(|c| c.get(&id)) {
            return Ok(bytes);
        }
        let bytes = photo::fit(&app.immich.preview(&id)?)?;
        if let Some(cache) = &app.cache {
            cache.put(&id, &bytes);
        }
        Ok(bytes)
    });
    match fitted.await {
        Ok(Ok(bytes)) => (
            [
                (header::CONTENT_TYPE, "image/jpeg"),
                (header::CACHE_CONTROL, "max-age=86400"),
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
        cameras: std::env::var("FRAME_CAMERAS").ok().map(|list| {
            cameras::Cameras::new(&list, &env("FRAME_GO2RTC"), &env("FRAME_FRIGATE"))
                .unwrap_or_else(|e| panic!("{e}"))
        }),
        zone: zone.parse().unwrap_or_else(|e| panic!("FRAME_TZ: {e}")),
        public: std::env::var("FRAME_PUBLIC")
            .ok()
            .map(|p| p.trim_end_matches('/').to_owned()),
        photos: Mutex::new(None),
        cache: std::env::var("CACHE_DIRECTORY")
            .ok()
            .map(|d| photo::Cache::new(&d)),
        calendar: std::env::var("FRAME_CALDAV_FILE").ok().map(|f| {
            let accounts = std::fs::read_to_string(&f).unwrap_or_else(|e| panic!("{f}: {e}"));
            Calendar::new(&accounts, &zone).unwrap_or_else(|e| panic!("{e}"))
        }),
        weather: std::env::var("FRAME_WEATHER")
            .ok()
            .map(|p| Weather::new(&p, &zone).unwrap_or_else(|e| panic!("{e}"))),
        air: std::env::var("FRAME_AIR").ok().map(|host| Air::new(&host)),
        home: home::Home::from_env(),
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
        .route("/api/v1/cameras", get(api::camera_list))
        .route("/api/v1/cameras/{id}/snapshot.jpg", get(api::snapshot))
        .route("/api/v1/cameras/{id}/live.mp4", get(api::live))
        .route("/api/v1/cameras/{id}/turn/{way}", post(api::turn))
        .route("/api/v1/events", get(api::events))
        .route("/api/v1/events/{id}", get(api::event))
        .route("/api/v1/events/{id}/thumbnail.webp", get(api::thumbnail))
        .route("/api/v1/events/{id}/clip.mp4", get(api::clip))
        .route("/mcp", get(mcp::get).post(mcp::post))
        .route("/home/{name}", get(home::asset))
        .route("/api/home", get(home::status))
        .route("/api/usage", get(home::usage))
        .with_state(app);
    let listen = env("FRAME_LISTEN");
    let socket = tokio::net::TcpListener::bind(&listen)
        .await
        .unwrap_or_else(|e| panic!("{listen}: {e}"));
    // The peer's address decides who reaches MCP (mcp.rs).
    axum::serve(
        socket,
        routes.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await
    .expect("serve");
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
