//! The pump: builds tree nodes in Taelin's strict order. A node starts when
//! it is not built or running, its sources exist, and every view line
//! before its end is a summary; so messages are compressed one at a time,
//! in order, while merges of finished parts run beside them.

use crate::memory::compact::{self, Fail, PROMPT_VERSION, Step, Usage, cut};
use crate::memory::server::{Core, Shared};
use crate::memory::store::Msg;
use crate::memory::tree::{NODE, Node, addr, flat};
use crate::memory::view::head;
use chrono::{DateTime, Local};
use std::collections::HashSet;
use std::sync::Arc;
use std::thread;

/// Compactor calls running at once.
pub const JOBS: usize = 8;
/// Wait on a limit that gives no reset time.
const LIMIT_WAIT: i64 = 300;

/// Compactor calls and tokens per local day, kept in `state/usage.jsonl`.
#[derive(Default)]
pub struct Spent {
    pub days: std::collections::BTreeMap<chrono::NaiveDate, (u64, Usage)>,
    path: Option<std::path::PathBuf>,
}

#[derive(serde::Serialize, serde::Deserialize)]
struct Spend {
    date: String,
    l: u8,
    i: u64,
    model: String,
    #[serde(flatten)]
    usage: Usage,
}

impl Spent {
    pub fn load(store: &std::path::Path) -> Result<Spent, String> {
        let path = store.join("state/usage.jsonl");
        let mut spent = Spent {
            days: Default::default(),
            path: Some(path.clone()),
        };
        let mut torn = Vec::new();
        crate::memory::store::read_jsonl::<Spend>(&path, &mut torn, |s, _, _| {
            if let Some(d) = crate::memory::store::parse_date(&s.date) {
                let day = spent.days.entry(d.date_naive()).or_default();
                day.0 += 1;
                day.1.add(s.usage);
            }
        })?;
        Ok(spent)
    }

    fn record(&mut self, l: u8, i: u64, model: &str, usage: Usage) {
        // Also one journal line per call, where `usage` counts each
        // assistant's share of the subscriptions.
        eprintln!(
            "hippo: tokens model={model} input={} cache_read={} cache_write={} output={}",
            usage.input, usage.cache_read, usage.cache_write, usage.output
        );
        let now = Local::now();
        let day = self.days.entry(now.date_naive()).or_default();
        day.0 += 1;
        day.1.add(usage);
        let Some(path) = &self.path else { return };
        let line = Spend {
            date: crate::memory::store::fmt_date(&now),
            l,
            i,
            model: model.to_owned(),
            usage,
        };
        let written = serde_json::to_string(&line)
            .map_err(|e| e.to_string())
            .and_then(|line| {
                let mut f = std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(path)
                    .map_err(|e| e.to_string())?;
                crate::memory::store::append_line(&mut f, &line)
            });
        if let Err(e) = written {
            eprintln!("hippo: recording usage: {e}");
        }
    }
}

#[derive(Default)]
pub struct Pump {
    pub spent: Spent,
    pub busy: std::collections::HashSet<(u8, u64)>,
    /// First failure of each node still failing.
    pub failed: std::collections::BTreeMap<(u8, u64), String>,
    /// Nodes that failed since the last message; a failed call is tried
    /// again at the next message.
    pub parked: HashSet<(u8, u64)>,
    /// Messages when `parked` was last cleared.
    pub t: u64,
    pub limit: Option<DateTime<Local>>,
    /// Lowest index per level that may still be unbuilt.
    pub lo: Vec<u64>,
}

/// `hippo pause` leaves this file; while it exists no model call starts.
/// Logging goes on, and the pause outlives restarts.
pub fn pause_file(store: &std::path::Path) -> std::path::PathBuf {
    store.join("state/paused")
}

pub fn paused(store: &std::path::Path) -> bool {
    pause_file(store).exists()
}

/// What a level-0 node is built from.
fn message(c: &Core, i: u64) -> Result<Msg, String> {
    c.store.get(i)
}

