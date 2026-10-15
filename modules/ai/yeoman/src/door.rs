//! A door is where the person talks with the yeoman: a Matrix room today,
//! the web app next. The core answers, reminds and asks for approval
//! through it without knowing which kind it is.

use crate::Read;
use crate::model::Step;
use std::fs;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub trait Door: Clone + Send + Sync + 'static {
    /// A file the person sent, not yet downloaded.
    type File: Send;

    /// Sends markdown, returning the message's id.
    fn say(&self, text: &str) -> impl Future<Output = Result<String, String>> + Send;
    /// Sends text word for word, unrendered, returning the message's id:
    /// drafts waiting for approval must show exactly what would go out.
    fn quote(&self, text: &str) -> impl Future<Output = Result<String, String>> + Send;
    /// Reacts to the message `to` with an emoji.
    fn react(&self, to: &str, emoji: &str) -> impl Future<Output = Result<(), String>> + Send;
    fn picture(&self, png: Vec<u8>) -> impl Future<Output = Result<(), String>> + Send;
    fn typing(&self, on: bool) -> impl Future<Output = ()> + Send;
    /// Shows a tool call or its result while the answer is being worked
    /// out. Called from the model's reader thread, so it must not block.
    fn step(&self, _step: Step) {}
    /// Downloads a file the person sent: its name, whether it is a photo,
    /// and what the model will see. Errors are what to tell the person.
    fn fetch(
        &self,
        file: &Self::File,
    ) -> impl Future<Output = Result<(String, bool, Read), String>> + Send;
}

/// What the person sent: words, and maybe a file.
pub struct Message<D: Door> {
    /// The message, for a reaction to it.
    pub id: String,
    pub text: String,
    pub file: Option<D::File>,
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

    pub async fn stop(self) {
        self.beat.abort();
        self.door.typing(false).await;
    }
}

impl<D: Door> Drop for Typing<D> {
    fn drop(&mut self) {
        self.beat.abort();
    }
}

/// Sends the pictures `make_image` left in the outbox, oldest first,
/// deleting each once sent; one that fails stays for the next answer.
pub async fn send_images(door: &impl Door, outbox: &Path) {
    let Ok(dir) = fs::read_dir(outbox) else {
        return;
    };
    let mut files: Vec<PathBuf> = dir
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "png"))
        .collect();
    files.sort();
    for path in files {
        let sent = match fs::read(&path) {
            Ok(data) => door.picture(data).await,
            Err(e) => Err(e.to_string()),
        };
        match sent {
            Ok(()) => {
                let _ = fs::remove_file(&path);
            }
            Err(e) => eprintln!("yeoman: picture {}: {e}", path.display()),
        }
    }
}
