//! The service: the only writer. In code mode its main loop follows the
//! transcripts; in chat mode the agent logs each message over the socket.
//! The CLI talks to it over `hippo.sock`, one JSON request and reply per
//! connection.

use crate::code::Follow;
use crate::code::live::Sources;
use crate::memory::compact::Backend;
use crate::memory::compactor::{Pump, Spent, pump};
use crate::memory::store::{Draft, Kind, Store, chat_key, fmt_date};
use crate::memory::tree::{Tree, addr, flat};
use crate::memory::view::{CONTEXT, PLACEHOLDER, UNBUILT, VIEW, View, head};
use chrono::{DateTime, Local};
use regex::RegexBuilder;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
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
    /// The compactions' own view, under `CONTEXT`, to the first message
    /// not built.
    pub context: View,
    pub pump: Pump,
    /// Code mode's transcript follower; chat mode has none.
    pub follow: Option<Follow>,
    pub started: DateTime<Local>,
    /// Rendered views being read page by page, by token.
    pages: Vec<(String, Vec<String>)>,
    /// The view changed since `view.md` was last written.
    pub stale: bool,
}

impl Core {
    #[cfg(test)]
    pub fn for_test(store: Store, tree: Tree, view: View, budget: u64) -> Core {
        Core {
            store,
            tree,
            view,
            budget,
            context: View::default(),
            pump: Pump::default(),
            follow: None,
            started: Local::now(),
            pages: Vec::new(),
            stale: true,
        }
    }

    pub fn context_budget(&self) -> u64 {
        CONTEXT.min(self.budget)
    }

    /// Both views changed only by appends and merges; the next start loads
    /// them instead of folding new ones, which would break the cache.
    pub fn save_views(&self) -> Result<(), String> {
        self.view.save(&self.store.dir, "view.json")?;
        self.context.save(&self.store.dir, "context.json")
    }

    /// Brings the view up to the log after messages were appended.
    pub fn sync(&mut self) {
        while self.view.t < self.store.len() {
            self.view.push();
            self.fit(true);
            self.stale = true;
        }
    }

    /// UniiChat's `Memory.fit`: the view to the log's end and the
    /// compactions' to the first message not built, each merged as `fit`
    /// allows; `next` at a new message.
    pub fn fit(&mut self, next: bool) {
        let first = self.first(0);
        self.context.reach(first);
        self.view.fit(&self.tree, self.budget, next);
        let budget = self.context_budget();
        self.context.fit(&self.tree, budget, next);
    }

    /// UniiChat's `Memory.first`: the message of the (k+1)th leaf not
    /// built, else the view's end.
    pub fn first(&mut self, k: usize) -> u64 {
        let lo = &mut self.pump.lo;
        if lo.is_empty() {
            lo.push(0);
        }
        while lo[0] < self.view.t && self.tree.built(0, lo[0]) {
            lo[0] += 1;
        }
        (lo[0]..self.view.t)
            .filter(|&i| !self.tree.built(0, i))
            .nth(k)
            .unwrap_or(self.view.t)
    }
}

pub struct Shared {
    pub core: Mutex<Core>,
    /// Signalled whenever the view may have changed.
    pub cv: Condvar,
    pub backend: Option<Box<dyn Backend>>,
}

const SEARCH_MAX: usize = 100;
const TAIL_MAX: u64 = 500;
/// How long `hippo view` waits for the compactor before printing
/// placeholders.
const SETTLE: Duration = Duration::from_secs(30);
/// Bytes per page of `hippo view`, under the harnesses' output limits.
const PAGE: usize = 24_000;

