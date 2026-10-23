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

use crate::door::{Door, Fetched, Message};
use crate::files::{Library, mime_of};
use crate::hippo::{Hippo, Said};
use crate::model::{Ask as SeatAsk, Asker, Attachment, Step};
use crate::pending::{self, Pending};
use crate::{Read, seen};
use crate::{keep, task};
use axum::extract::{DefaultBodyLimit, Multipart, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde::{Deserialize, Serialize};
use serde_json::Value;
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
use tower_http::set_header::{SetResponseHeader, SetResponseHeaderLayer};
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
/// Messages of history the page loads: a seat's tool calls and results
/// count, so enough for a few dozen turns.
const HISTORY: u64 = 400;
/// The most of a tool call or result the history carries, in bytes; the
/// rest opens from hippo.
const HISTORY_STEP: usize = 4 * 1024;
/// How long a reply read aloud stays cached.
const SPEECH_KEEP: Duration = Duration::from_secs(30 * 24 * 3600);
const SEND_MAX: usize = 32 * 1024;
/// Readings under way at once.
const SPEAKING_MAX: usize = 4;
/// The most files one message carries.
const FILES_MAX: usize = 10;
/// The largest request to /api/send, all its files together: what the
/// Cloudflare tunnel passes. Files stay whole to be kept and converted;
/// the model sees only what fits its request (`answer`).
const UPLOAD_MAX: usize = 100_000_000;

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
    /// What the person wrote, as it comes in: by another door, or by a
    /// page, which every other page open shows too.
    Heard {
        /// The other door's id, so a reaction to it lands here too.
        id: String,
        text: String,
        /// The sending page's own id for it, so that page knows it.
        #[serde(skip_serializing_if = "Option::is_none")]
        from: Option<String>,
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
    /// A picture kept as `name`, fetched from `/api/file/{name}`.
    Picture {
        name: String,
    },
    /// A kept file sent back, fetched from `/api/file/{name}`.
    File {
        name: String,
    },
    Typing {
        on: bool,
    },
    /// A tool call or its result, while the answer is worked out; `agent`
    /// names the subagent whose work it is, when it isn't the turn's.
    Step {
        step: Step,
        agent: Option<String>,
    },
    /// The subagents at work, by name, with their tasks.
    Agents {
        agents: Vec<Agent>,
    },
    /// The computer's browser opened or closed.
    Browser {
        open: bool,
    },
    /// The seat asks the person: may a tool run, or its questions.
    Ask {
        ask: SeatAsk,
    },
    /// Ask `id` is answered or taken back.
    Asked {
        id: String,
    },
    /// The oldest messages were forgotten: the history is read again.
    Forgot,
}

/// A subagent at work, as a page shows it. One the seat's Agent call
/// started goes by the call's id, `title` its description; the page can't
/// stop it, as nothing outside the CLI can.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Agent {
    name: String,
    task: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<String>,
}

impl Agent {
    fn own((name, task): (String, String)) -> Self {
        Self {
            name,
            task,
            title: None,
        }
    }
}

/// Where the person's answer to an ask goes: the input to run with, or
/// None to refuse.
type Waiter = std::sync::mpsc::Sender<Option<Value>>;

/// The open pages, as a door.
#[derive(Clone)]
pub struct Web {
    shown: broadcast::Sender<Shown>,
    ids: Arc<AtomicU64>,
    aside: bool,
    /// The agents as last shown, so a tick that changes nothing is silent.
    agents: Arc<Mutex<Vec<Agent>>>,
    /// The yeoman's own agents as the tick last gave them, and the seat's
    /// subagents at work, both shown as one list.
    own: Arc<Mutex<Vec<Agent>>>,
    seated: Arc<Mutex<Vec<Agent>>>,
    /// Whether the computer's browser is open, as the keeper last said.
    browser: Arc<AtomicBool>,
    /// Whether a turn is under way, for a page that missed the news.
    typing: Arc<AtomicBool>,
    /// The seat's asks waiting on the person, each with its waiter.
    asks: Arc<Mutex<Vec<(SeatAsk, Waiter)>>>,
    /// The last turn as the pages were shown it, for a page that loads
    /// before hippo has it: a seat's turn reaches hippo only once it ends.
    turn: Arc<Mutex<Turn>>,
}

/// What a turn showed so far: the person's words, the calls, the answer.
/// It stays past the turn's end, until the next one begins.
#[derive(Default, Clone, Serialize)]
struct Turn {
    /// When its first message came, in Unix milliseconds.
    start: u64,
    shown: Vec<Shown>,
    #[serde(skip)]
    ended: bool,
}

/// The most a turn record keeps; a page loading later sees hippo's.
const TURN_KEPT: usize = 400;

impl Web {
    pub fn new() -> Self {
        Self {
            shown: broadcast::channel(256).0,
            ids: Arc::new(AtomicU64::new(0)),
            aside: false,
            agents: Arc::default(),
            own: Arc::default(),
            seated: Arc::default(),
            browser: Arc::default(),
            typing: Arc::default(),
            asks: Arc::default(),
            turn: Arc::default(),
        }
    }

    /// The same pages, for what comes from no turn.
    pub fn aside(&self) -> Self {
        Self {
            aside: true,
            ..self.clone()
        }
    }

    /// Tells the pages the oldest messages went.
    pub fn forgot(&self) {
        self.show(Shown::Forgot);
    }

    /// Shows what the person wrote by another door.
    pub fn heard(&self, id: &str, text: &str) {
        self.show(Shown::Heard {
            id: id.into(),
            text: text.into(),
            from: None,
        });
    }

    /// Shows the agents at work, if that changed.
    fn at_work(&self) {
        let now: Vec<Agent> = [
            self.own.lock().unwrap().clone(),
            self.seated.lock().unwrap().clone(),
        ]
        .concat();
        let mut last = self.agents.lock().unwrap();
        if *last != now {
            *last = now.clone();
            self.show(Shown::Agents { agents: now });
        }
    }

    fn id(&self) -> String {
        format!("web-{}", self.ids.fetch_add(1, Ordering::Relaxed))
    }

    fn browser(&self, open: bool) {
        if self.browser.swap(open, Ordering::Relaxed) != open {
            self.show(Shown::Browser { open });
        }
    }

    /// Settles ask `id` with `input` (None refuses it); false when it is
    /// gone already.
    fn resolve(&self, id: &str, input: Option<Value>) -> bool {
        let found = {
            let mut asks = self.asks.lock().unwrap();
            let i = asks.iter().position(|(a, _)| a.id == id);
            i.map(|i| asks.remove(i))
        };
        let Some((_, waiter)) = found else {
            return false;
        };
        let _ = waiter.send(input);
        self.show(Shown::Asked { id: id.into() });
        true
    }

    /// Words typed while asks wait answer them, as a chat's reply does: a
    /// question takes them as the answer to each of its questions, and a
    /// tool waiting for a yes is refused, the words telling the turn why.
    /// True when they answered a question, and so are not news to the turn.
    fn typed(&self, text: &str) -> bool {
        let open: Vec<(String, Option<Value>)> = self
            .asks
            .lock()
            .unwrap()
            .iter()
            .map(|(a, _)| (a.id.clone(), typed_answer(a, text)))
            .collect();
        let mut answered = false;
        for (id, input) in open {
            answered |= input.is_some();
            self.resolve(&id, input);
        }
        answered
    }

    fn show(&self, s: Shown) {
        self.keep(&s);
        // No page open is no error: hippo has it for the next one.
        let _ = self.shown.send(s);
    }

