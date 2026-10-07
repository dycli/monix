//! The service: the only writer. One thread follows the transcripts; the
//! CLI talks to it over `hippo.sock`, one JSON request and reply per
//! connection.

use crate::compact::Backend;
use crate::compactor::{Pump, Spent, pump};
use crate::live::{Live, Sources};
use crate::store::{Draft, Kind, Store, fmt_date};
use crate::tree::{Tree, addr, flat};
use crate::view::{PLACEHOLDER, VIEW, View};
use crate::watcher::Watcher;
use chrono::{DateTime, Local};
use regex::RegexBuilder;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::Duration;

#[derive(Serialize, Deserialize)]
pub struct Request {
    pub cmd: String,
    #[serde(default)]
    pub args: Vec<String>,
}

#[derive(Serialize, Deserialize)]
pub struct Reply {
    pub ok: bool,
    pub out: String,
}

pub struct Core {
    pub store: Store,
    pub tree: Tree,
    pub view: View,
    pub budget: u64,
    pub pump: Pump,
    pub watcher: Watcher,
    pub live: Option<Live>,
    pub started: DateTime<Local>,
    /// Rendered views being read page by page, by token.
    pages: Vec<(String, Vec<String>)>,
}

impl Core {
    #[cfg(test)]
    pub fn for_test(store: Store, tree: Tree, view: View, budget: u64) -> Core {
        Core {
            store,
            tree,
            view,
            budget,
            pump: Pump::default(),
            watcher: Watcher::default(),
            live: None,
            started: Local::now(),
            pages: Vec::new(),
        }
    }

    /// Brings the view up to the log after messages were appended.
    pub fn sync(&mut self) {
        while self.view.t < self.store.len() {
            self.view.append(&self.tree, self.budget);
        }
    }
}

pub struct Shared {
    pub core: Mutex<Core>,
    /// Signalled whenever the view may have changed.
    pub cv: Condvar,
    pub backend: Option<Box<dyn Backend>>,
}

const SEARCH_MAX: usize = 100;
/// How long `hippo view` waits for the compactor before printing
/// placeholders.
const SETTLE: Duration = Duration::from_secs(30);
/// Bytes per page of `hippo view`, under the harnesses' output limits.
const PAGE: usize = 24_000;

/// Runs the service. Without `sources` it follows nothing and only serves
/// and compacts an existing store (a replayed scratch store, say).
pub fn serve(
    dir: &Path,
    sources: Option<Sources>,
    backend: Option<Box<dyn Backend>>,
) -> Result<(), String> {
    let store = Store::open(dir, true)?;
    let tree = Tree::open(dir)?;
    for at in store.torn.iter().chain(&tree.torn) {
        eprintln!("hippo: torn line at {at} skipped");
    }
    let live = match &sources {
        Some(s) => Some(Live::new(&store, s.clone())?),
        None => None,
    };
    let watcher = Watcher {
        paseo: sources.as_ref().map(|s| s.paseo.clone()),
        after: crate::live::imported(dir)?.and_then(|i| crate::store::parse_date(&i.cutoff)),
        ..Watcher::default()
    };
    let budget = std::env::var("HIPPO_VIEW")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(VIEW);
    let view = View::fold(&tree, store.len(), budget);
    let shared = Arc::new(Shared {
        core: Mutex::new(Core {
            store,
            tree,
            view,
            budget,
            pump: Pump {
                spent: Spent::load(dir)?,
                ..Pump::default()
            },
            watcher,
            live,
            started: Local::now(),
            pages: Vec::new(),
        }),
        cv: Condvar::new(),
        backend,
    });
    let sock = dir.join("hippo.sock");
    let _ = fs::remove_file(&sock);
    let listener = UnixListener::bind(&sock).map_err(|e| format!("{}: {e}", sock.display()))?;
    {
        let shared = shared.clone();
        thread::spawn(move || {
            for conn in listener.incoming().flatten() {
                let shared = shared.clone();
                thread::spawn(move || {
                    if let Err(e) = answer(conn, &shared) {
                        eprintln!("hippo: request failed: {e}");
                    }
                });
            }
        });
    }
    eprintln!("hippo: serving {}", dir.display());
    loop {
        {
            let mut guard = shared.core.lock().unwrap();
            let c = &mut *guard;
            if let Some(live) = c.live.as_mut() {
                live.scan(&mut c.watcher, &mut c.store)?;
                c.watcher.tick(&mut c.store, Local::now())?;
                live.save(&c.watcher)?;
            }
            c.sync();
            pump(&shared, c);
        }
        thread::sleep(Duration::from_secs(1));
    }
}

