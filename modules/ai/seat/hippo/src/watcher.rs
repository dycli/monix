//! Turns harness events into logged turns. Each chat's messages are held
//! until its turn ends, then appended whole, so parallel chats alternate in
//! the log by turn. Time comes from the caller: the wall clock when live,
//! the transcripts' own stamps when replaying archived days.

use crate::mask::mask;
use crate::source::{Event, Item, cap};
use crate::store::{ChatRec, Draft, Kind, OffRec, Store, chat_key, fmt_date};
use chrono::{DateTime, Duration, Local};
use regex::Regex;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

/// A turn is flushed after this many messages even if it runs on.
pub const TURN_MAX: usize = 50;
/// ...or this long after its first held message.
pub const TURN_AGE: Duration = Duration::minutes(10);
/// A turn that ended is flushed once its chat has been quiet this long, so
/// the last blocks of the final reply (written a moment apart) stay in it.
pub const QUIET: Duration = Duration::seconds(2);
/// Chats active within this window are live: their labels must differ.
const LIVE: Duration = Duration::hours(1);

pub const OMITTED: &str = "(hippo output omitted)";

static MARKER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?:^|\s)#(offrecord|amnesia)(?:$|[\s.,;:!?)])").unwrap());

/// The chat marker in a message of the captain's, if any.
pub fn marker(text: &str) -> Option<String> {
    MARKER.captures(text).map(|c| format!("#{}", &c[1]))
}

struct Held {
    draft: Draft,
    /// Byte offset of the transcript line it came from.
    line: Option<u64>,
}

#[derive(Default)]
pub struct Chat {
    harness: String,
    session: String,
    cwd: String,
    title: String,
    foreign: bool,
    off: bool,
    label: Option<String>,
    held: Vec<Held>,
    held_keys: HashSet<String>,
    since: Option<DateTime<Local>>,
    last: Option<DateTime<Local>>,
    ended: bool,
    omit: HashSet<String>,
}

impl Chat {
    /// The earliest transcript offset not yet logged or skipped.
    pub fn held_from(&self) -> Option<u64> {
        self.held.iter().filter_map(|h| h.line).min()
    }

    pub fn held(&self) -> usize {
        self.held.len()
    }
}

#[derive(Clone, Debug)]
pub struct Unparsed {
    pub harness: String,
    pub at: String,
    pub what: String,
}

#[derive(Default)]
pub struct Watcher {
    pub chats: HashMap<String, Chat>,
    pub unparsed: Vec<Unparsed>,
    pub unparsed_total: u64,
    /// Where Paseo keeps its agents, for chat titles.
    pub paseo: Option<PathBuf>,
}

impl Watcher {
    pub fn chat(&self, harness: &str, session: &str) -> Option<&Chat> {
        self.chats.get(&chat_key(harness, session))
    }

    /// Whether this source entry is logged or held: re-reads skip it.
    pub fn known(&self, store: &Store, harness: &str, session: &str, key: &str) -> bool {
        store.seen(key)
            || self
                .chat(harness, session)
                .is_some_and(|c| c.held_keys.contains(key))
    }

    fn entry(&mut self, store: &Store, harness: &str, session: &str) -> &mut Chat {
        let key = chat_key(harness, session);
        self.chats.entry(key.clone()).or_insert_with(|| Chat {
            harness: harness.to_owned(),
            session: session.to_owned(),
            off: store.offrecord.contains_key(&key),
            label: store.chats.get(&key).map(|c| c.chat.clone()),
            ..Chat::default()
        })
    }

    /// Takes one event of a chat. `at` is when its entry was written;
    /// `line` its byte offset in the transcript, if it has one.
    pub fn feed(
        &mut self,
        store: &mut Store,
        harness: &str,
        session: &str,
        line: Option<u64>,
        at: DateTime<Local>,
        ev: Event,
    ) -> Result<(), String> {
        match ev {
            Event::Unparsed(what) => {
                let place = match line {
                    Some(off) => format!("{session} @{off}"),
                    None => session.to_owned(),
                };
                eprintln!("hippo: unparsed {harness} entry at {place}: {what}");
                self.unparsed_total += 1;
                self.unparsed.push(Unparsed {
                    harness: harness.to_owned(),
                    at: place,
                    what,
                });
                if self.unparsed.len() > 20 {
                    self.unparsed.remove(0);
                }
            }
            Event::Info { cwd, title } => {
                let chat = self.entry(store, harness, session);
                if let Some(cwd) = cwd
                    && chat.cwd.is_empty()
                {
                    chat.cwd = cwd;
                }
                if let Some(title) = title.filter(|t| !t.trim().is_empty()) {
                    chat.title = title;
                }
            }
            Event::Foreign => self.entry(store, harness, session).foreign = true,
            Event::TurnEnd => {
                let chat = self.entry(store, harness, session);
                chat.ended = true;
                chat.last = Some(at);
            }
            Event::Item(item) => self.item(store, line, item)?,
        }
        Ok(())
    }

