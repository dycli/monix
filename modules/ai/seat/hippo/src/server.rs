//! The service: the only writer. One thread follows the transcripts; the
//! CLI talks to it over `hippo.sock`, one JSON request and reply per
//! connection.

use crate::live::{Live, Sources};
use crate::store::{Draft, Kind, Store, fmt_date};
use crate::watcher::Watcher;
use chrono::{DateTime, Local};
use regex::RegexBuilder;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::{Arc, Mutex};
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
    pub watcher: Watcher,
    pub live: Live,
    pub started: DateTime<Local>,
}

const SEARCH_MAX: usize = 100;

pub fn serve(dir: &Path, sources: Sources) -> Result<(), String> {
    let store = Store::open(dir, true)?;
    for at in &store.torn {
        eprintln!("hippo: torn line at {at} skipped");
    }
    let live = Live::new(&store, sources.clone())?;
    let watcher = Watcher {
        paseo: Some(sources.paseo.clone()),
        ..Watcher::default()
    };
    let core = Arc::new(Mutex::new(Core {
        store,
        watcher,
        live,
        started: Local::now(),
    }));
    let sock = dir.join("hippo.sock");
    let _ = fs::remove_file(&sock);
    let listener = UnixListener::bind(&sock).map_err(|e| format!("{}: {e}", sock.display()))?;
    {
        let core = core.clone();
        thread::spawn(move || {
            for conn in listener.incoming().flatten() {
                let core = core.clone();
                thread::spawn(move || {
                    if let Err(e) = answer(conn, &core) {
                        eprintln!("hippo: request failed: {e}");
                    }
                });
            }
        });
    }
    eprintln!("hippo: serving {}", dir.display());
    loop {
        {
            let mut guard = core.lock().unwrap();
            let c = &mut *guard;
            c.live.scan(&mut c.watcher, &mut c.store)?;
            c.watcher.tick(&mut c.store, Local::now())?;
            c.live.save(&c.watcher)?;
        }
        thread::sleep(Duration::from_secs(1));
    }
}

fn answer(conn: UnixStream, core: &Mutex<Core>) -> Result<(), String> {
    let mut line = String::new();
    BufReader::new(&conn)
        .read_line(&mut line)
        .map_err(|e| e.to_string())?;
    let reply = match serde_json::from_str::<Request>(&line) {
        Ok(req) => match handle(&req, core) {
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

fn handle(req: &Request, core: &Mutex<Core>) -> Result<String, String> {
    let a = &req.args;
    match req.cmd.as_str() {
        "zoom" => {
            let (id, n) = (num(a, 0, "id")?, num(a, 1, "n")?);
            let c = core.lock().unwrap();
            zoom(&c.store, id, n)
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
            Ok(format!("Noted as message {}.", ids[0]))
        }
        "status" => Ok(status(&core.lock().unwrap())),
        other => Err(format!("Unknown command {other}.")),
    }
}

pub fn zoom(store: &Store, id: u64, n: u64) -> Result<String, String> {
    let t = store.len();
    if n == 0 || !n.is_power_of_two() || !id.is_multiple_of(n) || id + n > t {
        return Err(format!("No line {id}+{n}."));
    }
    if n == 1 {
        let m = store.get(id)?;
        return Ok(format!("{id}+1|{}", m.render()));
    }
    Err("Lines above single messages come with the tree, which is not built yet.".into())
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

fn status(c: &Core) -> String {
    let s = &c.store;
    let mut out = format!(
        "{} messages in {} chats, at {}; following since {}.\n",
        s.len(),
        s.chats.len(),
        s.dir.display(),
        c.live.since().map(|d| fmt_date(&d)).unwrap_or_default()
    );
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
    if !s.torn.is_empty() {
        out.push_str(&format!(
            "torn lines skipped at load: {}\n",
            s.torn.join(", ")
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
