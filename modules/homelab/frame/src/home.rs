//! The house's homepage at home.<domain>, served beside the frame's page:
//! a Glance-style board of the services, Water's health, and the frame's
//! calendar, forecast and air. The look and much of the page's code come
//! from Glance (github.com/glanceapp/glance), so this module and `home/`
//! are AGPL-3.0; see `home/LICENSE`.
//!
//! Environment:
//! - `FRAME_SERVICES` (optional): a JSON list of `{"name", "url", "check",
//!   "icon", "about"}`, where `check` is the service's loopback address.
//! - `FRAME_DISKS` (optional): `label=/mountpoint` pairs, comma-separated.

use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{Html, IntoResponse, Json, Response};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::Mutex;

use crate::App;

/// Service checks and stats are reused this long, so many open tabs cost
/// Water no more than one.
const FRESH: Duration = Duration::from_secs(20);
/// A service slower than this counts as down.
const PATIENCE: Duration = Duration::from_secs(4);

#[derive(Clone, Deserialize, Serialize)]
pub struct Service {
    name: String,
    url: String,
    check: String,
    #[serde(default)]
    icon: String,
    #[serde(default)]
    about: String,
}

pub struct Home {
    services: Vec<Service>,
    disks: Vec<(String, String)>,
    agent: ureq::Agent,
    last: Mutex<Option<(Instant, Value)>>,
}

impl Home {
    pub fn from_env() -> Self {
        let services = std::env::var("FRAME_SERVICES").map_or_else(
            |_| Vec::new(),
            |s| serde_json::from_str(&s).unwrap_or_else(|e| panic!("FRAME_SERVICES: {e}")),
        );
        let disks = std::env::var("FRAME_DISKS")
            .unwrap_or_default()
            .split(',')
            .filter_map(|pair| pair.split_once('='))
            .map(|(label, path)| (label.to_owned(), path.to_owned()))
            .collect();
        Self {
            services,
            disks,
            agent: ureq::Agent::config_builder()
                .timeout_global(Some(PATIENCE))
                // Any answer means the service is up; a login redirect is
                // an answer.
                .max_redirects(0)
                .http_status_as_error(false)
                .build()
                .into(),
            last: Mutex::new(None),
        }
    }

    /// One service: up if it answers below 500, and how fast.
    fn check(&self, s: &Service) -> Value {
        let start = Instant::now();
        match self.agent.get(&s.check).call() {
            Ok(r) => json!({
                "up": r.status().as_u16() < 500,
                "code": r.status().as_u16(),
                "ms": start.elapsed().as_millis() as u64,
            }),
            Err(e) => json!({ "up": false, "error": e.to_string() }),
        }
    }
}

/// The page for whichever host asked: home.<domain> gets the homepage,
/// everything else (the frame on its LAN address, frame.<domain>) the
/// frame's page.
pub fn is_home(headers: &HeaderMap) -> bool {
    headers
        .get(header::HOST)
        .and_then(|h| h.to_str().ok())
        .is_some_and(|h| h.starts_with("home."))
}

pub fn page() -> Response {
    (
        [(header::CACHE_CONTROL, "no-cache")],
        Html(include_str!("home/home.html")),
    )
        .into_response()
}

pub async fn asset(axum::extract::Path(name): axum::extract::Path<String>) -> Response {
    let (kind, body): (&str, &'static [u8]) = match name.as_str() {
        "glance.css" => ("text/css", include_bytes!("home/glance.css")),
        "home.css" => ("text/css", include_bytes!("home/home.css")),
        "home.js" => ("text/javascript", include_bytes!("home/home.js")),
        "popover.js" => ("text/javascript", include_bytes!("home/popover.js")),
        "utils.js" => ("text/javascript", include_bytes!("home/utils.js")),
        "mono.woff2" => ("font/woff2", include_bytes!("home/mono.woff2")),
        _ => return StatusCode::NOT_FOUND.into_response(),
    };
    (
        [
            (header::CONTENT_TYPE, kind),
            (header::CACHE_CONTROL, "no-cache"),
        ],
        body,
    )
        .into_response()
}

/// Every service's state and Water's health.
pub async fn status(State(app): State<Arc<App>>) -> Response {
    let mut last = app.home.last.lock().await;
    if let Some((at, v)) = last.as_ref()
        && at.elapsed() < FRESH
    {
        return Json(v.clone()).into_response();
    }
    let checks = app.home.services.iter().map(|s| {
        let a = app.clone();
        let s = s.clone();
        tokio::task::spawn_blocking(move || a.home.check(&s))
    });
    let mut services = Vec::new();
    for (s, check) in app.home.services.iter().zip(checks) {
        let state = check.await.unwrap_or(Value::Null);
        services.push(json!({
            "name": s.name, "url": s.url, "icon": s.icon, "about": s.about, "state": state,
        }));
    }
    let a = app.clone();
    let server = tokio::time::timeout(
        PATIENCE,
        tokio::task::spawn_blocking(move || stats::read(&a.home.disks)),
    )
    .await
    .ok()
    .and_then(Result::ok)
    .map_or(Value::Null, |s| serde_json::to_value(s).unwrap_or_default());
    let v = json!({ "services": services, "server": server });
    *last = Some((Instant::now(), v.clone()));
    ([(header::CACHE_CONTROL, "no-cache")], Json(v)).into_response()
}

