mod blocks;

use regex_lite::{Regex, RegexBuilder};
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};

/// Today's local date as `YYYY-MM-DD`, via libc (the fleet-cli/agent-dispatch
/// shape) — the standard-library-only alternative to a chrono dependency.
fn today() -> String {
    let tm = unsafe {
        let now = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&now, &mut tm);
        tm
    };
    format!("{:04}-{:02}-{:02}", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday)
}

const ENTRY_CHARS: usize = 280;
const WAKE_LINES: usize = 208;
const RAW_MAX: usize = 16;
const PART_CHARS: usize = 20000;
const PART_LINES: usize = 500;
const LOG_REC: usize = 320;
const TREE_REC: usize = 288;

const USAGE: &str = r#"OptMem: a permanent, append-only memory for AI agents.

  memo wake [part [T]]     read your memory. Run first, every session.
  memo note "..."          record one memory: one line, at most 280 chars.
  memo nap [id "..."]      do the pending compressions.
  memo recall <regex>      search every memory ever recorded.
  memo zoom <lo>-<hi>      open a tree node: its two halves.
  memo forget <lo>-<hi>    drop a bad summary; nap rebuilds it.
  memo import <file>       bulk-load dated memories (bootstrap only).

Everything lives in $MEMORY_DIR. See README.md."#;

#[derive(Clone, Copy)]
struct Config {
    entry_chars: usize,
    wake_lines: usize,
    part_chars: usize,
    part_lines: usize,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            entry_chars: ENTRY_CHARS,
            wake_lines: WAKE_LINES,
            part_chars: PART_CHARS,
            part_lines: PART_LINES,
        }
    }
}

#[derive(Clone)]
struct Entry {
    id: usize,
    date: String,
    text: String,
}

fn die<T>(msg: impl Into<String>) -> Result<T, String> {
    Err(msg.into())
}

fn store() -> Result<PathBuf, String> {
    let raw = env::var("MEMORY_DIR")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| option_env!("MEMO_MEMORY_DIR").map(str::to_owned))
        .ok_or_else(|| "MEMORY_DIR is not set. Example: export MEMORY_DIR=~/memory".to_owned())?;
    let expanded = if raw == "~" || raw.starts_with("~/") {
        let home = env::var("HOME").unwrap_or_else(|_| "~".to_owned());
        PathBuf::from(home).join(raw.strip_prefix("~/").unwrap_or(""))
    } else {
        PathBuf::from(&raw)
    };
    if !expanded.is_dir() {
        return die(format!(
            "MEMORY_DIR={} does not exist.\nIf this is a new identity, run: mkdir -p {}",
            expanded.display(),
            expanded.display()
        ));
    }
    fs::create_dir_all(expanded.join("TREE")).map_err(|e| e.to_string())?;
    let log = expanded.join("LOG.txt");
    if !log.exists() {
        File::create(&log).map_err(|e| e.to_string())?;
    }
    Ok(expanded)
}

fn config(d: &Path) -> Result<Config, String> {
    let mut c = Config::default();
    let p = d.join("config");
    if p.exists() {
        let src = fs::read_to_string(p).map_err(|e| e.to_string())?;
        for raw in src.lines() {
            let line = raw.split('#').next().unwrap().trim();
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            let value: usize = value.trim().parse().map_err(|e| format!("{e}"))?;
            match key.trim() {
                "ENTRY_CHARS" => c.entry_chars = value,
                "WAKE_LINES" => c.wake_lines = value,
                "PART_CHARS" => c.part_chars = value,
                "PART_LINES" => c.part_lines = value,
                _ => {}
            }
        }
    }
    if c.entry_chars > (TREE_REC - 8).min(LOG_REC - 40) {
        return die(format!(
            "config: ENTRY_CHARS={} does not fit the {LOG_REC}/{TREE_REC}-byte records.",
            c.entry_chars
        ));
    }
    Ok(c)
}

fn log_path(d: &Path) -> PathBuf {
    d.join("LOG.txt")
}
fn tree_path(d: &Path, size: usize) -> PathBuf {
    d.join("TREE").join(size.to_string())
}
fn count(path: &Path, rec: usize) -> usize {
    fs::metadata(path)
        .map(|m| m.len() as usize / rec)
        .unwrap_or(0)
}
fn log_len(d: &Path) -> usize {
    count(&log_path(d), LOG_REC)
}

