//! A read fetched at most once per freshness window and kept through an
//! outage, the contract hob's modules follow (dycli/hob, core.rs).

use std::sync::Mutex;
use std::time::{Duration, Instant};

pub struct Cached<T> {
    fresh: Duration,
    held: Mutex<Option<(Instant, T)>>,
}

impl<T: Clone> Cached<T> {
    pub fn new(fresh: Duration) -> Self {
        Self {
            fresh,
            held: Mutex::new(None),
        }
    }

    /// The held answer while fresh, else a new one; when the fetch fails,
    /// the last good answer however old, or the failure if there is none.
    pub fn get(&self, fetch: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
        let mut held = self.held.lock().expect("cache");
        if let Some((at, v)) = held.as_ref()
            && at.elapsed() < self.fresh
        {
            return Ok(v.clone());
        }
        match fetch() {
            Ok(v) => {
                *held = Some((Instant::now(), v.clone()));
                Ok(v)
            }
            Err(e) => held.as_ref().map(|(_, v)| v.clone()).ok_or(e),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_failure_keeps_the_last_good_answer() {
        let c = Cached::new(Duration::ZERO);
        assert!(c.get(|| Err::<u8, _>("down".into())).is_err());
        assert_eq!(c.get(|| Ok(7)).unwrap(), 7);
        assert_eq!(c.get(|| Err("down".into())).unwrap(), 7);
    }
}
