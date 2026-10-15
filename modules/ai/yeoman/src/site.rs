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
use crate::{Read, fits, read};
use axum::extract::{DefaultBodyLimit, Multipart, State};
use axum::http::{HeaderMap, StatusCode, header};
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
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::{broadcast, mpsc};
use tower_http::services::{ServeDir, ServeFile};

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
/// The largest request to /api/send: the biggest PDF the model takes, the
/// words and the form's framing.
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
    /// A tool call or its result, while the answer is worked out.
    Step {
        step: Step,
    },
}

/// The open pages, as a door.
#[derive(Clone)]
pub struct Web {
    shown: broadcast::Sender<Shown>,
    ids: Arc<AtomicU64>,
    aside: bool,
}

impl Web {
    pub fn new() -> Self {
        Self {
            shown: broadcast::channel(256).0,
            ids: Arc::new(AtomicU64::new(0)),
            aside: false,
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
    pub fn heard(&self, text: &str) {
        self.show(Shown::Heard { text: text.into() });
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
        self.show(Shown::Step { step });
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
    sessions: Mutex<Sessions>,
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
        })
    };
    let body = serde_json::json!({
        "name": name,
        "short_name": name,
        "start_url": "/",
        "scope": "/",
        "display": "standalone",
        "background_color": "#ece3d4",
        "theme_color": "#ece3d4",
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

fn name_of(host: &str) -> String {
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
        sessions: Mutex::new(Sessions::load(dir.join("sessions"))),
    });
    let app = Router::new()
        .route_service("/", ServeFile::new(root.join("index.html")))
        .nest_service("/_site", ServeDir::new(root.join("_site")))
        .route("/manifest.webmanifest", get(manifest))
        .route("/api/history", get(history))
        .route("/api/events", get(events))
        .route(
            "/api/send",
            post(send).layer(DefaultBodyLimit::max(UPLOAD_MAX)),
        )
        .route("/api/pending", get(waiting))
        .route("/api/decide", post(decide))
        .route("/api/ask", post(ask))
        .route("/api/wait", post(wait))
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

/// The person's message, a form with `text` and maybe one `file`: answered
/// like one from Matrix, through the pages. Answers the id the yeoman will
/// react to.
async fn send(State(site): State<Arc<Site>>, headers: HeaderMap, mut form: Multipart) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let mut text = String::new();
    let mut file = None;
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
                    Ok(b) => {
                        file = Some(Upload {
                            name,
                            mime,
                            data: b.to_vec(),
                        })
                    }
                    Err(e) => return (e.status(), e.body_text()).into_response(),
                }
            }
            _ => {}
        }
    }
    let text = text.trim();
    if (text.is_empty() && file.is_none()) || text.len() > SEND_MAX {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let id = site.web.id();
    let msg = Message {
        id: id.clone(),
        text: text.to_owned(),
        file,
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

    #[test]
    fn name_from_host() {
        assert_eq!(name_of("sokka.su.is"), "Sokka");
        assert_eq!(name_of("127.0.0.1:8951"), "Chat");
        assert_eq!(name_of(""), "Chat");
    }

    use super::*;

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
}