fn repair(path: &Path, rec: usize) -> Result<(), String> {
    let Ok(meta) = fs::metadata(path) else {
        return Ok(());
    };
    let n = meta.len() as usize;
    if !n.is_multiple_of(rec) {
        OpenOptions::new()
            .write(true)
            .open(path)
            .map_err(|e| e.to_string())?
            .set_len((n - n % rec) as u64)
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn parse(bytes: &[u8]) -> Result<Entry, String> {
    let line = std::str::from_utf8(bytes)
        .map_err(|e| e.to_string())?
        .trim_end();
    let (head, rest) = line.split_once(' ').unwrap_or((line, ""));
    let (date, text) = rest.split_once(' ').unwrap_or((rest, ""));
    Ok(Entry {
        id: head
            .strip_prefix('#')
            .unwrap_or("")
            .parse()
            .map_err(|e| format!("{e}"))?,
        date: date.to_owned(),
        text: text.to_owned(),
    })
}

fn log_get(d: &Path, i: usize) -> Result<Entry, String> {
    let mut f = File::open(log_path(d)).map_err(|e| e.to_string())?;
    f.seek(SeekFrom::Start((i * LOG_REC) as u64))
        .map_err(|e| e.to_string())?;
    let mut rec = vec![0; LOG_REC];
    f.read_exact(&mut rec).map_err(|e| e.to_string())?;
    parse(&rec)
}

fn log_slice(d: &Path, lo: usize, hi: usize) -> Result<Vec<Entry>, String> {
    let mut f = File::open(log_path(d)).map_err(|e| e.to_string())?;
    f.seek(SeekFrom::Start((lo * LOG_REC) as u64))
        .map_err(|e| e.to_string())?;
    let mut buf = vec![0; (hi - lo) * LOG_REC];
    f.read_exact(&mut buf).map_err(|e| e.to_string())?;
    buf.chunks_exact(LOG_REC).map(parse).collect()
}

fn tree_get(d: &Path, lo: usize, hi: usize) -> Result<Option<String>, String> {
    let size = hi - lo;
    let Ok(mut f) = File::open(tree_path(d, size)) else {
        return Ok(None);
    };
    f.seek(SeekFrom::Start((lo / size * TREE_REC) as u64))
        .map_err(|e| e.to_string())?;
    let mut rec = vec![0; TREE_REC];
    let n = f.read(&mut rec).map_err(|e| e.to_string())?;
    let text = std::str::from_utf8(&rec[..n])
        .map_err(|e| e.to_string())?
        .trim_end();
    Ok((!text.is_empty()).then(|| text.to_owned()))
}

fn pad(text: &str, rec: usize) -> Result<Vec<u8>, String> {
    if text.len() > rec - 1 {
        return die(format!(
            "Too long: {} bytes. The record holds {}.",
            text.len(),
            rec - 1
        ));
    }
    let mut out = Vec::with_capacity(rec);
    out.extend_from_slice(text.as_bytes());
    out.resize(rec - 1, b' ');
    out.push(b'\n');
    Ok(out)
}

struct Lock(File);
impl Lock {
    fn take(d: &Path) -> Result<Self, String> {
        let f = File::create(d.join(".lock")).map_err(|e| e.to_string())?;
        // SAFETY: flock only uses this live file descriptor.
        if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX) } != 0 {
            return die(std::io::Error::last_os_error().to_string());
        }
        Ok(Self(f))
    }
}
impl Drop for Lock {
    fn drop(&mut self) {
        // SAFETY: the descriptor remains live until this drop completes.
        unsafe { libc::flock(self.0.as_raw_fd(), libc::LOCK_UN) };
    }
}

fn log_append(d: &Path, items: &[(String, String)]) -> Result<usize, String> {
    let _lock = Lock::take(d)?;
    let p = log_path(d);
    repair(&p, LOG_REC)?;
    let base = log_len(d);
    let mut f = OpenOptions::new()
        .append(true)
        .open(p)
        .map_err(|e| e.to_string())?;
    for (k, (date, text)) in items.iter().enumerate() {
        f.write_all(&pad(&format!("#{} {date} {text}", base + k), LOG_REC)?)
            .map_err(|e| e.to_string())?;
    }
    f.flush().map_err(|e| e.to_string())?;
    f.sync_all().map_err(|e| e.to_string())?;
    Ok(base)
}

