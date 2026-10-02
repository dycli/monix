//! Block math for OptMem.

fn cover_at(t: usize, alpha: f64) -> Vec<(usize, usize)> {
    let mut root = 1;
    while root < t {
        root *= 2;
    }
    let mut out = Vec::new();
    let mut stack = vec![(0, root)];
    while let Some((lo, hi)) = stack.pop() {
        if lo >= t {
            continue;
        }
        let size = hi - lo;
        if size > 1 && (hi > t || size as f64 > alpha * (t - lo) as f64) {
            let mid = (lo + hi) / 2;
            stack.push((mid, hi));
            stack.push((lo, mid));
        } else {
            out.push((lo, hi));
        }
    }
    out.sort_unstable();
    out
}

/// The blocks `memo wake` prints: at most `budget`, finest near T.
pub fn cover(t: usize, budget: usize) -> Vec<(usize, usize)> {
    if t == 0 {
        return Vec::new();
    }
    if t <= budget {
        return (0..t).map(|i| (i, i + 1)).collect();
    }
    let (mut lo, mut hi) = (0.0, 1.0);
    for _ in 0..60 {
        let mid = (lo + hi) / 2.0;
        if cover_at(t, mid).len() > budget {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    let mut out = cover_at(t, hi);
    // Spend the leftover budget nearest the present.
    while out.len() < budget {
        let Some(i) = out.iter().rposition(|(lo, hi)| hi - lo > 1) else {
            break;
        };
        let (lo, hi) = out[i];
        let mid = (lo + hi) / 2;
        out.splice(i..=i, [(lo, mid), (mid, hi)]);
    }
    out
}

/// Every block buildable from T memories, smallest first.
#[cfg(test)]
fn complete(t: usize) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut size = 2;
    while size <= t {
        for i in 0..t / size {
            out.push((i * size, (i + 1) * size));
        }
        size *= 2;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::{complete, cover};
    use std::collections::HashSet;

    const WAKE_LINES: usize = 96;

    #[test]
    fn covers_are_aligned_complete_and_finer_toward_present() {
        let mut ts: Vec<_> = (1..400).collect();
        ts.extend([1000, 4096, 10000, 65536, 100003]);
        for t in ts {
            let c = cover(t, WAKE_LINES);
            assert!(c.len() <= WAKE_LINES, "T={t}: {} lines", c.len());
            assert_eq!(c.first().unwrap().0, 0);
            assert_eq!(c.last().unwrap().1, t);
            for pair in c.windows(2) {
                assert_eq!(pair[0].1, pair[1].0, "T={t}");
                assert!(pair[1].1 - pair[1].0 <= pair[0].1 - pair[0].0, "T={t}");
            }
            for (lo, hi) in c {
                let size = hi - lo;
                assert!(size.is_power_of_two() && lo % size == 0, "T={t}");
            }
        }
        assert_eq!(
            cover(300, 320),
            (0..300).map(|i| (i, i + 1)).collect::<Vec<_>>()
        );
    }

    #[test]
    fn every_requested_block_is_buildable() {
        let mut ts: Vec<_> = (1..300).collect();
        ts.extend([512, 700, 1000, 1023, 1024, 2000, 2999]);
        let seen: HashSet<_> = ts
            .into_iter()
            .flat_map(|t| cover(t, WAKE_LINES))
            .filter(|(lo, hi)| hi - lo > 1)
            .collect();
        let buildable: HashSet<_> = complete(3000).into_iter().collect();
        assert!(seen.is_subset(&buildable));
    }

    #[test]
    fn work_never_spikes() {
        let (mut worst, mut prev) = (0, 0);
        for t in 1..2000 {
            let cur = complete(t).len();
            worst = worst.max(cur - prev);
            prev = cur;
        }
        assert!(worst <= 16, "a memory created {worst} naps");
    }
}
