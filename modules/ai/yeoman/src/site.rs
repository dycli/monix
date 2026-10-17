//! The web door: a chat page for the person beside Matrix, served on
//! loopback (`YEOMAN_SITE`) for a tunnel to put on the web. The page is
//! static files built from `site/` (React on assistant-ui); this serves
//! them and the API under `/api`. Replies reach open pages over SSE;
//! history comes from hippo, so a reload shows Matrix and web as one
//! conversation.
//!
//! Signing in works like a TV pairing with a phone: a page with no
//! session asks to be let in and shows a short code; the yeoman posts the
//! same code to the person over Matrix, and their 👍 there signs in the
//! browser that asked, with a cookie good for 30 days. Nothing travels
//! between devices, and a session only ever goes to the page that asked.

use crate::door::{Door, Message};
use crate::hippo::{Hippo, Said};
use crate::model::{Attachment, Step};
use crate::pending::{self, Pending};
use crate::task;
use crate::{Read, fits, read};
use axum::extract::{DefaultBodyLimit, Multipart, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{IntoResponse, Response};
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
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::{broadcast, mpsc};
use tower_http::services::{ServeDir, ServeFile};
use tower_http::set_header::SetResponseHeaderLayer;
use tower_layer::Layer;

use crate::push::{self, Push};

const COOKIE: &str = "session";
const SESSION: Duration = Duration::from_secs(30 * 24 * 3600);
/// How long a request to sign in waits for its answer.
const ASK: Duration = Duration::from_secs(5 * 60);
/// One request a minute at most: anyone who finds the page can ask.
const ASK_GAP: Duration = Duration::from_secs(60);
/// Letters for the code, without look-alikes (0 O 1 I L).
const CODE: &[u8] = b"23456789ABCDEFGHJKMNPQRSTUVWXYZ";
const HISTORY: u64 = 200;
const SEND_MAX: usize = 32 * 1024;
/// The most files one message carries.
const FILES_MAX: usize = 10;
/// The largest request to /api/send: the biggest PDF the model takes, the
/// words and the form's framing. It bounds all the files together, which
/// keeps the model's request under its limit too.
const UPLOAD_MAX: usize = crate::PDF_MAX + SEND_MAX + 64 * 1024;

/// What an open page is told, as one SSE event each.
#[derive(Clone, Serialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum Shown {
    /// A message from the yeoman; `plain` is shown word for word. One
    /// `aside` came from no turn (a reminder, an alert's answer), so it
    /// stands apart from any answer being worked out.
    Said {
        id: String,
        text: String,
        plain: bool,
        aside: bool,
    },
    /// What the person wrote by another door, as it comes in.
    Heard {
        /// The other door's id, so a reaction to it lands here too.
        id: String,
        text: String,
    },
    /// An act waiting for the person's word.
    Pending {
        pending: Pending,
    },
    /// The verdict on act `id` is carried out; when not `done` the act
    /// failed and still waits.
    Settled {
        id: u64,
        text: String,
        done: bool,
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
    /// A tool call or its result, while the answer is worked out; `task`
    /// when it is the task's work, not the turn's.
    Step {
        step: Step,
        task: bool,
    },
    /// The task under way and the question it waits on; none when it ended.
    Task {
        text: Option<String>,
        question: Option<String>,
    },
}

/// The open pages, as a door.
#[derive(Clone)]
pub struct Web {
    shown: broadcast::Sender<Shown>,
    ids: Arc<AtomicU64>,
    aside: bool,
    /// The task as last shown, so a tick that changes nothing is silent.
    task: Arc<Mutex<(Option<String>, Option<String>)>>,
}

impl Web {
    pub fn new() -> Self {
        Self {
            shown: broadcast::channel(256).0,
            ids: Arc::new(AtomicU64::new(0)),
            aside: false,
            task: Arc::default(),
        }
    }

    /// The same pages, for what comes from no turn.
    pub fn aside(&self) -> Self {
        Self {
            aside: true,
            ..self.clone()
        }
    }

    /// Shows what the person wrote by another door.
    pub fn heard(&self, id: &str, text: &str) {
        self.show(Shown::Heard {
            id: id.into(),
            text: text.into(),
        });
    }

    fn id(&self) -> String {
        format!("web-{}", self.ids.fetch_add(1, Ordering::Relaxed))
    }

    fn show(&self, s: Shown) {
        // No page open is no error: hippo has it for the next one.
        let _ = self.shown.send(s);
    }
}

impl Door for Web {
    type File = Upload;
    const CARDS: bool = true;

    async fn say(&self, text: &str) -> Result<String, String> {
        let id = self.id();
        self.show(Shown::Said {
            id: id.clone(),
            text: text.into(),
            plain: false,
            aside: self.aside,
        });
        Ok(id)
    }

    async fn quote(&self, text: &str) -> Result<String, String> {
        let id = self.id();
        self.show(Shown::Said {
            id: id.clone(),
            text: text.into(),
            plain: true,
            aside: self.aside,
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

    fn step(&self, step: Step) {
        self.show(Shown::Step { step, task: false });
    }

    fn task_step(&self, step: Step) {
        self.show(Shown::Step { step, task: true });
    }

    fn task(&self, text: Option<String>, question: Option<String>) {
        let now = (text, question);
        let mut last = self.task.lock().unwrap();
        if *last != now {
            *last = now.clone();
            let (text, question) = now;
            self.show(Shown::Task { text, question });
        }
    }

    async fn typing(&self, on: bool) {
        self.show(Shown::Typing { on });
    }

    /// A card with the draft and buttons, not a message: it answers to
    /// the act's own id.
    async fn ask(&self, p: &Pending) -> Result<String, String> {
        self.show(Shown::Pending { pending: p.clone() });
        Ok(format!("act-{}", p.id))
    }

    async fn settle(&self, p: &Pending, outcome: &str, done: bool) -> Result<(), String> {
        self.show(Shown::Settled {
            id: p.id,
            text: outcome.into(),
            done,
        });
        Ok(())
    }

    /// Already here: the page sent the bytes with the message. Photos
    /// arrive shrunk by the page, so one too big is refused rather than
    /// cut down.
    async fn fetch(&self, file: &Upload) -> Result<(String, bool, Read), String> {
        let r = read(file.data.clone(), file.mime.as_deref()).ok_or_else(|| {
            format!(
                "I can't read {}: only photos, PDFs and text files.",
                file.name
            )
        })?;
        if !fits(&r) {
            return Err(format!("{} is too big for me to read.", file.name));
        }
        let photo = matches!(r, Read::Model(Attachment::Image { .. }));
        Ok((file.name.clone(), photo, r))
    }
}

/// Another door whose talk the open pages see too, so the web is one
/// conversation with Matrix as it happens, not only after a reload.
/// Reactions answer the other door's messages and stay there.
#[derive(Clone)]
pub struct Mirror<D: Door> {
    pub door: D,
    pub web: Option<Web>,
}

impl<D: Door> Door for Mirror<D> {
    type File = D::File;

    async fn say(&self, text: &str) -> Result<String, String> {
        let id = self.door.say(text).await?;
        if let Some(w) = &self.web {
            w.say(text).await?;
        }
        Ok(id)
    }

    async fn quote(&self, text: &str) -> Result<String, String> {
        let id = self.door.quote(text).await?;
        if let Some(w) = &self.web {
            w.quote(text).await?;
        }
        Ok(id)
    }

    async fn react(&self, to: &str, emoji: &str) -> Result<(), String> {
        if let Some(w) = &self.web {
            w.react(to, emoji).await?;
        }
        self.door.react(to, emoji).await
    }

    async fn picture(&self, png: Vec<u8>) -> Result<(), String> {
        if let Some(w) = &self.web {
            w.picture(png.clone()).await?;
        }
        self.door.picture(png).await
    }

    async fn typing(&self, on: bool) {
        if let Some(w) = &self.web {
            w.typing(on).await;
        }
        self.door.typing(on).await;
    }

    fn step(&self, step: Step) {
        if let Some(w) = &self.web {
            w.step(step.clone());
        }
        self.door.step(step);
    }

    fn task_step(&self, step: Step) {
        if let Some(w) = &self.web {
            w.task_step(step.clone());
        }
        self.door.task_step(step);
    }

    fn task(&self, text: Option<String>, question: Option<String>) {
        if let Some(w) = &self.web {
            w.task(text.clone(), question.clone());
        }
        self.door.task(text, question);
    }

    async fn ask(&self, p: &Pending) -> Result<String, String> {
        let id = self.door.ask(p).await?;
        if let Some(w) = &self.web {
            w.ask(p).await?;
        }
        Ok(id)
    }

    async fn settle(&self, p: &Pending, outcome: &str, done: bool) -> Result<(), String> {
        if let Some(w) = &self.web {
            w.settle(p, outcome, done).await?;
        }
        self.door.settle(p, outcome, done).await
    }

    fn fetch(
        &self,
        file: &Self::File,
    ) -> impl Future<Output = Result<(String, bool, Read), String>> + Send {
        self.door.fetch(file)
    }
}

/// A file sent from the page with a message.
pub struct Upload {
    name: String,
    mime: Option<String>,
    data: Vec<u8>,
}

/// Asks the person by another door, answering the id of the message a
/// reaction will answer.
pub type Notify = Box<
    dyn Fn(String) -> Pin<Box<dyn Future<Output = Result<String, String>> + Send>> + Send + Sync,
>;

/// Pages waiting to be let in, by the secret each holds.
#[derive(Default)]
pub struct Gate {
    asks: Mutex<HashMap<String, Ask>>,
    last: Mutex<Option<Instant>>,
}

struct Ask {
    made: Instant,
    /// The message that asked the person, once posted.
    event: Option<String>,
    answer: Option<bool>,
}

impl Gate {
    /// Takes the person's 👍 or 👎 on `event`; false if it asked nothing.
    pub fn answer(&self, event: &str, yes: bool) -> bool {
        let mut asks = self.asks.lock().unwrap();
        let Some(ask) = asks
            .values_mut()
            .find(|a| a.event.as_deref() == Some(event) && a.made.elapsed() < ASK)
        else {
            return false;
        };
        // The first answer stands.
        ask.answer.get_or_insert(yes);
        true
    }
}

struct Site {
    web: Web,
    hippo: Arc<Hippo>,
    state: PathBuf,
    messages: mpsc::UnboundedSender<(Web, Message<Web>)>,
    /// Verdicts given on the page, by act id.
    verdicts: mpsc::UnboundedSender<(u64, bool)>,
    notify: Notify,
    gate: Arc<Gate>,
    stop: Arc<AtomicBool>,
    sessions: Mutex<Sessions>,
    /// None when the site's address is unknown or the key would not load.
    push: Option<Arc<Push>>,
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

/// Four letters to match by eye, not a secret: it tells the person which
/// page they let in.
fn code() -> Result<String, String> {
    let mut b = [0u8; 4];
    getrandom::fill(&mut b).map_err(|e| e.to_string())?;
    Ok(b.iter()
        .map(|x| CODE[*x as usize % CODE.len()] as char)
        .collect())
}

/// Writes a file only its owner reads, whole or not at all.
pub(crate) fn write_private(path: &Path, text: &str) -> Result<(), String> {
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

/// What makes the page installable as an app. Its name is the
/// assistant's, taken from the host as the page takes it: sokka.su.is is
/// Sokka.
async fn manifest(headers: HeaderMap) -> Response {
    let host = headers
        .get(header::HOST)
        .and_then(|h| h.to_str().ok())
        .unwrap_or_default();
    let name = name_of(host);
    let icon = |size: u32| {
        serde_json::json!({
            "src": format!("/_site/icon-{size}.png"),
            "sizes": format!("{size}x{size}"),
            "type": "image/png",
            // Full bleed with the mark in the safe circle: launchers may
            // crop it to their shape rather than plating it.
            "purpose": "any maskable",
        })
    };
    let body = serde_json::json!({
        "name": name,
        "short_name": name,
        "start_url": "/",
        "scope": "/",
        "display": "standalone",
        "id": "/",
        // Chrome paints the installed app's splash and Android navigation
        // bar from these at install and never again: the bar ignores the
        // page's live theme-color (the status bar follows it) and the
        // manifest's dark variants. So the bar is light paper, the default
        // theme, in either theme. Revisit when Chrome draws installed apps
        // edge to edge (crbug 506197579) or recolours the bar live.
        "background_color": "#e4d6bf",
        "theme_color": "#e4d6bf",
        "icons": [
            icon(192),
            icon(512),
            {"src": "/_site/icon.svg", "sizes": "any", "type": "image/svg+xml"},
        ],
    });
    (
        [(header::CONTENT_TYPE, "application/manifest+json")],
        body.to_string(),
    )
        .into_response()
}

pub(crate) fn name_of(host: &str) -> String {
    let label = host.split('.').next().unwrap_or_default();
    let mut chars = label.chars();
    match chars.next() {
        Some(first) if label.chars().all(|c| c.is_ascii_lowercase()) => {
            first.to_ascii_uppercase().to_string() + chars.as_str()
        }
        _ => "Chat".into(),
    }
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

/// The channels the page reaches the core by: what the person sends,
/// with the door to answer through, and their verdicts on acts.
pub struct Inbox {
    pub messages: mpsc::UnboundedSender<(Web, Message<Web>)>,
    pub verdicts: mpsc::UnboundedSender<(u64, bool)>,
    /// Set to stop the turn under way.
    pub stop: Arc<AtomicBool>,
}

/// Serves the chat page from `root` at `/`, the API, and every other path
/// from `pages` (what show_page wrote) on `addr`, through the pages `web`.
/// Requests to sign in go out through `notify`; their answers come back
/// through `gate`.
#[allow(clippy::too_many_arguments)]
pub async fn serve(
    addr: &str,
    root: PathBuf,
    pages: PathBuf,
    state: &Path,
    hippo: Arc<Hippo>,
    web: Web,
    inbox: Inbox,
    (notify, gate): (Notify, Arc<Gate>),
) -> Result<(), String> {
    let dir = state.join("site");
    fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let site = Arc::new(Site {
        web,
        hippo,
        state: state.to_owned(),
        messages: inbox.messages,
        verdicts: inbox.verdicts,
        notify,
        gate,
        stop: inbox.stop,
        sessions: Mutex::new(Sessions::load(dir.join("sessions"))),
        push: push_from_env(&dir).map(Arc::new),
    });
    if let Some(push) = &site.push {
        tokio::spawn(ring(site.web.shown.subscribe(), push.clone()));
    }
    // The entry document and the worker carry no hash in their names, so the
    // browser must revalidate them each load; otherwise a deploy's new asset
    // hashes never get picked up. The hashed assets under /_site are safe to
    // keep forever, but only once found: a miss mid-deploy must not stick.
    let revalidate = SetResponseHeaderLayer::overriding(
        header::CACHE_CONTROL,
        HeaderValue::from_static("no-cache"),
    );
    let forever = SetResponseHeaderLayer::overriding(header::CACHE_CONTROL, |r: &Response<_>| {
        r.status()
            .is_success()
            .then(|| HeaderValue::from_static("public, max-age=31536000, immutable"))
    });
    let app = Router::new()
        .route_service(
            "/",
            revalidate.layer(ServeFile::new(root.join("index.html"))),
        )
        // At the root, so its scope is the whole site.
        .route_service(
            "/sw.js",
            revalidate.layer(ServeFile::new(root.join("sw.js"))),
        )
        .nest_service("/_site", forever.layer(ServeDir::new(root.join("_site"))))
        .route("/manifest.webmanifest", get(manifest))
        .route("/api/history", get(history))
        .route("/api/search", get(search))
        .route("/api/said/{i}", get(said))
        .route("/api/events", get(events))
        .route(
            "/api/send",
            post(send).layer(DefaultBodyLimit::max(UPLOAD_MAX)),
        )
        .route("/api/pending", get(waiting))
        .route("/api/decide", post(decide))
        .route("/api/stop", post(stop))
        .route("/api/task", get(task_now))
        .route("/api/task/stop", post(task_stop))
        .route("/api/ask", post(ask))
        .route("/api/wait", post(wait))
        .route("/api/push", get(push_key).post(push_add))
        .route("/api/push/drop", post(push_drop))
        .fallback_service(ServeDir::new(pages))
        .with_state(site);
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .map_err(|e| format!("site {addr}: {e}"))?;
    axum::serve(listener, app)
        .await
        .map_err(|e| format!("site: {e}"))
}

fn push_from_env(dir: &Path) -> Option<Push> {
    let url = std::env::var("YEOMAN_SITE_URL").ok()?;
    Push::load(dir, &url)
        .inspect_err(|e| eprintln!("yeoman: push: {e}"))
        .ok()
}

/// Rings every device for what the yeoman says and what waits on the
/// person's word; the rest (steps, typing, reactions) only matters on an
/// open page.
async fn ring(mut rx: broadcast::Receiver<Shown>, push: Arc<Push>) {
    loop {
        let (body, tag) = match rx.recv().await {
            Ok(Shown::Said { text, .. }) => (push::gist(&text), "said"),
            Ok(Shown::Pending { pending }) => (push::gist(&pending.act.show()), "pending"),
            Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => continue,
            Err(broadcast::error::RecvError::Closed) => return,
        };
        let push = push.clone();
        tokio::task::spawn_blocking(move || {
            push.send(&push::Note {
                title: &push.title,
                body,
                tag,
            })
        });
    }
}

/// The key a device subscribes with; 404 when push is off.
async fn push_key(State(site): State<Arc<Site>>) -> Response {
    match &site.push {
        Some(p) => p.public().into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

/// A device's subscription, as the browser's `PushSubscription.toJSON()`.
async fn push_add(
    State(site): State<Arc<Site>>,
    headers: HeaderMap,
    Json(sub): Json<serde_json::Value>,
) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let Some(push) = site.push.clone() else {
        return StatusCode::NOT_FOUND.into_response();
    };
    match tokio::task::spawn_blocking(move || push.subscribe(sub)).await {
        Ok(Ok(())) => StatusCode::NO_CONTENT.into_response(),
        Ok(Err(e)) => (StatusCode::BAD_REQUEST, e).into_response(),
        Err(e) => {
            eprintln!("yeoman: push: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

#[derive(Deserialize)]
struct Endpoint {
    endpoint: String,
}

async fn push_drop(
    State(site): State<Arc<Site>>,
    headers: HeaderMap,
    Json(e): Json<Endpoint>,
) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let Some(push) = site.push.clone() else {
        return StatusCode::NOT_FOUND.into_response();
    };
    match tokio::task::spawn_blocking(move || push.unsubscribe(&e.endpoint)).await {
        Ok(Ok(())) => StatusCode::NO_CONTENT.into_response(),
        Ok(Err(e)) => {
            eprintln!("yeoman: push: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
        Err(e) => {
            eprintln!("yeoman: push: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

/// The last messages, oldest first: the person's, the yeoman's and notes.
async fn history(State(site): State<Arc<Site>>, headers: HeaderMap) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let h = site.hippo.clone();
    match tokio::task::spawn_blocking(move || h.tail(HISTORY)).await {
        Ok(Ok(all)) => Json(lines(all)).into_response(),
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

#[derive(Deserialize)]
struct Query {
    q: String,
}

/// A message hippo found, cut to the words around the match.
#[derive(Debug, PartialEq, Serialize)]
struct Hit {
    i: u64,
    kind: String,
    date: String,
    text: String,
}

/// The messages matching `q`, a case-insensitive regex, newest last; hippo
/// gives the newest few and says when there were more.
async fn search(
    State(site): State<Arc<Site>>,
    headers: HeaderMap,
    axum::extract::Query(Query { q }): axum::extract::Query<Query>,
) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if q.trim().is_empty() || q.len() > 200 {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let h = site.hippo.clone();
    match tokio::task::spawn_blocking(move || h.search(&q)).await {
        Ok(Ok(out)) => {
            let more = out.starts_with(|c: char| c.is_ascii_digit()) && out.contains(" matches; ");
            Json(serde_json::json!({ "hits": hits(&out), "more": more })).into_response()
        }
        // A regex that doesn't compile is the asker's.
        Ok(Err(e)) => (StatusCode::BAD_REQUEST, e).into_response(),
        Err(e) => {
            eprintln!("yeoman: site search: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

/// hippo's search lines, `{i} {kind}[ [chat]] {YYYY-MM-DD HH:MM}: {excerpt}`.
fn hits(out: &str) -> Vec<Hit> {
    out.lines()
        .filter_map(|l| {
            let (i, rest) = l.split_once(' ')?;
            let (head, text) = rest.split_once(": ")?;
            let date = head.get(head.len().checked_sub(16)?..)?;
            Some(Hit {
                i: i.parse().ok()?,
                kind: head.split(' ').next()?.to_owned(),
                date: date.to_owned(),
                text: text.to_owned(),
            })
        })
        .collect()
}

/// One message whole, to open a search hit.
async fn said(
    State(site): State<Arc<Site>>,
    headers: HeaderMap,
    axum::extract::Path(i): axum::extract::Path<u64>,
) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let h = site.hippo.clone();
    match tokio::task::spawn_blocking(move || h.zoom(i, 1)).await {
        // `{i}+1|{kind}[ [chat]]: {text}`
        Ok(Ok(out)) => match out.split_once('|').and_then(|(_, m)| m.split_once(": ")) {
            Some((_, text)) => text.to_owned().into_response(),
            None => StatusCode::BAD_GATEWAY.into_response(),
        },
        Ok(Err(_)) => StatusCode::NOT_FOUND.into_response(),
        Err(e) => {
            eprintln!("yeoman: site said: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

/// A message of the history, with the emoji the yeoman answered it by.
#[derive(Serialize)]
struct Line {
    #[serde(flatten)]
    said: Said,
    reaction: Option<String>,
}

/// The conversation for the page. hippo keeps a lone-emoji answer as a
/// message, but it went out as a reaction, so it goes back on the person's
/// message it answered.
fn lines(all: Vec<Said>) -> Vec<Line> {
    let mut out: Vec<Line> = Vec::new();
    for said in all {
        match said.kind.as_str() {
            "talk" if crate::is_reaction(&said.text) => {
                if let Some(last) = out
                    .last_mut()
                    .filter(|l| l.said.kind == "user" && l.reaction.is_none())
                {
                    last.reaction = Some(said.text);
                    continue;
                }
            }
            "user" | "talk" | "note" => {}
            _ => continue,
        }
        out.push(Line {
            said,
            reaction: None,
        });
    }
    out
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

/// The person's message, a form with `text` and maybe one `file`: answered
/// like one from Matrix, through the pages. Answers the id the yeoman will
/// react to.
async fn send(State(site): State<Arc<Site>>, headers: HeaderMap, mut form: Multipart) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let mut text = String::new();
    let mut files = Vec::new();
    loop {
        let field = match form.next_field().await {
            Ok(Some(f)) => f,
            Ok(None) => break,
            Err(e) => return (e.status(), e.body_text()).into_response(),
        };
        match field.name() {
            Some("text") => match field.text().await {
                Ok(t) => text = t,
                Err(e) => return (e.status(), e.body_text()).into_response(),
            },
            Some("file") => {
                let name = field.file_name().unwrap_or("file").to_owned();
                let mime = field.content_type().map(str::to_owned);
                match field.bytes().await {
                    Ok(b) => files.push(Upload {
                        name,
                        mime,
                        data: b.to_vec(),
                    }),
                    Err(e) => return (e.status(), e.body_text()).into_response(),
                }
            }
            _ => {}
        }
    }
    let text = text.trim();
    if (text.is_empty() && files.is_empty()) || text.len() > SEND_MAX || files.len() > FILES_MAX {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let id = site.web.id();
    let msg = Message {
        id: id.clone(),
        text: text.to_owned(),
        files,
    };
    if site.messages.send((site.web.clone(), msg)).is_err() {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    }
    Json(serde_json::json!({ "id": id })).into_response()
}

/// The acts waiting for the person's word, oldest first.
async fn waiting(State(site): State<Arc<Site>>, headers: HeaderMap) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    match pending::all(&site.state) {
        Ok(all) => Json(all).into_response(),
        Err(e) => {
            eprintln!("yeoman: site pending: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

#[derive(Deserialize)]
struct Verdict {
    id: u64,
    yes: bool,
}

/// The person's verdict on an act, as a 👍 or 👎 in Matrix would give
/// it: 202 while it is carried out (the page hears how over SSE), 404 when
/// the act is gone, decided already.
async fn decide(
    State(site): State<Arc<Site>>,
    headers: HeaderMap,
    Json(v): Json<Verdict>,
) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let known = pending::all(&site.state).is_ok_and(|all| all.iter().any(|p| p.id == v.id));
    if !known {
        return StatusCode::NOT_FOUND.into_response();
    }
    if site.verdicts.send((v.id, v.yes)).is_err() {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    }
    StatusCode::ACCEPTED.into_response()
}

/// Stops the turn under way, from the page or Matrix; it answers
/// "(Stopped.)". With no turn running it does nothing.
async fn stop(State(site): State<Arc<Site>>, headers: HeaderMap) -> StatusCode {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED;
    }
    site.stop.store(true, Ordering::Relaxed);
    StatusCode::ACCEPTED
}

/// The task under way, the question it waits on, and the computer's
/// screen to watch it by, when the yeoman has one.
async fn task_now(State(site): State<Arc<Site>>, headers: HeaderMap) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    Json(serde_json::json!({
        "text": task::running(&site.state),
        "question": task::question(&site.state),
        "screen": std::env::var("YEOMAN_SCREEN").ok(),
    }))
    .into_response()
}

/// Stops the task on the next tick, as cancel_task does.
async fn task_stop(State(site): State<Arc<Site>>, headers: HeaderMap) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    match task::cancel(&site.state) {
        Ok(()) => StatusCode::ACCEPTED.into_response(),
        Err(e) => (StatusCode::CONFLICT, e).into_response(),
    }
}

/// A page asks to be let in: the person gets its code over Matrix, the
/// page gets the code to show and a secret to wait with.
async fn ask(State(site): State<Arc<Site>>) -> Response {
    {
        let mut last = site.gate.last.lock().unwrap();
        if last.is_some_and(|t| t.elapsed() < ASK_GAP) {
            return StatusCode::TOO_MANY_REQUESTS.into_response();
        }
        *last = Some(Instant::now());
    }
    let (Ok(secret), Ok(code)) = (token(), code()) else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    {
        let mut asks = site.gate.asks.lock().unwrap();
        asks.retain(|_, a| a.made.elapsed() < ASK);
        asks.insert(
            secret.clone(),
            Ask {
                made: Instant::now(),
                event: None,
                answer: None,
            },
        );
    }
    let text = format!(
        "A browser asks to sign in to the web chat, showing **{code}**. React 👍 to let it in if that is you; 👎 or nothing keeps it out."
    );
    match (site.notify)(text).await {
        Ok(event) => {
            if let Some(a) = site.gate.asks.lock().unwrap().get_mut(&secret) {
                a.event = Some(event);
            }
            Json(serde_json::json!({ "secret": secret, "code": code })).into_response()
        }
        Err(e) => {
            eprintln!("yeoman: site ask: {e}");
            site.gate.asks.lock().unwrap().remove(&secret);
            StatusCode::BAD_GATEWAY.into_response()
        }
    }
}

#[derive(Deserialize)]
struct Waiting {
    secret: String,
}

/// The page that asked checks for its answer: 202 while none, the session
/// cookie once let in, 403 when refused or too old.
async fn wait(State(site): State<Arc<Site>>, Json(w): Json<Waiting>) -> Response {
    let answer = {
        let mut asks = site.gate.asks.lock().unwrap();
        match asks.get(&w.secret) {
            Some(a) if a.made.elapsed() < ASK && a.answer.is_none() => {
                return StatusCode::ACCEPTED.into_response();
            }
            Some(a) if a.made.elapsed() < ASK => a.answer,
            _ => None,
        }
        .inspect(|_| {
            asks.remove(&w.secret);
        })
    };
    if answer != Some(true) {
        return StatusCode::FORBIDDEN.into_response();
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
    ([(header::SET_COOKIE, cookie)], StatusCode::NO_CONTENT).into_response()
}

#[cfg(test)]
mod tests {

    fn said(i: u64, kind: &str, text: &str) -> Said {
        Said {
            i,
            kind: kind.into(),
            text: text.into(),
            date: String::new(),
        }
    }

    #[test]
    fn lone_emoji_answers_become_reactions() {
        let out = lines(vec![
            said(1, "user", "nevermind"),
            said(2, "talk", "👍"),
            said(3, "tool", "x"),
            said(4, "talk", "👍"),
            said(5, "talk", "Done 👍"),
        ]);
        let got: Vec<_> = out
            .iter()
            .map(|l| (l.said.i, l.reaction.as_deref()))
            .collect();
        // The second 👍 has no unanswered message of the person's, so it stays.
        assert_eq!(got, [(1, Some("👍")), (4, None), (5, None)]);
    }

    #[test]
    fn name_from_host() {
        assert_eq!(name_of("sokka.su.is"), "Sokka");
        assert_eq!(name_of("127.0.0.1:8951"), "Chat");
        assert_eq!(name_of(""), "Chat");
    }

    use super::*;

    #[test]
    fn a_task_is_shown_only_when_it_changes() {
        let web = Web::new();
        let mut seen = web.shown.subscribe();
        web.task(Some("book Cure".into()), None);
        web.aside().task(Some("book Cure".into()), None);
        web.task(Some("book Cure".into()), Some("6:15 or 7:30?".into()));
        web.task(None, None);
        let mut shown = Vec::new();
        while let Ok(Shown::Task { text, question }) = seen.try_recv() {
            shown.push((text, question));
        }
        assert_eq!(shown.len(), 3);
        assert_eq!(shown[1].1.as_deref(), Some("6:15 or 7:30?"));
        assert_eq!(shown[2], (None, None));
    }

    fn asked(gate: &Gate, secret: &str, event: &str) {
        gate.asks.lock().unwrap().insert(
            secret.into(),
            Ask {
                made: Instant::now(),
                event: Some(event.into()),
                answer: None,
            },
        );
    }

    #[test]
    fn a_reaction_answers_only_its_own_request_and_the_first_stands() {
        let gate = Gate::default();
        asked(&gate, "a", "$1");
        asked(&gate, "b", "$2");
        assert!(!gate.answer("$9", true));
        assert!(gate.answer("$1", true));
        assert!(gate.answer("$1", false));
        let asks = gate.asks.lock().unwrap();
        assert_eq!(asks["a"].answer, Some(true));
        assert_eq!(asks["b"].answer, None);
    }

    #[test]
    fn codes_are_four_plain_letters() {
        let c = code().unwrap();
        assert_eq!(c.len(), 4);
        assert!(c.bytes().all(|b| CODE.contains(&b)));
    }

    #[test]
    fn search_lines() {
        let out = "120 matches; the newest 2 follow. Narrow the regex for older ones.\n\
                   12 user 2026-10-15 09:01: …the dentist on Friday…\n\
                   40 talk [web] 2026-10-16 10:22: Booked: 10: 30 Friday";
        assert_eq!(
            hits(out),
            vec![
                Hit {
                    i: 12,
                    kind: "user".into(),
                    date: "2026-10-15 09:01".into(),
                    text: "…the dentist on Friday…".into(),
                },
                Hit {
                    i: 40,
                    kind: "talk".into(),
                    date: "2026-10-16 10:22".into(),
                    text: "Booked: 10: 30 Friday".into(),
                },
            ]
        );
    }
}
