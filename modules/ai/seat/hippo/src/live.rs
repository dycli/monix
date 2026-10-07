//! Following the harnesses' transcripts: where they are, how far each is
//! read, and the same readers run over whole days for replay and audit.

use crate::source::{self, Event, claude, codex, opencode};
use crate::store::{Kind, Store, fmt_date, parse_date};
use crate::watcher::{Watcher, marker};
use chrono::{DateTime, Local};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
pub struct Sources {
    pub claude: Vec<PathBuf>,
    pub codex: Vec<PathBuf>,
    pub opencode: PathBuf,
    pub paseo: PathBuf,
}

impl Sources {
    pub fn home(home: &Path) -> Sources {
        Sources {
            claude: vec![home.join(".claude/projects")],
            codex: vec![
                home.join(".codex/sessions"),
                home.join(".codex/archived_sessions"),
            ],
            opencode: home.join(".local/share/opencode/opencode-stable.db"),
            paseo: home.join(".paseo/agents"),
        }
    }

    /// The transcripts archived on the NAS, beside the live ones: the
    /// harnesses prune their own, the archive never does.
    pub fn with_archive(mut self, archive: &Path) -> Sources {
        self.claude.push(archive.join("claude"));
        self.codex.push(archive.join("codex"));
        self
    }

    /// Every transcript file, with its harness and session. A session found
    /// in several places (live and archived, or moved by Codex) is read
    /// from its largest copy.
    pub fn files(&self) -> Vec<(PathBuf, &'static str, String)> {
        let mut found = Vec::new();
        for root in &self.claude {
            for project in read_dir(root) {
                let name = project.file_name().unwrap_or_default().to_string_lossy();
                // The compactor's own calls never persist; skip its directory
                // anyway, should one ever appear.
                if !project.is_dir() || name.starts_with("-srv-storage-hippo") {
                    continue;
                }
                for file in read_dir(&project) {
                    if file.extension().is_some_and(|x| x == "jsonl") && file.is_file() {
                        let session = stem(&file);
                        found.push((file, "claude", session));
                    }
                }
            }
        }
        for root in &self.codex {
            let mut stack = vec![root.clone()];
            while let Some(dir) = stack.pop() {
                for path in read_dir(&dir) {
                    if path.is_dir() {
                        stack.push(path);
                    } else if path.extension().is_some_and(|x| x == "jsonl") {
                        let session = codex::session_of(&stem(&path)).to_owned();
                        found.push((path, "codex", session));
                    }
                }
            }
        }
        let mut best: HashMap<(&'static str, String), (u64, PathBuf)> = HashMap::new();
        for (path, harness, session) in found {
            let size = fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
            let key = (harness, session);
            if best.get(&key).is_none_or(|(s, _)| size > *s) {
                best.insert(key, (size, path));
            }
        }
        let mut out: Vec<_> = best
            .into_iter()
            .map(|((harness, session), (_, path))| (path, harness, session))
            .collect();
        out.sort();
        out
    }
}

fn read_dir(dir: &Path) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .collect();
    out.sort();
    out
}

fn stem(path: &Path) -> String {
    path.file_stem()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned()
}

/// One transcript record's events, with when it was written.
pub fn parse_line(
    harness: &str,
    session: &str,
    off: u64,
    line: &[u8],
) -> (Option<DateTime<Local>>, Vec<Event>) {
    let r: Value = match serde_json::from_slice(line) {
        Ok(v) => v,
        Err(e) => return (None, vec![Event::Unparsed(format!("not JSON: {e}"))]),
    };
    let at = r
        .get("timestamp")
        .and_then(Value::as_str)
        .and_then(source::iso);
    let events = match harness {
        "claude" => claude::parse(&r, session),
        _ => codex::parse(&r, session, off),
    };
    (at, events)
}