/// Runs the service: in code mode with `sources`, in chat mode without.
/// Chat mode also serves and compacts a store nothing writes to (a replayed
/// scratch store, say).
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
    let follow = match sources {
        Some(s) => Some(Follow::new(dir, &store, s)?),
        None => None,
    };
    let budget = match std::env::var("HIPPO_VIEW") {
        Ok(v) => v
            .parse()
            .map_err(|_| format!("HIPPO_VIEW is not a number: {v}"))?,
        Err(_) => VIEW,
    };
    let view = View::load(dir, "view.json", &tree, store.len(), budget);
    let context = View::load(dir, "context.json", &tree, store.len(), CONTEXT.min(budget));
    let shared = Arc::new(Shared {
        core: Mutex::new(Core {
            store,
            tree,
            view,
            budget,
            context,
            pump: Pump {
                spent: Spent::load(dir)?,
                ..Pump::default()
            },
            follow,
            started: Local::now(),
            pages: Vec::new(),
            stale: true,
        }),
        cv: Condvar::new(),
        backend,
    });
    // A saved compactions' view may reach past what is built.
    shared.core.lock().unwrap().fit(false);
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
            if let Some(f) = c.follow.as_mut() {
                f.step(&mut c.store)?;
            }
            c.sync();
            pump(&shared, c);
            if c.stale {
                publish(c)?;
            }
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
        // The last messages whole, one JSON object a line, for programs
        // that show a conversation (yeoman's web chat loads its history so).
        "tail" => {
            let n = num(a, 0, "n")?.min(TAIL_MAX);
            let c = core.lock().unwrap();
            let t = c.store.len();
            let mut out = Vec::new();
            for i in t.saturating_sub(n)..t {
                out.push(serde_json::to_string(&c.store.get(i)?).map_err(|e| e.to_string())?);
            }
            Ok(out.join("\n"))
        }
        "chat" => {
            let [harness, session] = a.as_slice() else {
                return Err("Usage: hippo chat <harness> <session>".into());
            };
            this_chat(&core.lock().unwrap().store, harness, session)
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
        // Only a store that follows nothing takes messages over the
        // socket: one that follows transcripts learns everything there, and
        // a logged `user` line would put words in the user's mouth.
        "log" => {
            if core.lock().unwrap().follow.is_some() {
                return Err("This memory follows transcripts; it takes no logged messages.".into());
            }
            let (kind, text) = a.split_first().ok_or("Missing kind.")?;
            let kind = match kind.as_str() {
                "user" => Kind::User,
                "talk" => Kind::Talk,
                "note" => Kind::Note,
                "work" => Kind::Work,
                other => return Err(format!("Cannot log a {other} message.")),
            };
            let text = text.join(" ");
            if text.trim().is_empty() {
                return Err("Nothing to log.".into());
            }
            let mut c = core.lock().unwrap();
            let ids = c.store.append(vec![Draft {
                kind,
                chat: None,
                text: crate::memory::mask::mask(text.trim()),
                date: Local::now(),
                src: None,
            }])?;
            c.sync();
            pump(shared, &mut c);
            Ok(format!("Logged as message {}.", ids[0]))
        }
        // The seat's PreCompact hook: its cache is about to go, so the batch
        // that would come at the budget comes now, and the view the fresh
        // context loads is already folded.
        "fold" => {
            let mut guard = core.lock().unwrap();
            let c = &mut *guard;
            let before = c.view.size();
            c.view.batch(&c.tree, c.budget);
            publish(c)?;
            Ok(format!(
                "Folded the view from {before} to {} bytes, {} lines.",
                c.view.size(),
                c.view.parts.len()
            ))
        }
        "status" => Ok(status(&core.lock().unwrap(), shared.backend.is_some())),
        "pause" => {
            let c = core.lock().unwrap();
            fs::write(crate::memory::compactor::pause_file(&c.store.dir), "")
                .map_err(|e| e.to_string())?;
            Ok(format!(
                "Paused: no new model calls; {} running finish. Logging goes on.",
                c.pump.busy.len()
            ))
        }
        "resume" => {
            let mut c = core.lock().unwrap();
            match fs::remove_file(crate::memory::compactor::pause_file(&c.store.dir)) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e.to_string()),
            }
            pump(shared, &mut c);
            Ok("Resumed.".into())
        }
        other => Err(format!("Unknown command {other}.")),
    }
}

/// How many of the captain's messages the chat's own block quotes.
const OWN_USER: usize = 4;
/// A quoted message is cut past this many characters; `hippo zoom` has it.
const OWN_CUT: usize = 800;

