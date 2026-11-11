//! The house over MCP, for Libri and any agent: the domains' functions as
//! tools, and the camera card, an MCP App (`io.modelcontextprotocol/ui`,
//! stable 2026-01-26) that hosts like Libri draw beside the call.
//!
//! Streamable HTTP at `/mcp`, stateless: each POST is one JSON-RPC message
//! answered as JSON, which the transport allows in place of an event
//! stream, so there are no sessions to keep and a GET has nothing to
//! offer. The protocol surface used here is small (initialize, tools,
//! resources, ping), so it is written out rather than taken from an SDK
//! and its dependencies.
//!
//! Only loopback reaches it: Libri on this host directly, the tailnet
//! through the host's TLS proxy. The frame's LAN gets the HTTP API it
//! draws from and never the agents' door. A request carrying an Origin is
//! a browser's, which MCP clients are not, and is refused, so no web page
//! can rebind a name onto it.

use std::net::SocketAddr;
use std::sync::Arc;

use axum::body::Bytes;
use axum::extract::{ConnectInfo, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Json, Response};
use base64::Engine;
use chrono::TimeZone;
use serde_json::{Value, json};

use crate::App;
use crate::api::{blocking, nudge};
use crate::cameras::{self, Event, Fault, Way};

/// The protocol versions this server speaks, newest last.
const VERSIONS: &[&str] = &["2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"];

/// The MCP Apps extension and the one content type it defines.
const EXTENSION: &str = "io.modelcontextprotocol/ui";
const MIME: &str = "text/html;profile=mcp-app";

/// The camera card.
const CARD: &str = "ui://home/cameras";
const CARD_HTML: &str = include_str!("ui/cameras.html");

/// How far back the cards and lists reach unless asked.
const DAY: f64 = 24.0 * 3600.0;
/// The most hours one listing may reach back: Frigate keeps about a week.
const WEEK_HOURS: f64 = 7.0 * 24.0;

pub async fn get() -> Response {
    StatusCode::METHOD_NOT_ALLOWED.into_response()
}

pub async fn post(
    State(app): State<Arc<App>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    if !peer.ip().is_loopback() {
        return StatusCode::NOT_FOUND.into_response();
    }
    if headers.contains_key(header::ORIGIN) {
        return StatusCode::FORBIDDEN.into_response();
    }
    let Ok(msg) = serde_json::from_slice::<Value>(&body) else {
        return Json(error(Value::Null, -32700, "parse error")).into_response();
    };
    // A notification or a response wants no answer.
    let Some(id) = msg.get("id").cloned() else {
        return StatusCode::ACCEPTED.into_response();
    };
    let Some(method) = msg["method"].as_str() else {
        return StatusCode::ACCEPTED.into_response();
    };
    let params = &msg["params"];
    let answer = match method {
        "initialize" => Ok(initialize(params)),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({ "tools": tools() })),
        "tools/call" => Ok(call(&app, params).await),
        "resources/list" => Ok(json!({ "resources": [{
            "uri": CARD, "name": "cameras", "title": "Cameras", "mimeType": MIME,
        }]})),
        "resources/templates/list" => Ok(json!({ "resourceTemplates": [] })),
        "resources/read" => read(&app, params),
        _ => Err((-32601, format!("no method {method}"))),
    };
    Json(match answer {
        Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
        Err((code, m)) => error(id, code, &m),
    })
    .into_response()
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
        "capabilities": {
            "tools": {},
            "resources": {},
            "extensions": { EXTENSION: {} },
        },
        "serverInfo": { "name": "home", "title": "Home", "version": env!("CARGO_PKG_VERSION") },
        "instructions": "The house: its cameras and what they saw (Frigate). Times are Unix seconds; text answers give the house's local time.",
    })
}

fn card_meta() -> Value {
    json!({ "ui": { "resourceUri": CARD } })
}