fn tree_put(d: &Path, lo: usize, hi: usize, text: &str) -> Result<bool, String> {
    let size = hi - lo;
    let _lock = Lock::take(d)?;
    let p = tree_path(d, size);
    repair(&p, TREE_REC)?;
    if count(&p, TREE_REC) != lo / size {
        return Ok(false);
    }
    let mut f = OpenOptions::new()
        .create(true)
        .append(true)
        .open(p)
        .map_err(|e| e.to_string())?;
    f.write_all(&pad(text, TREE_REC)?)
        .map_err(|e| e.to_string())?;
    f.flush().map_err(|e| e.to_string())?;
    f.sync_all().map_err(|e| e.to_string())?;
    Ok(true)
}

fn tree_drop(d: &Path, lo: usize, hi: usize) -> Result<Vec<(usize, usize)>, String> {
    let mut gone = Vec::new();
    let mut size = hi - lo;
    let _lock = Lock::take(d)?;
    while size <= log_len(d) {
        let p = tree_path(d, size);
        let k = lo / size;
        let n = count(&p, TREE_REC);
        if n > k {
            gone.extend((k..n).map(|i| (i * size, (i + 1) * size)));
            OpenOptions::new()
                .write(true)
                .open(p)
                .map_err(|e| e.to_string())?
                .set_len((k * TREE_REC) as u64)
                .map_err(|e| e.to_string())?;
        }
        size *= 2;
    }
    Ok(gone)
}

fn plural(n: usize, word: &str) -> String {
    if n == 1 {
        return format!("1 {word}");
    }
    let word = if word.ends_with('y') {
        format!("{}ie", &word[..word.len() - 1])
    } else if word.ends_with(['s', 'h', 'x']) {
        format!("{word}e")
    } else {
        word.to_owned()
    };
    format!("{n} {word}s")
}

fn check(text: &str, c: Config) -> Result<String, String> {
    let text = text.trim();
    if text.is_empty() {
        return die("Empty. A memory is one line of text.");
    }
    if text.contains(['\n', '\r']) {
        return die(format!(
            "{} lines. A memory is one line: merge them, or note them separately.",
            text.matches('\n').count() + 1
        ));
    }
    if text.len() > c.entry_chars {
        return die(format!(
            "Too long: {} bytes, limit {}. Accented characters cost 2 bytes. Compress it further.",
            text.len(),
            c.entry_chars
        ));
    }
    Ok(text.to_owned())
}

fn pending(d: &Path, t: usize, limit: Option<usize>) -> Vec<(usize, usize)> {
    let mut todo = Vec::new();
    let mut size = 2;
    while size <= t {
        let have = count(&tree_path(d, size), TREE_REC);
        for k in have..t / size {
            todo.push((k * size, (k + 1) * size));
            if limit.is_some_and(|limit| todo.len() >= limit) {
                return todo;
            }
        }
        size *= 2;
    }
    todo
}

fn pending_count(d: &Path, t: usize) -> usize {
    let (mut n, mut size) = (0, 2);
    while size <= t {
        n += (t / size).saturating_sub(count(&tree_path(d, size), TREE_REC));
        size *= 2;
    }
    n
}

fn nap_prompt(d: &Path, lo: usize, hi: usize, left: usize, c: Config) -> Result<String, String> {
    let body = if hi - lo <= RAW_MAX {
        log_slice(d, lo, hi)?
            .into_iter()
            .map(|e| format!("  #{} {} {}", e.id, e.date, e.text))
            .collect::<Vec<_>>()
            .join("\n")
    } else {
        let mid = (lo + hi) / 2;
        let mut halves = Vec::new();
        for (a, b) in [(lo, mid), (mid, hi)] {
            let Some(s) = tree_get(d, a, b)? else {
                // pending() lists a block only after its halves settled, so a
                // missing half is a blank record — a corrupt write.
                return die(format!(
                    "The summary of #{a}-{} is blank. Run: memo forget {a}-{}",
                    b - 1,
                    b - 1
                ));
            };
            halves.push(format!("  #{a}-{} {s}", b - 1));
        }
        halves.join("\n")
    };
    let tail = if left == 0 {
        String::new()
    } else if left == 1 {
        "\n1 compression remains after this one.".to_owned()
    } else {
        format!("\n{left} compressions remain after this one.")
    };
    Ok(format!(
        "Compress memories #{lo}-{} into one line of at most {} characters.\n\
         Keep what has lasting effect, drop what does not. Invent nothing.\n\n\
         {body}\n{tail}\n\
         Run: memo nap {lo}-{} \"<your line>\"",
        hi - 1,
        c.entry_chars,
        hi - 1
    ))
}

