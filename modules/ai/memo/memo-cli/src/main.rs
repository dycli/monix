mod blocks;

use regex::{Regex, RegexBuilder};
use std::collections::{HashMap, VecDeque};
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{BufReader, Read, Seek, SeekFrom, Write};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};

/// Today's local date as `YYYY-MM-DD`, via libc's localtime_r.
fn today() -> String {
    let tm = unsafe {
        let now = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&now, &mut tm);
        tm
    };
    format!(
        "{:04}-{:02}-{:02}",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday
    )
}

const ENTRY_CHARS: usize = 280;
const WAKE_LINES: usize = 96;
const RAW_MAX: usize = 16;
const PART_CHARS: usize = 20000;
const PART_LINES: usize = 500;
const LOG_REC: usize = 320;
const TREE_REC: usize = 288;
const KNOBS: [(&str, usize, &str); 4] = [
    (
        "WAKE_LINES",
        WAKE_LINES,
        "the memory context: how many lines wake prints",
    ),
    (
        "ENTRY_CHARS",
        ENTRY_CHARS,
        "the longest one memory may be, in bytes",
    ),
    (
        "PART_CHARS",
        PART_CHARS,
        "output paging: largest part, in bytes",
    ),
    (
        "PART_LINES",
        PART_LINES,
        "output paging: largest part, in lines",
    ),
];

const USAGE: &str = r#"OptMem: a permanent, append-only memory for AI agents.

  memo init                 create this memory; print the setup block.
  memo wake [part [T]]     read your memory. Run first, every session.
  memo note "..."          record one memory: one short line.
  memo nap [id "..."]      do the pending compressions.
  memo recall <regex>      search every memory ever recorded.
  memo zoom <lo>-<hi>      open a tree node: its two halves.
  memo forget <lo>-<hi>    drop a bad summary; nap rebuilds it.
  memo config [NAME=N]     show this memory's sizes, or change one.
  memo import <file>       bulk-load dated memories (bootstrap only).

The memories live in the Nix-configured directory, or in $MEMORY_DIR if set.
See github.com/VictorTaelin/OptMem."#;

const TEMPLATE: &str = r#"## Memory

Your memory is OptMem:
- The tool is `memo`
- Your memories are in `{data}`

OptMem outlives every session, compaction, model and vendor change.
Without it you do not know who you are, or what was decided and tried.

### At startup: activating OptMem (mandatory)

Run `memo wake` before any other tool call, in every session, and
then do exactly what it prints, to the end of its output.

### While working: register memories (mandatory)

Call `memo note "<1 line, max {bytes} bytes>"` whenever you learn
something new, or something worth keeping happens. That covers a task
worth real effort, a fact or insight the user teaches you, anything you
learn about their life (even indirectly), any event of lasting effect.

Do not register redundant memories.

If `memo note` asks a compression: do it before your next action.

Never edit or delete anything under `{data}`: the tool manages it.

### When you need an old memory: search, or navigate

`memo recall <regex>` searches every memory, word for word.

Your memories also form a binary tree: #0-1, #2-3 ... exist as one-line
summaries, pairs of those as #0-3, and so on -- every `#a-b` line wake
prints is one node of it. `memo zoom <a-b>` opens a node into its
two halves, down to the raw memories.

### If you're a subagent: skip everything above

Parallel sessions on this machine are all you, and may all write memories.
A subagent is not: it must never run `memo`, because it cannot judge what
is already known, and its notes would arrive duplicated and incorrectly.
When you spawn one, write: `You are a subagent. Don't run memo.`"#;

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

fn memory_dir() -> Result<PathBuf, String> {
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
    Ok(expanded)
}

fn pretty(path: &Path) -> String {
    let Ok(home) = env::var("HOME") else {
        return path.display().to_string();
    };
    path.strip_prefix(&home)
        .map(|rest| format!("~/{}", rest.display()))
        .unwrap_or_else(|_| path.display().to_string())
}

