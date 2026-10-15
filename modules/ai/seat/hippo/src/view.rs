//! The view: tree nodes that tile the whole log, oldest first, kept under a
//! byte budget. It changes only by appending each new message and merging
//! the most due pairs; once merged a part never splits, so consecutive views
//! share all but their end. Merges come in batches: past the budget the view
//! shrinks to half of it, then grows again, so its head stays the same, and
//! cached, between batches. A reader whose cache is about to go anyway (the
//! seat, before a compaction) asks for a batch early with `batch` (the `fold` command).

use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::tree::{Tree, addr, flat};

/// Budget of the view, in bytes of its lines as rendered, `id+n|` and
/// newline included.
pub const VIEW: u64 = 128_000;

/// Budget of the compactions' own view: the same sawtooth, smaller, so they
/// read each other's prefix from the cache.
pub const CONTEXT: u64 = 32_000;

pub const PLACEHOLDER: &str = "(not summarized yet: zoom it)";

/// Text of an unbuilt node standing for history `bound` cut from the front.
pub const BEYOND: &str = "(older history, past the view's budget: zoom it or search)";

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
    label(l, i) + tree.size(l, i).unwrap_or(PLACEHOLDER.len() as u64)
}

/// Lines for the nodes tiling messages `[0, at)`: each one's summary if
/// built, else `BEYOND`, so `zoom` opens either. They stand for what `cut`
/// leaves out.
pub fn head(tree: &Tree, at: u64) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    for (l, i) in cover(at) {
        let (s, n) = addr(l, i);
        let text = tree.text(l, i)?.map_or(BEYOND.to_owned(), |t| flat(&t));
        out.push(format!("{s}+{n}|{text}"));
    }
    Ok(out)
}

/// The fewest tree nodes tiling messages `[0, end)`, oldest first.
fn cover(end: u64) -> Vec<(u8, u64)> {
    let mut out = Vec::new();
    let mut at = 0;
    for l in (0..64u8).rev() {
        let n = 1u64 << l;
        if end & n != 0 {
            out.push((l, at / n));
            at += n;
        }
    }
    out
}

/// Bytes of a `bound` line for node `(l, i)`, newline included.
fn head_size(tree: &Tree, (l, i): (u8, u64)) -> u64 {
    label(l, i) + tree.size(l, i).unwrap_or(BEYOND.len() as u64)
}

