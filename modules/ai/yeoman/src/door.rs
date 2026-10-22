//! A door is where the person talks with the yeoman: a Matrix room today,
//! the web app next. The core answers, reminds and asks for approval
//! through it without knowing which kind it is.

use crate::files::{Library, mime_of};
use crate::hippo::Hippo;
use crate::model::Step;
use crate::pending::Pending;
use crate::{Read, image_type, log_talk};
use chrono::Local;
use std::fs;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

pub trait Door: Clone + Send + Sync + 'static {
    /// A file the person sent, not yet downloaded.
    type File: Send;
    /// Whether the door draws tool results as cards (the calendar's
    /// events), so the answer need not repeat them.
    const CARDS: bool = false;

    /// Sends markdown, returning the message's id.
    fn say(&self, text: &str) -> impl Future<Output = Result<String, String>> + Send;
    /// Sends text word for word, unrendered, returning the message's id:
    /// drafts waiting for approval must show exactly what would go out.
    fn quote(&self, text: &str) -> impl Future<Output = Result<String, String>> + Send;
    /// Reacts to the message `to` with an emoji.
    fn react(&self, to: &str, emoji: &str) -> impl Future<Output = Result<(), String>> + Send;
    /// Sends a picture of type `mime`, kept as `name`.
    fn picture(
        &self,
        name: &str,
        data: Vec<u8>,
        mime: &'static str,
    ) -> impl Future<Output = Result<(), String>> + Send;
    /// Sends a file the yeoman kept as `name`, for the person to save.
    fn file(
        &self,
        name: &str,
        data: Vec<u8>,
        mime: &str,
    ) -> impl Future<Output = Result<(), String>> + Send;
    fn typing(&self, on: bool) -> impl Future<Output = ()> + Send;
    /// Shows a tool call or its result while the answer is being worked
    /// out. Called from the model's reader thread, so it must not block.
    fn step(&self, _step: Step) {}

    /// Who answers the seat's questions here, when the door can show them.
    fn asker(&self) -> Option<std::sync::Arc<dyn crate::model::Asker>> {
        None
    }
    /// The same for subagent `agent`, at work apart from any turn.
    fn agent_step(&self, _agent: &str, _step: Step) {}
    /// The subagents at work, by name, with their tasks. Called on every
    /// tick, so a door shows only what changed.
    fn agents(&self, _now: Vec<(String, String)>) {}
    /// Shows an act waiting for the person's word, returning the id a
    /// verdict on it answers. Matrix shows the draft word for word.
    fn ask(&self, p: &Pending) -> impl Future<Output = Result<String, String>> + Send {
        let text = p.act.show();
        async move { self.quote(&text).await }
    }
    /// Says how a verdict on `p` came out; `done` is false when the act
    /// failed and still waits.
    fn settle(
        &self,
        _p: &Pending,
        outcome: &str,
        _done: bool,
    ) -> impl Future<Output = Result<(), String>> + Send {
        let text = outcome.to_owned();
        async move { self.quote(&text).await.map(|_| ()) }
    }
    /// Downloads a file the person sent, whole. Errors are what to tell
    /// the person.
    fn fetch(&self, file: &Self::File) -> impl Future<Output = Result<Fetched, String>> + Send;
}

/// What the person sent: words, and maybe a file.
pub struct Message<D: Door> {
    /// The message, for a reaction to it.
    pub id: String,
    pub text: String,
    pub files: Vec<D::File>,
}

/// Shows "typing" until dropped. A Matrix typing notice lapses after 4 s
/// and matrix-sdk resends one only after 3 s, so asking twice a second
/// keeps it up without extra requests.
pub struct Typing<D: Door> {
    door: D,
    beat: tokio::task::JoinHandle<()>,
}

impl<D: Door> Typing<D> {
    pub fn start(door: &D) -> Self {
        let d = door.clone();
        let beat = tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_millis(500));
            loop {
                tick.tick().await;
                d.typing(true).await;
            }
        });
        Self {
            door: door.clone(),
            beat,
        }
    }

    pub async fn stop(mut self) {
        self.beat.abort();
        // A beat already running on another thread would otherwise land
        // its "on" after this "off" and leave the page typing.
        let _ = (&mut self.beat).await;
        self.door.typing(false).await;
    }
}

impl<D: Door> Drop for Typing<D> {
    fn drop(&mut self) {
        self.beat.abort();
    }
}

/// A file the person sent: its name, whether it came as a photo, its
/// bytes, and what the model will see of it, if it can read it at all.
pub struct Fetched {
    pub name: String,
    pub photo: bool,
    pub data: Vec<u8>,
    pub read: Option<Read>,
}

/// Sends what the turn left in the outbox, oldest first, deleting each
/// once sent; one that fails stays for the next answer. `make_image`
/// leaves `<stamp>.png` (ChatGPT) or `.jpg` (Grok), kept as a picture
/// first; `send_file` leaves `<stamp>-<name>`, a kept file sent by its
/// name. hippo logs each as "(sent a picture: name)" or "(sent a file:
/// name)", as it logs what the person sends, so the page shows it again
/// after a reload and a later turn knows it by name.
pub async fn send_outbox(door: &impl Door, hippo: &Arc<Hippo>, state: &Path) {
    let outbox = state.join("outbox");
    let Ok(dir) = fs::read_dir(&outbox) else {
        return;
    };
    let mut files: Vec<PathBuf> = dir
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.is_file())
        .collect();
    files.sort();
    for path in files {
        let named = path
            .file_name()
            .and_then(|n| n.to_str())
            .and_then(|n| n.split_once('-'))
            .map(|(_, name)| name.to_owned());
        let sent = match (fs::read(&path), named) {
            (Ok(data), Some(name)) => {
                let mime = mime_of(&name, &data);
                door.file(&name, data, &mime)
                    .await
                    .map(|()| format!("(sent a file: {name})"))
            }
            (Ok(data), None) => match image_type(&data) {
                Some(mime) => {
                    let ext = mime.trim_start_matches("image/").replace("jpeg", "jpg");
                    let called = format!("picture {}.{ext}", Local::now().format("%Y-%m-%d %H.%M"));
                    match Library::new(state).keep(&called, &data) {
                        Ok(name) => door
                            .picture(&name, data, mime)
                            .await
                            .map(|()| format!("(sent a picture: {name})")),
                        Err(e) => Err(e.to_string()),
                    }
                }
                None => Err("not an image".into()),
            },
            (Err(e), _) => Err(e.to_string()),
        };
        match sent {
            Ok(line) => {
                let _ = fs::remove_file(&path);
                log_talk(hippo, line).await;
            }
            Err(e) => eprintln!("yeoman: outbox {}: {e}", path.display()),
        }
    }
}
