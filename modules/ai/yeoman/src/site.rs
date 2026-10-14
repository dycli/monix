//! The web door: a chat page for the person beside Matrix, served on
//! loopback (`YEOMAN_SITE`) for a tunnel to put on the web. The page is
//! static files built from `site/` (React on assistant-ui); this serves
//! them and the API under `/api`. Replies reach open pages over SSE;
//! history comes from hippo, so a reload shows Matrix and web as one
//! conversation.
//!
//! Signing in: a page with no session asks for a link, which goes to the
//! person over Matrix, where only they read it. The link is good once,
//! for ten minutes, and leaves a session cookie good for 30 days.

use crate::Read;
use crate::door::{Door, Message};
use crate::hippo::{Hippo, Said};
use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{IntoResponse, Redirect, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::convert::Infallible;
use std::fs;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::{broadcast, mpsc};
use tower_http::services::{ServeDir, ServeFile};

const COOKIE: &str = "session";
const SESSION: Duration = Duration::from_secs(30 * 24 * 3600);
const LINK: Duration = Duration::from_secs(10 * 60);
/// One link a minute at most: anyone who finds the page can ask for one.
const LINK_GAP: Duration = Duration::from_secs(60);
const HISTORY: u64 = 200;
const SEND_MAX: usize = 32 * 1024;

/// What an open page is told, as one SSE event each.
#[derive(Clone, Serialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum Shown {
    /// A message from the yeoman; `plain` is shown word for word.
    Said {
        id: String,
        text: String,
        plain: bool,
    },
    React {
        to: String,
        emoji: String,
    },
    /// A PNG, base64.
    Picture {
        png: String,
    },
    Typing {
        on: bool,
    },
}

/// The open pages, as a door.
#[derive(Clone)]
pub struct Web {
    shown: broadcast::Sender<Shown>,
    ids: Arc<AtomicU64>,
}

impl Web {
    fn id(&self) -> String {
        format!("web-{}", self.ids.fetch_add(1, Ordering::Relaxed))
    }

    fn show(&self, s: Shown) {
        // No page open is no error: hippo has it for the next one.
        let _ = self.shown.send(s);
    }
}

impl Door for Web {
    /// The page sends words only, for now.
    type File = Infallible;

    async fn say(&self, text: &str) -> Result<String, String> {
        let id = self.id();
        self.show(Shown::Said {
            id: id.clone(),
            text: text.into(),
            plain: false,
        });
        Ok(id)
    }

    async fn quote(&self, text: &str) -> Result<String, String> {
        let id = self.id();
        self.show(Shown::Said {
            id: id.clone(),
            text: text.into(),
            plain: true,
        });
        Ok(id)
    }

    async fn react(&self, to: &str, emoji: &str) -> Result<(), String> {
        self.show(Shown::React {
            to: to.into(),
            emoji: emoji.into(),
        });
        Ok(())
    }

    async fn picture(&self, png: Vec<u8>) -> Result<(), String> {
        self.show(Shown::Picture {
            png: STANDARD.encode(png),
        });
        Ok(())
    }

    async fn typing(&self, on: bool) {
        self.show(Shown::Typing { on });
    }

    async fn fetch(&self, file: &Infallible) -> Result<(String, bool, Read), String> {
        match *file {}
    }
}

/// Sends a sign-in link to the person by another door.
pub type Notify =
    Box<dyn Fn(String) -> Pin<Box<dyn Future<Output = Result<(), String>> + Send>> + Send + Sync>;

struct Site {
    web: Web,
    hippo: Arc<Hippo>,
    messages: mpsc::UnboundedSender<(Web, Message<Web>)>,
    notify: Notify,
    /// Where the page is reached, for links: `https://sokka.su.is`.
    url: String,
    sessions: Mutex<Sessions>,
    /// Unused links and when each was made.
    links: Mutex<HashMap<String, Instant>>,
    last_link: Mutex<Option<Instant>>,
}

/// Sessions by token, with when each ends in Unix seconds; kept in a file
/// so a restart signs nobody out.
struct Sessions {
    file: PathBuf,
    live: HashMap<String, u64>,
}

impl Sessions {
    fn load(file: PathBuf) -> Self {
        let now = unix();
        let live = fs::read_to_string(&file)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| {
                let (token, end) = l.split_once(' ')?;
                Some((token.to_owned(), end.parse().ok()?))
            })
            .filter(|(_, end)| *end > now)
            .collect();
        Self { file, live }
    }

    fn valid(&self, token: &str) -> bool {
        self.live.get(token).is_some_and(|end| *end > unix())
    }

    fn start(&mut self) -> Result<String, String> {
        let token = token()?;
        let now = unix();
        self.live.retain(|_, end| *end > now);
        self.live.insert(token.clone(), now + SESSION.as_secs());
        let text: String = self
            .live
            .iter()
            .map(|(t, e)| format!("{t} {e}\n"))
            .collect();
        write_private(&self.file, &text)?;
        Ok(token)
    }
}

fn unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

fn token() -> Result<String, String> {
    let mut b = [0u8; 32];
    getrandom::fill(&mut b).map_err(|e| e.to_string())?;
    Ok(URL_SAFE_NO_PAD.encode(b))
}

/// Writes a file only its owner reads, whole or not at all.
fn write_private(path: &Path, text: &str) -> Result<(), String> {
    use std::os::unix::fs::OpenOptionsExt;
    let tmp = path.with_extension("tmp");
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)
        .map_err(|e| format!("{}: {e}", tmp.display()))?;
    std::io::Write::write_all(&mut f, text.as_bytes()).map_err(|e| e.to_string())?;
    fs::rename(&tmp, path).map_err(|e| format!("{}: {e}", path.display()))
}