fn answer(conn: UnixStream, shared: &Arc<Shared>) -> Result<(), String> {
    let mut line = String::new();
    BufReader::new(&conn)
        .read_line(&mut line)
        .map_err(|e| e.to_string())?;
    let reply = match serde_json::from_str::<Request>(&line) {
        Ok(req) => match handle(&req, shared) {
            Ok(out) => Reply { ok: true, out },
            Err(out) => Reply { ok: false, out },
        },
        Err(e) => Reply {
            ok: false,
            out: format!("bad request: {e}"),
        },
    };
    let mut raw = serde_json::to_vec(&reply).map_err(|e| e.to_string())?;
    raw.push(b'\n');
    (&conn).write_all(&raw).map_err(|e| e.to_string())
}

fn num(args: &[String], k: usize, what: &str) -> Result<u64, String> {
    args.get(k)
        .ok_or_else(|| format!("Missing {what}."))?
        .parse()
        .map_err(|_| format!("{what} must be a number."))
}

fn handle(req: &Request, shared: &Arc<Shared>) -> Result<String, String> {
    let a = &req.args;
    let core = &shared.core;
    match req.cmd.as_str() {
        "view" => view(shared, a),
        "zoom" => {
            let (id, n) = (num(a, 0, "id")?, num(a, 1, "n")?);
            let c = core.lock().unwrap();
            zoom(&c.store, &c.tree, id, n)
        }
        "date" => {
            let id = num(a, 0, "id")?;
            let c = core.lock().unwrap();
            c.store
                .date(id)
                .map(|d| d.format("%Y-%m-%d %H:%M:%S %a").to_string())
                .ok_or_else(|| format!("No message {id}."))
        }
        "search" => {
            let pattern = a.first().ok_or("Missing regex.")?;
            let re = RegexBuilder::new(pattern)
                .case_insensitive(true)
                .build()
                .map_err(|e| e.to_string())?;
            let c = core.lock().unwrap();
            search(&c.store, &re)
        }
        "note" => {
            let text = a.join(" ");
            if text.trim().is_empty() {
                return Err("Nothing to note.".into());
            }
            let mut c = core.lock().unwrap();
            let ids = c.store.append(vec![Draft {
                kind: Kind::Note,
                chat: None,
                text: crate::mask::mask(text.trim()),
                date: Local::now(),
                src: None,
            }])?;
            c.sync();
            pump(shared, &mut c);
            Ok(format!("Noted as message {}.", ids[0]))
        }
        "status" => Ok(status(&core.lock().unwrap(), shared.backend.is_some())),
        "browse" => crate::browse::render(&core.lock().unwrap()),
        other => Err(format!("Unknown command {other}.")),
    }
}

