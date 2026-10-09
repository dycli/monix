//! Sokka's book: the reminders and lists its tools keep, one JSON file in
//! its state directory. The tool server (one per model call) and the bot
//! both change it, so every change holds an exclusive lock and lands by
//! rename.

use chrono::{Days, Months, NaiveDateTime};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::ErrorKind;
use std::path::Path;

#[derive(Serialize, Deserialize, Default)]
pub struct Book {
    #[serde(default)]
    pub reminders: Vec<Reminder>,
    #[serde(default)]
    pub lists: BTreeMap<String, Vec<String>>,
    #[serde(default)]
    pub next_id: u64,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Reminder {
    pub id: u64,
    /// Local time.
    pub at: NaiveDateTime,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repeat: Option<Repeat>,
    /// A routine: at `at`, Sokka carries out `text` as a request and sends
    /// its answer, instead of sending `text` itself.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub ask: bool,
}

#[derive(Serialize, Deserialize, JsonSchema, Clone, Copy)]
#[serde(rename_all = "lowercase")]
pub enum Repeat {
    Daily,
    Weekly,
    Monthly,
}

impl Repeat {
    fn after(self, t: NaiveDateTime) -> NaiveDateTime {
        match self {
            Repeat::Daily => t + Days::new(1),
            Repeat::Weekly => t + Days::new(7),
            Repeat::Monthly => t + Months::new(1),
        }
    }
}

/// Runs `f` on the book under the lock and saves what it leaves.
pub fn change<T>(dir: &Path, f: impl FnOnce(&mut Book) -> T) -> Result<T, String> {
    let lock = File::create(dir.join("book.lock")).map_err(|e| format!("book lock: {e}"))?;
    lock.lock().map_err(|e| format!("book lock: {e}"))?;
    let path = dir.join("book.json");
    let mut book = match fs::read(&path) {
        Ok(b) => serde_json::from_slice(&b).map_err(|e| format!("book: {e}"))?,
        Err(e) if e.kind() == ErrorKind::NotFound => Book::default(),
        Err(e) => return Err(format!("book: {e}")),
    };
    let out = f(&mut book);
    let tmp = dir.join("book.json.tmp");
    let json = serde_json::to_vec_pretty(&book).map_err(|e| e.to_string())?;
    fs::write(&tmp, json)
        .and_then(|()| fs::rename(&tmp, &path))
        .map_err(|e| format!("book: {e}"))?;
    Ok(out)
}

impl Book {
    pub fn remind(
        &mut self,
        at: NaiveDateTime,
        text: String,
        repeat: Option<Repeat>,
        ask: bool,
    ) -> u64 {
        self.next_id += 1;
        let id = self.next_id;
        self.reminders.push(Reminder {
            id,
            at,
            text,
            repeat,
            ask,
        });
        self.reminders.sort_by_key(|r| r.at);
        id
    }

    /// Takes the reminders due by `now`: one-offs leave the book, repeats
    /// move to their next time after `now`, so a missed stretch fires once.
    pub fn due(&mut self, now: NaiveDateTime) -> Vec<Reminder> {
        let mut due = Vec::new();
        self.reminders.retain_mut(|r| {
            if r.at > now {
                return true;
            }
            due.push(r.clone());
            match r.repeat {
                Some(rep) => {
                    while r.at <= now {
                        r.at = rep.after(r.at);
                    }
                    true
                }
                None => false,
            }
        });
        self.reminders.sort_by_key(|r| r.at);
        due
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(s: &str) -> NaiveDateTime {
        NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M").unwrap()
    }

    #[test]
    fn due_drops_one_offs_and_moves_repeats_past_now() {
        let mut b = Book::default();
        b.remind(t("2026-10-08 09:00"), "once".into(), None, false);
        b.remind(
            t("2026-10-01 18:00"),
            "weekly".into(),
            Some(Repeat::Weekly),
            true,
        );
        b.remind(t("2026-10-09 09:00"), "later".into(), None, false);
        let due = b.due(t("2026-10-08 12:00"));
        assert_eq!(due.len(), 2);
        assert_eq!(b.reminders.len(), 2);
        assert_eq!(b.reminders[0].at, t("2026-10-08 18:00"));
        assert!(b.reminders[0].ask && due[0].ask && !due[1].ask);
        assert!(b.due(t("2026-10-08 12:01")).is_empty());
    }

    #[test]
    fn change_persists_under_the_lock() {
        let dir = std::env::temp_dir().join(format!("sokka-book-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        change(&dir, |b| {
            b.lists.insert("groceries".into(), vec!["milk".into()])
        })
        .unwrap();
        let n = change(&dir, |b| b.lists["groceries"].len()).unwrap();
        assert_eq!(n, 1);
        fs::remove_dir_all(&dir).unwrap();
    }
}