fn tools() -> Value {
    let camera = json!({ "type": "string", "description": "A camera's id, from `cameras`." });
    json!([
        {
            "name": "cameras",
            "title": "Cameras",
            "description": "The house's cameras and what they saw in the last day, shown as a card with live views and the timeline.",
            "inputSchema": { "type": "object", "properties": {} },
            "annotations": { "readOnlyHint": true },
            "_meta": card_meta(),
        },
        {
            "name": "camera_events",
            "title": "Camera events",
            "description": "What the cameras saw (people, animals, cars), newest first, from Frigate's review items. An `alert` is something Frigate grades important; a `detection` is lesser.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "camera": camera,
                    "hours": { "type": "number", "description": "How many hours back, at most 168. Default 24." },
                    "severity": { "type": "string", "enum": ["alert", "detection"] },
                    "limit": { "type": "integer", "minimum": 1, "maximum": cameras::MOST },
                },
            },
            "annotations": { "readOnlyHint": true },
            "_meta": card_meta(),
        },
        {
            "name": "camera_snapshot",
            "title": "Camera snapshot",
            "description": "One camera's latest frame, as an image to look at.",
            "inputSchema": { "type": "object", "properties": { "camera": camera }, "required": ["camera"] },
            "annotations": { "readOnlyHint": true },
        },
        {
            "name": "camera_turn",
            "title": "Turn a camera",
            "description": "Pans or tilts a camera that turns, by a small step.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "camera": camera,
                    "direction": { "type": "string", "enum": ["left", "right", "up", "down"] },
                },
                "required": ["camera", "direction"],
            },
            "annotations": { "readOnlyHint": false, "destructiveHint": false },
        },
    ])
}

fn read(app: &App, params: &Value) -> Result<Value, (i64, String)> {
    let uri = params["uri"].as_str().unwrap_or_default();
    if uri != CARD {
        return Err((-32002, format!("no resource {uri}")));
    }
    // The card loads pictures and video from the house's tailnet address.
    let domains: Vec<&str> = app.public.as_deref().into_iter().collect();
    Ok(json!({ "contents": [{
        "uri": CARD,
        "mimeType": MIME,
        "text": CARD_HTML,
        "_meta": { "ui": { "csp": { "resourceDomains": domains }, "prefersBorder": true } },
    }]}))
}

fn failed(text: String) -> Value {
    json!({ "content": [{ "type": "text", "text": text }], "isError": true })
}

async fn call(app: &Arc<App>, params: &Value) -> Value {
    let args = &params["arguments"];
    let arg = |k: &str| args[k].as_str().map(str::to_owned);
    if app.cameras.is_none() {
        return failed("This house has no cameras configured.".into());
    }
    let outcome = match params["name"].as_str().unwrap_or_default() {
        "cameras" => listing(app, cameras::Query::default(), DAY).await,
        "camera_events" => {
            let hours = args["hours"]
                .as_f64()
                .unwrap_or(24.0)
                .clamp(0.1, WEEK_HOURS);
            let q = cameras::Query {
                camera: arg("camera"),
                severity: arg("severity"),
                limit: args["limit"]
                    .as_u64()
                    .map(|l| l.min(u64::from(cameras::MOST)) as u32),
                ..Default::default()
            };
            listing(app, q, hours * 3600.0).await
        }
        "camera_snapshot" => {
            let Some(id) = arg("camera") else {
                return failed("Say which camera.".into());
            };
            let a = app.clone();
            blocking(move || {
                a.cameras
                    .as_ref()
                    .expect("checked above")
                    .snapshot(&id, Some(720))
            })
            .await
            .map(|jpeg| {
                json!({ "content": [{
                    "type": "image",
                    "mimeType": "image/jpeg",
                    "data": base64::engine::general_purpose::STANDARD.encode(jpeg),
                }]})
            })
        }
        "camera_turn" => {
            let (Some(id), Some(way)) = (
                arg("camera"),
                arg("direction").as_deref().and_then(Way::parse),
            ) else {
                return failed("Say which camera and which way: left, right, up or down.".into());
            };
            nudge(app, id.clone(), way).await.map(
                |()| json!({ "content": [{ "type": "text", "text": format!("Turned {id}.") }] }),
            )
        }
        other => return failed(format!("There is no tool {other}.")),
    };
    outcome.unwrap_or_else(|f| match f {
        Fault::Unknown(s) | Fault::Invalid(s) => failed(s),
        Fault::Unavailable(s) => {
            eprintln!("{s}");
            failed("The cameras did not answer; try again shortly.".into())
        }
    })
}