/// `hippo chat <harness> <session>`: one chat's latest words, verbatim,
/// for the hook that reopens it after a compaction or a resume. The view
/// holds every chat in one timeline, so without this a compacted chat can
/// take up another's work. The captain's last few messages and the chat's
/// last reply, oldest first; nothing for a chat with no messages yet.
fn this_chat(store: &Store, harness: &str, session: &str) -> Result<String, String> {
    let key = chat_key(harness, session);
    let (mut users, mut talk) = (0, false);
    let mut own = Vec::new();
    for i in store.of_chat(&key) {
        if users == OWN_USER {
            break;
        }
        let m = store.get(i)?;
        match m.kind {
            Kind::User => users += 1,
            Kind::Talk if !talk => talk = true,
            _ => continue,
        }
        own.push((i, m));
    }
    if own.is_empty() {
        return Ok(String::new());
    }
    let mut out = String::from("## This chat\n\nYou are ");
    match store.chats.get(&key) {
        Some(rec) if !rec.cwd.is_empty() => out.push_str(&format!(
            "the {harness} chat \"{}\", in {}",
            rec.chat, rec.cwd
        )),
        Some(rec) => out.push_str(&format!("the {harness} chat \"{}\"", rec.chat)),
        None => out.push_str(&key),
    }
    out.push_str(
        ". The view holds every chat; these are this chat's own latest \
         messages, word for word (`hippo zoom <id> 1` opens one whole). \
         Carry on with this chat's work.\n\n",
    );
    for (i, m) in own.iter().rev() {
        let mut text: String = m.text.chars().take(OWN_CUT).collect();
        if text.len() < m.text.len() {
            text.push('…');
        }
        out.push_str(&format!("{i} {}: {text}\n", m.kind.name()));
    }
    Ok(out.trim_end().to_owned())
}

