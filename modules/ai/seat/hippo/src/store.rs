//! The log: every message, word for word, append-only, one line per message
//! in `main/YYYY-MM-DD.jsonl`, written with one `write` and an fsync. Only
//! an index stays in memory; texts are read back from disk when asked for.

use chrono::{DateTime, Local, NaiveDate};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    User,
    Talk,
    Tool,
    Echo,
    Note,
}

impl Kind {
    pub fn name(self) -> &'static str {
        match self {
            Kind::User => "user",
            Kind::Talk => "talk",
            Kind::Tool => "tool",
            Kind::Echo => "echo",
            Kind::Note => "note",
        }
    }
}

/// Where a message came from: harness, session and entry, so it can be
/// traced to the raw transcript. `h + e` is unique: resumed and forked
/// sessions repeat entries under the same entry id.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Src {
    pub h: String,
    pub s: String,
    pub e: String,
}

impl Src {
    pub fn key(&self) -> String {
        format!("{}:{}", self.h, self.e)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Msg {
    pub i: u64,
    pub kind: Kind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chat: Option<String>,
    pub text: String,
    pub size: u64,
    pub date: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub src: Option<Src>,
}

impl Msg {
    /// The message as level 0 of the tree sees it: `kind: text`. Chats share
    /// one timeline; a line names its subject in words, never its chat.
    pub fn render(&self) -> String {
        render(self.kind, &self.text)
    }

    /// The message with its chat, for reading it whole: `kind [chat]: text`.
    pub fn labelled(&self) -> String {
        match &self.chat {
            Some(chat) => format!("{} [{chat}]: {}", self.kind.name(), self.text),
            None => self.render(),
        }
    }
}

pub fn render(kind: Kind, text: &str) -> String {
    format!("{}: {text}", kind.name())
}

/// A message ready to be logged; the store gives it its id and size.
#[derive(Clone, Debug)]
pub struct Draft {
    pub kind: Kind,
    pub chat: Option<String>,
    pub text: String,
    pub date: DateTime<Local>,
    pub src: Option<Src>,
}

/// One registered chat, written once to `chats.jsonl` the first time a
/// message of it is logged.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChatRec {
    pub chat: String,
    pub harness: String,
    pub session: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub cwd: String,
    pub first: String,
}

/// A chat the captain took off the record, in `offrecord.jsonl`. The
/// transcript archive reads this file to skip the same sessions.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OffRec {
    pub harness: String,
    pub session: String,
    pub marker: String,
    pub date: String,
}

struct Meta {
    file: u32,
    off: u64,
    len: u32,
    date: i64,
}

pub struct Store {
    pub dir: PathBuf,
    days: Vec<NaiveDate>,
    index: Vec<Meta>,
    seen: HashSet<String>,
    out: Option<(NaiveDate, File, u64)>,
    pub chats: HashMap<String, ChatRec>,
    pub offrecord: HashMap<String, OffRec>,
    /// Lines that were not valid JSON at load, as `file:line`.
    pub torn: Vec<String>,
    /// Last message per harness: (id, date).
    pub last: HashMap<String, (u64, i64)>,
    _lock: Option<UnixListener>,
}

pub fn chat_key(harness: &str, session: &str) -> String {
    format!("{harness}:{session}")
}

/// Appends one line with a single write, then fsyncs.
pub fn append_line(file: &mut File, line: &str) -> Result<(), String> {
    let mut buf = Vec::with_capacity(line.len() + 1);
    buf.extend_from_slice(line.as_bytes());
    buf.push(b'\n');
    file.write_all(&buf).map_err(|e| e.to_string())?;
    file.sync_data().map_err(|e| e.to_string())
}

fn open_append(path: &Path) -> Result<File, String> {
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|e| format!("{}: {e}", path.display()))
}