fn store() -> Result<PathBuf, String> {
    let expanded = memory_dir()?;
    if !expanded.is_dir() {
        return die(format!(
            "No memory at {}.\nTo create one, run: memo init\nTo use an existing one, point MEMORY_DIR at it.",
            pretty(&expanded)
        ));
    }
    fs::create_dir_all(expanded.join("TREE")).map_err(|e| e.to_string())?;
    // create_new: an exists-check racing another process would truncate
    // the log it just wrote.
    match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(expanded.join("LOG.txt"))
    {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(format!("{}: {e}", log_path(&expanded).display())),
    }
    Ok(expanded)
}

fn parse_size(key: &str, value: &str, where_: &str) -> Result<usize, String> {
    if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) {
        return die(format!(
            "{where_}{key} must be a positive whole number, not '{value}'."
        ));
    }
    let value: usize = value.parse().map_err(|e| format!("{where_}{e}"))?;
    if value == 0 {
        return die(format!(
            "{where_}{key} must be a positive whole number, not '0'."
        ));
    }
    let top = (TREE_REC - 8).min(LOG_REC - 40);
    if key == "ENTRY_CHARS" && value > top {
        return die(format!(
            "{where_}ENTRY_CHARS is at most {top}: a memory has to fit the fixed-width records."
        ));
    }
    Ok(value)
}

fn overrides(d: &Path) -> Result<HashMap<String, usize>, String> {
    let mut out = HashMap::new();
    let p = d.join("config");
    if !p.exists() {
        return Ok(out);
    }
    let src = fs::read_to_string(&p).map_err(|e| e.to_string())?;
    for (n, raw) in src.lines().enumerate() {
        let line = raw.split('#').next().unwrap().trim();
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim().to_ascii_uppercase();
        let value = value.trim();
        let where_ = format!("{} line {}: ", pretty(&p), n + 1);
        if !KNOBS.iter().any(|(name, _, _)| *name == key) {
            return die(format!(
                "{where_}{key} is not a size. Delete the line, or name one of: {}.",
                KNOBS.map(|(name, _, _)| name).join(", ")
            ));
        }
        out.insert(key.clone(), parse_size(&key, value, &where_)?);
    }
    Ok(out)
}

fn write_config(d: &Path, over: &HashMap<String, usize>) -> Result<(), String> {
    let mut out = vec![
        "# OptMem sizes for this memory. A commented line means: follow the".to_owned(),
        "# tool's default. Edit with `memo config NAME=VALUE`.".to_owned(),
        String::new(),
    ];
    for (name, default, what) in KNOBS {
        out.push(format!(
            "{}{:12} = {:<6} # {what}",
            if over.contains_key(name) { "" } else { "# " },
            name,
            over.get(name).copied().unwrap_or(default)
        ));
    }
    fs::write(d.join("config"), format!("{}\n", out.join("\n"))).map_err(|e| e.to_string())
}