/// `hippo view [page token]`: the whole view, paged. The first call waits
/// for the compactor (up to `SETTLE`), renders once and keeps the pages,
/// so later pages come from the same render.
fn view(shared: &Arc<Shared>, a: &[String]) -> Result<String, String> {
    let mut c = shared.core.lock().unwrap();
    if let (Some(k), Some(token)) = (a.first(), a.get(1)) {
        let k: usize = k.parse().map_err(|_| "page must be a number.")?;
        let pages = &c
            .pages
            .iter()
            .find(|(t, _)| t == token)
            .ok_or("That view expired; run hippo view again.")?
            .1;
        let page = pages
            .get(k.wrapping_sub(1))
            .ok_or_else(|| format!("No page {k}."))?;
        return Ok(paged(page, k, pages.len(), token));
    }
    let deadline = std::time::Instant::now() + SETTLE;
    while c.view.unbuilt(&c.tree) > 0 {
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        if left.is_zero() {
            break;
        }
        c = shared.cv.wait_timeout(c, left).unwrap().0;
    }
    let mut lines = Vec::new();
    for &(l, i) in &c.view.parts {
        let (s, n) = addr(l, i);
        let text = c.tree.text(l, i)?.unwrap_or_else(|| PLACEHOLDER.to_owned());
        lines.push(format!("{s}+{n}|{}", flat(&text)));
    }
    let unbuilt = c.view.unbuilt(&c.tree);
    let mut head = String::new();
    if unbuilt > 0 {
        let why = match c.pump.limit {
            Some(t) => format!(" (compactor rate-limited until {})", t.format("%H:%M")),
            None => String::new(),
        };
        head = format!("{unbuilt} recent lines are not summarized yet{why}: zoom them.\n");
    }
    let mut pages = vec![format!("{head}<chat>")];
    for line in lines {
        let page = pages.last_mut().unwrap();
        if page.len() + line.len() + 1 > PAGE {
            pages.push(line);
        } else {
            page.push('\n');
            page.push_str(&line);
        }
    }
    pages.last_mut().unwrap().push_str("\n</chat>");
    let token = format!("{}", c.view.t);
    let n = pages.len();
    let first = paged(&pages[0], 1, n, &token);
    c.pages.retain(|(t, _)| *t != token);
    c.pages.push((token, pages));
    if c.pages.len() > 8 {
        c.pages.remove(0);
    }
    Ok(first)
}

fn paged(page: &str, k: usize, n: usize, token: &str) -> String {
    if n == 1 {
        return page.to_owned();
    }
    let mut out = format!("Your memory, part {k} of {n}.\n{page}");
    if k < n {
        out.push_str(&format!(
            "\nNot all read yet. Run: hippo view {} {token}",
            k + 1
        ));
    }
    out
}

/// Line `id+n` opened into its two halves; `n = 1` gives the message whole.
pub fn zoom(store: &Store, tree: &Tree, id: u64, n: u64) -> Result<String, String> {
    let t = store.len();
    if n == 0 || !n.is_power_of_two() || !id.is_multiple_of(n) || id + n > t {
        return Err(format!("No line {id}+{n}."));
    }
    if n == 1 {
        let m = store.get(id)?;
        return Ok(format!("{id}+1|{}", m.render()));
    }
    let l = n.trailing_zeros() as u8 - 1;
    let half = n / 2;
    let mut out = Vec::new();
    for (k, i) in [(id, id / half), (id + half, id / half + 1)] {
        let text = tree.text(l, i)?.unwrap_or_else(|| PLACEHOLDER.to_owned());
        out.push(format!("{k}+{half}|{}", flat(&text)));
    }
    Ok(out.join("\n"))
}

fn search(store: &Store, re: &regex::Regex) -> Result<String, String> {
    let mut hits = Vec::new();
    let mut total = 0usize;
    store.scan(|m| {
        if let Some(at) = re.find(&m.text) {
            total += 1;
            let label = m
                .chat
                .as_deref()
                .map(|c| format!(" [{c}]"))
                .unwrap_or_default();
            let date = m.date.get(..16).unwrap_or(&m.date).replace('T', " ");
            let excerpt = excerpt(&m.text, at.start(), at.end());
            let line = format!("{} {}{label} {date}: {excerpt}", m.i, m.kind.name());
            hits.push(line);
            if hits.len() > SEARCH_MAX {
                hits.remove(0);
            }
        }
        true
    })?;
    if hits.is_empty() {
        return Ok("No match.".into());
    }
    let mut out = String::new();
    if total > hits.len() {
        out.push_str(&format!(
            "{total} matches; the newest {} follow. Narrow the regex for older ones.\n",
            hits.len()
        ));
    }
    out.push_str(&hits.join("\n"));
    Ok(out)
}

/// About 200 bytes around a match, on one line.
fn excerpt(text: &str, start: usize, end: usize) -> String {
    let mut lo = start.saturating_sub(80);
    while !text.is_char_boundary(lo) {
        lo -= 1;
    }
    let mut hi = (end + 120).min(text.len());
    while !text.is_char_boundary(hi) {
        hi += 1;
    }
    let flat = text[lo..hi]
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    format!(
        "{}{flat}{}",
        if lo > 0 { "…" } else { "" },
        if hi < text.len() { "…" } else { "" }
    )
}