/// A file not ending in a newline (a crash mid-write) gets one, so the next
/// line starts on its own.
fn heal(path: &Path) -> Result<(), String> {
    let mut file = match File::open(path) {
        Ok(f) => f,
        Err(_) => return Ok(()),
    };
    let len = file.metadata().map_err(|e| e.to_string())?.len();
    if len == 0 {
        return Ok(());
    }
    file.seek(SeekFrom::End(-1)).map_err(|e| e.to_string())?;
    let mut last = [0u8];
    file.read_exact(&mut last).map_err(|e| e.to_string())?;
    if last[0] != b'\n' {
        let mut file = open_append(path)?;
        file.write_all(b"\n").map_err(|e| e.to_string())?;
        file.sync_data().map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Reads a JSONL file line by line with byte offsets, healing it first.
/// Lines that are not valid JSON land in `torn`.
pub fn read_jsonl<T: for<'de> Deserialize<'de>>(
    path: &Path,
    torn: &mut Vec<String>,
    mut each: impl FnMut(T, u64, u32),
) -> Result<(), String> {
    heal(path)?;
    let file = match File::open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(format!("{}: {e}", path.display())),
    };
    let mut reader = BufReader::new(file);
    let (mut off, mut n, mut line) = (0u64, 0usize, Vec::new());
    loop {
        line.clear();
        let len = reader
            .read_until(b'\n', &mut line)
            .map_err(|e| e.to_string())?;
        if len == 0 {
            break;
        }
        n += 1;
        match serde_json::from_slice::<T>(&line) {
            Ok(v) => each(v, off, len as u32),
            Err(_) if line.iter().all(u8::is_ascii_whitespace) => {}
            Err(e) => {
                let at = format!("{}:{n}", path.display());
                eprintln!("hippo: torn line skipped at {at}: {e}");
                torn.push(at);
            }
        }
        off += len as u64;
    }
    Ok(())
}

fn day_name(day: NaiveDate) -> String {
    day.format("%Y-%m-%d.jsonl").to_string()
}

pub fn parse_date(s: &str) -> Option<DateTime<Local>> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|d| d.with_timezone(&Local))
}

pub fn fmt_date(d: &DateTime<Local>) -> String {
    d.to_rfc3339_opts(chrono::SecondsFormat::Secs, false)
}

/// Days of a stream directory, oldest first.
pub fn day_files(dir: &Path) -> Result<Vec<NaiveDate>, String> {
    let mut days = Vec::new();
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(days),
        Err(e) => return Err(format!("{}: {e}", dir.display())),
    };
    for entry in entries {
        let name = entry.map_err(|e| e.to_string())?.file_name();
        let name = name.to_string_lossy();
        if let Some(stem) = name.strip_suffix(".jsonl")
            && let Ok(day) = NaiveDate::parse_from_str(stem, "%Y-%m-%d")
        {
            days.push(day);
        }
    }
    days.sort();
    Ok(days)
}

/// Holds `dir/lock` for the life of the process: a second process that can
/// connect to it exits; a socket that refuses connections is stale (its
/// owner died) and is taken over. No PID files, no timeouts.
pub fn take_lock(dir: &Path) -> Result<UnixListener, String> {
    let path = dir.join("lock");
    match UnixListener::bind(&path) {
        Ok(l) => Ok(l),
        Err(e) if e.kind() == std::io::ErrorKind::AddrInUse => {
            if UnixStream::connect(&path).is_ok() {
                return Err(format!("another hippo holds {}", path.display()));
            }
            fs::remove_file(&path).map_err(|e| e.to_string())?;
            UnixListener::bind(&path).map_err(|e| format!("{}: {e}", path.display()))
        }
        Err(e) => Err(format!("{}: {e}", path.display())),
    }
}

impl Store {
    /// Opens the store. `lock` takes the single-writer lock; a reader that
    /// never writes (tests, replay inspection) may skip it.
    pub fn open(dir: &Path, lock: bool) -> Result<Store, String> {
        fs::create_dir_all(dir.join("main")).map_err(|e| format!("{}: {e}", dir.display()))?;
        fs::create_dir_all(dir.join("tree")).map_err(|e| e.to_string())?;
        fs::create_dir_all(dir.join("state")).map_err(|e| e.to_string())?;
        let lock = if lock { Some(take_lock(dir)?) } else { None };
        let mut store = Store {
            dir: dir.to_owned(),
            days: Vec::new(),
            index: Vec::new(),
            seen: HashSet::new(),
            out: None,
            chats: HashMap::new(),
            offrecord: HashMap::new(),
            torn: Vec::new(),
            last: HashMap::new(),
            _lock: lock,
        };
        store.load()?;
        Ok(store)
    }

    fn load(&mut self) -> Result<(), String> {
        let mut torn = Vec::new();
        read_jsonl::<ChatRec>(&self.dir.join("chats.jsonl"), &mut torn, |c, _, _| {
            self.chats
                .entry(chat_key(&c.harness, &c.session))
                .or_insert(c);
        })?;
        read_jsonl::<OffRec>(&self.dir.join("offrecord.jsonl"), &mut torn, |o, _, _| {
            self.offrecord
                .entry(chat_key(&o.harness, &o.session))
                .or_insert(o);
        })?;
        self.days = day_files(&self.dir.join("main"))?;
        for (f, day) in self.days.clone().into_iter().enumerate() {
            let path = self.dir.join("main").join(day_name(day));
            let mut rows = Vec::new();
            read_jsonl::<Msg>(&path, &mut torn, |m, off, len| rows.push((m, off, len)))?;
            for (m, off, len) in rows {
                if m.i != self.index.len() as u64 {
                    return Err(format!(
                        "{}: message {} where {} was expected",
                        path.display(),
                        m.i,
                        self.index.len()
                    ));
                }
                self.index_msg(&m, f as u32, off, len);
            }
        }
        self.torn = torn;
        Ok(())
    }

