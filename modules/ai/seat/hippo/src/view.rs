//! The view: tree nodes that tile the whole log, oldest first, kept under a
//! byte budget. It changes only by appending each new message and merging
//! the most due pairs; once merged a part never splits, so consecutive views
//! share all but their end. Merges come in batches: past the budget the view
//! shrinks to half of it, then grows again, so its head stays the same, and
//! cached, between batches.

use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::tree::{Tree, addr};

/// Budget of the view, in bytes of its lines' text.
pub const VIEW: u64 = 128_000;

/// Budget of the compactions' own view: the same sawtooth, smaller, so they
/// read each other's prefix from the cache.
pub const CONTEXT: u64 = 32_000;

pub const PLACEHOLDER: &str = "(not summarized yet: zoom it)";

#[derive(Default, Clone, Serialize, Deserialize)]
pub struct View {
    /// (level, index) of each part, in order.
    pub parts: Vec<(u8, u64)>,
    /// Messages covered: the log's length when last appended to.
    pub t: u64,
    /// A batch of merges is under way: it went past the budget and has not
    /// yet come down to half of it, held back by unbuilt parents.
    #[serde(default)]
    shrinking: bool,
    #[serde(skip)]
    size: u64,
}

fn part_size(tree: &Tree, (l, i): (u8, u64)) -> u64 {
    tree.size(l, i).unwrap_or(PLACEHOLDER.len() as u64)
}

impl View {
    /// Folds a view from message 0, as at service start.
    pub fn fold(tree: &Tree, t: u64, budget: u64) -> View {
        let mut v = View::default();
        for _ in 0..t {
            v.append(tree, budget);
        }
        v
    }

    /// The next message enters as its own part.
    pub fn append(&mut self, tree: &Tree, budget: u64) {
        let part = (0, self.t);
        self.t += 1;
        self.size += part_size(tree, part);
        self.parts.push(part);
        self.fit(tree, budget);
    }

    /// Once over budget, merges the most due built pairs until the view is
    /// at most half the budget; if unbuilt parents stop it short, it goes on
    /// at each later call. A pair waits for its parent to be built.
    pub fn fit(&mut self, tree: &Tree, budget: u64) {
        // Sizes change when placeholders turn into summaries.
        self.size = self.parts.iter().map(|&p| part_size(tree, p)).sum();
        if self.size > budget {
            self.shrinking = true;
        }
        while self.shrinking {
            if self.size <= budget / 2 {
                self.shrinking = false;
                break;
            }
            // Due: messages since the pair's last one, per message it
            // covers. Ties go to the oldest pair.
            let mut best: Option<(f64, usize)> = None;
            for k in 0..self.parts.len().saturating_sub(1) {
                let (a, b) = (self.parts[k], self.parts[k + 1]);
                if a.0 == b.0 && a.1 % 2 == 0 && b.1 == a.1 + 1 && tree.built(a.0 + 1, a.1 / 2) {
                    let (start, len) = addr(b.0, b.1);
                    let last = start + len - 1;
                    let due = (self.t - 1 - last) as f64 / (1u64 << a.0) as f64;
                    if best.is_none_or(|(d, _)| due > d) {
                        best = Some((due, k));
                    }
                }
            }
            let Some((_, k)) = best else { break };
            let (a, b) = (self.parts[k], self.parts[k + 1]);
            let parent = (a.0 + 1, a.1 / 2);
            self.size =
                self.size - part_size(tree, a) - part_size(tree, b) + part_size(tree, parent);
            self.parts.splice(k..k + 2, [parent]);
        }
    }

    /// First message whose view line is not built, or `t` if all are.
    pub fn first(&self, tree: &Tree) -> u64 {
        self.parts
            .iter()
            .find(|&&(l, i)| !tree.built(l, i))
            .map_or(self.t, |&(l, i)| addr(l, i).0)
    }