fn status(c: &Core, compacting: bool) -> String {
    let s = &c.store;
    let following = match &c.live {
        Some(live) => format!(
            "following since {}",
            live.since().map(|d| fmt_date(&d)).unwrap_or_default()
        ),
        None => "following nothing".to_owned(),
    };
    let mut out = format!(
        "{} messages in {} chats, at {}; {following}.\n",
        s.len(),
        s.chats.len(),
        s.dir.display(),
    );
    let first = c.view.first(&c.tree);
    let built: usize = c.tree.counts().iter().sum();
    out.push_str(&format!(
        "tree: {built} nodes; messages summarized in order up to {first} of {}; view {} lines, {} bytes, {} unsummarized\n",
        s.len(),
        c.view.parts.len(),
        c.view.size(),
        c.view.unbuilt(&c.tree)
    ));
    if !compacting {
        out.push_str("compactor: off\n");
    } else {
        out.push_str(&format!("compactor: {} running\n", c.pump.busy.len()));
    }
    let today = Local::now().date_naive();
    let tokens = |u: &crate::compact::Usage| {
        format!(
            "{} input, {} cache read, {} cache write, {} output",
            u.input, u.cache_read, u.cache_write, u.output
        )
    };
    let (calls, used) = c.pump.spent.days.get(&today).copied().unwrap_or_default();
    out.push_str(&format!(
        "compactor today: {calls} calls; tokens {}\n",
        tokens(&used)
    ));
    let (mut week_calls, mut week) = (0, crate::compact::Usage::default());
    for (_, (n, u)) in c
        .pump
        .spent
        .days
        .range(today - chrono::Duration::days(6)..=today)
    {
        week_calls += n;
        week.add(*u);
    }
    out.push_str(&format!(
        "compactor last 7 days: {week_calls} calls; tokens {}\n",
        tokens(&week)
    ));
    if let Some(t) = c.pump.limit {
        out.push_str(&format!("compactor rate-limited until {}\n", fmt_date(&t)));
    }
    if !c.pump.failed.is_empty() {
        out.push_str(&format!("failing nodes: {}\n", c.pump.failed.len()));
        for (&(l, i), e) in c.pump.failed.iter().take(5) {
            let (s, n) = addr(l, i);
            let e: String = e.chars().take(200).collect();
            out.push_str(&format!("  {s}+{n}: {e}\n"));
        }
    }
    for h in ["claude", "codex", "opencode"] {
        match s.last.get(h) {
            Some((i, date)) => {
                let d = DateTime::from_timestamp(*date, 0)
                    .map(|d| fmt_date(&d.with_timezone(&Local)))
                    .unwrap_or_default();
                out.push_str(&format!("last {h} message: {i} at {d}\n"));
            }
            None => out.push_str(&format!("last {h} message: none\n")),
        }
    }
    let holding = c.watcher.holding();
    if holding.is_empty() {
        out.push_str("holding: nothing\n");
    } else {
        let list: Vec<String> = holding.iter().map(|(c, n)| format!("{c} {n}")).collect();
        out.push_str(&format!("holding: {}\n", list.join(", ")));
    }
    out.push_str(&format!(
        "unparsed entries since {}: {}\n",
        fmt_date(&c.started),
        c.watcher.unparsed_total
    ));
    for u in &c.watcher.unparsed {
        out.push_str(&format!("  {} {}: {}\n", u.harness, u.at, u.what));
    }
    let torn: Vec<&String> = s.torn.iter().chain(&c.tree.torn).collect();
    if !torn.is_empty() {
        let torn: Vec<&str> = torn.iter().map(|t| t.as_str()).collect();
        out.push_str(&format!(
            "torn lines skipped at load: {}\n",
            torn.join(", ")
        ));
    }
    let mut off: Vec<_> = s.offrecord.values().collect();
    off.sort_by(|a, b| a.date.cmp(&b.date));
    out.push_str(&format!("off the record: {} chats\n", off.len()));
    for o in off {
        out.push_str(&format!(
            "  {}:{} {} since {}\n",
            o.harness, o.session, o.marker, o.date
        ));
    }
    out.trim_end().to_owned()
}