/// Water's health, read from /proc and /sys as Glance's server-stats widget
/// shows it.
mod stats {
    use serde::Serialize;

    #[derive(Serialize, Debug, PartialEq)]
    pub struct Stats {
        pub host: String,
        pub uptime: u64,
        pub load1: u32,
        pub load15: u32,
        pub temp: Option<u32>,
        pub mem_used: u64,
        pub mem_total: u64,
        pub swap_used: u64,
        pub swap_total: u64,
        pub disks: Vec<Disk>,
    }

    #[derive(Serialize, Debug, PartialEq)]
    pub struct Disk {
        pub name: String,
        pub used: u64,
        pub total: u64,
    }

    pub fn read(disks: &[(String, String)]) -> Stats {
        let file = |p: &str| std::fs::read_to_string(p).unwrap_or_default();
        let cpus = std::thread::available_parallelism().map_or(1, |n| n.get()) as f64;
        let (load1, load15) = loads(&file("/proc/loadavg"), cpus);
        let mem = memory(&file("/proc/meminfo"));
        Stats {
            host: file("/proc/sys/kernel/hostname").trim().to_owned(),
            uptime: file("/proc/uptime")
                .split_whitespace()
                .next()
                .and_then(|s| s.parse::<f64>().ok())
                .map_or(0, |s| s as u64),
            load1,
            load15,
            temp: temperature(),
            mem_used: mem.0,
            mem_total: mem.1,
            swap_used: mem.2,
            swap_total: mem.3,
            disks: disks
                .iter()
                .filter_map(|(name, path)| {
                    let (used, total) = space(path)?;
                    Some(Disk {
                        name: name.clone(),
                        used,
                        total,
                    })
                })
                .collect(),
        }
    }

    /// Load averages as a share of the cores, in percent, as Glance shows.
    pub fn loads(loadavg: &str, cpus: f64) -> (u32, u32) {
        let f: Vec<f64> = loadavg
            .split_whitespace()
            .take(3)
            .filter_map(|s| s.parse().ok())
            .collect();
        let pct = |l: f64| (l / cpus * 100.0).round().min(100.0) as u32;
        match f[..] {
            [one, _, fifteen] => (pct(one), pct(fifteen)),
            _ => (0, 0),
        }
    }

    /// Used and total memory and swap, in MB.
    pub fn memory(meminfo: &str) -> (u64, u64, u64, u64) {
        let kb = |key: &str| {
            meminfo
                .lines()
                .find_map(|l| l.strip_prefix(key)?.strip_prefix(':'))
                .and_then(|v| v.split_whitespace().next()?.parse::<u64>().ok())
                .unwrap_or(0)
        };
        let total = kb("MemTotal");
        let swap = kb("SwapTotal");
        (
            (total - kb("MemAvailable").min(total)) / 1024,
            total / 1024,
            (swap - kb("SwapFree").min(swap)) / 1024,
            swap / 1024,
        )
    }

    /// The CPU's temperature from AMD's k10temp or Intel's coretemp.
    fn temperature() -> Option<u32> {
        std::fs::read_dir("/sys/class/hwmon")
            .ok()?
            .flatten()
            .find_map(|d| {
                let name = std::fs::read_to_string(d.path().join("name")).ok()?;
                if !matches!(name.trim(), "k10temp" | "coretemp") {
                    return None;
                }
                let milli: u32 = std::fs::read_to_string(d.path().join("temp1_input"))
                    .ok()?
                    .trim()
                    .parse()
                    .ok()?;
                Some(milli / 1000)
            })
    }

    /// Used and total space of a mounted filesystem, in MB.
    fn space(path: &str) -> Option<(u64, u64)> {
        let c = std::ffi::CString::new(path).ok()?;
        let mut s: libc::statvfs = unsafe { std::mem::zeroed() };
        // SAFETY: `c` is a valid C string and `s` is ours to fill.
        if unsafe { libc::statvfs(c.as_ptr(), &mut s) } != 0 {
            return None;
        }
        let block = s.f_frsize as u64;
        let total = s.f_blocks as u64 * block;
        let free = s.f_bavail as u64 * block;
        Some(((total - free) >> 20, total >> 20))
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn load_is_a_share_of_the_cores() {
            assert_eq!(loads("12.00 6.00 3.00 2/1234 99", 48.0), (25, 6));
            assert_eq!(loads("99 99 99", 4.0), (100, 100));
            assert_eq!(loads("", 4.0), (0, 0));
        }

        #[test]
        fn memory_counts_available_as_free() {
            let m = "MemTotal: 2048000 kB\nMemFree: 1 kB\nMemAvailable: 1024000 kB\n\
                     SwapTotal: 1024000 kB\nSwapFree: 512000 kB\n";
            assert_eq!(memory(m), (1000, 2000, 500, 1000));
        }
    }
}
