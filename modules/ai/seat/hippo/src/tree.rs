//! The tree: one-line summaries over the log. `node(l, i)` covers messages
//! `[i·2^l, (i+1)·2^l)`; level 0 summarizes one message, each level above
//! merges its two children. Nodes are appended to `tree/YYYY-MM-DD.jsonl`
//! as they are built and never rebuilt; only an index stays in memory.

use crate::store::{append_line, day_files, read_jsonl};
use chrono::{Local, NaiveDate};
use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

/// Target size of one summary line, in bytes.
pub const NODE: usize = 512;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Node {
    pub l: u8,
    pub i: u64,
    pub text: String,
    pub size: u64,
    /// Model that wrote it; empty for a free node (its source fit as is).
    #[serde(default)]
    pub model: String,
    /// Compactor prompt version; empty for a free node.
    #[serde(default)]
    pub prompt: String,
}

#[derive(Clone, Copy)]
struct Slot {
    file: u16,
    off: u64,
    len: u32,
    size: u32,
}

pub struct Tree {
    dir: PathBuf,
    days: Vec<NaiveDate>,
    levels: Vec<Vec<Option<Slot>>>,
    out: Option<(NaiveDate, File, u64)>,
    pub torn: Vec<String>,
}

fn day_name(day: NaiveDate) -> String {
    day.format("%Y-%m-%d.jsonl").to_string()
}

impl Tree {
    pub fn open(store: &Path) -> Result<Tree, String> {
        let dir = store.join("tree");
        std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        let mut tree = Tree {
            days: day_files(&dir)?,
            dir,
            levels: Vec::new(),
            out: None,
            torn: Vec::new(),
        };
        let mut torn = Vec::new();
        for (f, day) in tree.days.clone().into_iter().enumerate() {
            let path = tree.dir.join(day_name(day));
            let mut rows = Vec::new();
            read_jsonl::<Node>(&path, &mut torn, |n, off, len| rows.push((n, off, len)))?;
            for (n, off, len) in rows {
                // A node is written once; should one appear twice, the
                // first stays.
                if !tree.built(n.l, n.i) {
                    tree.set(
                        n.l,
                        n.i,
                        Slot {
                            file: f as u16,
                            off,
                            len,
                            size: n.size as u32,
                        },
                    );
                }
            }
        }
        tree.torn = torn;
        Ok(tree)
    }

    fn set(&mut self, l: u8, i: u64, slot: Slot) {
        let l = l as usize;
        while self.levels.len() <= l {
            self.levels.push(Vec::new());
        }
        let level = &mut self.levels[l];
        if level.len() <= i as usize {
            level.resize(i as usize + 1, None);
        }
        level[i as usize] = Some(slot);
    }

    fn slot(&self, l: u8, i: u64) -> Option<Slot> {
        *self.levels.get(l as usize)?.get(i as usize)?
    }

    pub fn built(&self, l: u8, i: u64) -> bool {
        self.slot(l, i).is_some()
    }

    pub fn size(&self, l: u8, i: u64) -> Option<u64> {
        self.slot(l, i).map(|s| s.size as u64)
    }

    /// Nodes built per level, for status.
    pub fn counts(&self) -> Vec<usize> {
        self.levels
            .iter()
            .map(|lv| lv.iter().filter(|s| s.is_some()).count())
            .collect()
    }

    pub fn get(&self, l: u8, i: u64) -> Result<Option<Node>, String> {
        let Some(s) = self.slot(l, i) else {
            return Ok(None);
        };
        let path = self.dir.join(day_name(self.days[s.file as usize]));
        let mut file = File::open(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        file.seek(SeekFrom::Start(s.off))
            .map_err(|e| e.to_string())?;
        let mut buf = vec![0; s.len as usize];
        file.read_exact(&mut buf).map_err(|e| e.to_string())?;
        serde_json::from_slice(&buf)
            .map(Some)
            .map_err(|e| format!("{}: {e}", path.display()))
    }

    pub fn text(&self, l: u8, i: u64) -> Result<Option<String>, String> {
        Ok(self.get(l, i)?.map(|n| n.text))
    }

    /// Saves a node (one write, fsync). A node already built stays as it is.
    pub fn save(&mut self, node: Node) -> Result<(), String> {
        if self.built(node.l, node.i) {
            return Ok(());
        }
        let day = Local::now().date_naive();
        let day = self.days.last().map_or(day, |&last| day.max(last));
        if self.out.as_ref().is_none_or(|(d, _, _)| *d != day) {
            let path = self.dir.join(day_name(day));
            let file = OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
                .map_err(|e| format!("{}: {e}", path.display()))?;
            let end = file.metadata().map_err(|e| e.to_string())?.len();
            if self.days.last() != Some(&day) {
                self.days.push(day);
            }
            self.out = Some((day, file, end));
        }
        let line = serde_json::to_string(&node).map_err(|e| e.to_string())?;
        let (_, out, end) = self.out.as_mut().unwrap();
        let off = *end;
        append_line(out, &line)?;
        *end += line.len() as u64 + 1;
        let file = self.days.len() as u16 - 1;
        self.set(
            node.l,
            node.i,
            Slot {
                file,
                off,
                len: line.len() as u32 + 1,
                size: node.size as u32,
            },
        );
        Ok(())
    }
}

/// Node `(l, i)` as the view and zoom name it: `id+n`.
pub fn addr(l: u8, i: u64) -> (u64, u64) {
    let n = 1u64 << l;
    (i * n, n)
}

/// A line of text on one line: newlines become spaces.
pub fn flat(text: &str) -> String {
    text.split('\n').collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saves_and_reloads() {
        let dir = std::env::temp_dir().join(format!("hippo-tree-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut t = Tree::open(&dir).unwrap();
        for (l, i, text) in [(0, 0, "a"), (0, 1, "b"), (1, 0, "a b")] {
            t.save(Node {
                l,
                i,
                text: text.into(),
                size: text.len() as u64,
                model: String::new(),
                prompt: String::new(),
            })
            .unwrap();
        }
        let t = Tree::open(&dir).unwrap();
        assert_eq!(t.text(1, 0).unwrap().as_deref(), Some("a b"));
        assert!(t.built(0, 1) && !t.built(1, 1));
        assert_eq!(addr(3, 2), (16, 8));
    }
}