/// Complete lines of `path` from byte `from`, each with its offset; returns
/// where the next unread line starts.
pub fn read_lines(
    path: &Path,
    from: u64,
    mut each: impl FnMut(u64, &[u8]) -> Result<(), String>,
) -> Result<u64, String> {
    let mut file = match File::open(path) {
        Ok(f) => f,
        // Moved away since it was listed (Codex archiving a session).
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(from),
        Err(e) => return Err(format!("{}: {e}", path.display())),
    };
    file.seek(SeekFrom::Start(from))
        .map_err(|e| e.to_string())?;
    let mut reader = BufReader::with_capacity(1 << 20, file);
    let (mut off, mut buf) = (from, Vec::new());
    loop {
        buf.clear();
        let n = reader
            .read_until(b'\n', &mut buf)
            .map_err(|e| e.to_string())?;
        // A line without its newline is still being written.
        if n == 0 || buf.last() != Some(&b'\n') {
            return Ok(off);
        }
        if buf.len() > 1 {
            each(off, &buf[..buf.len() - 1])?;
        }
        off += n as u64;
    }
}

#[derive(Default, Serialize, Deserialize)]
struct Cursors {
    /// When hippo first started following: older entries were never its.
    since: String,
    files: BTreeMap<PathBuf, u64>,
    opencode: i64,
}

/// The live follower. Its cursors (`state/cursors.json`) are the only
/// mutable data; losing them re-reads every transcript, and dedupe on the
/// source keeps that from logging anything twice.
pub struct Live {
    pub sources: Sources,
    path: PathBuf,
    cur: Cursors,
    read: HashMap<PathBuf, u64>,
    /// Harness and session of each file followed.
    whose: HashMap<PathBuf, (&'static str, String)>,
    fresh: bool,
    db: Option<rusqlite::Connection>,
    /// OpenCode changes read so far; `cur.opencode` stays behind it while
    /// an OpenCode turn is held.
    oc_read: i64,
    saved: String,
}

impl Live {
    pub fn new(store: &Store, sources: Sources) -> Result<Live, String> {
        let path = store.dir.join("state/cursors.json");
        let (cur, fresh) = match fs::read_to_string(&path) {
            Ok(raw) => (
                serde_json::from_str(&raw).map_err(|e| format!("{}: {e}", path.display()))?,
                false,
            ),
            Err(_) => (
                Cursors {
                    // Only a store that starts empty starts following now.
                    since: match store.is_empty() {
                        true => fmt_date(&Local::now()),
                        false => String::new(),
                    },
                    ..Cursors::default()
                },
                // A store with messages but no cursors lost its state:
                // read everything again. An empty one starts now.
                store.is_empty(),
            ),
        };
        let read = cur.files.iter().map(|(p, o)| (p.clone(), *o)).collect();
        Ok(Live {
            sources,
            path,
            oc_read: cur.opencode,
            cur,
            read,
            whose: HashMap::new(),
            fresh,
            db: None,
            saved: String::new(),
        })
    }

    pub fn since(&self) -> Option<DateTime<Local>> {
        parse_date(&self.cur.since)
    }

    /// Reads whatever the harnesses wrote since the last scan.
    pub fn scan(&mut self, w: &mut Watcher, store: &mut Store) -> Result<(), String> {
        let now = Local::now();
        let files = self.sources.files();
        // Cursors of files gone for good are dropped.
        let listed: HashSet<&PathBuf> = files.iter().map(|(p, _, _)| p).collect();
        self.read.retain(|p, _| listed.contains(p));
        self.whose = files
            .iter()
            .map(|(p, h, s)| (p.clone(), (*h, s.clone())))
            .collect();
        for (path, harness, session) in files.iter().cloned() {
            let len = match fs::metadata(&path) {
                Ok(m) => m.len(),
                Err(_) => continue,
            };
            let pos = match self.read.get(&path) {
                Some(&p) if p <= len => p,
                // Shrunk: rewritten in place. Read again; dedupe skips repeats.
                Some(_) => 0,
                None if self.fresh => len,
                None => 0,
            };
            self.read.insert(path.clone(), pos);
            if pos == len {
                continue;
            }
            let end = read_lines(&path, pos, |off, line| {
                let (at, events) = parse_line(harness, &session, off, line);
                for ev in events {
                    w.feed(store, harness, &session, Some(off), at.unwrap_or(now), ev)?;
                }
                Ok(())
            })?;
            self.read.insert(path, end);
        }
        self.scan_opencode(w, store, now)?;
        self.fresh = false;
        Ok(())
    }

