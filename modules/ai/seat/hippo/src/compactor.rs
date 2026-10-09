//! The pump: builds tree nodes in Taelin's strict order. A node starts when
//! it is not built or running, its sources exist, and every view line
//! before its end is a summary; so messages are compressed one at a time,
//! in order, while merges of finished parts run beside them.

use crate::compact::{self, Fail, PROMPT_VERSION, Step, Usage};
use crate::server::{Core, Shared};
use crate::store::Msg;
use crate::tree::{NODE, Node, addr, flat};
use chrono::{DateTime, Local};
use std::collections::HashSet;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

/// Compactor calls running at once.
pub const JOBS: usize = 8;
/// Wait before retrying a failed node.
pub const RETRY: Duration = Duration::from_secs(10);
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
        crate::store::read_jsonl::<Spend>(&path, &mut torn, |s, _, _| {
            if let Some(d) = crate::store::parse_date(&s.date) {
                let day = spent.days.entry(d.date_naive()).or_default();
                day.0 += 1;
                day.1.add(s.usage);
            }
        })?;
        Ok(spent)
    }

    fn record(&mut self, l: u8, i: u64, model: &str, usage: Usage) {
        let now = Local::now();
        let day = self.days.entry(now.date_naive()).or_default();
        day.0 += 1;
        day.1.add(usage);
        let Some(path) = &self.path else { return };
        let line = Spend {
            date: crate::store::fmt_date(&now),
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
                crate::store::append_line(&mut f, &line)
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

/// The compactions' view up to `end` (exclusive), bare: no ids. None
/// until all of it is built.
fn context(c: &Core, end: u64) -> Result<Option<Vec<String>>, String> {
    let mut out = Vec::new();
    for &(l, i) in &c.context.parts {
        let (s, n) = addr(l, i);
        if s + n > end {
            break;
        }
        match c.tree.text(l, i)? {
            Some(t) => out.push(flat(&t)),
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
fn prepare(c: &Core, l: u8, i: u64) -> Result<Option<Job>, String> {
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
                if !c.tree.built(l, i) && !c.pump.busy.contains(&(l, i)) && ready {
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
            Some((b, apart)) => Step::Merge(&a, b, *apart),
            None => Step::Compress(&a),
        };
        let backend = shared
            .backend
            .as_deref()
            .expect("pump runs only with a backend");
        let result = compact::run(backend, &context, &step);
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
                    (until - Local::now()).to_std().unwrap_or(RETRY)
                }
                Err(Fail::Other(e)) => {
                    let (s, n) = addr(l, i);
                    if !c.pump.failed.contains_key(&(l, i)) {
                        eprintln!("hippo: node {s}+{n} failed: {e}");
                    }
                    c.pump.failed.entry((l, i)).or_insert(e);
                    RETRY
                }
            }
        };
        thread::sleep(wait);
        let mut c = shared.core.lock().unwrap();
        c.pump.busy.remove(&(l, i));
        pump(&shared, &mut c);
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::compact::{Backend, Chat};
    use crate::server::Core;
    use crate::tree::Tree;
    use crate::view::{PLACEHOLDER, View};
    use std::sync::{Condvar, Mutex};

    /// Answers every step with a short line and records what it was shown.
    struct Fake(Arc<Mutex<Vec<String>>>);
    struct FakeChat(Arc<Mutex<Vec<String>>>);
    impl Chat for FakeChat {
        fn say(&mut self, blocks: &[String]) -> Result<String, Fail> {
            self.0.lock().unwrap().push(blocks.join("\n"));
            let step = blocks.last().unwrap();
            let body = step.lines().rev().nth(1).unwrap_or("");
            Ok(format!("sum: {}", &body[..body.len().min(60)]))
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
    fn builds_in_order_and_folds_the_view() {
        let dir = std::env::temp_dir().join(format!("hippo-pump-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut store = crate::store::Store::open(&dir, true).unwrap();
        // A store of long messages, so most nodes need a call.
        let drafts = (0..40)
            .map(|k| crate::store::Draft {
                kind: crate::store::Kind::Talk,
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
            assert!(!ids.is_match(call), "ids in a call");
            assert!(call.starts_with("<chat>\n"));
        }
        // The published view is the whole view in one block, unpaged.
        assert!(c.stale);
        crate::server::publish(&mut c).unwrap();
        assert!(!c.stale);
        let file = std::fs::read_to_string(dir.join("view.md")).unwrap();
        assert!(file.starts_with("<chat>\n") && file.ends_with("\n</chat>\n"));
        assert!(file.lines().nth(1).unwrap().starts_with("0+"));
        assert_eq!(file.lines().count(), c.view.parts.len() + 2);
    }

    #[test]
    fn merges_know_when_their_halves_share_no_chat() {
        let dir = std::env::temp_dir().join(format!("hippo-apart-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut store = crate::store::Store::open(&dir, true).unwrap();
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
            .map(|(k, session)| crate::store::Draft {
                kind: crate::store::Kind::Talk,
                chat: Some("bridge".into()),
                text: "hi".into(),
                date: chrono::Local::now(),
                src: session.map(|s| crate::store::Src {
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
}
