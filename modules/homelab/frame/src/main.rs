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

mod calendar;
mod weather;

use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use axum::Router;
use axum::extract::{Path, State};
use axum::http::{StatusCode, header};
use axum::response::{Html, IntoResponse, Json, Response};
use axum::routing::get;
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::Mutex;

use calendar::Calendar;
use weather::Weather;

/// How long an album listing is reused before asking Immich again.
const FRESH: Duration = Duration::from_secs(600);
/// Immich's largest search page.
const PAGE: u32 = 1000;
/// How long the calendar and the forecast are reused.
const CALENDAR_FRESH: Duration = Duration::from_secs(300);
const WEATHER_FRESH: Duration = Duration::from_secs(900);
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
    photos: Mutex<Option<(Instant, Vec<String>)>>,
    calendar: Option<Calendar>,
    weather: Option<Weather>,
    /// The last good answer of each, kept through outages.
    events: Mutex<Option<(Instant, Value)>>,
    forecast: Mutex<Option<(Instant, Value)>>,
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

/// Everything around the photos: the calendar from today and the forecast.
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
    (
        [(header::CACHE_CONTROL, "no-cache")],
        Json(json!({ "boot": app.boot, "events": events, "weather": forecast })),
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
        photos: Mutex::new(None),
        calendar: std::env::var("FRAME_CALDAV_FILE").ok().map(|f| {
            let accounts = std::fs::read_to_string(&f).unwrap_or_else(|e| panic!("{f}: {e}"));
            Calendar::new(&accounts, &zone).unwrap_or_else(|e| panic!("{e}"))
        }),
        weather: std::env::var("FRAME_WEATHER")
            .ok()
            .map(|p| Weather::new(&p, &zone).unwrap_or_else(|e| panic!("{e}"))),
        events: Mutex::new(None),
        forecast: Mutex::new(None),
        boot: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_secs()),
    });
    let routes = Router::new()
        .route("/", get(page))
        .route("/api/photos", get(photos))
        .route("/api/board", get(board))
        .route("/photo/{id}", get(photo))
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