    /// Adds what belongs to the turn to its record; the first thing after
    /// a turn's end begins the next.
    fn keep(&self, s: &Shown) {
        let mut t = self.turn.lock().unwrap();
        match s {
            Shown::Typing { on: false } => {
                t.ended = true;
                return;
            }
            // A turn no one's words began (a routine, a report) begins
            // here, before its prompt reaches hippo, so a page loading later
            // knows hippo's prompt and calls for this turn's own.
            Shown::Typing { on: true } => {
                if t.ended || t.start == 0 {
                    *t = Turn {
                        start: unix_ms(),
                        ..Turn::default()
                    };
                }
                return;
            }
            Shown::Heard { .. }
            | Shown::Step { agent: None, .. }
            | Shown::Said { aside: false, .. }
            | Shown::Picture { .. }
            | Shown::File { .. } => {}
            _ => return,
        }
        if t.ended || t.start == 0 {
            *t = Turn {
                start: unix_ms(),
                ..Turn::default()
            };
        }
        // The words stream in a few letters at a time: they join the
        // words before them, so a long answer doesn't use up the record.
        if let (
            Shown::Step {
                step: Step::Text { text },
                agent: None,
            },
            Some(Shown::Step {
                step: Step::Text { text: before },
                agent: None,
            }),
        ) = (s, t.shown.last_mut())
        {
            before.push_str(text);
            return;
        }
        if let (
            Shown::Step {
                step: Step::Thinking { text },
                agent: None,
            },
            Some(Shown::Step {
                step: Step::Thinking { text: before },
                agent: None,
            }),
        ) = (s, t.shown.last_mut())
        {
            before.push_str(text);
            return;
        }
        // Only the latest count of background jobs is true.
        if let Shown::Step {
            step: Step::Jobs { .. },
            agent: None,
        } = s
        {
            t.shown.retain(|x| {
                !matches!(
                    x,
                    Shown::Step {
                        step: Step::Jobs { .. },
                        ..
                    }
                )
            });
            t.shown.push(s.clone());
            return;
        }
        if t.shown.len() < TURN_KEPT {
            t.shown.push(s.clone());
        }
    }

    /// The person's words from a page, to every page open: the one that
    /// sent them knows them by `from`. A redo goes to the record alone;
    /// the other pages see its answer, and the history, on their next load.
    fn sent(&self, id: &str, text: &str, from: Option<String>, redo: bool) {
        let heard = Shown::Heard {
            id: id.into(),
            text: text.into(),
            from,
        };
        if redo {
            self.keep(&heard);
        } else {
            self.show(heard);
        }
    }
}

impl Asker for Web {
    fn put(&self, ask: SeatAsk) -> Option<Value> {
        let (waiter, answer) = std::sync::mpsc::channel();
        self.asks.lock().unwrap().push((ask.clone(), waiter));
        self.show(Shown::Ask { ask });
        // A waiter dropped unanswered refuses.
        answer.recv().ok().flatten()
    }

    fn withdraw(&self, id: &str) {
        self.resolve(id, None);
    }
}

impl Door for Web {
    type File = Upload;
    const CARDS: bool = true;

    fn asker(&self) -> Option<Arc<dyn Asker>> {
        Some(Arc::new(self.clone()))
    }

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

    async fn picture(&self, name: &str, _data: Vec<u8>, _mime: &'static str) -> Result<(), String> {
        self.show(Shown::Picture { name: name.into() });
        Ok(())
    }

    fn step(&self, step: Step) {
        match step {
            Step::Inner { parent, step } => {
                // Claude Code's subagents end on a SubagentHandback call,
                // whose message is the report; the notice that follows only
                // points to it.
                if let Step::Call { name, input, .. } = step.as_ref()
                    && name == "SubagentHandback"
                    && let Some(report) = input["message"].as_str()
                {
                    self.show(Shown::Step {
                        step: Step::Done {
                            id: parent.clone(),
                            report: report.to_owned(),
                        },
                        agent: None,
                    });
                }
                self.agent_step(&parent, *step)
            }
            Step::Agent { id, name, task } => {
                self.seated.lock().unwrap().push(Agent {
                    name: id,
                    task,
                    title: Some(name),
                });
                self.at_work();
            }
            Step::Result { id, text, error } => {
                // An Agent call run in the foreground ends with its report;
                // a background one's result only says it started.
                let mut seated = self.seated.lock().unwrap();
                let was = seated.len();
                if !text.starts_with("Async agent launched") {
                    seated.retain(|a| a.name != id);
                }
                let gone = seated.len() != was;
                drop(seated);
                if gone {
                    self.at_work();
                }
                self.show(Shown::Step {
                    step: Step::Result { id, text, error },
                    agent: None,
                });
            }
            Step::Done { id, report } => {
                // The report goes to the call, as its result does.
                self.seated.lock().unwrap().retain(|a| a.name != id);
                self.at_work();
                self.show(Shown::Step {
                    step: Step::Done { id, report },
                    agent: None,
                });
            }
            step => self.show(Shown::Step { step, agent: None }),
        }
    }

    fn agent_step(&self, agent: &str, step: Step) {
        self.show(Shown::Step {
            step,
            agent: Some(agent.into()),
        });
    }

    fn agents(&self, now: Vec<(String, String)>) {
        *self.own.lock().unwrap() = now.into_iter().map(Agent::own).collect();
        self.at_work();
    }

