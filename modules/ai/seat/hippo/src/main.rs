//! hippo: the bridge seat's episodic memory. It records every chat of the
//! seat word for word and serves it back. `hippo serve` is the service and
//! the only writer; every other command asks it over its socket.

mod browse;
mod compact;
mod compactor;
mod live;
mod mask;
mod server;
mod source;
mod store;
mod tree;
mod view;
mod watcher;

use chrono::{DateTime, Local, NaiveDate, TimeZone};
use live::Sources;
use server::{Reply, Request};
use std::env;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const USAGE: &str = "\
Usage:
  hippo view               the whole history as one-line summaries
  hippo zoom <id> <n>      open line id+n; n = 1 prints message id whole
  hippo date <id>          date and time of message id
  hippo search <regex>     search every message, word for word
  hippo note \"<text>\"      pin a fact as a note
  hippo status             what the service is doing
  hippo pause / resume     stop or restart the compactor's model calls;
                           logging goes on
  hippo browse <file.html> write the whole memory as one HTML page
Service and maintenance:
  hippo serve [--no-follow]
                           run the service (the only writer); without
                           following, it only serves and compacts its store
  hippo audit [YYYY-MM-DD] check a day of the log against the transcripts
  hippo import [--since YYYY-MM-DD]
                           bootstrap an empty store with every past chat,
                           reduced, including any dropped in ~/hold/import
                           (claude/, codex/, opencode/); the service starts
                           after
  hippo replay <store> <from> <to>
                           rebuild a scratch store from transcripts
                           written between two dates (YYYY-MM-DD[THH:MM])";

fn dir() -> PathBuf {
    env::var_os("HIPPO_DIR")
        .map(PathBuf::from)
        .or_else(|| option_env!("HIPPO_DIR").map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("/srv/storage/hippo"))
}

/// The NAS archive of the seat's transcripts, read by the import.
fn archive() -> PathBuf {
    env::var_os("HIPPO_ARCHIVE")
        .map(PathBuf::from)
        .or_else(|| option_env!("HIPPO_ARCHIVE").map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("/srv/storage/transcripts"))
}

fn sources() -> Sources {
    let home = env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    Sources::home(&home)
}

fn ask(cmd: &str, args: &[String]) -> Result<String, String> {
    let sock = dir().join("hippo.sock");
    let mut conn = UnixStream::connect(&sock).map_err(|e| {
        format!(
            "The hippo service is not answering at {}: {e}",
            sock.display()
        )
    })?;
    let mut raw = serde_json::to_vec(&Request {
        cmd: cmd.to_owned(),
        args: args.to_vec(),
    })
    .map_err(|e| e.to_string())?;
    raw.push(b'\n');
    conn.write_all(&raw).map_err(|e| e.to_string())?;
    let mut line = String::new();
    BufReader::new(&conn)
        .read_line(&mut line)
        .map_err(|e| e.to_string())?;
    let reply: Reply = serde_json::from_str(&line).map_err(|e| format!("bad reply: {e}"))?;
    if reply.ok {
        Ok(reply.out)
    } else {
        Err(reply.out)
    }
}

/// A local date or date-time, as the start of that day or minute.
fn when(s: &str) -> Result<DateTime<Local>, String> {
    let naive = chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M")
        .or_else(|_| {
            NaiveDate::parse_from_str(s, "%Y-%m-%d").map(|d| d.and_hms_opt(0, 0, 0).unwrap())
        })
        .map_err(|_| format!("Not a date: {s}"))?;
    Local
        .from_local_datetime(&naive)
        .earliest()
        .ok_or_else(|| format!("No such local time: {s}"))
}

fn audit(day: Option<&String>) -> Result<String, String> {
    let from = match day {
        Some(d) => when(d)?,
        None => when(&Local::now().format("%Y-%m-%d").to_string())?,
    };
    let to = from + chrono::Duration::days(1);
    let store = store::Store::open(&dir(), false)?;
    let live = live::Live::new(&store, sources())?;
    live::audit(&store, &live.sources, from, to, live.since())
}

fn replay(args: &[String]) -> Result<String, String> {
    let [target, from, to] = args else {
        return Err(USAGE.into());
    };
    let (from, to) = (when(from)?, when(to)?);
    let mut store = store::Store::open(Path::new(target), true)?;
    let sources = sources();
    let mut w = watcher::Watcher {
        paseo: Some(sources.paseo.clone()),
        ..watcher::Watcher::default()
    };
    live::replay(&mut store, &mut w, &sources, from, to)?;
    Ok(format!(
        "{} messages in {} chats; {} entries unparsed.",
        store.len(),
        store.chats.len(),
        w.unparsed_total
    ))
}

fn serve(args: &[String]) -> Result<String, String> {
    let follow = match args {
        [] => true,
        [flag] if flag == "--no-follow" => false,
        _ => return Err(USAGE.into()),
    };
    let backend = match env::var("HIPPO_BACKEND").as_deref() {
        Ok("none") => None,
        _ => Some(compact::from_env()?),
    };
    server::serve(&dir(), follow.then(sources), backend).map(|_| String::new())
}

fn browse(args: &[String]) -> Result<String, String> {
    let [path] = args else {
        return Err(USAGE.into());
    };
    let html = ask("browse", &[])?;
    std::fs::write(path, html).map_err(|e| format!("{path}: {e}"))?;
    Ok(format!("Wrote {path}."))
}

fn import(args: &[String]) -> Result<String, String> {
    let home = env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let sources = sources()
        .with_archive(&archive())
        .with_drop(&home.join("hold/import"));
    let mut since = None;
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        match (arg.as_str(), rest.next()) {
            ("--since", Some(d)) => since = Some(when(d)?),
            _ => return Err(USAGE.into()),
        }
    }
    let mut store = store::Store::open(&dir(), true)?;
    let mut w = watcher::Watcher {
        paseo: Some(sources.paseo.clone()),
        ..watcher::Watcher::default()
    };
    live::import(&mut store, &mut w, &sources, since)
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    let (cmd, rest) = match args.split_first() {
        Some((c, r)) => (c.as_str(), r),
        None => ("help", &[][..]),
    };
    let result = match cmd {
        "serve" => serve(rest),
        "audit" => audit(rest.first()),
        "replay" => replay(rest),
        "import" => import(rest),
        "view" | "zoom" | "date" | "search" | "status" | "pause" | "resume" => ask(cmd, rest),
        "browse" => browse(rest),
        "note" => ask(cmd, &[rest.join(" ")]),
        "help" | "-h" | "--help" => Ok(USAGE.into()),
        _ => Err(USAGE.into()),
    };
    match result {
        Ok(out) => {
            if !out.is_empty() {
                println!("{out}");
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}
