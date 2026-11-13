//! The house's dashboard at home.<domain>: a Glance-style board of the
//! services and the host's health, the house's calendar, forecast and air,
//! an Agents tab with the assistants and how much of each subscription
//! they used, and a Monitoring tab. The look and much of the page's code
//! come from Glance (github.com/glanceapp/glance), so this crate and `ui/`
//! are AGPL-3.0; see `ui/LICENSE`.
//!
//! The calendar, forecast and air come from hob, the house's backend
//! (dycli/hob), over its HTTP API; the services, the host and the
//! subscriptions are read here. I/O blocks, a thread per connection, as in
//! hob.
//!
//! Environment:
//! - `DASHBOARD_LISTEN`: address to bind, e.g. `127.0.0.1:8971`.
//! - `DASHBOARD_HOB`: hob's API, e.g. `http://127.0.0.1:8970`.
//! - `DASHBOARD_SERVICES`, `DASHBOARD_DISKS` (optional): see system.rs.
//! - `DASHBOARD_USAGE` (optional): the usage service's socket.

mod core;
mod http;
mod system;
mod usage;

use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};

use http::Response;
use system::System;
use usage::Usage;

struct App {
    hob: String,
    agent: ureq::Agent,
    system: System,
    usage: Option<Usage>,
}

impl App {
    /// One of hob's readings, or null when hob has none or did not answer.
    fn hob(&self, path: &str) -> Value {
        self.agent
            .get(format!("{}/api/v1/{path}", self.hob))
            .call()
            .and_then(|mut r| r.body_mut().read_json())
            .unwrap_or_else(|e| {
                eprintln!("hob {path}: {e}");
                Value::Null
            })
    }
}

fn asset(name: &str) -> Response {
    let (kind, body): (&str, &'static [u8]) = match name {
        "glance.css" => ("text/css", include_bytes!("ui/glance.css")),
        "home.css" => ("text/css", include_bytes!("ui/home.css")),
        "home.js" => ("text/javascript", include_bytes!("ui/home.js")),
        "popover.js" => ("text/javascript", include_bytes!("ui/popover.js")),
        "utils.js" => ("text/javascript", include_bytes!("ui/utils.js")),
        "mono.woff2" => ("font/woff2", include_bytes!("ui/mono.woff2")),
        _ => return Response::empty(404),
    };
    Response::bytes(200, kind, body).cache("no-cache")
}

fn route(app: &App, method: &str, path: &str) -> Response {
    if method != "GET" && method != "HEAD" {
        return Response::empty(405);
    }
    let parts: Vec<&str> = path
        .split('?')
        .next()
        .unwrap_or_default()
        .trim_matches('/')
        .split('/')
        .collect();
    match &parts[..] {
        [""] => Response::bytes(
            200,
            "text/html; charset=utf-8",
            include_str!("ui/home.html"),
        )
        .cache("no-cache"),
        ["home", name] => asset(name),
        ["api", "home"] => app
            .system
            .status()
            .map_or_else(failed, |v| Response::json(&v)),
        ["api", "usage"] => match &app.usage {
            Some(u) => u.report().map_or_else(failed, |v| Response::json(&v)),
            None => Response::json(&Value::Null),
        },
        ["api", "board"] => {
            let (events, weather, air) = std::thread::scope(|s| {
                let events = s.spawn(|| app.hob("calendar"));
                let weather = s.spawn(|| app.hob("weather"));
                let air = s.spawn(|| app.hob("air"));
                (
                    events.join().unwrap_or_default(),
                    weather.join().unwrap_or_default(),
                    air.join().unwrap_or_default(),
                )
            });
            Response::json(&json!({ "events": events["events"], "weather": weather, "air": air }))
        }
        _ => Response::empty(404),
    }
}

fn failed(f: String) -> Response {
    eprintln!("{f}");
    Response::json(&Value::Null)
}

fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("{name} is not set"))
}

fn optional(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

fn main() {
    let app = Arc::new(App {
        hob: env("DASHBOARD_HOB").trim_end_matches('/').to_owned(),
        agent: ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(20)))
            .build()
            .into(),
        system: System::new(
            optional("DASHBOARD_SERVICES").map_or_else(Vec::new, |s| {
                serde_json::from_str(&s).unwrap_or_else(|e| panic!("DASHBOARD_SERVICES: {e}"))
            }),
            optional("DASHBOARD_DISKS")
                .unwrap_or_default()
                .split(',')
                .filter_map(|pair| pair.split_once('='))
                .map(|(label, path)| (label.to_owned(), path.to_owned()))
                .collect(),
        ),
        usage: optional("DASHBOARD_USAGE").map(Usage::new),
    });
    let listen = env("DASHBOARD_LISTEN");
    let server = tiny_http::Server::http(&listen).unwrap_or_else(|e| panic!("{listen}: {e}"));
    for request in server.incoming_requests() {
        let app = app.clone();
        std::thread::spawn(move || {
            let (method, path) = (request.method().to_string(), request.url().to_owned());
            route(&app, &method, &path).send(request);
        });
    }
}