fn next_nap(d: &Path, t: usize, c: Config) -> Result<Option<String>, String> {
    let Some(&(lo, hi)) = pending(d, t, Some(1)).first() else {
        return Ok(None);
    };
    Ok(Some(nap_prompt(d, lo, hi, pending_count(d, t) - 1, c)?))
}

fn paginate(lines: Vec<String>, c: Config) -> Vec<Vec<String>> {
    let (mut parts, mut cur, mut size) = (Vec::new(), Vec::new(), 0);
    for line in lines {
        let n = line.len() + 1;
        if !cur.is_empty() && (cur.len() >= c.part_lines || size + n > c.part_chars) {
            parts.push(cur);
            cur = Vec::new();
            size = 0;
        }
        cur.push(line);
        size += n;
    }
    if !cur.is_empty() {
        parts.push(cur)
    }
    parts
}

fn cmd_wake(d: &Path, args: &[String], c: Config) -> Result<(), String> {
    let now = log_len(d);
    let (mut k, mut t) = (1, now);
    if !args.is_empty() {
        if args.len() > 2
            || args
                .iter()
                .any(|a| a.is_empty() || !a.bytes().all(|b| b.is_ascii_digit()))
        {
            return die("usage: memo wake [part [T]]");
        }
        k = args[0].parse().map_err(|e| format!("{e}"))?;
        if args.len() == 2 {
            t = args[1].parse().map_err(|e| format!("{e}"))?;
            if t > now {
                return die(format!(
                    "T={t}, but the memory holds {}. Run: memo wake",
                    plural(now, "entry")
                ));
            }
        }
    }
    if t == 0 {
        println!("No memories yet. Record the first with: memo note \"<one line>\"");
        println!("You are awake.");
        return Ok(());
    }
    let mut lines = Vec::new();
    for (lo, hi) in blocks::cover(t, c.wake_lines) {
        if hi - lo == 1 {
            let e = log_get(d, lo)?;
            lines.push(format!("#{} {} {}", e.id, e.date, e.text));
        } else {
            let Some(s) = tree_get(d, lo, hi)? else {
                // Refuse only when the document itself needs this summary;
                // pending work the document does not need is handed over
                // after the read instead.
                if let Some(nap) = next_nap(d, t, c)? {
                    println!(
                        "Cannot wake: the memory context needs #{lo}-{}, which is \
                         not compressed yet.\nDo the {} below, then run memo wake \
                         again.\n",
                        hi - 1,
                        plural(pending_count(d, t), "compression")
                    );
                    println!("{nap}");
                    std::process::exit(1);
                }
                return die(format!(
                    "The summary of #{lo}-{} is blank. Run: memo forget {lo}-{}",
                    hi - 1,
                    hi - 1
                ));
            };
            lines.push(format!("#{lo}-{} {s}", hi - 1));
        }
    }
    let parts = paginate(lines, c);
    if k == 0 || k > parts.len() {
        return die(format!(
            "No part {k}: the memory has {}. Run: memo wake",
            plural(parts.len(), "part")
        ));
    }
    if parts.len() > 1 {
        println!(
            "Your memory, part {k} of {}, oldest first ({}).",
            parts.len(),
            plural(t, "memory")
        );
    }
    println!("{}", parts[k - 1].join("\n"));
    if k < parts.len() {
        println!("Not awake yet. Run: memo wake {} {t}", k + 1);
    } else {
        println!("You are awake.");
        if let Some(nap) = next_nap(d, t, c)? {
            println!("\n{nap}");
        }
    }
    Ok(())
}

fn cmd_note(d: &Path, args: &[String], c: Config) -> Result<(), String> {
    if args.len() != 1 {
        return die(format!(
            "usage: memo note \"<one line, at most {} chars>\"",
            c.entry_chars
        ));
    }
    let text = check(&args[0], c)?;
    let i = log_append(d, &[(today(), text)])?;
    println!("Saved as #{i}.");
    if let Some(nap) = next_nap(d, i + 1, c)? {
        println!("\n{nap}");
    }
    Ok(())
}

fn block_id(arg: &str) -> Option<(usize, usize)> {
    let caps = Regex::new(r"^(\d+)-(\d+)$").unwrap().captures(arg)?;
    Some((caps[1].parse().ok()?, caps[2].parse::<usize>().ok()? + 1))
}