    pub fn unbuilt(&self, tree: &Tree) -> usize {
        self.parts
            .iter()
            .filter(|&&(l, i)| !tree.built(l, i))
            .count()
    }

    pub fn size(&self) -> u64 {
        self.size
    }

    /// Loads the view saved as `name` in `dir`, if any and if it fits a log of `len`
    /// messages; else folds it from the start.
    pub fn load(dir: &Path, name: &str, tree: &Tree, len: u64, budget: u64) -> View {
        let saved = fs::read(dir.join(name))
            .ok()
            .and_then(|b| serde_json::from_slice::<View>(&b).ok())
            .filter(|v| v.t <= len && v.tiles());
        let Some(mut v) = saved else {
            return View::fold(tree, len, budget);
        };
        v.fit(tree, budget);
        v
    }

    /// Saves the view as `name` in `dir`, atomically.
    pub fn save(&self, dir: &Path, name: &str) -> Result<(), String> {
        let path = dir.join(name);
        let tmp = path.with_extension("tmp");
        let json = serde_json::to_vec(self).map_err(|e| e.to_string())?;
        fs::write(&tmp, json).map_err(|e| format!("{}: {e}", tmp.display()))?;
        fs::rename(&tmp, &path).map_err(|e| format!("{}: {e}", path.display()))
    }

    /// The parts cover messages 0 to `t` in order, each exactly once.
    fn tiles(&self) -> bool {
        let mut at = 0;
        for &(l, i) in &self.parts {
            let (s, len) = addr(l, i);
            if s != at {
                return false;
            }
            at += len;
        }
        at == self.t
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tree::Node;

    fn node(t: &mut Tree, l: u8, i: u64, size: usize) {
        t.save(Node {
            l,
            i,
            text: "x".repeat(size),
            size: size as u64,
            model: String::new(),
            prompt: String::new(),
        })
        .unwrap();
    }

    #[test]
    fn folds_under_budget_and_never_splits() {
        let dir = std::env::temp_dir().join(format!("hippo-view-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut t = Tree::open(&dir).unwrap();
        let n = 64u64;
        for l in 0..7u8 {
            for i in 0..(n >> l) {
                node(&mut t, l, i, 100);
            }
        }
        let mut v = View::default();
        let mut prev: Vec<(u8, u64)> = Vec::new();
        for _ in 0..n {
            let before = v.parts.len();
            v.append(&t, 1000);
            assert!(v.size() <= 1000);
            // A batch merges down to half the budget, then the view grows.
            if v.parts.len() <= before {
                assert!(v.size() <= 500, "batch stopped at {}", v.size());
            }
            // Every earlier part is still there or inside a coarser one.
            for &(l, i) in &prev {
                let (s, len) = addr(l, i);
                assert!(v.parts.iter().any(|&(pl, pi)| {
                    let (ps, plen) = addr(pl, pi);
                    pl >= l && ps <= s && s + len <= ps + plen
                }));
            }
            prev = v.parts.clone();
        }
        // Parts tile [0, n) in order.
        let mut at = 0;
        for &(l, i) in &v.parts {
            let (s, len) = addr(l, i);
            assert_eq!(s, at);
            at += len;
        }
        assert_eq!(at, n);
        // Detail fades with age: the oldest part is the coarsest.
        assert!(v.parts[0].0 >= v.parts.last().unwrap().0);
        assert_eq!(View::fold(&t, n, 1000).parts, v.parts);
        // Saved and loaded, it carries on as if never stopped.
        v.save(&dir, "view.json").unwrap();
        let mut w = View::load(&dir, "view.json", &t, n, 1000);
        assert_eq!(w.parts, v.parts);
        assert_eq!(w.size(), v.size());
        w.parts.pop();
        w.save(&dir, "view.json").unwrap();
        assert_eq!(
            View::load(&dir, "view.json", &t, n, 1000).parts,
            v.parts,
            "torn view refolded"
        );
    }
}