    fn item(&mut self, store: &mut Store, line: Option<u64>, item: Item) -> Result<(), String> {
        let (harness, session) = (item.src.h.clone(), item.src.s.clone());
        let ckey = chat_key(&harness, &session);
        let chat = self.entry(store, &harness, &session);
        chat.last = Some(item.date);
        if chat.foreign || chat.off {
            return Ok(());
        }
        if item.kind == Kind::User
            && let Some(mark) = marker(&item.text)
        {
            // Everything before the marker stays; nothing from it on enters.
            self.flush(store, &ckey)?;
            let chat = self.chats.get_mut(&ckey).unwrap();
            chat.off = true;
            chat.ended = false;
            store.take_off_record(OffRec {
                harness,
                session,
                marker: mark,
                date: fmt_date(&item.date),
            })?;
            return Ok(());
        }
        let key = item.src.key();
        if store.seen(&key) || chat.held_keys.contains(&key) {
            return Ok(());
        }
        if item.opens && !chat.held.is_empty() {
            self.flush(store, &ckey)?;
        }
        let chat = self.chats.get_mut(&ckey).unwrap();
        let mut text = mask(&item.text);
        match item.kind {
            Kind::Tool if item.memory => {
                if let Some(call) = &item.call {
                    chat.omit.insert(call.clone());
                }
            }
            Kind::Echo => {
                if item.call.as_ref().is_some_and(|c| chat.omit.contains(c)) {
                    text = OMITTED.to_owned();
                } else {
                    text = cap(text);
                }
            }
            _ => {}
        }
        chat.ended = false;
        chat.since.get_or_insert(item.date);
        chat.held_keys.insert(key);
        chat.held.push(Held {
            draft: Draft {
                kind: item.kind,
                chat: None,
                text,
                date: item.date,
                src: Some(item.src),
            },
            line,
        });
        if chat.held.len() >= TURN_MAX {
            self.flush(store, &ckey)?;
        }
        Ok(())
    }

    /// Flushes every chat whose turn is due, oldest activity first.
    pub fn tick(&mut self, store: &mut Store, now: DateTime<Local>) -> Result<(), String> {
        let mut due: Vec<(DateTime<Local>, String)> = self
            .chats
            .iter()
            .filter(|(_, c)| !c.held.is_empty())
            .filter(|(_, c)| {
                let quiet = c.last.is_none_or(|l| now - l >= QUIET);
                (c.ended && quiet) || c.since.is_some_and(|s| now - s >= TURN_AGE)
            })
            .map(|(k, c)| (c.last.unwrap_or(now), k.clone()))
            .collect();
        due.sort();
        for (_, key) in due {
            self.flush(store, &key)?;
        }
        Ok(())
    }

    /// Flushes everything held, as at the end of a replay.
    pub fn flush_all(&mut self, store: &mut Store) -> Result<(), String> {
        let mut keys: Vec<(DateTime<Local>, String)> = self
            .chats
            .iter()
            .filter(|(_, c)| !c.held.is_empty())
            .map(|(k, c)| (c.last.unwrap_or_default(), k.clone()))
            .collect();
        keys.sort();
        for (_, key) in keys {
            self.flush(store, &key)?;
        }
        Ok(())
    }

    fn flush(&mut self, store: &mut Store, key: &str) -> Result<(), String> {
        let Some(chat) = self.chats.get(key) else {
            return Ok(());
        };
        if chat.held.is_empty() {
            return Ok(());
        }
        let label = match &chat.label {
            Some(l) => l.clone(),
            None => self.register(store, key)?,
        };
        let chat = self.chats.get_mut(key).unwrap();
        let drafts = chat
            .held
            .iter()
            .map(|h| Draft {
                chat: Some(label.clone()),
                ..h.draft.clone()
            })
            .collect();
        // Held until written: a failed append keeps the turn (and its
        // transcript cursor) for the next try; dedupe skips what did land.
        store.append(drafts)?;
        chat.held.clear();
        chat.held_keys.clear();
        chat.since = None;
        chat.ended = false;
        Ok(())
    }