    fn scan_opencode(
        &mut self,
        w: &mut Watcher,
        store: &mut Store,
        now: DateTime<Local>,
    ) -> Result<(), String> {
        if !self.sources.opencode.exists() {
            return Ok(());
        }
        if self.db.is_none() {
            self.db = Some(opencode::open(&self.sources.opencode)?);
        }
        let db = self.db.as_ref().unwrap();
        let mark = opencode::watermark(db)?;
        if self.fresh {
            self.oc_read = mark;
        }
        if mark > self.oc_read {
            for s in opencode::changed(db, self.oc_read)? {
                feed_opencode(w, store, &s, now)?;
            }
            self.oc_read = mark;
        }
        Ok(())
    }

    /// Saves the cursors when they moved: each file's is the first line not
    /// yet logged, so held turns are read again after a restart.
    pub fn save(&mut self, w: &Watcher) -> Result<(), String> {
        let mut files = BTreeMap::new();
        for (path, &read) in &self.read {
            let held = self
                .whose
                .get(path)
                .and_then(|(harness, session)| w.chat(harness, session))
                .and_then(|c| c.held_from());
            files.insert(path.clone(), held.unwrap_or(read).min(read));
        }
        let holding = w
            .chats
            .iter()
            .any(|(k, c)| k.starts_with("opencode:") && c.held() > 0);
        if !holding {
            self.cur.opencode = self.oc_read;
        }
        self.cur.files = files;
        let raw = serde_json::to_string(&self.cur).map_err(|e| e.to_string())?;
        if raw != self.saved {
            let tmp = self.path.with_extension("tmp");
            fs::write(&tmp, &raw).map_err(|e| e.to_string())?;
            fs::rename(&tmp, &self.path).map_err(|e| e.to_string())?;
            self.saved = raw;
        }
        Ok(())
    }
}

/// Feeds one OpenCode session read whole: only what follows the last entry
/// already logged or held is new.
fn feed_opencode(
    w: &mut Watcher,
    store: &mut Store,
    s: &opencode::Session,
    now: DateTime<Local>,
) -> Result<(), String> {
    let start = s
        .events
        .iter()
        .rposition(|(_, ev)| match ev {
            Event::Item(it) => w.known(store, "opencode", &s.id, &it.src.key()),
            _ => false,
        })
        .map_or(0, |i| i + 1);
    for (i, (ms, ev)) in s.events.iter().enumerate() {
        let session_fact = matches!(ev, Event::Info { .. } | Event::Foreign);
        if i < start && !session_fact {
            continue;
        }
        let at = DateTime::from_timestamp_millis(*ms)
            .map(|d| d.with_timezone(&Local))
            .filter(|_| *ms > 0)
            .unwrap_or(now);
        w.feed(store, "opencode", &s.id, None, at, ev.clone())?;
    }
    Ok(())
}

/// Every record of every source, in time order, as (when, harness,
/// session, line, events). Session facts are always kept; items only when
/// written in [from, to).
type Record = (
    DateTime<Local>,
    &'static str,
    String,
    Option<u64>,
    Vec<Event>,
);

pub fn records(
    sources: &Sources,
    from: DateTime<Local>,
    to: DateTime<Local>,
) -> Result<Vec<Record>, String> {
    records_read(sources, from, to, &mut HashMap::new())
}

/// `records`, also saying how far each file was read.
fn records_read(
    sources: &Sources,
    from: DateTime<Local>,
    to: DateTime<Local>,
    ends: &mut HashMap<PathBuf, u64>,
) -> Result<Vec<Record>, String> {
    let mut out: Vec<Record> = Vec::new();
    for (path, harness, session) in sources.files() {
        let end = read_lines(&path, 0, |off, line| {
            let (at, events) = parse_line(harness, &session, off, line);
            let at = at.unwrap_or(from);
            let keep: Vec<Event> = if at >= from && at < to {
                events
            } else {
                events
                    .into_iter()
                    .filter(|e| matches!(e, Event::Info { .. } | Event::Foreign))
                    .collect()
            };
            if !keep.is_empty() {
                out.push((at.max(from), harness, session.clone(), Some(off), keep));
            }
            Ok(())
        })?;
        ends.insert(path, end);
    }
    if sources.opencode.exists() {
        let db = opencode::open(&sources.opencode)?;
        for s in opencode::changed(&db, 0)? {
            for (ms, ev) in s.events {
                let at = DateTime::from_timestamp_millis(ms)
                    .unwrap_or_default()
                    .with_timezone(&Local);
                let fact = matches!(ev, Event::Info { .. } | Event::Foreign);
                if fact || (at >= from && at < to) {
                    out.push((at.max(from), "opencode", s.id.clone(), None, vec![ev]));
                }
            }
        }
    }
    out.sort_by_key(|r| r.0);
    Ok(out)
}

/// Rebuilds a scratch store from the transcripts written in [from, to), as
/// if the watcher had followed them live.
pub fn replay(
    store: &mut Store,
    w: &mut Watcher,
    sources: &Sources,
    from: DateTime<Local>,
    to: DateTime<Local>,
) -> Result<(), String> {
    if !store.is_empty() {
        return Err(format!("{} is not empty.", store.dir.display()));
    }
    for (at, harness, session, line, events) in records(sources, from, to)? {
        w.tick(store, at)?;
        for ev in events {
            w.feed(store, harness, &session, line, at, ev)?;
        }
    }
    w.flush_all(store)
}

/// Checks that every transcript entry of a day that the log should hold
/// is there exactly once.
pub fn audit(
    store: &Store,
    sources: &Sources,
    from: DateTime<Local>,
    to: DateTime<Local>,
    since: Option<DateTime<Local>>,
) -> Result<String, String> {
    let start = since.map_or(from, |s| s.max(from));
    let mut foreign = HashSet::new();
    let mut off: HashMap<String, DateTime<Local>> = store
        .offrecord
        .iter()
        .filter_map(|(k, o)| parse_date(&o.date).map(|d| (k.clone(), d)))
        .collect();
    let mut expected: BTreeMap<String, (DateTime<Local>, Kind, String)> = BTreeMap::new();
    for (at, harness, session, _, events) in records(sources, start, to)? {
        let chat = format!("{harness}:{session}");
        for ev in events {
            match ev {
                Event::Foreign => {
                    foreign.insert(chat.clone());
                }
                Event::Item(it) => {
                    if it.kind == Kind::User && marker(&it.text).is_some() {
                        off.entry(chat.clone()).or_insert(it.date);
                    }
                    let gone = off.get(&chat).is_some_and(|d| it.date >= *d);
                    if foreign.contains(&chat) || gone || at < start {
                        continue;
                    }
                    let excerpt: String = it.text.chars().take(80).collect();
                    expected.insert(it.src.key(), (it.date, it.kind, excerpt));
                }
                _ => {}
            }
        }
    }
    let mut count: HashMap<String, u32> = HashMap::new();
    store.scan(|m| {
        if let Some(src) = m.src {
            *count.entry(src.key()).or_default() += 1;
        }
        true
    })?;
    let recent = Local::now() - crate::watcher::TURN_AGE;
    let (mut ok, mut missing, mut held, mut twice) = (0, Vec::new(), 0, Vec::new());
    for (key, (date, kind, excerpt)) in &expected {
        match count.get(key).copied().unwrap_or(0) {
            1 => ok += 1,
            0 if *date >= recent => held += 1,
            0 => missing.push(format!(
                "  missing {key} {} {}: {}",
                fmt_date(date),
                kind.name(),
                excerpt.replace('\n', " ")
            )),
            n => twice.push(format!("  {n} times {key}")),
        }
    }
    let mut out = format!(
        "{} to {}: {} entries expected, {ok} logged once, {} missing, {} duplicated{}\n",
        fmt_date(&start),
        fmt_date(&to),
        expected.len(),
        missing.len(),
        twice.len(),
        if held > 0 {
            format!(", {held} recent (may still be held)")
        } else {
            String::new()
        }
    );
    for line in missing.iter().chain(&twice).take(40) {
        out.push_str(line);
        out.push('\n');
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::Store;
    use crate::watcher::OMITTED;

    fn fixtures() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
    }

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("hippo-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn sources(tmp: &Path, claude: PathBuf) -> Sources {
        let db = tmp.join("opencode.db");
        let conn = rusqlite::Connection::open(&db).unwrap();
        conn.execute_batch(&fs::read_to_string(fixtures().join("opencode.sql")).unwrap())
            .unwrap();
        Sources {
            claude: vec![claude],
            codex: vec![fixtures().join("codex/sessions")],
            opencode: db,
            paseo: tmp.join("no-paseo"),
        }
    }

    fn day() -> (DateTime<Local>, DateTime<Local>) {
        let from = parse_date("2026-10-06T00:00:00Z").unwrap() - chrono::Duration::hours(12);
        (from, from + chrono::Duration::days(2))
    }

    fn log_of(store: &Store) -> Vec<String> {
        let mut out = Vec::new();
        store
            .scan(|m| {
                out.push(m.render());
                true
            })
            .unwrap();
        out
    }

    const EXPECTED: &[&str] = &[
        // The boiler chat's turn ends first, so it is logged first.
        "user [bridge]: Check the boiler.",
        "tool [bridge]: Bash {\"command\":\"systemctl status boiler\",\"description\":\"Status\"}",
        "echo [bridge]: active (running)",
        "talk [bridge]: The boiler runs.",
        "user [bridge-1111]: Plan the shed roof.",
        "talk [bridge-1111]: Checking the notes first.",
        "tool [bridge-1111]: Bash {\"command\":\"memo wake\",\"description\":\"Load memory\"}",
        "echo [bridge-1111]: (hippo output omitted)",
        "tool [bridge-1111]: Bash {\"command\":\"cat shed.txt\",\"description\":\"Read the notes\"}",
        "user [bridge-1111]: Use cedar, not pine.",
        "echo [bridge-1111]: width 3m\nauth: Bearer [secret masked]",
        "talk [bridge-1111]: Cedar roof planned.",
        "echo [bridge-1111]: <task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n<summary>Background command \"Measure\" completed (exit code 0)</summary>\n</task-notification>",
        "user [bridge-1111]: [image]\nDoes this look right?",
        "echo [bridge-1111]: API Error: the image could not be processed.",
        // #offrecord: nothing of the shed chat from there on. The boiler
        // chat went quiet over an hour ago, so this one may be "bridge" too.
        "user [bridge]: Fix the gutter.",
        "tool [bridge]: exec const r = await tools.exec_command({cmd:\"memo wake\",\"workdir\":\"/home/bridge\"}); text(r.output);\n",
        "echo [bridge]: (hippo output omitted)",
        "tool [bridge]: shell {\"command\":[\"bash\",\"-lc\",\"ls gutter\"],\"workdir\":\"/home/bridge\"}",
        "echo [bridge]: gutter.txt",
        "talk [bridge]: The gutter is fixed.",
        "user [fix-fence-gate]: Fix the fence gate.",
        "tool [fix-fence-gate]: bash {\"command\":\"ls gate\"}",
        "echo [fix-fence-gate]: hinge.txt",
        "talk [fix-fence-gate]: The gate hinge is replaced.",
        // The reply still streaming waits; the prompt before it does not.
        "user [fix-fence-gate]: Paint it too.",
    ];

    #[test]
    fn replays_the_fixture_day() {
        let tmp = scratch("replay");
        let src = sources(&tmp, fixtures().join("claude"));
        let mut store = Store::open(&tmp.join("store"), true).unwrap();
        let mut w = Watcher::default();
        let (from, to) = day();
        replay(&mut store, &mut w, &src, from, to).unwrap();
        assert_eq!(log_of(&store), EXPECTED);
        assert_eq!(w.unparsed_total, 1, "{:?}", w.unparsed);
        assert!(w.unparsed[0].what.contains("brand-new-entry"));
        let off: Vec<_> = store
            .offrecord
            .values()
            .map(|o| o.marker.as_str())
            .collect();
        assert_eq!(off, ["#offrecord"]);
        let report = audit(&store, &src, from, to, None).unwrap();
        assert!(report.contains("0 missing, 0 duplicated"), "{report}");
        assert!(!OMITTED.is_empty());
    }

    #[test]
    fn imports_reduced_chats() {
        let tmp = scratch("import");
        let src = sources(&tmp, fixtures().join("claude"));
        let mut store = Store::open(&tmp.join("store"), true).unwrap();
        let mut w = Watcher::default();
        import(&mut store, &mut w, &src).unwrap();
        let got = log_of(&store);
        assert_eq!(
            got,
            [
                "user [bridge]: Check the boiler.",
                "talk [bridge]: The boiler runs.",
                "user [bridge-1111]: Plan the shed roof.",
                "user [bridge-1111]: Use cedar, not pine.",
                "talk [bridge-1111]: Cedar roof planned.",
                "user [bridge-1111]: [image]\nDoes this look right?",
                "user [bridge]: Fix the gutter.",
                "talk [bridge]: The gutter is fixed.",
                "user [fix-fence-gate]: Fix the fence gate.",
                "talk [fix-fence-gate]: The gate hinge is replaced.",
                "user [fix-fence-gate]: Paint it too.",
            ]
        );
        assert!(imported(&store.dir).unwrap().is_some());
        // A second import refuses.
        assert!(import(&mut store, &mut Watcher::default(), &src).is_err());
    }

    #[test]
    fn follows_live_and_survives_a_restart() {
        let tmp = scratch("live");
        let claude = tmp.join("claude/-home-bridge");
        fs::create_dir_all(&claude).unwrap();
        let src = sources(&tmp, tmp.join("claude"));
        let name = "11111111-1111-4111-8111-111111111111.jsonl";
        let lines: Vec<String> =
            fs::read_to_string(fixtures().join("claude/-home-bridge").join(name))
                .unwrap()
                .lines()
                .map(|l| format!("{l}\n"))
                .collect();
        let file = claude.join(name);
        let store_dir = tmp.join("store");
        let later = parse_date("2026-10-07T00:00:00Z").unwrap();
        let mut written = 0;
        let write_to = |n: usize, written: &mut usize| {
            let mut f = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&file)
                .unwrap();
            for l in &lines[*written..n] {
                std::io::Write::write_all(&mut f, l.as_bytes()).unwrap();
            }
            *written = n;
        };
        {
            // An empty store starts at the end of what exists: nothing yet.
            let mut store = Store::open(&store_dir, true).unwrap();
            let mut live = Live::new(&store, src.clone()).unwrap();
            let mut w = Watcher::default();
            live.scan(&mut w, &mut store).unwrap();
            // Mid-turn: the shed turn is held, half a line is in flight.
            write_to(8, &mut written);
            let mut f = fs::OpenOptions::new().append(true).open(&file).unwrap();
            std::io::Write::write_all(&mut f, &lines[8].as_bytes()[..40]).unwrap();
            live.scan(&mut w, &mut store).unwrap();
            live.save(&w).unwrap();
            assert!(store.is_empty());
            assert!(w.holding().iter().any(|(_, n)| *n == 5));
            // The service dies here, its held turn with it.
        }
        // Finish the torn line and the rest of the file.
        let mut f = fs::OpenOptions::new().append(true).open(&file).unwrap();
        std::io::Write::write_all(&mut f, &lines[8].as_bytes()[40..]).unwrap();
        written = 9;
        write_to(lines.len(), &mut written);
        let mut store = Store::open(&store_dir, true).unwrap();
        let mut live = Live::new(&store, src).unwrap();
        let mut w = Watcher::default();
        live.scan(&mut w, &mut store).unwrap();
        w.tick(&mut store, later).unwrap();
        live.save(&w).unwrap();
        let shed: Vec<String> = EXPECTED
            .iter()
            .filter(|l| l.contains("[bridge-1111]"))
            .map(|l| l.replace("[bridge-1111]", "[bridge]"))
            .collect();
        assert_eq!(log_of(&store), shed);
        // Scanning again finds nothing new.
        live.scan(&mut w, &mut store).unwrap();
        w.tick(&mut store, later).unwrap();
        assert_eq!(log_of(&store).len(), shed.len());
    }
}

