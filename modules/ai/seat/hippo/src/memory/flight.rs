//! Single flight, after UniiChat's `AskAI.wait`. Compactor calls running at
//! once share most of their context; each would write that shared prefix
//! to Anthropic's cache, since an entry serves only once its writer's
//! response has begun. So a call whose longest cached prefix is still being
//! written waits for that writer to begin, then reads it; a call whose
//! whole prefix is not cached leads, writing it while later calls wait.

use std::collections::{HashMap, VecDeque};
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
/// How long a lapsed entry, and a past request's keys, stay on record for
/// `probe`, which explains each call's cache misses.
const RECORD: Duration = Duration::from_secs(3600);

enum Entry {
    /// Its leader's response has not begun; the number tells leaders apart.
    Writing(u64),
    Until(Instant),
}

/// The prefixes one backend's calls have cached, or are caching.
pub struct Flights {
    map: Mutex<(HashMap<u64, Entry>, u64)>,
    cv: Condvar,
    /// The keys of recent requests, newest last, for `probe`.
    recent: Mutex<VecDeque<(Instant, Vec<u64>)>>,
    ttl: Duration,
}

impl Default for Flights {
    fn default() -> Self {
        Self::with_ttl(TTL)
    }
}

/// What the cache should hold for a call, by this backend's own record, in
/// blocks of its context: a call's misses traced to their cause. Anthropic
/// reading less than `hit` means its cache works otherwise than modelled
/// here; a `hit` short of the whole context is a cause in the rules.
#[derive(Debug, Default, PartialEq)]
pub struct Probe {
    /// Blocks it should read: the longest live entry within `LOOK` blocks.
    pub hit: usize,
    /// The longest live entry further back than Anthropic looks.
    pub beyond: usize,
    /// The longest entry that lapsed within the last hour.
    pub lapsed: usize,
    /// The most blocks it shares with any request of the last five minutes:
    /// more than `hit` when only longer contexts held them.
    pub shared: usize,
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
    pub fn with_ttl(ttl: Duration) -> Self {
        Self {
            map: Mutex::default(),
            cv: Condvar::new(),
            recent: Mutex::default(),
            ttl,
        }
    }

    /// What the cache should hold for `keys`, before the call waits or
    /// leads; records the call's keys for the probes after it.
    pub fn probe(&self, keys: &[u64]) -> Probe {
        let now = Instant::now();
        let mut p = Probe::default();
        {
            let guard = self.map.lock().unwrap();
            let from = keys.len().saturating_sub(LOOK);
            for (k, key) in keys.iter().enumerate() {
                match guard.0.get(key) {
                    Some(Entry::Writing(_)) => p.hit = p.hit.max(k + 1),
                    Some(Entry::Until(t)) if *t > now => {
                        if k >= from {
                            p.hit = p.hit.max(k + 1)
                        } else {
                            p.beyond = p.beyond.max(k + 1)
                        }
                    }
                    Some(Entry::Until(_)) => p.lapsed = p.lapsed.max(k + 1),
                    None => {}
                }
            }
        }
        let mut recent = self.recent.lock().unwrap();
        while recent.front().is_some_and(|(t, _)| now - *t > RECORD) {
            recent.pop_front();
        }
        p.shared = recent
            .iter()
            .filter(|(t, _)| now - *t < self.ttl)
            .map(|(_, k)| k.iter().zip(keys).take_while(|(a, b)| a == b).count())
            .max()
            .unwrap_or(0);
        recent.push_back((now, keys.to_vec()));
        p
    }

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
                    *t = now + self.ttl;
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
            // Lapsed entries stay a while on record, for `probe`.
            map.retain(|_, e| match e {
                Entry::Writing(_) => true,
                Entry::Until(t) => *t + RECORD > now,
            });
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
                guard.0.insert(key, Entry::Until(Instant::now() + self.ttl));
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
    fn a_probe_names_what_the_cache_holds() {
        let flights = Arc::new(Flights::default());
        let (short, long) = (keys(&context(40), 4), keys(&context(48), 4));
        assert_eq!(flights.probe(&long), Probe::default());
        flights.wait(&long).begun()();
        // The shorter context shares all its blocks but no entry ends there.
        let p = flights.probe(&short);
        assert_eq!((p.hit, p.shared), (0, 10));
        assert_eq!(flights.probe(&long).hit, 12);
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
