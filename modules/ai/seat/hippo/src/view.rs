//! The view: tree nodes that tile the whole log, oldest first, kept under a
//! byte budget. It changes only by appending each new message and merging
//! the most due pair; once merged a part never splits, so consecutive views
//! share all but their end.

use crate::tree::{Tree, addr};

/// Budget of the view, in bytes of its lines' text.
pub const VIEW: u64 = 128_000;

pub const PLACEHOLDER: &str = "(not summarized yet: zoom it)";

#[derive(Default, Clone)]
pub struct View {
    /// (level, index) of each part, in order.
    pub parts: Vec<(u8, u64)>,
    /// Messages covered: the log's length when last appended to.
    pub t: u64,
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

    /// Merges the most due built pair while over budget. A pair waits for
    /// its parent to be built.
    pub fn fit(&mut self, tree: &Tree, budget: u64) {
        // Sizes change when placeholders turn into summaries.
        self.size = self.parts.iter().map(|&p| part_size(tree, p)).sum();
        while self.size > budget {
            let mut best: Option<(f64, usize)> = None;
            for k in 0..self.parts.len().saturating_sub(1) {
                let (a, b) = (self.parts[k], self.parts[k + 1]);
                if a.0 == b.0 && a.1 % 2 == 0 && b.1 == a.1 + 1 && tree.built(a.0 + 1, a.1 / 2) {
                    let start = addr(a.0, a.1).0;
                    let due = (self.t - start) as f64 / (1u64 << (a.0 + 2)) as f64;
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
            v.append(&t, 1000);
            assert!(v.size() <= 1000);
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
    }
}