/// The record of the import that bootstrapped a store (`import.json`):
/// entries written before `cutoff` came in reduced and are never logged
/// again.
#[derive(Serialize, Deserialize)]
pub struct Imported {
    pub cutoff: String,
    pub messages: u64,
}

pub fn imported(store: &Path) -> Result<Option<Imported>, String> {
    match fs::read_to_string(store.join("import.json")) {
        Ok(raw) => serde_json::from_str(&raw)
            .map(Some)
            .map_err(|e| e.to_string()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

/// Bootstraps an empty store with every chat the transcripts still hold,
/// in time order and reduced to the captain's messages and each turn's
/// final reply. Leaves cursors where the reading
/// stopped, so the service follows on from there in full.
pub fn import(store: &mut Store, w: &mut Watcher, sources: &Sources) -> Result<String, String> {
    if !store.is_empty() || imported(&store.dir)?.is_some() {
        return Err(format!("{} is not empty.", store.dir.display()));
    }
    let mark = match sources.opencode.exists() {
        true => opencode::watermark(&opencode::open(&sources.opencode)?)?,
        false => 0,
    };
    let start = DateTime::from_timestamp(0, 0)
        .unwrap()
        .with_timezone(&Local);
    let mut ends = HashMap::new();
    let records = records_read(
        sources,
        start,
        Local::now() + chrono::Duration::days(1),
        &mut ends,
    )?;
    let cutoff = Local::now();
    w.reduce = true;
    for (at, harness, session, line, events) in records {
        w.tick(store, at)?;
        for ev in events {
            w.feed(store, harness, &session, line, at, ev)?;
        }
    }
    w.flush_all(store)?;
    let cursors = Cursors {
        since: fmt_date(&cutoff),
        files: ends.into_iter().collect(),
        opencode: mark,
    };
    let raw = serde_json::to_string(&cursors).map_err(|e| e.to_string())?;
    fs::write(store.dir.join("state/cursors.json"), raw).map_err(|e| e.to_string())?;
    let done = Imported {
        cutoff: fmt_date(&cutoff),
        messages: store.len(),
    };
    // Written last: the service starts once this exists.
    let raw = serde_json::to_string(&done).map_err(|e| e.to_string())?;
    let tmp = store.dir.join("import.json.tmp");
    fs::write(&tmp, raw).map_err(|e| e.to_string())?;
    fs::rename(&tmp, store.dir.join("import.json")).map_err(|e| e.to_string())?;
    Ok(format!(
        "{} messages in {} chats; live logging follows from {}.",
        done.messages,
        store.chats.len(),
        done.cutoff
    ))
}