fn cmd_nap(d: &Path, args: &[String], c: Config) -> Result<(), String> {
    let t = log_len(d);
    let said = !args.is_empty();
    if said {
        if args.len() != 2 {
            return die("usage: memo nap <lo>-<hi> \"<one line>\"");
        }
        let Some((lo, hi)) = block_id(&args[0]) else {
            return die(format!(
                "'{}' is not a block id. Copy it from the prompt.",
                args[0]
            ));
        };
        let todo = pending(d, t, Some(1));
        if todo.is_empty() {
            println!("Nothing left to compress.");
            return Ok(());
        }
        if (lo, hi) != todo[0] {
            if tree_get(d, lo, hi)?.is_some() {
                println!("{lo}-{} is already settled.", hi - 1);
            } else {
                return die(format!(
                    "Wrong block: {}. Blocks are built in order; the next is {}-{}. Run: memo nap",
                    args[0],
                    todo[0].0,
                    todo[0].1 - 1
                ));
            }
        } else if !tree_put(d, lo, hi, &check(&args[1], c)?)? {
            println!("{lo}-{} was settled or forgotten meanwhile.", hi - 1);
        } else {
            println!("{lo}-{} saved.", hi - 1);
        }
    }
    let Some(nap) = next_nap(d, t, c)? else {
        println!("Nothing left to compress.");
        return Ok(());
    };
    println!("{}{nap}", if said { "\n" } else { "" });
    Ok(())
}

fn cmd_forget(d: &Path, args: &[String]) -> Result<(), String> {
    if args.len() != 1 {
        return die("usage: memo forget <lo>-<hi>");
    }
    let Some((lo, hi)) = block_id(&args[0]) else {
        return die(format!("'{}' is not a block id.", args[0]));
    };
    let size = hi - lo;
    if size < 2 || !size.is_power_of_two() || !lo.is_multiple_of(size) {
        return die(format!(
            "{} is not a block. Copy the id printed by wake, like 16-31.",
            args[0]
        ));
    }
    let gone = tree_drop(d, lo, hi)?;
    if gone.is_empty() {
        return die(format!("No summary at {}.", args[0]));
    }
    println!(
        "Forgot {}, from {}-{} up. Run: memo nap",
        plural(gone.len(), "summary"),
        gone[0].0,
        gone[0].1 - 1
    );
    Ok(())
}

fn cmd_recall(d: &Path, args: &[String], c: Config) -> Result<(), String> {
    if args.len() != 1 {
        return die("usage: memo recall <regex>");
    }
    let pat = RegexBuilder::new(&args[0])
        .case_insensitive(true)
        .build()
        .map_err(|e| format!("bad regex: {e}"))?;
    let hits: Vec<_> = log_slice(d, 0, log_len(d))?
        .into_iter()
        .filter(|e| pat.is_match(&format!("#{} {} {}", e.id, e.date, e.text)))
        .collect();
    if hits.is_empty() {
        println!("No match.");
        return Ok(());
    }
    let (mut out, mut size) = (Vec::new(), 0);
    for e in hits.iter().rev() {
        let line = format!("#{} {} {}", e.id, e.date, e.text);
        size += line.len() + 1;
        if size > c.part_chars {
            break;
        }
        out.push(line);
    }
    out.reverse();
    println!("{}", out.join("\n"));
    if out.len() < hits.len() {
        println!(
            "Newest {} of {}. Narrow the regex.",
            out.len(),
            plural(hits.len(), "match")
        );
    } else {
        println!("{}.", plural(hits.len(), "match"));
    }
    Ok(())
}