/// The cameras and their events over the last `span` seconds: as text for
/// a model, and as data for the card.
async fn listing(app: &Arc<App>, mut q: cameras::Query, span: f64) -> Result<Value, Fault> {
    q.after = Some(now() - span);
    let a = app.clone();
    let events = blocking(move || a.cameras.as_ref().expect("checked above").events(&q)).await?;
    let list = app.cameras.as_ref().expect("checked above").list();
    let mut text = String::from("Cameras: ");
    text += &list
        .iter()
        .map(|c| {
            format!(
                "{} ({}{})",
                c.name,
                c.id,
                if c.turns { ", turns" } else { "" }
            )
        })
        .collect::<Vec<_>>()
        .join(", ");
    text += &format!("\n{} events, newest first:\n", events.len());
    for e in &events {
        let name = list
            .iter()
            .find(|c| c.id == e.camera)
            .map_or(e.camera.as_str(), |c| c.name.as_str());
        text += &format!("{}\n", line(e, name, app.zone));
    }
    Ok(json!({
        "content": [{ "type": "text", "text": text }],
        "structuredContent": {
            "base": app.public,
            "cameras": list,
            "events": events,
        },
    }))
}

/// One event as a line: `Tue 14:03 Living room alert: person, dog (12 s) [id]`.
fn line(e: &Event, camera: &str, zone: chrono_tz::Tz) -> String {
    let at = zone
        .timestamp_opt(e.start as i64, 0)
        .single()
        .map_or_else(String::new, |t| t.format("%a %H:%M").to_string());
    let lasted = match e.end {
        Some(end) => format!("{} s", (end - e.start).round() as i64),
        None => "ongoing".into(),
    };
    format!(
        "{at} {camera} {}: {} ({lasted}) [{}]",
        e.severity,
        e.objects.join(", "),
        e.id
    )
}

fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initialize_answers_the_asked_version_or_the_newest() {
        let v = initialize(&json!({ "protocolVersion": "2025-06-18" }));
        assert_eq!(v["protocolVersion"], "2025-06-18");
        let v = initialize(&json!({ "protocolVersion": "1999-01-01" }));
        assert_eq!(v["protocolVersion"], *VERSIONS.last().unwrap());
        assert!(v["capabilities"]["extensions"][EXTENSION].is_object());
    }

    #[test]
    fn card_tools_name_the_card() {
        let t = tools();
        let named: Vec<_> = t
            .as_array()
            .unwrap()
            .iter()
            .filter(|t| t["_meta"]["ui"]["resourceUri"] == CARD)
            .map(|t| t["name"].as_str().unwrap())
            .collect();
        assert_eq!(named, ["cameras", "camera_events"]);
    }

    #[test]
    fn an_event_reads_as_one_line() {
        let e = Event {
            id: "1794403906.668138-ivcve9".into(),
            camera: "tapo1".into(),
            start: 1794403906.6,
            end: Some(1794403918.6),
            severity: "alert".into(),
            objects: vec!["person".into(), "dog".into()],
            zones: vec![],
            reviewed: false,
        };
        let l = line(&e, "Living room", chrono_tz::America::New_York);
        assert!(
            l.ends_with("Living room alert: person, dog (12 s) [1794403906.668138-ivcve9]"),
            "{l}"
        );
    }
}