    fn register(&mut self, store: &mut Store, key: &str) -> Result<String, String> {
        let chat = &self.chats[key];
        let paseo = if chat.title.is_empty() {
            self.paseo
                .as_deref()
                .and_then(|dir| paseo_title(dir, &chat.session))
        } else {
            None
        };
        let title = paseo.unwrap_or_else(|| chat.title.clone());
        let mut label = slug(&title);
        if label.is_empty() {
            label = Path::new(&chat.cwd)
                .file_name()
                .map(|n| n.to_string_lossy().to_lowercase())
                .filter(|n| !n.is_empty())
                .unwrap_or_else(|| chat.harness.clone());
        }
        let now = chat.last.unwrap_or_default();
        let taken = self.chats.iter().any(|(k, c)| {
            k != key
                && c.label.as_deref() == Some(label.as_str())
                && c.last.is_some_and(|l| now - l < LIVE)
        });
        if taken {
            let tail: String = chat
                .session
                .chars()
                .filter(char::is_ascii_alphanumeric)
                .collect();
            label = format!("{label}-{}", &tail[tail.len().saturating_sub(4)..]);
        }
        let first = chat
            .held
            .first()
            .map(|h| fmt_date(&h.draft.date))
            .unwrap_or_default();
        store.register(ChatRec {
            chat: label.clone(),
            harness: chat.harness.clone(),
            session: chat.session.clone(),
            title,
            cwd: chat.cwd.clone(),
            first,
        })?;
        self.chats.get_mut(key).unwrap().label = Some(label.clone());
        Ok(label)
    }

    /// Messages held, per chat label or session, for status.
    pub fn holding(&self) -> Vec<(String, usize)> {
        let mut out: Vec<(String, usize)> = self
            .chats
            .values()
            .filter(|c| !c.held.is_empty())
            .map(|c| {
                let name = c
                    .label
                    .clone()
                    .unwrap_or_else(|| format!("{}:{}", c.harness, c.session));
                (name, c.held.len())
            })
            .collect();
        out.sort();
        out
    }
}

const STOP: &[&str] = &[
    "a", "about", "again", "alright", "am", "an", "and", "any", "are", "as", "at", "be", "but",
    "can", "could", "do", "does", "for", "from", "get", "go", "going", "got", "has", "have", "hey",
    "how", "i", "if", "im", "in", "into", "is", "it", "its", "just", "lets", "like", "look", "me",
    "my", "now", "of", "ok", "okay", "on", "or", "our", "please", "really", "see", "should", "so",
    "some", "that", "the", "then", "there", "this", "to", "up", "us", "wanna", "want", "was", "we",
    "what", "whats", "when", "where", "which", "why", "will", "with", "would", "yeah", "yes",
    "you", "your",
];

/// A short label from a title: its first three words that say something.
pub fn slug(title: &str) -> String {
    let words: Vec<String> = title
        .to_lowercase()
        .replace('\'', "")
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|w| !w.is_empty() && !STOP.contains(w))
        .take(3)
        .map(str::to_owned)
        .collect();
    let mut out = words.join("-");
    out.truncate(28);
    out.trim_end_matches('-').to_owned()
}

/// The title Paseo shows for a session it drives.
pub fn paseo_title(dir: &Path, session: &str) -> Option<String> {
    for project in std::fs::read_dir(dir).ok()?.flatten() {
        for file in std::fs::read_dir(project.path())
            .into_iter()
            .flatten()
            .flatten()
        {
            let Ok(raw) = std::fs::read_to_string(file.path()) else {
                continue;
            };
            if !raw.contains(session) {
                continue;
            }
            let Ok(v) = serde_json::from_str::<Value>(&raw) else {
                continue;
            };
            let ids = ["/persistence/sessionId", "/runtimeInfo/sessionId"];
            if ids
                .iter()
                .any(|p| v.pointer(p).and_then(Value::as_str) == Some(session))
            {
                return v.get("title").and_then(Value::as_str).map(str::to_owned);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markers() {
        assert_eq!(marker("#offrecord"), Some("#offrecord".into()));
        assert_eq!(marker("ok so #amnesia. go"), Some("#amnesia".into()));
        assert_eq!(marker("mention #offrecords"), None);
        assert_eq!(marker("tag#offrecord"), None);
    }

    #[test]
    fn slugs() {
        assert_eq!(
            slug("Look into Victor optchat again. I want to really understand"),
            "victor-optchat-understand"
        );
        assert_eq!(
            slug("alright i wanna see some price quotes for the keyboard"),
            "price-quotes-keyboard"
        );
        assert_eq!(slug(""), "");
    }
}