fn session(headers: &HeaderMap) -> Option<&str> {
    headers
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(';'))
        .find_map(|c| c.trim().strip_prefix(COOKIE)?.strip_prefix('='))
}

impl Site {
    fn signed(&self, headers: &HeaderMap) -> bool {
        session(headers).is_some_and(|t| self.sessions.lock().unwrap().valid(t))
    }
}

/// Serves the chat page from `root` at `/`, the API, and every other path
/// from `pages` (what show_page wrote) on `addr`, handing what the person
/// sends to `messages` with the door to answer through.
pub async fn serve(
    addr: &str,
    root: PathBuf,
    (pages, url): (PathBuf, String),
    state: &Path,
    hippo: Arc<Hippo>,
    messages: mpsc::UnboundedSender<(Web, Message<Web>)>,
    notify: Notify,
) -> Result<(), String> {
    let dir = state.join("site");
    fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let site = Arc::new(Site {
        web: Web {
            shown: broadcast::channel(64).0,
            ids: Arc::new(AtomicU64::new(0)),
        },
        hippo,
        messages,
        notify,
        url,
        sessions: Mutex::new(Sessions::load(dir.join("sessions"))),
        links: Mutex::new(HashMap::new()),
        last_link: Mutex::new(None),
    });
    let app = Router::new()
        .route_service("/", ServeFile::new(root.join("index.html")))
        .nest_service("/_site", ServeDir::new(root.join("_site")))
        .route("/api/history", get(history))
        .route("/api/events", get(events))
        .route("/api/send", post(send))
        .route("/api/link", post(link))
        .route("/login", get(login))
        .fallback_service(ServeDir::new(pages))
        .with_state(site);
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .map_err(|e| format!("site {addr}: {e}"))?;
    axum::serve(listener, app)
        .await
        .map_err(|e| format!("site: {e}"))
}

/// The last messages, oldest first: the person's, the yeoman's and notes.
async fn history(State(site): State<Arc<Site>>, headers: HeaderMap) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let h = site.hippo.clone();
    match tokio::task::spawn_blocking(move || h.tail(HISTORY)).await {
        Ok(Ok(all)) => Json(
            all.into_iter()
                .filter(|m| matches!(m.kind.as_str(), "user" | "talk" | "note"))
                .collect::<Vec<Said>>(),
        )
        .into_response(),
        Ok(Err(e)) => {
            eprintln!("yeoman: site history: {e}");
            StatusCode::BAD_GATEWAY.into_response()
        }
        Err(e) => {
            eprintln!("yeoman: site history: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

async fn events(State(site): State<Arc<Site>>, headers: HeaderMap) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let rx = site.web.shown.subscribe();
    let stream = futures_util::stream::unfold(rx, |mut rx| async move {
        loop {
            match rx.recv().await {
                Ok(s) => {
                    let e = Event::default().json_data(&s).unwrap_or_default();
                    return Some((Ok::<_, Infallible>(e), rx));
                }
                // A page too slow to keep up skips ahead; a reload fills in.
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => return None,
            }
        }
    });
    Sse::new(stream)
        .keep_alive(KeepAlive::default())
        .into_response()
}

#[derive(Deserialize)]
struct Sent {
    text: String,
}

/// The person's message: answered like one from Matrix, through the pages.
/// Answers the id the yeoman will react to.
async fn send(
    State(site): State<Arc<Site>>,
    headers: HeaderMap,
    Json(sent): Json<Sent>,
) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let text = sent.text.trim();
    if text.is_empty() || text.len() > SEND_MAX {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let id = site.web.id();
    let msg = Message {
        id: id.clone(),
        text: text.to_owned(),
        file: None,
    };
    if site.messages.send((site.web.clone(), msg)).is_err() {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    }
    Json(serde_json::json!({ "id": id })).into_response()
}

/// Sends a sign-in link over Matrix.
async fn link(State(site): State<Arc<Site>>) -> Response {
    {
        let mut last = site.last_link.lock().unwrap();
        if last.is_some_and(|t| t.elapsed() < LINK_GAP) {
            return StatusCode::TOO_MANY_REQUESTS.into_response();
        }
        *last = Some(Instant::now());
    }
    let Ok(t) = token() else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    {
        let mut links = site.links.lock().unwrap();
        links.retain(|_, made| made.elapsed() < LINK);
        links.insert(t.clone(), Instant::now());
    }
    let text = format!(
        "Someone asked to sign in to the web chat. If it was you, open this link within ten minutes; if not, ignore it.\n\n{}/login?t={t}",
        site.url
    );
    match (site.notify)(text).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => {
            eprintln!("yeoman: site link: {e}");
            StatusCode::BAD_GATEWAY.into_response()
        }
    }
}

#[derive(Deserialize)]
struct Login {
    t: String,
}

async fn login(State(site): State<Arc<Site>>, Query(q): Query<Login>) -> Response {
    let made = site.links.lock().unwrap().remove(&q.t);
    if !made.is_some_and(|m| m.elapsed() < LINK) {
        return (
            StatusCode::FORBIDDEN,
            "This link is used or too old. Ask for a new one.",
        )
            .into_response();
    }
    let token = match site.sessions.lock().unwrap().start() {
        Ok(t) => t,
        Err(e) => {
            eprintln!("yeoman: site session: {e}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };
    let cookie = format!(
        "{COOKIE}={token}; Path=/; Max-Age={}; HttpOnly; Secure; SameSite=Lax",
        SESSION.as_secs()
    );
    ([(header::SET_COOKIE, cookie)], Redirect::to("/")).into_response()
}