/// Bytes of `id+n|` and the newline.
fn label(l: u8, i: u64) -> u64 {
    let (s, n) = addr(l, i);
    let digits = |x: u64| x.checked_ilog10().unwrap_or(0) as u64 + 1;
    digits(s) + digits(n) + 3
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
            // covers. Ties go to the oldest pair. The most due pair is the
            // one to merge; if its parent is not built yet, the batch waits
            // for it rather than merging a readier pair out of turn, which
            // would fold old history away while the new stays raw.
            let mut best: Option<(f64, usize)> = None;
            for k in 0..self.parts.len().saturating_sub(1) {
                let (a, b) = (self.parts[k], self.parts[k + 1]);
                if a.0 == b.0 && a.1 % 2 == 0 && b.1 == a.1 + 1 {
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
            if !tree.built(parent.0, parent.1) {
                break;
            }
            self.size =
                self.size - part_size(tree, a) - part_size(tree, b) + part_size(tree, parent);
            self.parts.splice(k..k + 2, [parent]);
        }
    }

    /// A batch now, whatever the size: merges down to half the budget as
    /// far as built parents allow, the rest at later appends.
    pub fn batch(&mut self, tree: &Tree, budget: u64) {
        self.shrinking = true;
        self.fit(tree, budget);
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

    /// The message before which the view's parts ending by `end`, rendered,
    /// give way to `head`, so that they stay within `budget`; 0 when they fit
    /// whole. `fit` keeps a view under budget only as far as built parents
    /// allow, so while merges wait (a backlog, a pause) it can grow without
    /// limit. Past the budget the cut moves on until the rest is at most half
    /// of it, then holds at `last` while the view grows back, so successive
    /// renders share their head and read it from the cache.
    pub fn cut(&self, tree: &Tree, budget: u64, last: u64, end: u64) -> u64 {
        let mut sizes: Vec<(u64, u64)> = Vec::new();
        let mut covered = 0;
        for &(l, i) in &self.parts {
            let (s, n) = addr(l, i);
            if s + n > end {
                break;
            }
            sizes.push((s, part_size(tree, (l, i))));
            covered = s + n;
        }
        if sizes.iter().map(|p| p.1).sum::<u64>() <= budget {
            return 0;
        }
        let heads = |at: u64| -> u64 { cover(at).iter().map(|&p| head_size(tree, p)).sum() };
        let at = |k: usize| sizes.get(k).map_or(covered, |p| p.0);
        // A part merged across the last cut goes whole into the head.
        let mut k = sizes
            .iter()
            .position(|p| p.0 >= last)
            .unwrap_or(sizes.len());
        let mut rest: u64 = sizes[k..].iter().map(|p| p.1).sum();
        if rest + heads(at(k)) > budget {
            while k < sizes.len() && rest + heads(at(k)) > budget / 2 {
                rest -= sizes[k].1;
                k += 1;
            }
        }
        at(k)
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

    /// A tree of `n` messages of `size` bytes and their unmerged view.
    fn unmerged(name: &str, n: u64, size: usize) -> (Tree, View) {
        let dir = std::env::temp_dir().join(format!("hippo-view-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut t = Tree::open(&dir).unwrap();
        let mut v = View::default();
        for i in 0..n {
            node(&mut t, 0, i, size);
            v.append(&t, u64::MAX);
        }
        (t, v)
    }

    /// The view's lines from `cut` on, after its head.
    fn rendered(t: &Tree, v: &View, cut: u64) -> Vec<String> {
        let mut out = head(t, cut).unwrap();
        for &(l, i) in &v.parts {
            let (s, n) = addr(l, i);
            if s >= cut {
                out.push(format!("{s}+{n}|{}", t.text(l, i).unwrap().unwrap()));
            }
        }
        out
    }

    #[test]
    fn a_cut_view_fits_and_its_head_zooms() {
        let (mut t, v) = unmerged("cut", 1000, 90);
        assert_eq!(v.cut(&t, 1_000_000, 0, v.t), 0);
        let cut = v.cut(&t, 10_000, 0, v.t);
        let lines = rendered(&t, &v, cut);
        let size: usize = lines.iter().map(|l| l.len() + 1).sum();
        assert!(size <= 10_000, "{size} bytes");
        assert!(lines.last().unwrap().starts_with("999+1|"));
        // The head tiles what was cut with nodes zoom accepts.
        let mut at = 0;
        for line in lines.iter().take_while(|l| l.ends_with(BEYOND)) {
            let (id, n) = line.split_once('|').unwrap().0.split_once('+').unwrap();
            let (id, n): (u64, u64) = (id.parse().unwrap(), n.parse().unwrap());
            assert!(id == at && n.is_power_of_two() && id % n == 0, "{line}");
            at += n;
        }
        assert_eq!(at, cut);
        // A built node shows its summary instead.
        node(&mut t, 9, 0, 300);
        assert_eq!(
            head(&t, cut).unwrap()[0],
            format!("0+512|{}", "x".repeat(300))
        );
        let size: usize = rendered(&t, &v, v.cut(&t, 10_000, 0, v.t))
            .iter()
            .map(|l| l.len() + 1)
            .sum();
        assert!(size <= 10_000, "{size} bytes");
    }

    #[test]
    fn a_cut_holds_while_the_view_grows() {
        let (t, all) = unmerged("hold", 2_000, 220);
        let (budget, mut cut, mut cuts) = (32_000, 0, Vec::new());
        let mut v = View::default();
        for _ in 0..2_000 {
            v.append(&t, u64::MAX);
            let next = v.cut(&t, budget, cut, v.t);
            let size: usize = rendered(&t, &v, next).iter().map(|l| l.len() + 1).sum();
            assert!(size as u64 <= budget, "{size} bytes");
            if next != cut {
                cuts.push(next);
            }
            cut = next;
        }
        // Each cut sheds half the budget: one per ~70 messages, not one each.
        assert!(
            cuts.len() <= 2_000 * 230 / 16_000 + 1,
            "{} cuts",
            cuts.len()
        );
        assert!(cuts.windows(2).all(|w| w[0] < w[1]));
        assert_eq!(all.parts, v.parts);
        // A view that fits again is not cut.
        let small = View::fold(&t, 10, u64::MAX);
        assert_eq!(small.cut(&t, budget, cut, small.t), 0);
    }

    #[test]
    fn a_batch_waits_for_the_due_pair_instead_of_folding_old_history() {
        // A bulk run: the whole log is there before any folding, and the
        // compactor has built the old half's nodes but none of the new.
        let dir = std::env::temp_dir().join(format!("hippo-view-bulk-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut t = Tree::open(&dir).unwrap();
        let n = 64u64;
        for i in 0..n {
            node(&mut t, 0, i, 100);
        }
        for l in 1..6u8 {
            for i in 0..(n >> l) / 2 {
                node(&mut t, l, i, 100);
            }
        }
        let mut v = View::default();
        for _ in 0..n {
            v.append(&t, u64::MAX);
        }
        v.fit(&t, 1000);
        // Merges go by due: the old half's raw pairs, then its first
        // level-1 pair, which ties with the new half's oldest raw pair
        // and wins as the older. The next old pair is less due than that
        // raw one, whose parent is unbuilt, so the batch stops and waits
        // instead of folding the old half to one line.
        assert!(v.shrinking);
        let mut want = vec![(2, 0)];
        want.extend((2..16).map(|i| (1, i)));
        want.extend((32..64).map(|i| (0, i)));
        assert_eq!(v.parts, want);
        // Once the rest is built the batch goes on and ends under half.
        for l in 1..7u8 {
            for i in 0..(n >> l) {
                if !t.built(l, i) {
                    node(&mut t, l, i, 100);
                }
            }
        }
        v.fit(&t, 1000);
        assert!(
            !v.shrinking && v.size() <= 500 && v.tiles(),
            "{:?}",
            v.parts
        );
    }

    #[test]
    fn a_fold_batches_early_and_the_view_grows_again() {
        let dir = std::env::temp_dir().join(format!("hippo-view-fold-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut t = Tree::open(&dir).unwrap();
        let n = 32u64;
        for l in 0..6u8 {
            for i in 0..(n >> l) {
                node(&mut t, l, i, 100);
            }
        }
        let mut v = View::default();
        for _ in 0..n {
            v.append(&t, 10_000);
        }
        // Well under budget, so nothing has merged.
        assert_eq!(v.parts.len(), 32);
        v.batch(&t, 10_000);
        assert!(
            !v.shrinking && v.size() <= 5_000 && v.tiles(),
            "{:?}",
            v.parts
        );
        // The newest end stays the finest: the last parts are still raw.
        assert_eq!(v.parts.last(), Some(&(0, 31)));
        // Afterwards the view grows as before, with no further merging.
        let before = v.parts.len();
        v.append(&t, 10_000);
        assert_eq!(v.parts.len(), before + 1);
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