fn cmd_import(d: &Path, args: &[String], c: Config) -> Result<(), String> {
    if args.len() != 1 {
        return die("usage: memo import <file>   # lines of 'YYYY-MM-DD <text>'");
    }
    let src = fs::read_to_string(&args[0]).map_err(|e| {
        format!(
            "Cannot read {}: {}",
            args[0],
            e.raw_os_error()
                .map(|n| std::io::Error::from_raw_os_error(n).to_string())
                .unwrap_or_else(|| e.to_string())
        )
    })?;
    let mut last = if log_len(d) == 0 {
        "0000-00-00".to_owned()
    } else {
        log_get(d, log_len(d) - 1)?.date
    };
    let date_re = Regex::new(r"^\d{4}-\d{2}-\d{2}$").unwrap();
    let mut out = Vec::new();
    for (i, raw) in src.split_inclusive('\n').enumerate() {
        let line = raw.strip_suffix('\n').unwrap_or(raw);
        if line.trim().is_empty() {
            continue;
        }
        let (date, text) = line.split_once(' ').unwrap_or((line, ""));
        if !date_re.is_match(date) {
            return die(format!(
                "line {}: expected 'YYYY-MM-DD <text>', got: {line}",
                i + 1
            ));
        }
        if date < last.as_str() {
            return die(format!(
                "line {}: date {date} precedes the previous memory ({last}).",
                i + 1
            ));
        }
        let text = text.trim();
        if text.is_empty() || text.len() > c.entry_chars {
            return die(format!(
                "line {}: {} bytes, limit {}.",
                i + 1,
                text.len(),
                c.entry_chars
            ));
        }
        out.push((date.to_owned(), text.to_owned()));
        last = date.to_owned();
    }
    if out.is_empty() {
        return die(format!("{} has no memories.", args[0]));
    }
    let base = log_append(d, &out)?;
    println!(
        "Imported {}, #{base} to #{}.",
        plural(out.len(), "memory"),
        base + out.len() - 1
    );
    let n = pending_count(d, log_len(d));
    if n > 0 {
        println!("{} pending. Run: memo nap", plural(n, "compression"))
    }
    Ok(())
}

fn cmd_zoom(d: &Path, args: &[String]) -> Result<(), String> {
    // One node of the tree, opened: its two halves, each rendered as wake
    // renders it. The navigating intelligence is the agent's; the tool only
    // reads.
    if args.len() != 1 {
        return die("usage: memo zoom <lo>-<hi>   # a block id, as wake prints them");
    }
    let Some((lo, hi)) = block_id(&args[0]) else {
        return die(format!(
            "'{}' is not a block id. Copy it from wake's output.",
            args[0]
        ));
    };
    let size = hi - lo;
    if size < 2 || !size.is_power_of_two() || !lo.is_multiple_of(size) {
        return die(format!(
            "{} is not a block. Copy the id printed by wake, like 16-31.",
            args[0]
        ));
    }
    let t = log_len(d);
    if lo >= t {
        return die(format!(
            "#{} is beyond the memory: it holds {}. Run: memo wake",
            args[0],
            plural(t, "memory")
        ));
    }
    let mid = (lo + hi) / 2;
    for (a, b) in [(lo, mid), (mid, hi)] {
        if a >= t {
            continue; // the future: no memories there yet
        }
        if b - a == 1 {
            let e = log_get(d, a)?;
            println!("#{} {} {}", e.id, e.date, e.text);
        } else {
            println!(
                "#{a}-{} {}",
                b - 1,
                tree_get(d, a, b)?.unwrap_or_else(|| "not compressed yet".to_owned())
            );
        }
    }
    Ok(())
}

fn run() -> Result<(), String> {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty() {
        println!("{USAGE}");
        return Ok(());
    }
    if !matches!(
        args[0].as_str(),
        "wake" | "note" | "nap" | "recall" | "zoom" | "forget" | "import"
    ) {
        eprintln!("No such command: {}\n", args[0]);
        eprintln!("{USAGE}");
        std::process::exit(1);
    }
    let d = store()?;
    let c = config(&d)?;
    match args[0].as_str() {
        "wake" => cmd_wake(&d, &args[1..], c),
        "note" => cmd_note(&d, &args[1..], c),
        "nap" => cmd_nap(&d, &args[1..], c),
        "recall" => cmd_recall(&d, &args[1..], c),
        "zoom" => cmd_zoom(&d, &args[1..]),
        "forget" => cmd_forget(&d, &args[1..]),
        "import" => cmd_import(&d, &args[1..], c),
        _ => unreachable!(),
    }
}

fn main() {
    if let Err(msg) = run() {
        eprintln!("{msg}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::{TREE_REC, pending, pending_count};
    use std::fs::{self, File};
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn pending_count_clamps_levels_ahead_of_snapshot() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let d = std::env::temp_dir().join(format!("memo-pending-{}-{unique}", std::process::id()));
        fs::create_dir_all(d.join("TREE")).unwrap();
        for (size, records) in [(2, 20), (4, 10), (8, 4), (16, 2), (32, 1)] {
            File::create(d.join("TREE").join(size.to_string()))
                .unwrap()
                .set_len((records * TREE_REC) as u64)
                .unwrap();
        }
        for t in 1..40 {
            assert_eq!(pending_count(&d, t), pending(&d, t, None).len(), "T={t}");
        }
        fs::remove_dir_all(d).unwrap();
    }
}