/// `hippo view [page token]`: the whole view, paged. The first call waits
/// for the compactor (up to `SETTLE`, not while it is limited, paused or
/// stuck on a failure),
/// renders once and keeps the pages,
/// so later pages come from the same render. `view whole`, for programs
/// that put the view into a prompt, answers in one piece.
fn view(shared: &Arc<Shared>, a: &[String]) -> Result<String, String> {
    let mut c = shared.core.lock().unwrap();
    let whole = a == ["whole"];
    if !a.is_empty() && !whole {
        let [k, token] = a else {
            return Err("Name the page and its view: hippo view <page> <token>.".into());
        };
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
    let stalled = |c: &Core| {
        c.pump.limit.is_some_and(|t| Local::now() < t)
            || crate::memory::compactor::paused(&c.store.dir)
            || (c.pump.busy.is_empty() && !c.pump.parked.is_empty())
    };
    while c.view.unbuilt(&c.tree) > 0 && !stalled(&c) {
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        if left.is_zero() {
            break;
        }
        c = shared.cv.wait_timeout(c, left).unwrap().0;
    }
    if whole {
        return text(&c);
    }
    let (note, lines) = render(&c)?;
    let mut pages = vec!["<chat>".to_owned()];
    for line in lines {
        let page = pages.last_mut().unwrap();
        if page.len() + line.len() + 1 > PAGE {
            pages.push(line);
        } else {
            page.push('\n');
            page.push_str(&line);
        }
    }
    let last = pages.last_mut().unwrap();
    last.push_str("\n</chat>");
    if !note.is_empty() {
        last.push('\n');
        last.push_str(note.trim_end());
    }
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

/// The view as text: one line per part, oldest first, and a note when
/// recent lines wait for the compactor. The note goes last: it changes
/// from turn to turn, and anything after it would miss the model's
/// prompt cache. With `<chat>` around it, the whole stays within the
/// budget.
fn render(c: &Core) -> Result<(String, Vec<String>), String> {
    let unbuilt = c.view.unbuilt(&c.tree);
    let mut note = String::new();
    if unbuilt > 0 {
        let why = match c.pump.limit {
            Some(t) => format!(" (compactor rate-limited until {})", t.format("%H:%M")),
            None => String::new(),
        };
        note = format!("{unbuilt} recent lines are not summarized yet{why}: zoom them.\n");
    }
    // A session loads the view once, so unlike the compactions' view it
    // need not keep its head between renders.
    let wrap = ("<chat>\n\n</chat>\n".len() + note.len()) as u64;
    let cut = c.view.cut(&c.tree, c.budget.saturating_sub(wrap), c.view.t);
    let mut lines = head(&c.tree, cut)?;
    // A run of unbuilt parts shows as one line: one placeholder per part
    // once grew the view past what it was meant to hold whenever the
    // compactor stalled.
    let mut run: Option<(u64, u64)> = None;
    for &(l, i) in &c.view.parts {
        let (s, n) = addr(l, i);
        if s < cut {
            continue;
        }
        match c.tree.text(l, i)? {
            Some(text) => {
                if let Some((s, n)) = run.take() {
                    lines.push(unbuilt_line(s, n));
                }
                lines.push(format!("{s}+{n}|{}", flat(&text)));
            }
            None => {
                run = Some(match run {
                    Some((rs, rn)) => (rs, rn + n),
                    None => (s, n),
                });
            }
        }
    }
    if let Some((s, n)) = run {
        lines.push(unbuilt_line(s, n));
    }
    Ok((note, lines))
}

/// The line for `n` unbuilt messages from `s`.
fn unbuilt_line(s: u64, n: u64) -> String {
    if n == 1 {
        format!("{s}+1|{PLACEHOLDER}")
    } else {
        format!("{s}+{n}|{UNBUILT}")
    }
}

/// The whole view as one text, as `view.md` holds it.
fn text(c: &Core) -> Result<String, String> {
    let (note, lines) = render(c)?;
    Ok(format!("<chat>\n{}\n</chat>\n{note}", lines.join("\n")))
}

/// While this file exists, `view.md` holds its text instead of the view, so
/// a repair can keep the history out of every new context; like a pause,
/// it outlives restarts. It takes effect at the next publish: at start, or
/// when the next message arrives.
pub fn override_file(store: &Path) -> PathBuf {
    store.join("state/view-override.md")
}

/// Writes the whole view to `view.md` in the store, which the seat's Claude
/// Code loads as a rules file at session start and after each compaction,
/// and both views' parts, which the next start loads.
pub fn publish(c: &mut Core) -> Result<(), String> {
    let over = override_file(&c.store.dir);
    let text = match fs::read_to_string(&over) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => text(c)?,
        Err(e) => return Err(format!("{}: {e}", over.display())),
    };
    let path = c.store.dir.join("view.md");
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, text).map_err(|e| format!("{}: {e}", tmp.display()))?;
    fs::rename(&tmp, &path).map_err(|e| format!("{}: {e}", path.display()))?;
    c.save_views()?;
    c.stale = false;
    Ok(())
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
        return Ok(format!("{id}+1|{}", m.labelled()));
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
    let following = match &c.follow {
        Some(f) => format!(
            "code mode, following transcripts since {}",
            f.live.since().map(|d| fmt_date(&d)).unwrap_or_default()
        ),
        None => "chat mode, taking messages over the socket".to_owned(),
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
    if override_file(&s.dir).exists() {
        out.push_str(&format!(
            "view.md: overridden by {}\n",
            override_file(&s.dir).display()
        ));
    }
    if !compacting {
        out.push_str("compactor: off\n");
    } else if crate::memory::compactor::paused(&s.dir) {
        out.push_str(&format!(
            "compactor: paused (hippo resume); {} running\n",
            c.pump.busy.len()
        ));
    } else {
        out.push_str(&format!("compactor: {} running\n", c.pump.busy.len()));
    }
    let today = Local::now().date_naive();
    let tokens = |u: &crate::memory::compact::Usage| {
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
    let (mut week_calls, mut week) = (0, crate::memory::compact::Usage::default());
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
    if let Some(f) = &c.follow {
        out.push_str(&f.status(s, &c.started));
    }
    let torn: Vec<&String> = s.torn.iter().chain(&c.tree.torn).collect();
    if !torn.is_empty() {
        let torn: Vec<&str> = torn.iter().map(|t| t.as_str()).collect();
        out.push_str(&format!(
            "torn lines skipped at load: {}\n",
            torn.join(", ")
        ));
    }
    out.trim_end().to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::memory::tree::Node;

    /// A store of `n` messages, each its own built line, and no merges:
    /// the state of a paused or backlogged compactor.
    fn stalled(name: &str, n: u64, budget: u64) -> Core {
        let dir = std::env::temp_dir().join(format!("hippo-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let mut store = Store::open(&dir, true).unwrap();
        let drafts = (0..n)
            .map(|k| Draft {
                kind: Kind::Talk,
                chat: Some("c".into()),
                text: format!("message {k} {}", "x".repeat(200)),
                date: Local::now(),
                src: None,
            })
            .collect();
        store.append(drafts).unwrap();
        let mut tree = Tree::open(&dir).unwrap();
        for i in 0..n {
            let text = format!("talk: message {i} {}", "x".repeat(200));
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
        let mut c = Core::for_test(store, tree, View::default(), budget);
        c.sync();
        c
    }

    #[test]
    fn a_stalled_view_publishes_within_its_budget() {
        let mut c = stalled("stalled", 2_000, 50_000);
        assert!(
            c.view.size() > 4 * c.budget,
            "the view did not outgrow its budget"
        );
        publish(&mut c).unwrap();
        let file = fs::read_to_string(c.store.dir.join("view.md")).unwrap();
        assert!(
            file.len() as u64 <= c.budget,
            "view.md {} bytes",
            file.len()
        );
        assert!(file.starts_with("<chat>\n0+1024|") && file.ends_with("</chat>\n"));
        // The newest message keeps its line, and what was cut still opens.
        assert!(file.contains("\n1999+1|talk: message 1999 "));
        assert!(
            zoom(&c.store, &c.tree, 0, 1024)
                .unwrap()
                .starts_with("0+512|")
        );
        assert!(
            zoom(&c.store, &c.tree, 0, 1)
                .unwrap()
                .contains("message 0 ")
        );
    }

    #[test]
    fn a_chat_quotes_only_its_own_latest_words() {
        let dir = std::env::temp_dir().join(format!("hippo-own-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let mut store = Store::open(&dir, true).unwrap();
        let msg = |k: usize, kind, s: &str, text: String| Draft {
            kind,
            chat: Some(s.into()),
            text,
            date: Local::now(),
            src: Some(crate::memory::store::Src {
                h: "claude".into(),
                s: s.into(),
                e: k.to_string(),
            }),
        };
        let mut drafts = Vec::new();
        for k in 0..6 {
            drafts.push(msg(4 * k, Kind::User, "a", format!("a asks {k}")));
            drafts.push(msg(4 * k + 1, Kind::Tool, "a", format!("a runs {k}")));
            drafts.push(msg(4 * k + 2, Kind::Talk, "a", format!("a says {k}")));
            drafts.push(msg(4 * k + 3, Kind::User, "b", format!("b asks {k}")));
        }
        drafts.push(msg(99, Kind::User, "a", "y".repeat(OWN_CUT + 5)));
        store.append(drafts).unwrap();

        let out = this_chat(&store, "claude", "a").unwrap();
        let lines: Vec<&str> = out.lines().filter(|l| l.contains(": ")).collect();
        assert!(out.starts_with("## This chat"));
        assert!(!out.contains("b asks") && !out.contains("a runs"));
        // The last four of the captain's, the last reply only, oldest first.
        assert_eq!(lines[0], "12 user: a asks 3");
        assert_eq!(lines[1], "16 user: a asks 4");
        assert_eq!(lines[2], "20 user: a asks 5");
        assert_eq!(lines[3], "22 talk: a says 5");
        assert!(lines[4].starts_with("24 user: yyy") && lines[4].ends_with("y…"));
        assert_eq!(lines.len(), 5);
        assert_eq!(this_chat(&store, "claude", "fresh").unwrap(), "");
    }

    #[test]
    fn an_override_replaces_the_published_view() {
        let mut c = stalled("override", 20, VIEW);
        let over = override_file(&c.store.dir);
        fs::create_dir_all(over.parent().unwrap()).unwrap();
        fs::write(&over, "Repair: history is offline.\n").unwrap();
        publish(&mut c).unwrap();
        let path = c.store.dir.join("view.md");
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "Repair: history is offline.\n"
        );
        assert!(status(&c, false).contains("view.md: overridden"));
        fs::remove_file(&over).unwrap();
        publish(&mut c).unwrap();
        assert!(
            fs::read_to_string(&path)
                .unwrap()
                .contains("19+1|talk: message 19")
        );
    }
}