fn config(d: &Path) -> Result<Config, String> {
    let over = overrides(d)?;
    let mut c = Config::default();
    for (key, value) in over {
        match key.as_str() {
            "ENTRY_CHARS" => c.entry_chars = value,
            "WAKE_LINES" => c.wake_lines = value,
            "PART_CHARS" => c.part_chars = value,
            "PART_LINES" => c.part_lines = value,
            _ => unreachable!(),
        }
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
    // Only absence means empty; any other error impersonating an empty
    // log would corrupt every decision built on these counts.
    match fs::metadata(path) {
        Ok(m) => m.len() as usize / rec,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => 0,
        Err(e) => {
            eprintln!("memo: read {}: {e}", path.display());
            std::process::exit(1);
        }
    }
}
fn log_len(d: &Path) -> usize {
    count(&log_path(d), LOG_REC)
}

fn repair(path: &Path, rec: usize) -> Result<(), String> {
    let meta = match fs::metadata(path) {
        Ok(meta) => meta,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(format!("{}: {e}", path.display())),
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
    let mut f = match File::open(tree_path(d, size)) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("{}: {e}", tree_path(d, size).display())),
    };
    f.seek(SeekFrom::Start((lo / size * TREE_REC) as u64))
        .map_err(|e| e.to_string())?;
    let mut rec = vec![0; TREE_REC];
    let n = f.read(&mut rec).map_err(|e| e.to_string())?;
    let text = std::str::from_utf8(&rec[..n])
        .map_err(|_| {
            format!(
                "The summary of #{lo}-{} is corrupt. Run: memo forget {lo}-{}",
                hi - 1,
                hi - 1
            )
        })?
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
        let f = OpenOptions::new()
            .create(true)
            .append(true)
            .open(d.join(".lock"))
            .map_err(|e| e.to_string())?;
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
    let word = if let Some(stem) = word.strip_suffix('y') {
        format!("{stem}ie")
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
        "Compress memories #{lo}-{} into one line of at most {} bytes.\n\
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

fn cmd_init(d: &Path, args: &[String]) -> Result<(), String> {
    if !args.is_empty() {
        return die("usage: memo init");
    }
    let fresh = !d.is_dir();
    fs::create_dir_all(d.join("TREE")).map_err(|e| e.to_string())?;
    match OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(log_path(d))
    {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e.to_string()),
    }
    let config_path = d.join("config");
    if !config_path.exists() {
        write_config(d, &HashMap::new())?;
    }
    let c = config(d)?;
    if fresh {
        println!(
            "Created {}: this machine's memory, one identity, forever.",
            pretty(d)
        );
    } else {
        println!("Found {}: {}.", pretty(d), plural(log_len(d), "memory"));
    }
    println!("Sizes live in {}/config; the defaults are fine.", pretty(d));
    println!("\nPaste this at the top of your agent's AGENTS.md (or CLAUDE.md), done:\n");
    println!(
        "{}",
        TEMPLATE
            .replace("{data}", &pretty(d))
            .replace("{bytes}", &c.entry_chars.to_string())
    );
    Ok(())
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
            let mut summary = tree_get(d, lo, hi)?;
            if summary.is_none() {
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
                // A parallel session may have settled this block between our
                // first read and the pending-work check.
                summary = tree_get(d, lo, hi)?;
            }
            let Some(s) = summary else {
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
            "usage: memo note \"<one line, at most {} bytes>\"",
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

fn cmd_config(d: &Path, args: &[String]) -> Result<(), String> {
    let mut over = overrides(d)?;
    for arg in args {
        let Some((key, value)) = arg.split_once('=') else {
            return die(format!(
                "usage: memo config [NAME=VALUE ...]   # NAME one of {}",
                KNOBS.map(|(name, _, _)| name).join(", ")
            ));
        };
        let key = key.trim().to_ascii_uppercase();
        if !KNOBS.iter().any(|(name, _, _)| *name == key) {
            return die(format!(
                "usage: memo config [NAME=VALUE ...]   # NAME one of {}",
                KNOBS.map(|(name, _, _)| name).join(", ")
            ));
        }
        let value = value.trim();
        if value.is_empty() {
            over.remove(&key);
        } else {
            over.insert(key.clone(), parse_size(&key, value, "")?);
        }
    }
    if !args.is_empty() {
        write_config(d, &over)?;
    }
    for (name, default, what) in KNOBS {
        let value = over.get(name).copied().unwrap_or(default);
        println!(
            "{name:12} {value:<7} {what}{}",
            if over.contains_key(name) {
                format!(" (default {default})")
            } else {
                String::new()
            }
        );
    }
    Ok(())
}

fn block_id(arg: &str) -> Result<(usize, usize), String> {
    let Some(caps) = Regex::new(r"^(\d+)-(\d+)$").unwrap().captures(arg) else {
        return die(format!(
            "'{arg}' is not a block id. Copy it from the prompt."
        ));
    };
    let lo: usize = caps[1]
        .parse()
        .map_err(|_| format!("'{arg}' is not a block id. Copy it from the prompt."))?;
    let inclusive_hi: usize = caps[2]
        .parse()
        .map_err(|_| format!("'{arg}' is not a block id. Copy it from the prompt."))?;
    let Some(hi) = inclusive_hi.checked_add(1) else {
        return die(format!(
            "'{arg}' is not a block id. Copy it from the prompt."
        ));
    };
    let size = hi.saturating_sub(lo);
    if size < 2 || !size.is_power_of_two() || !lo.is_multiple_of(size) {
        return die(format!(
            "{arg} is not a block. Copy the id printed by wake, like 16-31."
        ));
    }
    Ok((lo, hi))
}

fn cmd_nap(d: &Path, args: &[String], c: Config) -> Result<(), String> {
    let t = log_len(d);
    let said = !args.is_empty();
    if said {
        if args.len() != 2 {
            return die("usage: memo nap <lo>-<hi> \"<one line>\"");
        }
        let (lo, hi) = block_id(&args[0])?;
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
    let (lo, hi) = block_id(&args[0])?;
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
    let mut reader = BufReader::new(File::open(log_path(d)).map_err(|e| e.to_string())?);
    let (mut hits, mut out, mut size) = (0, VecDeque::new(), 0);
    for _ in 0..log_len(d) {
        let mut record = [0; LOG_REC];
        reader.read_exact(&mut record).map_err(|e| e.to_string())?;
        let e = parse(&record)?;
        let line = format!("#{} {} {}", e.id, e.date, e.text);
        if !pat.is_match(&line) {
            continue;
        }
        hits += 1;
        size += line.len() + 1;
        out.push_back(line);
        while size > c.part_chars {
            let dropped = out.pop_front().unwrap();
            size -= dropped.len() + 1;
        }
    }
    if hits == 0 {
        println!("No match.");
        return Ok(());
    }
    println!("{}", out.iter().cloned().collect::<Vec<_>>().join("\n"));
    if out.len() < hits {
        println!(
            "Newest {} of {}. Narrow the regex.",
            out.len(),
            plural(hits, "match")
        );
    } else {
        println!("{}.", plural(hits, "match"));
    }
    Ok(())
}

/// The shape regex admits 2026-99-99; this checks the calendar, keeping
/// the log's lexicographic ordering equivalent to chronological.
fn valid_date(date: &str) -> bool {
    let field = |r: std::ops::Range<usize>| date.get(r).and_then(|s| s.parse::<u32>().ok());
    let (Some(y), Some(m), Some(day)) = (field(0..4), field(5..7), field(8..10)) else {
        return false;
    };
    let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
    let days = match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => {
            if leap {
                29
            } else {
                28
            }
        }
        _ => return false,
    };
    (1..=days).contains(&day)
}

fn cmd_import(d: &Path, args: &[String], c: Config) -> Result<(), String> {
    if args.len() != 1 {
        return die("usage: memo import <file>   # lines of 'YYYY-MM-DD <text>'");
    }
    let src = fs::read(&args[0]).map_err(|e| format!("Cannot read {}: {e}", args[0]))?;
    let src = String::from_utf8(src).map_err(|_| {
        format!(
            "{} is not UTF-8 text. Convert it, then import again.",
            pretty(Path::new(&args[0]))
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
        if !valid_date(date) {
            return die(format!("line {}: {date} is not a real date.", i + 1));
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
    let (lo, hi) = block_id(&args[0])?;
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
        "init" | "wake" | "note" | "nap" | "recall" | "zoom" | "forget" | "config" | "import"
    ) {
        eprintln!("No such command: {}\n", args[0]);
        eprintln!("{USAGE}");
        std::process::exit(1);
    }
    if args[0] == "init" {
        return cmd_init(&memory_dir()?, &args[1..]);
    }
    let d = store()?;
    let c = config(&d)?;
    match args[0].as_str() {
        "init" => unreachable!(),
        "wake" => cmd_wake(&d, &args[1..], c),
        "note" => cmd_note(&d, &args[1..], c),
        "nap" => cmd_nap(&d, &args[1..], c),
        "recall" => cmd_recall(&d, &args[1..], c),
        "zoom" => cmd_zoom(&d, &args[1..]),
        "forget" => cmd_forget(&d, &args[1..]),
        "config" => cmd_config(&d, &args[1..]),
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