    async fn typing(&self, on: bool) {
        // The beat asks twice a second; the page hears only the change.
        if self.typing.swap(on, Ordering::Relaxed) != on {
            self.show(Shown::Typing { on });
        }
        // The seat's run is over, and its subagents with it.
        if !on && !self.seated.lock().unwrap().is_empty() {
            self.seated.lock().unwrap().clear();
            self.at_work();
        }
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

    /// Already here: the page sent the bytes with the message, and for a
    /// photo too big or of a kind the model can't see, a JPEG to see.
    async fn fetch(&self, file: &Upload) -> Result<Fetched, String> {
        let read = match &file.view {
            Some(view) => seen(view, Some("image/jpeg")),
            None => seen(&file.data, file.mime.as_deref()),
        };
        let photo =
            file.view.is_some() || matches!(read, Some(Read::Model(Attachment::Image { .. })));
        Ok(Fetched {
            name: file.name.clone(),
            photo,
            data: file.data.clone(),
            read,
        })
    }

    async fn file(&self, name: &str, _data: Vec<u8>, _mime: &str) -> Result<(), String> {
        self.show(Shown::File { name: name.into() });
        Ok(())
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

    fn asker(&self) -> Option<Arc<dyn Asker>> {
        self.web.as_ref().and_then(Door::asker)
    }

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

    async fn picture(&self, name: &str, data: Vec<u8>, mime: &'static str) -> Result<(), String> {
        if let Some(w) = &self.web {
            w.picture(name, Vec::new(), mime).await?;
        }
        self.door.picture(name, data, mime).await
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

    fn agent_step(&self, agent: &str, step: Step) {
        if let Some(w) = &self.web {
            w.agent_step(agent, step.clone());
        }
        self.door.agent_step(agent, step);
    }

    fn agents(&self, now: Vec<(String, String)>) {
        if let Some(w) = &self.web {
            w.agents(now.clone());
        }
        self.door.agents(now);
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

    fn fetch(&self, file: &Self::File) -> impl Future<Output = Result<Fetched, String>> + Send {
        self.door.fetch(file)
    }

    async fn file(&self, name: &str, data: Vec<u8>, mime: &str) -> Result<(), String> {
        if let Some(w) = &self.web {
            w.file(name, data.clone(), mime).await?;
        }
        self.door.file(name, data, mime).await
    }
}

/// A file sent from the page with a message.
pub struct Upload {
    name: String,
    mime: Option<String>,
    data: Vec<u8>,
    /// The page's JPEG of a photo the model can't take as it is.
    view: Option<Vec<u8>>,
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
    /// When each address last asked: one browser's asking must not shut
    /// out another's.
    last: Mutex<HashMap<String, Instant>>,
}

struct Ask {
    made: Instant,
    /// The message that asked the person, once posted.
    event: Option<String>,
    answer: Option<bool>,
}

impl Gate {
    /// Whether `from` may ask now, counting it as asking if so.
    fn may_ask(&self, from: &str) -> bool {
        let mut last = self.last.lock().unwrap();
        last.retain(|_, t| t.elapsed() < ASK_GAP);
        if last.contains_key(from) {
            return false;
        }
        last.insert(from.to_owned(), Instant::now());
        true
    }

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
    who: Who,
    index: PathBuf,
    /// None when the site's address is unknown or the key would not load.
    push: Option<Arc<Push>>,
    /// yeoman-x's socket, which reads replies aloud.
    x: Option<PathBuf>,
    /// Replies being read aloud now, by key.
    speaking: Mutex<HashMap<String, tokio::sync::watch::Sender<Sofar>>>,
    /// xAI's voices as last asked, and when.
    voices: Mutex<Option<(std::time::Instant, serde_json::Value)>>,
    /// The subscription windows as last read, and when.
    usage: Mutex<Option<(std::time::Instant, Vec<Limit>)>>,
}

/// Who answers here, and every assistant the proxy serves on this host,
/// picked by the page's `persona` cookie (yeoman.mod.nix): the name from
/// YEOMAN_NAME, the others from YEOMAN_PERSONAS, `unit=Name,...`.
#[derive(Serialize)]
struct Who {
    name: String,
    /// What the site and its installed app are called: YEOMAN_APP, else
    /// the name.
    app: String,
    personas: Vec<Persona>,
    /// The xAI voice replies are read aloud in: YEOMAN_VOICE, none when
    /// unset or without yeoman-x.
    voice: Option<String>,
    /// The models the person may switch between (YEOMAN_MODELS); empty
    /// when the model is fixed.
    models: Vec<String>,
    /// The windows, in minutes, the person may pick for forgetting; empty
    /// for one that remembers.
    forgets: Vec<u64>,
}

#[derive(Serialize)]
struct Persona {
    unit: String,
    name: String,
}

impl Who {
    fn from_env() -> Self {
        let var = |k| std::env::var(k).unwrap_or_default();
        let name = std::env::var("YEOMAN_NAME").unwrap_or_else(|_| "Chat".into());
        Who {
            app: std::env::var("YEOMAN_APP").unwrap_or_else(|_| name.clone()),
            name,
            personas: personas(&var("YEOMAN_PERSONAS")),
            voice: std::env::var("YEOMAN_VOICE")
                .ok()
                .filter(|_| std::env::var_os("YEOMAN_X").is_some()),
            models: crate::model::choices(),
            forgets: match std::env::var_os("YEOMAN_FORGET") {
                Some(_) => crate::forget::CHOICES.to_vec(),
                None => Vec::new(),
            },
        }
    }
}

fn personas(list: &str) -> Vec<Persona> {
    list.split(',')
        .filter_map(|p| p.split_once('='))
        .map(|(unit, name)| Persona {
            unit: unit.into(),
            name: name.into(),
        })
        .collect()
}

/// Sessions by token, with when each ends in Unix seconds, in a file so a
/// restart signs nobody out. The assistants that share a host share the
/// file (YEOMAN_SESSIONS, in a directory only their group reaches), so one
/// sign-in lets the person into each; it is read afresh each time, since
/// another may have added to it.
struct Sessions {
    file: PathBuf,
    /// Group-readable when shared, else the owner's alone.
    mode: u32,
}

impl Sessions {
    fn live(&self) -> HashMap<String, u64> {
        let now = unix();
        fs::read_to_string(&self.file)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| {
                let (token, end) = l.split_once(' ')?;
                Some((token.to_owned(), end.parse().ok()?))
            })
            .filter(|(_, end)| *end > now)
            .collect()
    }

    fn valid(&self, token: &str) -> bool {
        self.live().contains_key(token)
    }

    fn start(&mut self) -> Result<String, String> {
        let token = token()?;
        let mut live = self.live();
        live.insert(token.clone(), unix() + SESSION.as_secs());
        let text: String = live.iter().map(|(t, e)| format!("{t} {e}\n")).collect();
        write_mode(&self.file, &text, self.mode)?;
        Ok(token)
    }
}

fn unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

fn unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
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
    write_mode(path, text, 0o600)
}

/// Writes a file whole or not at all, by way of a temporary one named for
/// this process, so two writers never share it.
fn write_mode(path: &Path, text: &str, mode: u32) -> Result<(), String> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let tmp = path.with_extension(format!("{}.tmp", std::process::id()));
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(mode)
        .open(&tmp)
        .map_err(|e| format!("{}: {e}", tmp.display()))?;
    // The unit's umask (0077) strips the group bits `mode` gave at create,
    // which would leave a shared sessions file unreadable to the others.
    f.set_permissions(fs::Permissions::from_mode(mode))
        .map_err(|e| format!("{}: {e}", tmp.display()))?;
    std::io::Write::write_all(&mut f, text.as_bytes()).map_err(|e| e.to_string())?;
    fs::rename(&tmp, path).map_err(|e| format!("{}: {e}", path.display()))
}

/// The entry document, titled with the site's name and carrying the
/// assistant's, which the page takes from it: the host no longer names the
/// assistant when several share one. Revalidated each load, as it carries no hash in its name, so
/// a deploy's new asset hashes are picked up.
async fn index(State(site): State<Arc<Site>>) -> Response {
    match fs::read_to_string(&site.index) {
        Ok(html) => (
            [(header::CACHE_CONTROL, "no-cache")],
            axum::response::Html(titled(&html, &site.who.app, &site.who.name)),
        )
            .into_response(),
        Err(e) => {
            eprintln!("yeoman: {}: {e}", site.index.display());
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

fn titled(html: &str, app: &str, name: &str) -> String {
    let clean = |s: &str| -> String { s.chars().filter(char::is_ascii_alphanumeric).collect() };
    html.replacen(
        "<title>Chat</title>",
        &format!(
            "<title>{}</title><meta name=\"persona\" content=\"{}\" />",
            clean(app),
            clean(name)
        ),
        1,
    )
}

/// The assistant's name and the others on this host, for the switcher.
async fn me(State(site): State<Arc<Site>>) -> Json<serde_json::Value> {
    Json(serde_json::json!(site.who))
}

/// What makes the page installable as an app, under the site's name.
async fn manifest(State(site): State<Arc<Site>>) -> Response {
    let name = &site.who.app;
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

/// What show_page wrote, sandboxed: a page shares the chat's address, so
/// unsandboxed its scripts could read the chat and act as the person. In
/// the sandbox it has an origin of its own, which the session cookie
/// (SameSite=Lax) never reaches.
const PAGE_SANDBOX: &str =
    "sandbox allow-scripts allow-forms allow-popups allow-modals allow-downloads";

fn pages_of(dir: PathBuf) -> SetResponseHeader<ServeDir, HeaderValue> {
    SetResponseHeaderLayer::overriding(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(PAGE_SANDBOX),
    )
    .layer(ServeDir::new(dir))
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
    let who = Who::from_env();
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
        sessions: Mutex::new(match std::env::var("YEOMAN_SESSIONS") {
            Ok(file) => {
                // A file written under the umask before the fix kept only
                // the owner's bits; whichever assistant owns it opens it up.
                use std::os::unix::fs::PermissionsExt;
                let _ = fs::set_permissions(&file, fs::Permissions::from_mode(0o660));
                Sessions {
                    file: file.into(),
                    mode: 0o660,
                }
            }
            Err(_) => Sessions {
                file: dir.join("sessions"),
                mode: 0o600,
            },
        }),
        push: push_from_env(&dir, &who.name).map(Arc::new),
        who,
        index: root.join("index.html"),
        x: std::env::var_os("YEOMAN_X").map(PathBuf::from),
        speaking: Mutex::default(),
        voices: Mutex::default(),
        usage: Mutex::default(),
    });
    if let Some(push) = &site.push {
        tokio::spawn(ring(site.web.shown.subscribe(), push.clone()));
    }
    if let Ok(url) = std::env::var("YEOMAN_KEEP") {
        tokio::spawn(watch_browser(url, site.web.clone()));
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
        .route("/", get(index))
        // At the root, so its scope is the whole site.
        .route_service(
            "/sw.js",
            revalidate.layer(ServeFile::new(root.join("sw.js"))),
        )
        .nest_service("/_site", forever.layer(ServeDir::new(root.join("_site"))))
        .route("/manifest.webmanifest", get(manifest))
        .route("/api/me", get(me))
        .route("/api/history", get(history))
        .route("/api/search", get(search))
        .route("/api/said/{i}", get(said))
        .route("/api/past", get(past))
        .route("/api/zoom/{id}/{n}", get(zoom))
        .route("/api/agent/{id}/chat", get(agent_chat))
        .route("/api/file/{name}", get(kept))
        .route("/api/speak", post(speak))
        .route("/api/speak/{key}", get(spoken))
        .route("/api/voices", get(voices))
        .route("/api/usage", get(usage))
        .route("/api/model", get(model_now).post(model_pick))
        .route("/api/forget", get(forget_now).post(forget_pick))
        .route("/api/call", post(call))
        .route("/api/call/end", post(call_end))
        .route("/api/events", get(events))
        .route(
            "/api/send",
            post(send).layer(DefaultBodyLimit::max(UPLOAD_MAX)),
        )
        .route("/api/pending", get(waiting))
        .route("/api/decide", post(decide))
        .route("/api/asks", get(asks))
        .route("/api/answer", post(answer))
        .route("/api/stop", post(stop))
        .route("/api/task", get(task_now))
        .route("/api/agent/{name}/stop", post(agent_stop))
        .route("/api/browser/open", post(browser_open))
        .route("/api/browser/close", post(browser_close))
        .route("/api/ask", post(ask))
        .route("/api/wait", post(wait))
        .route("/api/push", get(push_key).post(push_add))
        .route("/api/push/drop", post(push_drop))
        .fallback_service(pages_of(pages))
        .with_state(site);
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .map_err(|e| format!("site {addr}: {e}"))?;
    axum::serve(listener, app)
        .await
        .map_err(|e| format!("site: {e}"))
}

fn push_from_env(dir: &Path, title: &str) -> Option<Push> {
    let url = std::env::var("YEOMAN_SITE_URL").ok()?;
    Push::load(dir, &url, title)
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

/// A line of hippo's view: messages `id..id+n`, folded into one summary.
#[derive(Debug, PartialEq, Serialize)]
struct Part {
    id: u64,
    n: u64,
    text: String,
}

#[derive(Deserialize)]
struct Before {
    before: u64,
}

/// What came before the history: the yeoman's own view of it, as the
/// lines that end by message `before`, each opened by `/api/zoom`. The
/// page draws them as UniiChat does, folded blocks over the talk.
async fn past(
    State(site): State<Arc<Site>>,
    headers: HeaderMap,
    axum::extract::Query(Before { before }): axum::extract::Query<Before>,
) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let h = site.hippo.clone();
    match tokio::task::spawn_blocking(move || past_parts(&h, before)).await {
        Ok(Ok(parts)) => Json(parts).into_response(),
        Ok(Err(e)) => {
            eprintln!("yeoman: site past: {e}");
            StatusCode::BAD_GATEWAY.into_response()
        }
        Err(e) => {
            eprintln!("yeoman: site past: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

/// The view's lines that start before `before`, as the yeoman sees them.
/// One that runs past it stays whole, as UniiChat draws its view: opening
/// it to fit would stack one line of each size above the talk, which is
/// nothing the yeoman reads, though its tail repeats the history's start.
fn past_parts(h: &crate::hippo::Hippo, before: u64) -> Result<Vec<Part>, String> {
    Ok(parts(&h.view()?)
        .into_iter()
        .filter(|p| p.id < before)
        .collect())
}

/// hippo's `id+n|text` lines. A run of messages not yet summarized comes
/// as one line whose span needn't be a node of the tree, so it is cut into
/// the nodes that tile it, which `zoom` opens.
fn parts(out: &str) -> Vec<Part> {
    let mut all = Vec::new();
    for l in out.lines() {
        let Some((at, text)) = l.split_once('|') else {
            continue;
        };
        let Some((Ok(id), Ok(n))) = at.split_once('+').map(|(i, n)| (i.parse(), n.parse())) else {
            continue;
        };
        for (id, n) in tiles(id, n) {
            all.push(Part {
                id,
                n,
                text: text.to_owned(),
            });
        }
    }
    all
}

/// The fewest tree nodes covering messages `id..id+n`: each as large as
/// its start allows.
fn tiles(mut id: u64, n: u64) -> Vec<(u64, u64)> {
    let end = id + n;
    let mut out = Vec::new();
    while id < end {
        let mut size = if id == 0 {
            1 << 62
        } else {
            1 << id.trailing_zeros()
        };
        while id + size > end {
            size /= 2;
        }
        out.push((id, size));
        id += size;
    }
    out
}

/// A line of the view opened: its two halves, or for one message the
/// message whole and who said it.
async fn zoom(
    State(site): State<Arc<Site>>,
    headers: HeaderMap,
    axum::extract::Path((id, n)): axum::extract::Path<(u64, u64)>,
) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let h = site.hippo.clone();
    match tokio::task::spawn_blocking(move || h.zoom(id, n)).await {
        Ok(Ok(out)) if n == 1 => match whole(&out) {
            Some((kind, text)) => {
                Json(serde_json::json!({ "kind": kind, "text": text })).into_response()
            }
            None => StatusCode::BAD_GATEWAY.into_response(),
        },
        Ok(Ok(out)) => Json(serde_json::json!({ "parts": parts(&out) })).into_response(),
        Ok(Err(_)) => StatusCode::NOT_FOUND.into_response(),
        Err(e) => {
            eprintln!("yeoman: site zoom: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

/// A seat subagent's whole chat, for its page once it is done.
async fn agent_chat(
    State(site): State<Arc<Site>>,
    headers: HeaderMap,
    axum::extract::Path(id): axum::extract::Path<String>,
) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let h = site.hippo.clone();
    match tokio::task::spawn_blocking(move || h.agent(&id)).await {
        Ok(Ok(text)) => Json(serde_json::json!({ "text": text })).into_response(),
        Ok(Err(_)) => StatusCode::NOT_FOUND.into_response(),
        Err(e) => {
            eprintln!("yeoman: site agent chat: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

/// One message as zoom gives it, `{i}+1|{kind}[ [chat]]: {text}`.
fn whole(out: &str) -> Option<(&str, &str)> {
    let (_, m) = out.split_once('|')?;
    let (head, text) = m.split_once(": ")?;
    Some((head.split(' ').next()?, text))
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
/// A kept file, for the person to save: only by its exact kept name.
async fn kept(
    State(site): State<Arc<Site>>,
    headers: HeaderMap,
    axum::extract::Path(name): axum::extract::Path<String>,
) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let Some(path) = Library::new(&site.state).path(&name) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    match tokio::fs::read(&path).await {
        Ok(data) => {
            let mime = mime_of(&name, &data);
            // Saved, never shown in place: a kept HTML or SVG file is the
            // person's data, not part of this site.
            let saved = format!("attachment; filename*=UTF-8''{}", percent(&name));
            (
                [
                    (header::CONTENT_TYPE, mime),
                    (header::CONTENT_DISPOSITION, saved),
                    (header::X_CONTENT_TYPE_OPTIONS, "nosniff".into()),
                ],
                data,
            )
                .into_response()
        }
        Err(e) => {
            eprintln!("yeoman: file {name}: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

/// A name as RFC 5987 wants it in a header: unreserved bytes as they
/// are, the rest as %XX.
fn percent(name: &str) -> String {
    name.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

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
        Ok(Ok(out)) => match whole(&out) {
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

#[derive(Deserialize)]
struct Speak {
    text: String,
    /// One of the voices the page picked; else the assistant's own.
    voice: Option<String>,
}

/// A reply being read aloud: the MP3 so far, and how it ended once it has
/// (true when whole). Every listener plays it from the start.
#[derive(Default)]
struct Sofar {
    mp3: Vec<u8>,
    end: Option<bool>,
}

/// Starts reading a reply aloud in this assistant's voice and answers its
/// key, which `/api/speak/{key}` plays while xAI is still making it. Kept
/// by voice and text rather than message id, since a live reply's id is
/// the door's and changes once it is in the history.
async fn speak(
    State(site): State<Arc<Site>>,
    headers: HeaderMap,
    Json(Speak {
        text,
        voice: picked,
    }): Json<Speak>,
) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let (Some(sock), Some(own)) = (site.x.clone(), site.who.voice.clone()) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let voice = match picked {
        Some(v) if crate::x::voice_ok(&v) => v,
        Some(_) => return StatusCode::BAD_REQUEST.into_response(),
        None => own,
    };
    let text = plain(&text);
    if text.is_empty() || text.chars().count() > crate::x::SPEAK_MAX {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let key = format!("{:016x}", speech_key(&voice, &text));
    let dir = site.state.join("speech");
    let file = dir.join(format!("{key}.mp3"));
    let answer = Json(serde_json::json!({ "key": key })).into_response();
    let tx = {
        let mut speaking = site.speaking.lock().unwrap();
        if file.exists() || speaking.contains_key(&key) {
            return answer;
        }
        // Each reading holds a blocking thread and an xAI session.
        if speaking.len() >= SPEAKING_MAX {
            return StatusCode::TOO_MANY_REQUESTS.into_response();
        }
        let (tx, _) = tokio::sync::watch::channel(Sofar::default());
        speaking.insert(key.clone(), tx.clone());
        tx
    };
    let site = site.clone();
    tokio::task::spawn_blocking(move || {
        let made = crate::x::speak(&sock, &text, &voice, |b| {
            tx.send_modify(|s| s.mp3.extend_from_slice(b));
        });
        // Only a whole reading is kept; a cut one is made afresh next time.
        if let Err(e) = made.and_then(|()| {
            prune(&dir, SPEECH_KEEP);
            let tmp = file.with_extension("part");
            fs::create_dir_all(&dir)
                .and_then(|_| fs::write(&tmp, &tx.borrow().mp3))
                .and_then(|_| fs::rename(&tmp, &file))
                .map_err(|e| format!("{}: {e}", file.display()))
        }) {
            eprintln!("yeoman: site speak: {e}");
            tx.send_modify(|s| s.end = Some(false));
        } else {
            tx.send_modify(|s| s.end = Some(true));
        }
        site.speaking.lock().unwrap().remove(&key);
    });
    answer
}

/// A reply read aloud, as MP3: from the cache once whole, else as xAI
/// makes it. nginx is told not to buffer, or the page would hear nothing
/// until the end.
async fn spoken(
    State(site): State<Arc<Site>>,
    axum::extract::Path(key): axum::extract::Path<String>,
    req: axum::extract::Request,
) -> Response {
    if !site.signed(req.headers()) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if key.len() != 16 || !key.bytes().all(|b| b.is_ascii_hexdigit()) {
        return StatusCode::NOT_FOUND.into_response();
    }
    let rx = site
        .speaking
        .lock()
        .unwrap()
        .get(&key)
        .map(|tx| tx.subscribe());
    let Some(rx) = rx else {
        let file = site.state.join("speech").join(format!("{key}.mp3"));
        // ServeFile answers Range requests, which the player seeks with.
        return match ServeFile::new(file).try_call(req).await {
            Ok(r) => r.into_response(),
            Err(_) => StatusCode::NOT_FOUND.into_response(),
        };
    };
    (
        [
            (header::CONTENT_TYPE, "audio/mpeg"),
            (header::CACHE_CONTROL, "no-store"),
            (header::HeaderName::from_static("x-accel-buffering"), "no"),
        ],
        axum::body::Body::from_stream(follow(rx)),
    )
        .into_response()
}

/// A reading as one listener hears it: from the first byte, each new piece
/// as it comes, then the end, or an error if it was cut. `done` once over.
fn follow(
    rx: tokio::sync::watch::Receiver<Sofar>,
) -> impl futures_util::Stream<Item = std::io::Result<Vec<u8>>> {
    futures_util::stream::unfold((rx, 0, false), |(mut rx, at, done)| async move {
        if done {
            return None;
        }
        let mut gone = false;
        loop {
            // Some(next piece, or None at the end); None to wait for more.
            let step = {
                let s = rx.borrow_and_update();
                if s.mp3.len() > at {
                    Some(Some(Ok(s.mp3[at..].to_vec())))
                } else {
                    match s.end {
                        Some(true) => Some(None),
                        // An error, not an end, so the player knows it was cut.
                        Some(false) => Some(Some(Err(std::io::Error::other("speech cut")))),
                        None if gone => Some(None),
                        None => None,
                    }
                }
            };
            match step {
                Some(Some(Ok(b))) => {
                    let at = at + b.len();
                    return Some((Ok(b), (rx, at, false)));
                }
                Some(Some(Err(e))) => return Some((Err(e), (rx, at, true))),
                Some(None) => return None,
                None => gone = rx.changed().await.is_err(),
            }
        }
    })
}

/// How long a call's pass to Grok Voice lasts. It only opens the call,
/// which runs on once open.
const CALL_PASS: u64 = 120;

/// How long xAI's voice list is trusted before it is asked again.
const VOICES_FRESH: std::time::Duration = std::time::Duration::from_secs(24 * 3600);

/// The voices the page may pick for reading aloud and calls, `[{id, name}]`,
/// as xAI lists them; only where the assistant has a voice.
async fn voices(State(site): State<Arc<Site>>, headers: HeaderMap) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let (Some(sock), Some(_)) = (site.x.clone(), site.who.voice.as_ref()) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if let Some((at, list)) = &*site.voices.lock().unwrap()
        && at.elapsed() < VOICES_FRESH
    {
        return Json(list.clone()).into_response();
    }
    match tokio::task::spawn_blocking(move || crate::x::voices(&sock)).await {
        Ok(Ok(list)) => {
            *site.voices.lock().unwrap() = Some((std::time::Instant::now(), list.clone()));
            Json(list).into_response()
        }
        Ok(Err(e)) => {
            eprintln!("yeoman: site voices: {e}");
            (StatusCode::BAD_GATEWAY, e).into_response()
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

/// Each usage read asks every provider afresh, so one is kept a while.
const USAGE_FRESH: std::time::Duration = std::time::Duration::from_secs(300);

/// One limit window of a subscription, as the composer's rings draw it.
#[derive(Clone, Serialize, Debug, PartialEq)]
struct Limit {
    account: String,
    window: String,
    pct: u32,
    resets: String,
}

/// The window lines of the usage report (`claude  5h  3%  resets Thu Oct
/// 22 23:19`); the shares under each, and accounts that couldn't be read,
/// are left out, as the rings show only how full each window is.
fn limits(text: &str) -> Vec<Limit> {
    text.lines()
        .filter_map(|line| {
            let mut w = line.split_whitespace();
            let (account, window, pct) = (w.next()?, w.next()?, w.next()?);
            let pct = pct.strip_suffix('%')?.parse().ok()?;
            (w.next()? == "resets").then(|| Limit {
                account: account.into(),
                window: window.into(),
                pct,
                resets: w.collect::<Vec<_>>().join(" "),
            })
        })
        .collect()
}

/// How full each subscription window is. A failed read keeps the last
/// good one.
async fn usage(State(site): State<Arc<Site>>, headers: HeaderMap) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if let Some((at, list)) = &*site.usage.lock().unwrap()
        && at.elapsed() < USAGE_FRESH
    {
        return Json(list.clone()).into_response();
    }
    match tokio::task::spawn_blocking(crate::tools::usage).await {
        Ok(Ok(text)) => {
            let list = limits(&text);
            *site.usage.lock().unwrap() = Some((std::time::Instant::now(), list.clone()));
            Json(list).into_response()
        }
        Ok(Err(e)) => {
            eprintln!("yeoman: site usage: {e}");
            match &*site.usage.lock().unwrap() {
                Some((_, list)) => Json(list.clone()).into_response(),
                None => (StatusCode::BAD_GATEWAY, e).into_response(),
            }
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

/// What the page needs to start a call: a pass to Grok Voice, the voice,
/// and the instructions with the newest of the memory. Only where the
/// assistant has a voice, so never for one kept off xAI.
async fn call(State(site): State<Arc<Site>>, headers: HeaderMap) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let (Some(sock), Some(voice)) = (site.x.clone(), site.who.voice.clone()) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let h = site.hippo.clone();
    let name = site.who.name.clone();
    let made = tokio::task::spawn_blocking(move || {
        let view = h.view()?;
        let pass = crate::x::secret(&sock, CALL_PASS)?;
        let env = |k| std::env::var(k).unwrap_or_default();
        let instructions =
            crate::call::instructions(&name, &env("YEOMAN_PERSON"), &env("YEOMAN_STYLE"), &view);
        Ok::<_, String>(serde_json::json!({
            "secret": pass["value"],
            "voice": voice,
            "instructions": instructions,
        }))
    })
    .await;
    match made {
        Ok(Ok(body)) => Json(body).into_response(),
        Ok(Err(e)) => {
            eprintln!("yeoman: site call: {e}");
            (StatusCode::BAD_GATEWAY, e).into_response()
        }
        Err(e) => {
            eprintln!("yeoman: site call: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

#[derive(Deserialize)]
struct CallEnd {
    lines: Vec<crate::call::Line>,
    minutes: u64,
}

/// A finished call into hippo, so the chat and the memory hold it.
async fn call_end(
    State(site): State<Arc<Site>>,
    headers: HeaderMap,
    Json(CallEnd { lines, minutes }): Json<CallEnd>,
) -> StatusCode {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED;
    }
    let h = site.hippo.clone();
    let logged = tokio::task::spawn_blocking(move || {
        crate::call::record(lines, minutes)
            .into_iter()
            .try_for_each(|(kind, text)| h.log(kind, &text))
    })
    .await;
    match logged {
        Ok(Ok(())) => StatusCode::NO_CONTENT,
        Ok(Err(e)) => {
            eprintln!("yeoman: site call end: {e}");
            StatusCode::BAD_GATEWAY
        }
        Err(e) => {
            eprintln!("yeoman: site call end: {e}");
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}

/// Names a spoken text in the cache. std's SipHash keys are fixed, so the
/// name holds across restarts; a Rust release that changed it would only
/// cost a miss.
fn speech_key(voice: &str, text: &str) -> u64 {
    use std::hash::{DefaultHasher, Hash, Hasher};
    let mut h = DefaultHasher::new();
    (voice, text).hash(&mut h);
    h.finish()
}

/// Drops the files in `dir` older than `keep`.
fn prune(dir: &Path, keep: Duration) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for e in entries.flatten() {
        let old = e
            .metadata()
            .and_then(|m| m.modified())
            .is_ok_and(|t| t.elapsed().is_ok_and(|age| age > keep));
        if old {
            let _ = fs::remove_file(e.path());
        }
    }
}

/// Markdown as it should be heard: code blocks, images, link targets,
/// table rules and the marks themselves left out.
fn plain(md: &str) -> String {
    let mut out = Vec::new();
    let mut code = false;
    for line in md.lines() {
        let t = line.trim();
        if t.starts_with("```") || t.starts_with("~~~") {
            code = !code;
            continue;
        }
        if code || t.is_empty() {
            continue;
        }
        // A table's rule row says nothing; its other rows read as a list.
        if t.starts_with('|') && t.chars().all(|c| "|-: ".contains(c)) {
            continue;
        }
        let t = t.trim_start_matches(['#', '>']).trim_start();
        let t = ["- ", "* ", "+ "]
            .iter()
            .find_map(|m| t.strip_prefix(m))
            .unwrap_or(t);
        let t = if t.starts_with('|') {
            t.trim_matches('|')
                .split('|')
                .map(str::trim)
                .filter(|c| !c.is_empty())
                .collect::<Vec<_>>()
                .join(", ")
        } else {
            t.to_owned()
        };
        let t = inline(&t);
        if !t.is_empty() {
            out.push(t);
        }
    }
    out.join("\n")
}

/// `inline` markdown as plain words: links keep their text, images go.
fn inline(s: &str) -> String {
    let mut out = String::new();
    let mut rest = s;
    while let Some(i) = rest.find('[') {
        let image = rest[..i].ends_with('!');
        out.push_str(&rest[..if image { i - 1 } else { i }]);
        let after = &rest[i + 1..];
        match after
            .find("](")
            .and_then(|j| after[j + 2..].find(')').map(|k| (j, j + 2 + k + 1)))
        {
            Some((j, end)) => {
                if !image {
                    out.push_str(&after[..j]);
                }
                rest = &after[end..];
            }
            None => {
                out.push('[');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out.replace("**", "")
        .replace("__", "")
        .replace("~~", "")
        .replace(['`', '*'], "")
        .trim()
        .to_owned()
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
/// message it answered. An edited or asked-again message replaces the
/// person's last one and all that followed it.
fn lines(all: Vec<Said>) -> Vec<Line> {
    let mut out: Vec<Line> = Vec::new();
    for mut said in all {
        if said.kind == "user"
            && let Some(text) = crate::redone(&said.text)
        {
            said.text = text.to_owned();
            if let Some(last) = out.iter().rposition(|l| l.said.kind == "user") {
                out.truncate(last);
            }
        }
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
            // A seat's work, as hippo read it from the session: the page
            // draws each call with its result, among the words, and a
            // subagent's report in its Agent call's frame.
            "tool" | "echo" | "work" => {
                if said.text.len() > HISTORY_STEP {
                    let mut cut = HISTORY_STEP;
                    while !said.text.is_char_boundary(cut) {
                        cut -= 1;
                    }
                    said.text.truncate(cut);
                    said.text.push('…');
                }
            }
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
    // A page too slow to keep up has lost news it can't do without, such
    // as the end of a turn: ending the stream makes it reconnect and sync.
    let stream = futures_util::stream::unfold(rx, |mut rx| async move {
        let s = rx.recv().await.ok()?;
        let e = Event::default().json_data(&s).unwrap_or_default();
        Some((Ok::<_, Infallible>(e), rx))
    });
    Sse::new(stream)
        .keep_alive(KeepAlive::default())
        .into_response()
}

/// The person's message, a form with `text` and maybe some `file`s:
/// answered like one from Matrix, through the pages. `redo` = "edit" or
/// "again" makes it take the place of their last message. Answers the id the
/// yeoman will react to.
async fn send(State(site): State<Arc<Site>>, headers: HeaderMap, mut form: Multipart) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let mut text = String::new();
    let mut redo = "";
    let mut local = None;
    let mut files = Vec::new();
    loop {
        let field = match form.next_field().await {
            Ok(Some(f)) => f,
            Ok(None) => break,
            Err(e) => return (e.status(), e.body_text()).into_response(),
        };
        match field.name() {
            Some("text") => match capped(field, SEND_MAX).await.map(String::from_utf8) {
                Ok(Ok(t)) => text = t,
                Ok(Err(_)) => return StatusCode::BAD_REQUEST.into_response(),
                Err(code) => return code.into_response(),
            },
            Some("file") => {
                let name = field.file_name().unwrap_or("file").to_owned();
                let mime = field.content_type().map(str::to_owned);
                match field.bytes().await {
                    Ok(b) => files.push(Upload {
                        name,
                        mime,
                        data: b.to_vec(),
                        view: None,
                    }),
                    Err(e) => return (e.status(), e.body_text()).into_response(),
                }
            }
            Some("local") => match field.text().await {
                Ok(t) if t.len() <= 64 => local = Some(t),
                _ => return StatusCode::BAD_REQUEST.into_response(),
            },
            Some("redo") => match field.text().await.as_deref() {
                Ok("edit") => redo = crate::EDITED,
                Ok("again") => redo = crate::AGAIN,
                _ => return StatusCode::BAD_REQUEST.into_response(),
            },
            // Follows the file it shows.
            Some("view") => match (field.bytes().await, files.last_mut()) {
                (Ok(b), Some(f)) => f.view = Some(b.to_vec()),
                (Ok(_), None) => return StatusCode::BAD_REQUEST.into_response(),
                (Err(e), _) => return (e.status(), e.body_text()).into_response(),
            },
            _ => {}
        }
    }
    let text = text.trim();
    if (text.is_empty() && files.is_empty()) || text.len() > SEND_MAX || files.len() > FILES_MAX {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let id = site.web.id();
    site.web.sent(&id, text, local, !redo.is_empty());
    // An answer reaches the turn as the question's answer; sent on as well,
    // the turn would hear it twice. Files with it still go on.
    let answered = redo.is_empty() && !text.eq_ignore_ascii_case("stop") && site.web.typed(text);
    if answered && files.is_empty() {
        return Json(serde_json::json!({ "id": id })).into_response();
    }
    let msg = Message {
        id: id.clone(),
        text: format!("{redo}{text}"),
        files,
    };
    if site.messages.send((site.web.clone(), msg)).is_err() {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    }
    Json(serde_json::json!({ "id": id })).into_response()
}

/// A field's bytes, refused once past `max` rather than read whole first.
async fn capped(
    mut field: axum::extract::multipart::Field<'_>,
    max: usize,
) -> Result<Vec<u8>, StatusCode> {
    let mut data = Vec::new();
    loop {
        match field.chunk().await {
            Ok(Some(c)) if data.len() + c.len() <= max => data.extend_from_slice(&c),
            Ok(Some(_)) => return Err(StatusCode::PAYLOAD_TOO_LARGE),
            Ok(None) => return Ok(data),
            Err(e) => return Err(e.status()),
        }
    }
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

/// The seat's asks waiting on the person, for a page that missed them.
async fn asks(State(site): State<Arc<Site>>, headers: HeaderMap) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let asks: Vec<SeatAsk> = site
        .web
        .asks
        .lock()
        .unwrap()
        .iter()
        .map(|(a, _)| a.clone())
        .collect();
    Json(asks).into_response()
}

#[derive(Deserialize)]
struct Reply {
    id: String,
    yes: bool,
    /// For AskUserQuestion: each question's answer, by its text.
    answers: Option<serde_json::Map<String, Value>>,
}

/// The person's answer to an ask: the tool runs as it was asked, with the
/// answers added for questions; 404 when it is answered or gone already.
async fn answer(
    State(site): State<Arc<Site>>,
    headers: HeaderMap,
    Json(a): Json<Reply>,
) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let input = {
        let asks = site.web.asks.lock().unwrap();
        let Some((ask, _)) = asks.iter().find(|(k, _)| k.id == a.id) else {
            return StatusCode::NOT_FOUND.into_response();
        };
        answered(&ask.input, a.yes, a.answers)
    };
    if site.web.resolve(&a.id, input) {
        StatusCode::NO_CONTENT.into_response()
    } else {
        StatusCode::NOT_FOUND.into_response()
    }
}

/// A question's input answered in the person's own words, or None for any
/// other ask, which they refuse.
fn typed_answer(ask: &SeatAsk, text: &str) -> Option<Value> {
    if ask.tool != "AskUserQuestion" {
        return None;
    }
    let answers = ask.input["questions"]
        .as_array()?
        .iter()
        .filter_map(|q| q["question"].as_str())
        .map(|q| (q.to_owned(), Value::String(text.to_owned())))
        .collect();
    answered(&ask.input, true, Some(answers))
}

/// The input a tool runs with once answered, or None when refused.
fn answered(
    input: &Value,
    yes: bool,
    answers: Option<serde_json::Map<String, Value>>,
) -> Option<Value> {
    let mut input = input.clone();
    if let (Some(answers), Some(o)) = (answers, input.as_object_mut()) {
        o.insert("answers".into(), Value::Object(answers));
    }
    yes.then_some(input)
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
/// The model the next turn runs on: the person's pick, else YEOMAN_MODEL.
async fn model_now(State(site): State<Arc<Site>>, headers: HeaderMap) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let model = crate::model::picked(&site.state)
        .or_else(|| std::env::var("YEOMAN_MODEL").ok())
        .unwrap_or_default();
    Json(serde_json::json!({ "model": model })).into_response()
}

#[derive(Deserialize)]
struct Pick {
    model: String,
}

/// Switches the model from the next turn on; the one under way keeps its.
async fn model_pick(
    State(site): State<Arc<Site>>,
    headers: HeaderMap,
    Json(p): Json<Pick>,
) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    match crate::model::pick(&site.state, &p.model) {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, e).into_response(),
    }
}

async fn forget_now(State(site): State<Arc<Site>>, headers: HeaderMap) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    match crate::forget::window(&site.state) {
        Some(m) => Json(serde_json::json!({ "minutes": m })).into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

#[derive(Deserialize)]
struct Window {
    minutes: u64,
}

/// Sets how long it remembers; the next sweep, within a minute, uses it.
async fn forget_pick(
    State(site): State<Arc<Site>>,
    headers: HeaderMap,
    Json(w): Json<Window>,
) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    match crate::forget::pick(&site.state, w.minutes) {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, e).into_response(),
    }
}

async fn stop(State(site): State<Arc<Site>>, headers: HeaderMap) -> StatusCode {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED;
    }
    site.stop.store(true, Ordering::Relaxed);
    StatusCode::ACCEPTED
}

/// Follows the keeper, so the screen stays on the page while the browser is
/// open, past the reply that opened it, and goes when the lease ends. The
/// keeper is on the computer's own link, so asking it often costs nothing.
async fn watch_browser(url: String, web: Web) {
    loop {
        let u = url.clone();
        if let Ok(Ok(open)) = tokio::task::spawn_blocking(move || keep::open(&u)).await {
            web.browser(open);
        }
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
    }
}

/// Opens the computer's browser on the person's word, on the lease a reply
/// would take, so it closes on its own once left alone.
async fn browser_open(State(site): State<Arc<Site>>, headers: HeaderMap) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let Ok(url) = std::env::var("YEOMAN_KEEP") else {
        return StatusCode::NOT_FOUND.into_response();
    };
    match tokio::task::spawn_blocking(move || keep::hold(&url, keep::LEASE)).await {
        Ok(Ok(_)) => {
            site.web.browser(true);
            StatusCode::ACCEPTED.into_response()
        }
        Ok(Err(e)) => (StatusCode::BAD_GATEWAY, e).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

/// Closes the computer's browser, as computer_close does.
async fn browser_close(State(site): State<Arc<Site>>, headers: HeaderMap) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let Ok(url) = std::env::var("YEOMAN_KEEP") else {
        return StatusCode::NOT_FOUND.into_response();
    };
    match tokio::task::spawn_blocking(move || keep::release(&url)).await {
        Ok(Ok(_)) => {
            site.web.browser(false);
            StatusCode::ACCEPTED.into_response()
        }
        Ok(Err(e)) => (StatusCode::BAD_GATEWAY, e).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

/// The subagents at work, the computer's screen to watch them by, when
/// the yeoman has one, whether its browser is open, and whether a turn is
/// under way.
async fn task_now(State(site): State<Arc<Site>>, headers: HeaderMap) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    Json(serde_json::json!({
        "agents": site.web.agents.lock().unwrap().clone(),
        "screen": std::env::var("YEOMAN_SCREEN").ok(),
        "size": std::env::var("YEOMAN_SCREEN_SIZE").ok(),
        "browser": site.web.browser.load(Ordering::Relaxed),
        "typing": site.web.typing.load(Ordering::Relaxed),
        "turn": site.web.turn.lock().unwrap().clone(),
    }))
    .into_response()
}

/// Stops a subagent on the next tick, as cancel_task does.
async fn agent_stop(
    State(site): State<Arc<Site>>,
    headers: HeaderMap,
    axum::extract::Path(name): axum::extract::Path<String>,
) -> Response {
    if !site.signed(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    match task::cancel(&site.state, &name) {
        Ok(()) => StatusCode::ACCEPTED.into_response(),
        Err(e) => (StatusCode::CONFLICT, e).into_response(),
    }
}

/// A page asks to be let in: the person gets its code over Matrix, the
/// page gets the code to show and a secret to wait with.
async fn ask(State(site): State<Arc<Site>>, headers: HeaderMap) -> Response {
    // nginx names the address (recommendedProxySettings); the site listens
    // on loopback only, so no one else can.
    let from = headers
        .get("x-real-ip")
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default();
    if !site.gate.may_ask(from) {
        return StatusCode::TOO_MANY_REQUESTS.into_response();
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
    fn typed_words_answer_a_question_and_refuse_a_tool() {
        let ask = |tool: &str, input: Value| SeatAsk {
            id: "a".into(),
            tool: tool.into(),
            input,
            about: None,
        };
        let q = serde_json::json!({"questions": [{"question": "Tea or coffee?"}, {"question": "Milk?"}]});
        let got = typed_answer(&ask("AskUserQuestion", q), "coffee, black").unwrap();
        assert_eq!(got["answers"]["Tea or coffee?"], "coffee, black");
        assert_eq!(got["answers"]["Milk?"], "coffee, black");
        assert!(typed_answer(&ask("Bash", serde_json::json!({"command": "ls"})), "no").is_none());
    }

    #[test]
    fn plain_reads_markdown_as_words() {
        let md = "## Weather\n\n**Cold** today, see [the map](https://x.y/m) ![radar](r.png).\n\n- Wear a `coat`\n1. Bring tea\n\n```sh\nrm -rf /\n```\n> quoted\n\n| Day | High |\n|---|---:|\n| Mon | 45 |";
        assert_eq!(
            super::plain(md),
            "Weather\nCold today, see the map .\nWear a coat\n1. Bring tea\nquoted\nDay, High\nMon, 45"
        );
    }

    #[tokio::test]
    async fn every_listener_hears_a_reading_whole_or_cut() {
        use futures_util::StreamExt;
        let (tx, _) = tokio::sync::watch::channel(super::Sofar::default());
        let early = super::follow(tx.subscribe());
        tx.send_modify(|s| s.mp3.extend_from_slice(b"ab"));
        let late = super::follow(tx.subscribe());
        let feed = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(20)).await;
            tx.send_modify(|s| s.mp3.extend_from_slice(b"cd"));
            tx.send_modify(|s| s.end = Some(true));
        });
        for heard in [early, late] {
            let got: Vec<_> = heard.map(Result::unwrap).collect().await;
            assert_eq!(got.concat(), b"abcd");
        }
        feed.await.unwrap();
        let (tx, rx) = tokio::sync::watch::channel(super::Sofar::default());
        tx.send_modify(|s| {
            s.mp3.extend_from_slice(b"ab");
            s.end = Some(false);
        });
        let got: Vec<_> = super::follow(rx).collect().await;
        assert!(matches!(got.as_slice(), [Ok(_), Err(_)]));
    }

    #[test]
    fn only_a_live_session_signs_in() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("yeoman-sessions-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("sessions");
        std::fs::write(&file, format!("old {}\n", super::unix() - 1)).unwrap();
        let mut sessions = super::Sessions {
            file: file.clone(),
            mode: 0o640,
        };
        let token = sessions.start().unwrap();
        assert!(sessions.valid(&token));
        assert!(!sessions.valid("old"), "an ended session is let in");
        assert!(!sessions.valid("forged"));
        assert!(
            !std::fs::read_to_string(&file).unwrap().contains("old "),
            "ended sessions are kept"
        );
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o640
        );

        let mut headers = axum::http::HeaderMap::new();
        let cookie = format!("theme=dark; {}={token}; x=y", super::COOKIE);
        headers.insert(axum::http::header::COOKIE, cookie.parse().unwrap());
        assert_eq!(super::session(&headers), Some(token.as_str()));
        assert_eq!(super::session(&axum::http::HeaderMap::new()), None);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn speech_key_tells_voices_apart() {
        assert_eq!(
            super::speech_key("leo", "hi"),
            super::speech_key("leo", "hi")
        );
        assert_ne!(
            super::speech_key("leo", "hi"),
            super::speech_key("ara", "hi")
        );
    }

    #[test]
    fn view_lines_become_tree_nodes() {
        assert_eq!(super::tiles(0, 8), [(0, 8)]);
        assert_eq!(super::tiles(5, 7), [(5, 1), (6, 2), (8, 4)]);
        let p = super::parts("<chat>\n0+4|old: a|b\n4+1|x\n5+3|(not summarized)\n</chat>\nnote");
        let got: Vec<_> = p.iter().map(|p| (p.id, p.n, p.text.as_str())).collect();
        assert_eq!(
            got,
            [
                (0, 4, "old: a|b"),
                (4, 1, "x"),
                (5, 1, "(not summarized)"),
                (6, 2, "(not summarized)")
            ]
        );
        assert_eq!(
            super::whole("7+1|talk [door]: hi: there"),
            Some(("talk", "hi: there"))
        );
        assert_eq!(super::whole("7+1|user: hi"), Some(("user", "hi")));
    }

    #[test]
    fn the_past_is_the_view_up_to_the_history_whole_lines() {
        use std::io::{BufRead, BufReader, Write};
        use std::os::unix::net::UnixListener;
        let sock = std::env::temp_dir().join(format!("yeoman-past-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&sock);
        let listener = UnixListener::bind(&sock).unwrap();
        let server = std::thread::spawn(move || {
            let mut asked = Vec::new();
            for out in ["<chat>\n0+8|a\n8+8|b\n16+1|c\n</chat>"] {
                let (mut c, _) = listener.accept().unwrap();
                let mut line = String::new();
                BufReader::new(c.try_clone().unwrap())
                    .read_line(&mut line)
                    .unwrap();
                asked.push(line.trim().to_owned());
                let reply = serde_json::json!({"ok": true, "out": out}).to_string() + "\n";
                c.write_all(reply.as_bytes()).unwrap();
            }
            asked
        });
        let h = crate::hippo::Hippo {
            sock: sock.clone(),
            seat: None,
        };
        let got: Vec<_> = super::past_parts(&h, 14)
            .unwrap()
            .into_iter()
            .map(|p| (p.id, p.n, p.text))
            .collect();
        assert_eq!(got, [(0, 8, "a".into()), (8, 8, "b".into())]);
        assert_eq!(
            server.join().unwrap(),
            [r#"{"args":["whole"],"cmd":"view"}"#]
        );
        std::fs::remove_file(sock).unwrap();
    }

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
        assert_eq!(got, [(1, Some("👍")), (3, None), (4, None), (5, None)]);
    }

    #[test]
    fn a_seats_work_comes_clipped() {
        let long = "é".repeat(HISTORY_STEP);
        let out = lines(vec![
            said(1, "user", "check"),
            said(2, "tool", r#"Bash {"command":"ls"}"#),
            said(3, "echo", &long),
            said(4, "work", "[Counter] COUNTED"),
            said(5, "talk", "Done."),
        ]);
        let kinds: Vec<_> = out.iter().map(|l| l.said.kind.as_str()).collect();
        assert_eq!(kinds, ["user", "tool", "echo", "work", "talk"]);
        let echo = &out[2].said.text;
        assert!(echo.len() <= HISTORY_STEP + '…'.len_utf8() && echo.ends_with('…'));
    }

    #[test]
    fn a_redo_replaces_the_last_exchange() {
        let out = lines(vec![
            said(1, "user", "hi"),
            said(2, "talk", "hello"),
            said(3, "user", "weather?"),
            said(4, "talk", "rain"),
            said(5, "note", "(routine) x"),
            said(6, "user", &format!("{}weather in Boston?", crate::EDITED)),
            said(7, "talk", "sun"),
            said(8, "user", &format!("{}weather in Boston?", crate::AGAIN)),
            said(9, "talk", "clouds"),
        ]);
        let got: Vec<_> = out
            .iter()
            .map(|l| (l.said.i, l.said.text.as_str()))
            .collect();
        assert_eq!(
            got,
            [
                (1, "hi"),
                (2, "hello"),
                (8, "weather in Boston?"),
                (9, "clouds")
            ]
        );
    }

    #[test]
    fn answers_join_the_input() {
        let input = serde_json::json!({"questions": [{"question": "Tea?"}]});
        let mut answers = serde_json::Map::new();
        answers.insert("Tea?".into(), "Yes".into());
        let out = answered(&input, true, Some(answers)).unwrap();
        assert_eq!(out["answers"]["Tea?"], "Yes");
        assert_eq!(out["questions"], input["questions"]);
        assert_eq!(answered(&input, false, None), None);
        assert_eq!(answered(&input, true, None), Some(input));
    }

    #[test]
    fn title_and_personas() {
        let html = "<head><title>Chat</title></head>";
        assert_eq!(
            titled(html, "Hippo", "Azula"),
            "<head><title>Hippo</title><meta name=\"persona\" content=\"Azula\" /></head>"
        );
        assert_eq!(
            titled(html, "<b>", "\"x"),
            "<head><title>b</title><meta name=\"persona\" content=\"x\" /></head>"
        );
        let p = personas("sokka=Sokka,azula=Azula");
        assert_eq!((p[1].unit.as_str(), p[1].name.as_str()), ("azula", "Azula"));
        assert!(personas("").is_empty());
    }

    use super::*;

    #[test]
    fn usage_keeps_the_windows_and_drops_the_rest() {
        let got = limits(concat!(
            "claude  5h      3%  resets Thu Oct 22 23:19\n",
            "        korra 63% (memory 2%) · raava 37% · $10 at API prices\n",
            "codex   2 free full resets unused\n",
            "go      unknown (HTTPError: HTTP Error 401: Unauthorized)\n",
            "claude  week   27%  resets Sun Oct 25 17:59\n",
        ));
        let w = |window: &str, pct, resets: &str| Limit {
            account: "claude".into(),
            window: window.into(),
            pct,
            resets: resets.into(),
        };
        assert_eq!(
            got,
            [
                w("5h", 3, "Thu Oct 22 23:19"),
                w("week", 27, "Sun Oct 25 17:59")
            ]
        );
    }

    #[test]
    fn agents_are_shown_only_when_they_change() {
        let web = Web::new();
        let mut seen = web.shown.subscribe();
        let ada = || ("Ada".to_owned(), "book Cure".to_owned());
        web.agents(vec![ada()]);
        web.aside().agents(vec![ada()]);
        web.agents(vec![ada(), ("Basil".into(), "price flights".into())]);
        web.agents(Vec::new());
        let mut shown = Vec::new();
        while let Ok(Shown::Agents { agents }) = seen.try_recv() {
            shown.push(agents.len());
        }
        assert_eq!(shown, [1, 2, 0]);
    }

    #[test]
    fn a_turns_words_keep_as_one_step_between_calls() {
        let web = Web::new();
        let text = |t: &str| Shown::Step {
            step: Step::Text { text: t.into() },
            agent: None,
        };
        web.sent("web-1", "how big?", None, false);
        for t in ["Let me ", "look."] {
            web.show(text(t));
        }
        web.show(Shown::Step {
            step: Step::Call {
                id: "t1".into(),
                name: "Bash".into(),
                input: Value::Null,
            },
            agent: None,
        });
        for t in ["Big", "."] {
            web.show(text(t));
        }
        let turn = web.turn.lock().unwrap().clone();
        let words: Vec<_> = turn
            .shown
            .iter()
            .filter_map(|s| match s {
                Shown::Step {
                    step: Step::Text { text },
                    ..
                } => Some(text.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!((turn.shown.len(), words), (4, vec!["Let me look.", "Big."]));
    }

    #[test]
    fn one_browser_asking_shuts_out_only_itself() {
        let gate = Gate::default();
        assert!(gate.may_ask("100.64.0.1"));
        assert!(!gate.may_ask("100.64.0.1"));
        assert!(gate.may_ask("100.64.0.2"));
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