/// The compactions' view up to `end` (exclusive), as `id+n|text` lines,
/// never over the context budget. None until all of it is built.
fn context(c: &mut Core, end: u64) -> Result<Option<Vec<String>>, String> {
    // Calls work at the frontier of what is summarized, behind any backlog,
    // so the cut is measured up to it, not to the newest message.
    let frontier = c.view.first(&c.tree).max(end);
    c.context_cut = c
        .context
        .cut(&c.tree, c.context_budget(), c.context_cut, frontier);
    let cut = c.context_cut;
    let mut out = head(&c.tree, cut.min(end))?;
    for &(l, i) in &c.context.parts {
        let (s, n) = addr(l, i);
        if s + n > end {
            break;
        }
        if s < cut {
            continue;
        }
        match c.tree.text(l, i)? {
            Some(t) => out.push(format!("{s}+{n}|{}", flat(&t))),
            None => return Ok(None),
        }
    }
    Ok(Some(out))
}

enum Job {
    Free(String),
    Call {
        context: Vec<String>,
        a: String,
        /// The second line of a merge, and whether the two share no chat.
        b: Option<(String, bool)>,
    },
}

/// Whether the messages `[s, s + n)` and the next `n` share no chat. Only
/// said when both halves come from known chats.
fn apart(c: &Core, s: u64, n: u64) -> bool {
    let chats =
        |r: std::ops::Range<u64>| -> HashSet<&str> { r.filter_map(|i| c.store.chat(i)).collect() };
    let (a, b) = (chats(s..s + n), chats(s + n..s + 2 * n));
    !a.is_empty() && !b.is_empty() && a.is_disjoint(&b)
}

/// Prepares node `(l, i)`: free if its source fits in `NODE`.
fn prepare(c: &mut Core, l: u8, i: u64) -> Result<Option<Job>, String> {
    if l == 0 {
        let src = message(c, i)?.render();
        if src.len() <= NODE {
            return Ok(Some(Job::Free(src)));
        }
        return Ok(context(c, i)?.map(|context| Job::Call {
            context,
            a: src,
            b: None,
        }));
    }
    let (Some(a), Some(b)) = (c.tree.text(l - 1, 2 * i)?, c.tree.text(l - 1, 2 * i + 1)?) else {
        return Ok(None);
    };
    let joined = format!("{a}\n{b}");
    if joined.len() <= NODE {
        return Ok(Some(Job::Free(joined)));
    }
    let (s, n) = addr(l, i);
    let apart = apart(c, s, n / 2);
    Ok(context(c, s + n)?.map(|context| Job::Call {
        context,
        a,
        b: Some((b, apart)),
    }))
}

fn save(
    c: &mut Core,
    l: u8,
    i: u64,
    text: String,
    model: &str,
    prompt: &str,
) -> Result<(), String> {
    c.tree.save(Node {
        l,
        i,
        size: text.len() as u64,
        text,
        model: model.to_owned(),
        prompt: prompt.to_owned(),
    })?;
    c.view.fit(&c.tree, c.budget);
    let budget = c.context_budget();
    c.context.fit(&c.tree, budget);
    c.stale = true;
    Ok(())
}

