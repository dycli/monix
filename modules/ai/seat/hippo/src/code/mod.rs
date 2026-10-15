//! Code mode: the memory follows coding agents' transcripts (Claude Code,
//! Codex, Muse Code, OpenCode) instead of being told each message. The agent
//! keeps its own raw context and compaction; hippo records every chat beside
//! it and hands the view back as a rule file.

pub mod live;
pub mod source;
pub mod watcher;

use crate::memory::store::{Store, fmt_date, parse_date};
use chrono::{DateTime, Local};
use live::{Live, Sources};
use std::path::Path;
use watcher::Watcher;

/// What the service runs in code mode: the transcripts it reads and the
/// watcher that turns them into messages.
pub struct Follow {
    pub live: Live,
    pub watcher: Watcher,
}

impl Follow {
    pub fn new(dir: &Path, store: &Store, sources: Sources) -> Result<Follow, String> {
        let watcher = Watcher {
            paseo: Some(sources.paseo.clone()),
            after: live::imported(dir)?.and_then(|i| parse_date(&i.cutoff)),
            ..Watcher::default()
        };
        Ok(Follow {
            live: Live::new(store, sources)?,
            watcher,
        })
    }

    /// Reads whatever the transcripts gained and logs it.
    pub fn step(&mut self, store: &mut Store) -> Result<(), String> {
        self.live.scan(&mut self.watcher, store)?;
        self.watcher.tick(store, Local::now())?;
        self.live.save(&self.watcher)
    }

    /// The status lines only code mode has.
    pub fn status(&self, store: &Store, started: &DateTime<Local>) -> String {
        let mut out = String::new();
        for h in ["claude", "codex", "muse", "opencode"] {
            match store.last.get(h) {
                Some((i, date)) => {
                    let d = DateTime::from_timestamp(*date, 0)
                        .map(|d| fmt_date(&d.with_timezone(&Local)))
                        .unwrap_or_default();
                    out.push_str(&format!("last {h} message: {i} at {d}\n"));
                }
                None => out.push_str(&format!("last {h} message: none\n")),
            }
        }
        let holding = self.watcher.holding();
        if holding.is_empty() {
            out.push_str("holding: nothing\n");
        } else {
            let list: Vec<String> = holding.iter().map(|(c, n)| format!("{c} {n}")).collect();
            out.push_str(&format!("holding: {}\n", list.join(", ")));
        }
        out.push_str(&format!(
            "unparsed entries since {}: {}\n",
            fmt_date(started),
            self.watcher.unparsed_total
        ));
        for u in &self.watcher.unparsed {
            out.push_str(&format!("  {} {}: {}\n", u.harness, u.at, u.what));
        }
        out
    }
}
