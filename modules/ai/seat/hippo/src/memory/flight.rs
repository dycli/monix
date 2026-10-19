//! Single flight, after UniiChat's `AskAI.wait`. Compactor calls running at
//! once share most of their context; each would write that shared prefix
//! to Anthropic's cache, since an entry serves only once its writer's
//! response has begun. So a call whose longest cached prefix is still being
//! written waits for that writer to begin, then reads it; a call whose
//! whole prefix is not cached leads, writing it while later calls wait.

use std::collections::HashMap;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

/// Blocks Anthropic walks back from a mark looking for an entry.
pub const LOOK: usize = 20;
/// How long an entry lives past its last use: the five-minute cache.
pub const TTL: Duration = Duration::from_secs(300);
/// Longest wait on a leader. One whose response has not begun by then is
/// likely stuck, and going ahead costs a cache write, not a stall.
const PATIENCE: Duration = Duration::from_secs(60);

enum Entry {
    /// Its leader's response has not begun; the number tells leaders apart.
    Writing(u64),
    Until(Instant),
}

/// The prefixes one backend's calls have cached, or are caching.
#[derive(Default)]
pub struct Flights {
    map: Mutex<(HashMap<u64, Entry>, u64)>,
    cv: Condvar,
}

/// A call's place in single flight: when it leads, the prefix it writes.
pub struct Flight {
    flights: Arc<Flights>,
    lead: Option<(u64, u64)>,
}

/// Keys of a context's prefix at each whole block of `block` lines: each
/// block's hash chained from the one before, so a key names its prefix.
pub fn keys(context: &str, block: usize) -> Vec<u64> {
    let lines: Vec<&str> = context.split_inclusive('\n').collect();
    let mut key = 0u64;
    lines
        .chunks(block)
        .take(lines.len() / block)
        .map(|chunk| {
            let mut h = DefaultHasher::new();
            key.hash(&mut h);
            chunk.hash(&mut h);
            key = h.finish();
            key
        })
        .collect()
}

impl Flights {
    /// Waits while a leader writes the longest prefix of `keys` it could
    /// read; then leads, unless the whole prefix is cached.
    pub fn wait(self: &Arc<Self>, keys: &[u64]) -> Flight {
        let none = Flight {
            flights: self.clone(),
            lead: None,
        };
        let Some(&last) = keys.last() else {
            return none;
        };
        let start = Instant::now();
        let mut guard = self.map.lock().unwrap();
        loop {
            let now = Instant::now();
            let (map, round) = &mut *guard;
            let live = |e: &Entry| match e {
                Entry::Writing(_) => true,
                Entry::Until(t) => *t > now,
            };
            let from = keys.len().saturating_sub(LOOK);
            let k = (from..keys.len())
                .rev()
                .find(|&k| map.get(&keys[k]).is_some_and(live));
            let writing = match k.map(|k| map.get_mut(&keys[k]).unwrap()) {
                Some(Entry::Writing(_)) => true,
                Some(Entry::Until(t)) => {
                    *t = now + TTL;
                    false
                }
                None => false,
            };
            if writing && start.elapsed() < PATIENCE {
                let left = PATIENCE - start.elapsed();
                guard = self.cv.wait_timeout(guard, left).unwrap().0;
                continue;
            }
            if !writing && k == Some(keys.len() - 1) {
                return none;
            }
            map.retain(|_, e| live(e));
            *round += 1;
            map.insert(last, Entry::Writing(*round));
            return Flight {
                flights: self.clone(),
                lead: Some((last, *round)),
            };
        }
    }
}

impl Flight {
    /// Whether this call writes its prefix, rather than reading it whole.
    pub fn leads(&self) -> bool {
        self.lead.is_some()
    }

    /// What to call once the response begins: the prefix then serves.
    pub fn begun(&self) -> impl FnOnce() + Send + 'static {
        let (flights, lead) = (self.flights.clone(), self.lead);
        move || flights.settle(lead, true)
    }
}

impl Flights {
    fn settle(&self, lead: Option<(u64, u64)>, written: bool) {
        let Some((key, round)) = lead else { return };
        let mut guard = self.map.lock().unwrap();
        if matches!(guard.0.get(&key), Some(Entry::Writing(g)) if *g == round) {
            if written {
                guard.0.insert(key, Entry::Until(Instant::now() + TTL));
            } else {
                guard.0.remove(&key);
            }
            self.cv.notify_all();
        }
    }
}

/// A call that ends without its response beginning wrote nothing: the next
/// waiter leads.
impl Drop for Flight {
    fn drop(&mut self) {
        self.flights.settle(self.lead, false);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    fn context(n: usize) -> String {
        (0..n).map(|k| format!("{k}+1|line {k}\n")).collect()
    }

    #[test]
    fn keys_name_whole_blocks_of_a_prefix() {
        let (a, b) = (keys(&context(10), 4), keys(&context(13), 4));
        assert_eq!(a.len(), 2);
        assert_eq!(b.len(), 3);
        assert_eq!(a[..], b[..2]);
        assert_ne!(keys(&context(8), 4), keys(&context(8).replace("7", "x"), 4));
    }

    #[test]
    fn a_call_waits_for_the_leader_to_begin_then_reads() {
        let flights = Arc::new(Flights::default());
        let (short, long) = (keys(&context(40), 4), keys(&context(48), 4));
        let lead = flights.wait(&short);
        assert!(lead.lead.is_some());
        let f = flights.clone();
        let waiter = thread::spawn(move || {
            let at = Instant::now();
            let flight = f.wait(&long);
            (at.elapsed(), flight.lead.is_some())
        });
        thread::sleep(Duration::from_millis(100));
        lead.begun()();
        let (waited, leads) = waiter.join().unwrap();
        assert!(waited >= Duration::from_millis(90));
        // It leads its own longer prefix, reading the shared part.
        assert!(leads);
        // The same prefix again is cached whole: no lead, no wait.
        assert!(flights.wait(&short).lead.is_none());
    }

    #[test]
    fn a_leader_that_fails_hands_the_lead_on() {
        let flights = Arc::new(Flights::default());
        let k = keys(&context(8), 4);
        let lead = flights.wait(&k);
        let f = flights.clone();
        let k2 = k.clone();
        let waiter = thread::spawn(move || f.wait(&k2).lead.is_some());
        thread::sleep(Duration::from_millis(50));
        drop(lead);
        assert!(waiter.join().unwrap());
    }

    #[test]
    fn prefixes_beyond_the_lookback_are_not_waited_for() {
        let flights = Arc::new(Flights::default());
        let _lead = flights.wait(&keys(&context(4), 4));
        // 25 blocks: the leader's one block is past the 20 Anthropic checks.
        let far = flights.wait(&keys(&context(100), 4));
        assert!(far.lead.is_some());
    }
}