/// Starts every node that may start. Call with the core locked, after any
/// change: a new message, a node built, a wait over.
pub fn pump(shared: &Arc<Shared>, c: &mut Core) {
    if shared.backend.is_none() || paused(&c.store.dir) {
        return;
    }
    if c.pump.t != c.view.t {
        c.pump.t = c.view.t;
        c.pump.parked.clear();
    }
    if let Some(until) = c.pump.limit {
        if Local::now() < until {
            return;
        }
        c.pump.limit = None;
    }
    loop {
        let mut progressed = false;
        let t = c.view.t;
        let first = c.view.first(&c.tree);
        let mut l = 0u8;
        while (1u64 << l) <= t {
            let n = 1u64 << l;
            if c.pump.lo.len() <= l as usize {
                c.pump.lo.push(0);
            }
            while c.tree.built(l, c.pump.lo[l as usize]) {
                c.pump.lo[l as usize] += 1;
            }
            let mut i = c.pump.lo[l as usize];
            while (i + 1) * n <= t {
                if c.pump.busy.len() >= JOBS {
                    return;
                }
                let end = if l == 0 { i } else { (i + 1) * n };
                if end > first {
                    break;
                }
                let ready =
                    l == 0 || (c.tree.built(l - 1, 2 * i) && c.tree.built(l - 1, 2 * i + 1));
                if !c.tree.built(l, i)
                    && !c.pump.busy.contains(&(l, i))
                    && !c.pump.parked.contains(&(l, i))
                    && ready
                {
                    match prepare(c, l, i) {
                        Ok(Some(Job::Free(text))) => {
                            if let Err(e) = save(c, l, i, text, "", "") {
                                eprintln!("hippo: saving node {l}/{i}: {e}");
                                return;
                            }
                            progressed = true;
                        }
                        Ok(Some(Job::Call { context, a, b })) => {
                            c.pump.busy.insert((l, i));
                            spawn(shared.clone(), l, i, context, a, b);
                        }
                        Ok(None) => {}
                        Err(e) => eprintln!("hippo: preparing node {l}/{i}: {e}"),
                    }
                }
                i += 1;
            }
            l += 1;
        }
        shared.cv.notify_all();
        if !progressed {
            return;
        }
    }
}

fn spawn(
    shared: Arc<Shared>,
    l: u8,
    i: u64,
    context: Vec<String>,
    a: String,
    b: Option<(String, bool)>,
) {
    thread::spawn(move || {
        let step = match &b {
            Some((b, apart)) => Step::Merge {
                l,
                i,
                a: &a,
                b,
                apart: *apart,
            },
            None => Step::Compress { id: i, msg: &a },
        };
        let backend = shared
            .backend
            .as_deref()
            .expect("pump runs only with a backend");
        let result = compact::run(backend.for_level(l).unwrap_or(backend), &context, &step);
        let wait = {
            let mut c = shared.core.lock().unwrap();
            match result {
                Ok((line, model, usage)) => {
                    c.pump.spent.record(l, i, &model, usage);
                    if let Err(e) = save(&mut c, l, i, line, &model, PROMPT_VERSION) {
                        eprintln!("hippo: saving node {l}/{i}: {e}");
                    }
                    c.pump.failed.remove(&(l, i));
                    c.pump.busy.remove(&(l, i));
                    pump(&shared, &mut c);
                    return;
                }
                Err(Fail::Limit(until)) => {
                    let until = until
                        .unwrap_or_else(|| Local::now() + chrono::Duration::seconds(LIMIT_WAIT));
                    if c.pump.limit.is_none() {
                        eprintln!("hippo: compactor limited until {}", until.format("%H:%M"));
                    }
                    c.pump.limit = Some(until);
                    (until - Local::now()).to_std().unwrap_or_default()
                }
                Err(Fail::Refused(e)) => {
                    // Retrying fails the same way, and every later node
                    // waits on this one, so it gets a line built by hand.
                    let (s, n) = addr(l, i);
                    eprintln!("hippo: node {s}+{n} refused, saving a fallback: {e}");
                    let line = fallback(&a, b.as_ref().map(|(b, _)| b.as_str()));
                    if let Err(e) = save(&mut c, l, i, line, "fallback", PROMPT_VERSION) {
                        eprintln!("hippo: saving node {l}/{i}: {e}");
                    }
                    c.pump.failed.remove(&(l, i));
                    c.pump.parked.remove(&(l, i));
                    c.pump.busy.remove(&(l, i));
                    pump(&shared, &mut c);
                    return;
                }
                Err(Fail::Other(e)) => {
                    let (s, n) = addr(l, i);
                    if !c.pump.failed.contains_key(&(l, i)) {
                        eprintln!("hippo: node {s}+{n} failed: {e}");
                    }
                    c.pump.failed.entry((l, i)).or_insert(e);
                    c.pump.parked.insert((l, i));
                    c.pump.busy.remove(&(l, i));
                    pump(&shared, &mut c);
                    return;
                }
            }
        };
        thread::sleep(wait);
        let mut c = shared.core.lock().unwrap();
        c.pump.busy.remove(&(l, i));
        pump(&shared, &mut c);
    });
}