    fn index_msg(&mut self, m: &Msg, file: u32, off: u64, len: u32) {
        let date = parse_date(&m.date).map(|d| d.timestamp()).unwrap_or(0);
        if let Some(src) = &m.src {
            self.seen.insert(src.key());
            self.last.insert(src.h.clone(), (m.i, date));
        }
        self.index.push(Meta {
            file,
            off,
            len,
            date,
        });
    }

    pub fn len(&self) -> u64 {
        self.index.len() as u64
    }

    pub fn is_empty(&self) -> bool {
        self.index.is_empty()
    }

    pub fn seen(&self, key: &str) -> bool {
        self.seen.contains(key)
    }

    pub fn date(&self, i: u64) -> Option<DateTime<Local>> {
        let m = self.index.get(i as usize)?;
        DateTime::from_timestamp(m.date, 0).map(|d| d.with_timezone(&Local))
    }

    /// Message `i`, read back from its file.
    pub fn get(&self, i: u64) -> Result<Msg, String> {
        let m = self
            .index
            .get(i as usize)
            .ok_or_else(|| format!("No message {i}."))?;
        let path = self
            .dir
            .join("main")
            .join(day_name(self.days[m.file as usize]));
        let mut file = File::open(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        file.seek(SeekFrom::Start(m.off))
            .map_err(|e| e.to_string())?;
        let mut buf = vec![0; m.len as usize];
        file.read_exact(&mut buf).map_err(|e| e.to_string())?;
        serde_json::from_slice(&buf).map_err(|e| format!("{}: {e}", path.display()))
    }

    /// Every message in order, read file by file (for search and audits).
    pub fn scan(&self, mut each: impl FnMut(Msg) -> bool) -> Result<(), String> {
        let mut torn = Vec::new();
        for day in &self.days {
            let path = self.dir.join("main").join(day_name(*day));
            let mut stop = false;
            read_jsonl::<Msg>(&path, &mut torn, |m, _, _| {
                if !stop {
                    stop = !each(m);
                }
            })?;
            if stop {
                break;
            }
        }
        Ok(())
    }

    /// Logs drafts in order, each its own fsynced line. A draft whose
    /// source was logged before is skipped. Returns the ids given.
    pub fn append(&mut self, drafts: Vec<Draft>) -> Result<Vec<u64>, String> {
        let mut ids = Vec::new();
        for d in drafts {
            if let Some(src) = &d.src
                && self.seen.contains(&src.key())
            {
                continue;
            }
            let i = self.len();
            let size = render(d.kind, &d.text).len() as u64;
            let msg = Msg {
                i,
                kind: d.kind,
                chat: d.chat,
                text: d.text,
                size,
                date: fmt_date(&d.date),
                src: d.src,
            };
            // Files split by day only to stay manageable; a message never
            // goes to a day before the last written one, so ids stay in
            // file order.
            let mut day = d.date.date_naive();
            if let Some(&last) = self.days.last() {
                day = day.max(last);
            }
            let line = serde_json::to_string(&msg).map_err(|e| e.to_string())?;
            let file = self.writer(day)?;
            let (_, out, end) = self.out.as_mut().unwrap();
            let off = *end;
            append_line(out, &line)?;
            *end += line.len() as u64 + 1;
            self.index_msg(&msg, file, off, line.len() as u32 + 1);
            ids.push(i);
        }
        Ok(ids)
    }

    fn writer(&mut self, day: NaiveDate) -> Result<u32, String> {
        if self.out.as_ref().is_none_or(|(d, _, _)| *d != day) {
            let path = self.dir.join("main").join(day_name(day));
            heal(&path)?;
            let file = open_append(&path)?;
            let end = file.metadata().map_err(|e| e.to_string())?.len();
            if self.days.last() != Some(&day) {
                self.days.push(day);
            }
            self.out = Some((day, file, end));
        }
        Ok(self.days.len() as u32 - 1)
    }

    pub fn register(&mut self, rec: ChatRec) -> Result<(), String> {
        let key = chat_key(&rec.harness, &rec.session);
        if self.chats.contains_key(&key) {
            return Ok(());
        }
        let line = serde_json::to_string(&rec).map_err(|e| e.to_string())?;
        append_line(&mut open_append(&self.dir.join("chats.jsonl"))?, &line)?;
        self.chats.insert(key, rec);
        Ok(())
    }

    pub fn take_off_record(&mut self, rec: OffRec) -> Result<(), String> {
        let key = chat_key(&rec.harness, &rec.session);
        if self.offrecord.contains_key(&key) {
            return Ok(());
        }
        let line = serde_json::to_string(&rec).map_err(|e| e.to_string())?;
        append_line(&mut open_append(&self.dir.join("offrecord.jsonl"))?, &line)?;
        self.offrecord.insert(key, rec);
        Ok(())
    }
}