/// A line for a step the model refused: a message's opening up to any
/// THINK text (what a refusal most often trips on), or two lines joined.
fn fallback(a: &str, b: Option<&str>) -> String {
    match b {
        Some(b) => cut(&flat(&format!("{a} {b}")), NODE).to_owned(),
        None => {
            let head = a.split(" THINK").next().unwrap_or(a);
            format!(
                "{} (summary refused: zoom it)",
                cut(&flat(head), 200).trim_end()
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::memory::compact::{Backend, Chat};
    use crate::memory::server::Core;
    use crate::memory::tree::Tree;
    use crate::memory::view::{PLACEHOLDER, View};
    use std::sync::{Condvar, Mutex};
    use std::time::Duration;

    /// Answers every step with a short line and records what it was shown.
    struct Fake(Arc<Mutex<Vec<String>>>);
    struct FakeChat(Arc<Mutex<Vec<String>>>);
    impl Chat for FakeChat {
        fn say(&mut self, blocks: &[String]) -> Result<String, Fail> {
            self.0.lock().unwrap().push(blocks.join("\n"));
            let step = blocks.last().unwrap();
            let body = step.lines().rev().nth(1).unwrap_or("");
            Ok(format!("talk: {}", &body[..body.len().min(60)]))
        }
        fn model(&self) -> String {
            "fake".into()
        }
    }
    impl Backend for Fake {
        fn start(&self) -> Result<Box<dyn Chat>, Fail> {
            Ok(Box::new(FakeChat(self.0.clone())))
        }
    }

    #[test]
    fn a_stalled_context_stays_within_its_budget() {
        let dir = std::env::temp_dir().join(format!("hippo-ctx-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut store = crate::memory::store::Store::open(&dir, true).unwrap();
        let n = 1_000u64;
        let drafts = (0..n)
            .map(|k| crate::memory::store::Draft {
                kind: crate::memory::store::Kind::Talk,
                chat: Some("c".into()),
                text: format!("message {k} ") + &"x".repeat(200),
                date: chrono::Local::now(),
                src: None,
            })
            .collect();
        store.append(drafts).unwrap();
        let mut tree = Tree::open(&dir).unwrap();
        for i in 0..n {
            let text = format!("talk: message {i} ") + &"x".repeat(200);
            tree.save(Node {
                l: 0,
                i,
                size: text.len() as u64,
                text,
                model: String::new(),
                prompt: String::new(),
            })
            .unwrap();
        }
        // A backlog behind them: logged, not summarized.
        let backlog = (0..500)
            .map(|k| crate::memory::store::Draft {
                kind: crate::memory::store::Kind::Talk,
                chat: Some("c".into()),
                text: format!("later {k} ") + &"x".repeat(200),
                date: chrono::Local::now(),
                src: None,
            })
            .collect();
        store.append(backlog).unwrap();
        // No level-1 node is built, so the context view cannot fold.
        let mut c = Core::for_test(store, tree, View::default(), crate::memory::view::VIEW);
        c.sync();
        assert!(c.context.size() > 5 * c.context_budget());
        let budget = c.context_budget();
        let size = |lines: &[String]| lines.iter().map(|l| l.len() as u64 + 1).sum::<u64>();
        // The next message's call sees the history right before it: just
        // under half the budget of it after a cut, never over the budget.
        let lines = context(&mut c, n).unwrap().unwrap();
        assert!(size(&lines) <= budget, "context {} bytes", size(&lines));
        assert!(size(&lines) > budget / 3, "context {} bytes", size(&lines));
        assert!(lines.last().unwrap().starts_with(&format!("{}+1|", n - 1)));
        // A call a little further back shares its head, so reads it cached.
        let earlier = context(&mut c, n - 20).unwrap().unwrap();
        assert_eq!(earlier[..10], lines[..10]);
    }

    #[test]
    fn refused_steps_fall_back_to_their_opening() {
        let line = fallback("echo [jump-back]: 12014 THINK private reasoning", None);
        assert_eq!(line, "echo [jump-back]: 12014 (summary refused: zoom it)");
        assert!(fallback(&"x".repeat(900), None).len() < NODE);
        assert_eq!(fallback("talk: a", Some("talk: b")), "talk: a talk: b");
    }

    #[test]
    fn builds_in_order_and_folds_the_view() {
        let dir = std::env::temp_dir().join(format!("hippo-pump-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut store = crate::memory::store::Store::open(&dir, true).unwrap();
        // A store of long messages, so most nodes need a call.
        let drafts = (0..40)
            .map(|k| crate::memory::store::Draft {
                kind: crate::memory::store::Kind::Talk,
                chat: Some("c".into()),
                text: format!("message {k} ") + &"x".repeat(if k % 3 == 0 { 10 } else { 600 }),
                date: chrono::Local::now(),
                src: None,
            })
            .collect();
        store.append(drafts).unwrap();
        let tree = Tree::open(&dir).unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let budget = 2_000;
        let shared = Arc::new(Shared {
            core: Mutex::new(Core::for_test(store, tree, View::default(), budget)),
            cv: Condvar::new(),
            backend: Some(Box::new(Fake(seen.clone()))),
        });
        {
            let mut c = shared.core.lock().unwrap();
            c.sync();
            pump(&shared, &mut c);
        }
        let deadline = std::time::Instant::now() + Duration::from_secs(20);
        let mut c = shared.core.lock().unwrap();
        while (c.view.unbuilt(&c.tree) > 0 || !c.pump.busy.is_empty())
            && std::time::Instant::now() < deadline
        {
            c = shared
                .cv
                .wait_timeout(c, Duration::from_millis(200))
                .unwrap()
                .0;
        }
        assert_eq!(c.view.unbuilt(&c.tree), 0);
        assert!(c.view.size() <= budget, "view {} bytes", c.view.size());
        assert!(c.view.parts.iter().any(|&(l, _)| l > 0), "nothing merged");
        // Short messages are their own line, word for word, without their chat.
        assert_eq!(
            c.tree.text(0, 0).unwrap().unwrap(),
            "talk: message 0 xxxxxxxxxx"
        );
        let ids = regex::Regex::new(r"(?m)^\d+\+\d+\|").unwrap();
        for call in seen.lock().unwrap().iter() {
            assert!(
                !call.contains(PLACEHOLDER),
                "a call saw an unsummarized line"
            );
            assert!(call.starts_with("<chat>\n"));
            assert!(
                call.contains("</chat>\nCompaction: "),
                "the task names its message or lines"
            );
            if let Some(ctx) = call
                .split("</chat>")
                .next()
                .unwrap()
                .strip_prefix("<chat>\n")
            {
                for line in ctx.lines() {
                    assert!(ids.is_match(line), "a bare context line: {line}");
                }
            }
        }
        // The published view is the whole view in one block, unpaged.
        assert!(c.stale);
        crate::memory::server::publish(&mut c).unwrap();
        assert!(!c.stale);
        let file = std::fs::read_to_string(dir.join("view.md")).unwrap();
        assert!(file.starts_with("<chat>\n") && file.ends_with("\n</chat>\n"));
        assert!(file.lines().nth(1).unwrap().starts_with("0+"));
        assert_eq!(file.lines().count(), c.view.parts.len() + 2);
    }

    /// Fails its first call, then answers.
    struct Flaky(Arc<Mutex<u32>>);
    struct FlakyChat(Arc<Mutex<u32>>);
    impl Chat for FlakyChat {
        fn say(&mut self, _: &[String]) -> Result<String, Fail> {
            let mut n = self.0.lock().unwrap();
            *n += 1;
            if *n == 1 {
                return Err(Fail::Other("boom".into()));
            }
            Ok("sum".into())
        }
        fn model(&self) -> String {
            "fake".into()
        }
    }
    impl Backend for Flaky {
        fn start(&self) -> Result<Box<dyn Chat>, Fail> {
            Ok(Box::new(FlakyChat(self.0.clone())))
        }
    }

    #[test]
    fn a_failed_call_waits_for_the_next_message() {
        let dir = std::env::temp_dir().join(format!("hippo-park-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut store = crate::memory::store::Store::open(&dir, true).unwrap();
        let draft = |k: u32| crate::memory::store::Draft {
            kind: crate::memory::store::Kind::Talk,
            chat: Some("c".into()),
            text: format!("message {k} ") + &"x".repeat(600),
            date: chrono::Local::now(),
            src: None,
        };
        store.append(vec![draft(0)]).unwrap();
        let tree = Tree::open(&dir).unwrap();
        let calls = Arc::new(Mutex::new(0));
        let shared = Arc::new(Shared {
            core: Mutex::new(Core::for_test(store, tree, View::default(), 100_000)),
            cv: Condvar::new(),
            backend: Some(Box::new(Flaky(calls.clone()))),
        });
        let settle = |shared: &Arc<Shared>| {
            let deadline = std::time::Instant::now() + Duration::from_secs(5);
            let mut c = shared.core.lock().unwrap();
            while !c.pump.busy.is_empty() && std::time::Instant::now() < deadline {
                c = shared
                    .cv
                    .wait_timeout(c, Duration::from_millis(50))
                    .unwrap()
                    .0;
            }
        };
        {
            let mut c = shared.core.lock().unwrap();
            c.sync();
            pump(&shared, &mut c);
        }
        settle(&shared);
        {
            let mut c = shared.core.lock().unwrap();
            assert!(c.pump.parked.contains(&(0, 0)));
            pump(&shared, &mut c);
            assert!(c.pump.busy.is_empty(), "retried before a message");
            c.store.append(vec![draft(1)]).unwrap();
            c.sync();
            pump(&shared, &mut c);
        }
        settle(&shared);
        let c = shared.core.lock().unwrap();
        assert!(c.tree.built(0, 0));
        assert!(c.pump.failed.is_empty());
    }

    #[test]
    fn merges_know_when_their_halves_share_no_chat() {
        let dir = std::env::temp_dir().join(format!("hippo-apart-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut store = crate::memory::store::Store::open(&dir, true).unwrap();
        // Every chat has the same label: only the session tells them apart.
        let sessions = [
            Some("a"),
            Some("a"),
            Some("b"),
            Some("b"),
            Some("a"),
            None,
            None,
            None,
        ];
        let drafts = sessions
            .into_iter()
            .enumerate()
            .map(|(k, session)| crate::memory::store::Draft {
                kind: crate::memory::store::Kind::Talk,
                chat: Some("bridge".into()),
                text: "hi".into(),
                date: chrono::Local::now(),
                src: session.map(|s| crate::memory::store::Src {
                    h: "claude".into(),
                    s: s.into(),
                    e: k.to_string(),
                }),
            })
            .collect();
        store.append(drafts).unwrap();
        let tree = Tree::open(&dir).unwrap();
        let c = Core::for_test(store, tree, View::default(), 2_000);
        assert!(!apart(&c, 0, 1));
        assert!(apart(&c, 0, 2));
        assert!(!apart(&c, 0, 4), "chat a on both sides");
        assert!(!apart(&c, 4, 2), "no known chat on one side");
    }

    /// Anthropic's prompt cache, faked by its rules as UniiChat's
    /// cache.test.ts fakes it: an entry is written only at a mark, keyed by
    /// the prefix up to it, found walking back at most `LOOK` blocks from a
    /// mark, served once its writer's answer has begun, and alive `TTL` past
    /// its last use. Claude Code marks the system prompt and the request's
    /// last block; `marked` marks the context. Time runs a thousand times
    /// fast.
    struct Anthropic {
        entries: Mutex<std::collections::HashMap<u64, (Instant, Instant)>>,
        /// Bytes of the calls' input read from the cache, written to it and
        /// sent uncached; each request's last block, its own task (or the
        /// retry note), is never in a cache and not counted.
        used: Mutex<(u64, u64, u64)>,
        /// Calls that read none of the context, only the system prompt.
        cold: Mutex<u64>,
        flights: Option<Arc<Flights>>,
        seed: Mutex<u64>,
    }
    use crate::memory::compact::marked;
    use crate::memory::flight::{Flights, LOOK, TTL};
    use std::time::Instant;

    /// When an answer begins, after its request.
    const FIRST: Duration = Duration::from_millis(3);

    impl Anthropic {
        fn rand(&self, lo: u64, hi: u64) -> u64 {
            let mut s = self.seed.lock().unwrap();
            *s = s
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            lo + (*s >> 33) % (hi - lo)
        }

        fn request(&self, blocks: &[(String, bool)]) {
            use std::hash::{DefaultHasher, Hash, Hasher};
            let now = Instant::now();
            let last = blocks.len() - 1;
            let (mut keys, mut ends, mut key, mut end) = (vec![], vec![], 0u64, 0u64);
            for (text, _) in blocks {
                let mut h = DefaultHasher::new();
                (key, text).hash(&mut h);
                key = h.finish();
                end += text.len() as u64;
                keys.push(key);
                ends.push(end);
            }
            let marks: Vec<usize> = (0..=last).filter(|&k| blocks[k].1 || k == last).collect();
            let mut entries = self.entries.lock().unwrap();
            let live = |k: usize| {
                entries
                    .get(&keys[k])
                    .is_some_and(|&(from, until)| from <= now && now < until)
            };
            let mut hit: Option<usize> = None;
            for &m in &marks {
                if let Some(k) = (m.saturating_sub(LOOK - 1)..=m).rev().find(|&k| live(k)) {
                    hit = hit.max(Some(k));
                }
            }
            if let Some(h) = hit {
                entries.get_mut(&keys[h]).unwrap().1 = now + TTL;
            }
            for &m in marks.iter().filter(|&&m| hit.is_none_or(|h| m > h)) {
                if !entries.get(&keys[m]).is_some_and(|&(_, until)| now < until) {
                    entries.insert(keys[m], (now + FIRST, now + TTL));
                }
            }
            if hit.is_none_or(|h| h == 0) {
                *self.cold.lock().unwrap() += 1;
            }
            let counted = ends[last - 1];
            let read = hit.map_or(0, |h| ends[h]).min(counted);
            let written = ends[*marks.iter().max().unwrap()]
                .min(counted)
                .saturating_sub(read);
            let mut used = self.used.lock().unwrap();
            used.0 += read;
            used.1 += written;
            used.2 += counted - read - written;
        }
    }

    struct Sim(Arc<Anthropic>);
    struct SimChat {
        api: Arc<Anthropic>,
        blocks: Vec<(String, bool)>,
        begun: Option<Box<dyn FnOnce() + Send>>,
    }
    impl Backend for Sim {
        fn start(&self) -> Result<Box<dyn Chat>, Fail> {
            Ok(Box::new(SimChat {
                api: self.0.clone(),
                blocks: vec![(crate::memory::compact::COMPACT.to_owned(), true)],
                begun: None,
            }))
        }
        fn flights(&self) -> Option<&Arc<Flights>> {
            self.0.flights.as_ref()
        }
    }
    impl Chat for SimChat {
        fn say(&mut self, blocks: &[String]) -> Result<String, Fail> {
            let first = self.blocks.len() == 1;
            for b in marked(blocks) {
                let text = b["text"].as_str().unwrap().to_owned();
                self.blocks.push((text, b.get("cache_control").is_some()));
            }
            self.api.request(&self.blocks);
            thread::sleep(FIRST);
            if let Some(f) = self.begun.take() {
                f();
            }
            thread::sleep(Duration::from_millis(self.api.rand(4, 12)));
            // A compression answers in its message's kind; a fourth of the
            // first answers run too long, as real ones do.
            let step = blocks.last().unwrap();
            let kind = step
                .split("<input>\n")
                .nth(1)
                .and_then(|r| r.split(':').next())
                .unwrap_or("talk");
            let long = if first && self.api.rand(0, 4) == 0 {
                400
            } else {
                0
            };
            let line = format!(
                "{kind}: {}",
                "x".repeat(self.api.rand(120, 450) as usize + long)
            );
            self.blocks.push((line.clone(), false));
            Ok(line)
        }
        fn model(&self) -> String {
            "sim".into()
        }
        fn on_begin(&mut self, f: Box<dyn FnOnce() + Send>) {
            self.begun = Some(f);
        }
    }

    /// Replays a synthetic chat of `n` messages, turns of tool steps, in
    /// real time a thousand times fast; the share of the compactions'
    /// input read from the cache.
    fn replay(n: usize, single_flight: bool) -> f64 {
        let dir = std::env::temp_dir().join(format!(
            "hippo-cache-{}-{single_flight}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let store = crate::memory::store::Store::open(&dir, true).unwrap();
        let tree = Tree::open(&dir).unwrap();
        let api = Arc::new(Anthropic {
            entries: Default::default(),
            used: Default::default(),
            cold: Default::default(),
            flights: single_flight.then(Arc::default),
            seed: Mutex::new(1),
        });
        let shared = Arc::new(Shared {
            core: Mutex::new(Core::for_test(
                store,
                tree,
                View::default(),
                crate::memory::view::VIEW,
            )),
            cv: Condvar::new(),
            backend: Some(Box::new(Sim(api.clone()))),
        });
        use crate::memory::store::Kind;
        let sent = std::cell::Cell::new(0);
        let say = |kind: Kind, lo: u64, hi: u64, gap: (u64, u64)| {
            thread::sleep(Duration::from_micros(api.rand(gap.0 * 1000, gap.1 * 1000)));
            let text = format!("{} ", sent.get()) + &"y".repeat(api.rand(lo, hi) as usize);
            let mut c = shared.core.lock().unwrap();
            c.store
                .append(vec![crate::memory::store::Draft {
                    kind,
                    chat: Some("c".into()),
                    text,
                    date: chrono::Local::now(),
                    src: None,
                }])
                .unwrap();
            c.sync();
            pump(&shared, &mut c);
            sent.set(sent.get() + 1);
        };
        while sent.get() < n {
            let steps = api.rand(0, 7);
            say(Kind::User, 40, 1500, (20, 240));
            for _ in 0..steps {
                say(Kind::Tool, 80, 600, (2, 12));
                say(Kind::Echo, 40, 8000, (1, 6));
            }
            say(Kind::Talk, 100, 2500, (2, 9));
        }
        let deadline = Instant::now() + Duration::from_secs(120);
        let mut c = shared.core.lock().unwrap();
        while (c.view.unbuilt(&c.tree) > 0 || !c.pump.busy.is_empty()) && Instant::now() < deadline
        {
            c = shared
                .cv
                .wait_timeout(c, Duration::from_millis(50))
                .unwrap()
                .0;
        }
        assert_eq!(c.view.unbuilt(&c.tree), 0, "the replay never caught up");
        let (read, written, input) = *api.used.lock().unwrap();
        eprintln!(
            "single flight {single_flight}: {} cold calls",
            api.cold.lock().unwrap()
        );
        let _ = std::fs::remove_dir_all(&dir);
        read as f64 / (read + written + input) as f64
    }

    #[test]
    fn compactions_read_most_of_their_input_from_the_cache() {
        let read = replay(1_200, true);
        assert!(read >= 0.95, "read {:.1}% from the cache", 100.0 * read);
    }

    /// Single flight against none, by hand: `cargo test -- --ignored
    /// --nocapture single_flight`. On 2026-10-19 it was 97.1% against
    /// 96.5%, with 33 calls rereading the whole context against 49.
    #[test]
    #[ignore]
    fn single_flight_against_none() {
        let (with, without) = (replay(1_200, true), replay(1_200, false));
        eprintln!(
            "{:.1}% single flight, {:.1}% without",
            100.0 * with,
            100.0 * without
        );
    }
}
