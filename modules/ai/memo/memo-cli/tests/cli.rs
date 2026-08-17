use std::collections::HashSet;
use std::fs::{self, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

const N: usize = 2000;

/// 2020-01-01 plus `days`, as `YYYY-MM-DD`, to seed dated entries.
fn seed_date(mut days: u32) -> String {
    let (mut year, mut month, mut day) = (2020u32, 1u32, 1u32);
    loop {
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
        let len = match month {
            4 | 6 | 9 | 11 => 30,
            2 => {
                if leap {
                    29
                } else {
                    28
                }
            }
            _ => 31,
        };
        let remaining = len - day;
        if days <= remaining {
            day += days;
            break;
        }
        days -= remaining + 1;
        (month, day) = (month + 1, 1);
        if month == 13 {
            (year, month) = (year + 1, 1);
        }
    }
    format!("{year:04}-{month:02}-{day:02}")
}
const WAKE_LINES: usize = 96;
const CAP_CHARS: usize = 30000;
const CAP_LINES: usize = 2000;

struct TempDir(PathBuf);

impl TempDir {
    fn new(label: &str) -> Self {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path =
            std::env::temp_dir().join(format!("optmem-{label}-{}-{unique}", std::process::id()));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn command(store: &Path) -> Command {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_memo"));
    cmd.env("MEMORY_DIR", store);
    cmd
}

fn run(store: &Path, args: &[&str]) -> Output {
    command(store).args(args).output().unwrap()
}

fn stdout(out: &Output) -> String {
    String::from_utf8(out.stdout.clone()).unwrap()
}

fn stderr(out: &Output) -> String {
    String::from_utf8(out.stderr.clone()).unwrap()
}

fn nap_id(out: &str) -> String {
    let start = out.find("memo nap ").expect("nap command") + "memo nap ".len();
    out[start..].split_whitespace().next().unwrap().to_owned()
}

fn settle(store: &Path, summary: &str) -> usize {
    let mut naps = 0;
    loop {
        let offered = run(store, &["nap"]);
        assert!(offered.status.success(), "{}", stderr(&offered));
        let text = stdout(&offered);
        if text.contains("Nothing left to compress") {
            return naps;
        }
        let command_line = text
            .lines()
            .find(|line| line.contains("memo nap "))
            .expect("command");
        assert!(command_line.starts_with("Run: "));
        let id = nap_id(&text);
        let joined = text
            .lines()
            .filter(|line| line.starts_with("  #"))
            .map(str::trim)
            .collect::<Vec<_>>()
            .join(" ");
        let mut end = joined.len().min(280);
        while !joined.is_char_boundary(end) {
            end -= 1
        }
        let compressed = joined[..end].trim();
        let compressed = if compressed.is_empty() {
            summary
        } else {
            compressed
        };
        let saved = run(store, &["nap", &id, compressed]);
        assert!(
            saved.status.success(),
            "{}\n{}",
            stdout(&saved),
            stderr(&saved)
        );
        naps += 1;
    }
}

fn complete_len(t: usize) -> usize {
    let (mut n, mut size) = (0, 2);
    while size <= t {
        n += t / size;
        size *= 2;
    }
    n
}

fn tree_size(store: &Path) -> u64 {
    fs::read_dir(store.join("TREE"))
        .unwrap()
        .map(|entry| entry.unwrap().metadata().unwrap().len())
        .sum()
}

#[test]
fn init_and_config_match_upstream() {
    let store = TempDir::new("init");
    fs::remove_dir(&store.0).unwrap();

    let created = run(&store.0, &["init"]);
    assert!(created.status.success(), "{}", stderr(&created));
    assert!(stdout(&created).contains("Created") && stdout(&created).contains("## Memory"));
    assert!(store.0.join("LOG.txt").is_file());
    assert!(store.0.join("TREE").is_dir());
    assert!(store.0.join("config").is_file());

    let shown = run(&store.0, &["config"]);
    assert!(shown.status.success());
    assert!(stdout(&shown).contains("WAKE_LINES   96"));
    assert!(!stdout(&shown).contains("default 96"));

    let set = run(&store.0, &["config", "wake_lines=12"]);
    assert!(set.status.success(), "{}", stderr(&set));
    assert!(stdout(&set).contains("WAKE_LINES   12") && stdout(&set).contains("default 96"));

    let reset = run(&store.0, &["config", "WAKE_LINES="]);
    assert!(reset.status.success());
    assert!(stdout(&reset).contains("WAKE_LINES   96"));
    assert!(!stdout(&reset).contains("default 96"));

    for bad in [
        "WAKE_LINES=0",
        "WAKE_LINES=x",
        "ENTRY_CHARS=999",
        "NOPE=1",
        "WAKE_LINES",
    ] {
        assert!(
            !run(&store.0, &["config", bad]).status.success(),
            "accepted {bad}"
        );
    }

    let note = run(&store.0, &["note", "an initialized memory"]);
    assert!(note.status.success());
    let log = fs::read(store.0.join("LOG.txt")).unwrap();
    let config = fs::read(store.0.join("config")).unwrap();

    let invalid_utf8 = store.0.join("latin1.txt");
    fs::write(&invalid_utf8, b"2027-01-01 caf\xe9\n").unwrap();
    let bad = run(&store.0, &["import", invalid_utf8.to_str().unwrap()]);
    assert!(!bad.status.success() && stderr(&bad).contains("not UTF-8"));

    let invalid_date = store.0.join("bad-date.txt");
    fs::write(&invalid_date, b"2027-99-99 impossible\n").unwrap();
    let bad = run(&store.0, &["import", invalid_date.to_str().unwrap()]);
    assert!(!bad.status.success() && stderr(&bad).contains("not a real date"));
    assert_eq!(fs::read(store.0.join("LOG.txt")).unwrap(), log);

    let found = run(&store.0, &["init"]);
    assert!(found.status.success() && stdout(&found).contains("Found"));
    assert_eq!(fs::read(store.0.join("LOG.txt")).unwrap(), log);
    assert_eq!(fs::read(store.0.join("config")).unwrap(), config);

    OpenOptions::new()
        .append(true)
        .open(store.0.join("config"))
        .unwrap()
        .write_all(b"WAKE_LNES=100\n")
        .unwrap();
    let bad = run(&store.0, &["wake"]);
    assert!(!bad.status.success());
    assert!(stderr(&bad).contains("config line") && stderr(&bad).contains("WAKE_LNES"));
}

#[test]
fn zoom_and_corrupt_summary_recovery_match_upstream() {
    let store = TempDir::new("recovery");
    for i in 0..4 {
        assert!(
            run(&store.0, &["note", &format!("recovery probe {i}")])
                .status
                .success()
        );
    }
    assert_eq!(settle(&store.0, "settled recovery probe"), 3);

    let zoom = run(&store.0, &["zoom", "0-3"]);
    assert!(
        zoom.status.success() && stdout(&zoom).contains("#0-1 ") && stdout(&zoom).contains("#2-3 ")
    );
    for bad in ["5-6", "0-2", "3-9", "backwards"] {
        assert!(!run(&store.0, &["zoom", bad]).status.success());
    }

    let level = store.0.join("TREE/2");
    let mut file = OpenOptions::new().write(true).open(&level).unwrap();
    file.seek(SeekFrom::Start(0)).unwrap();
    file.write_all(b"\xff\xfe").unwrap();
    let corrupt = run(&store.0, &["zoom", "0-3"]);
    assert!(
        !corrupt.status.success()
            && stderr(&corrupt).contains("corrupt")
            && stderr(&corrupt).contains("forget 0-1")
    );

    file.seek(SeekFrom::Start(0)).unwrap();
    file.write_all(&[b' '; 287]).unwrap();
    file.write_all(b"\n").unwrap();
    drop(file);
    assert!(run(&store.0, &["config", "WAKE_LINES=2"]).status.success());
    let blank = run(&store.0, &["wake"]);
    assert!(!blank.status.success() && stderr(&blank).contains("forget 0-1"));
}

#[test]
fn cli_end_to_end() {
    let store = TempDir::new("test");

    // Real entry point, argv parsing, and store resolution.
    let smoke = run(&store.0, &["wake"]);
    assert!(smoke.status.success() && stdout(&smoke).contains("No memories yet"));
    let typo = store.0.with_extension("typo");
    let ghost = run(&typo, &["wake"]);
    assert!(!ghost.status.success() && stderr(&ghost).contains("No memory at"));
    assert!(!typo.exists());
    let noenv = Command::new(env!("CARGO_BIN_EXE_memo"))
        .env_remove("MEMORY_DIR")
        .arg("wake")
        .output()
        .unwrap();
    // With no env var the binary falls back to the compile-time default
    // (MEMO_MEMORY_DIR, baked in by the Nix build); only when neither exists
    // must it die with the "not set" message. The default is a build env, so
    // the test crate sees the same value the binary was built with.
    let expected = match option_env!("MEMO_MEMORY_DIR") {
        // The baked default points outside the sandbox; it must be reported
        // missing, never silently created (that would be a second identity).
        Some(_) => "No memory at",
        None => "MEMORY_DIR is not set",
    };
    assert!(!noenv.status.success() && stderr(&noenv).contains(expected));
    let usage = Command::new(env!("CARGO_BIN_EXE_memo"))
        .env_remove("MEMORY_DIR")
        .output()
        .unwrap();
    assert!(usage.status.success() && stdout(&usage).contains("memo wake [part [T]]"));
    let unknown = Command::new(env!("CARGO_BIN_EXE_memo"))
        .arg("wat")
        .output()
        .unwrap();
    assert!(!unknown.status.success() && stderr(&unknown).contains("No such command: wat"));

    let r = run(&store.0, &["note", &"x".repeat(281)]);
    assert!(!r.status.success() && stderr(&r).contains("Too long"));
    let r = run(&store.0, &["note", "two\nlines"]);
    assert!(!r.status.success() && stderr(&r).contains("one line"));
    assert!(!run(&store.0, &["note", "   "]).status.success());
    let r = run(&store.0, &["wake"]);
    assert!(stdout(&r).contains("No memories yet"));
    assert!(stdout(&r).trim_end().ends_with("You are awake."));

    let mut seed = String::new();
    for i in 0..N {
        let date = seed_date((i / 5) as u32);
        seed.push_str(&format!(
            "{date} memory number {i}, a thing that happened, was weighed against the rest of the week, turned out to matter more than anyone guessed at the time, and left a mark on every plan that followed it\n"
        ));
    }
    let seed_path = store.0.join("seed.txt");
    fs::write(&seed_path, seed).unwrap();
    let r = run(&store.0, &["import", seed_path.to_str().unwrap()]);
    assert!(
        stdout(&r).contains(&format!("Imported {N}")),
        "{}{}",
        stdout(&r),
        stderr(&r)
    );
    assert!(!store.0.join("config").exists());

    let r = run(&store.0, &["wake"]);
    assert!(!r.status.success() && stdout(&r).contains("Cannot wake"));
    assert!(stdout(&r).contains("run memo wake again"));
    assert!(!stdout(&r).contains("None"));

    let r = run(&store.0, &["nap"]);
    assert!(stdout(&r).contains("Compress memories #"));
    let naps = settle(&store.0, "synthetic summary preserving all relevant facts");
    assert_eq!(naps, complete_len(N));
    assert!(!stdout(&run(&store.0, &["nap"])).contains("You are awake"));
    assert!(run(&store.0, &["wake"]).status.success());

    // Pagination survives the transport caps and tiles the whole wake.
    let mut parts = Vec::new();
    for k in 1.. {
        let r = run(&store.0, &["wake", &k.to_string()]);
        if !r.status.success() {
            break;
        }
        let text = stdout(&r);
        assert!(text.len() < CAP_CHARS);
        assert!(text.lines().count() < CAP_LINES);
        parts.push(
            text.lines()
                .filter(|line| line.starts_with('#'))
                .map(str::to_owned)
                .collect::<Vec<_>>(),
        );
    }
    assert!(parts.len() > 1);
    let lines: Vec<_> = parts.into_iter().flatten().collect();
    assert_eq!(lines.len(), WAKE_LINES);
    assert!(lines.last().unwrap().starts_with(&format!("#{} ", N - 1)));
    assert!(lines.first().unwrap().starts_with("#0-"));
    assert!(stdout(&run(&store.0, &["wake"])).contains("Run: memo wake 2"));
    let mut k = 1;
    while run(&store.0, &["wake", &k.to_string()]).status.success() {
        k += 1
    }
    assert!(stdout(&run(&store.0, &["wake", &(k - 1).to_string()])).contains("You are awake."));

    let log_size = fs::metadata(store.0.join("LOG.txt")).unwrap().len();
    run(&store.0, &["note", "one more thing happened today"]);
    assert!(fs::metadata(store.0.join("LOG.txt")).unwrap().len() > log_size);
    assert_eq!(log_size % 320, 0);
    for entry in fs::read_dir(store.0.join("TREE")).unwrap() {
        assert_eq!(entry.unwrap().metadata().unwrap().len() % 288, 0);
    }
    let r = run(&store.0, &["nap", "0-1", "attempted overwrite"]);
    assert!(r.status.success() && stdout(&r).contains("Nothing left to compress"));

    let r = run(&store.0, &["recall", "memory number 7,"]);
    assert!(stdout(&r).contains("#7 ") && stdout(&r).contains("1 match."));
    assert!(stdout(&run(&store.0, &["recall", "^#7 "])).contains("memory number 7,"));
    let r = run(&store.0, &["recall", "2020-01-02"]);
    assert!(stdout(&r).contains("#7 ") && stdout(&r).contains("5 matches."));

    let before = tree_size(&store.0);
    let log_size = fs::metadata(store.0.join("LOG.txt")).unwrap().len();
    let r = run(&store.0, &["forget", "16-31"]);
    assert!(stdout(&r).contains("16-31"));
    assert!(tree_size(&store.0) < before);
    assert_eq!(
        fs::metadata(store.0.join("LOG.txt")).unwrap().len(),
        log_size
    );
    assert!(!run(&store.0, &["wake"]).status.success());
    let mid = tree_size(&store.0);
    let r = run(&store.0, &["nap", "0-1", "attempted overwrite"]);
    assert!(r.status.success() && stdout(&r).contains("already settled"));
    assert_eq!(tree_size(&store.0), mid);
    let r = run(&store.0, &["nap", "0-31", "out of order"]);
    assert!(!r.status.success() && stderr(&r).contains("Wrong block"));
    for bad in ["5-6", "0-2", "3-9", "backwards"] {
        let r = run(&store.0, &["nap", bad, "not a real block"]);
        assert!(
            !r.status.success() && stderr(&r).contains("not a block"),
            "accepted {bad}: {}{}",
            stdout(&r),
            stderr(&r)
        );
    }
    assert!(settle(&store.0, "rebuilt after forget") > 0);
    assert!(run(&store.0, &["wake"]).status.success());
    assert_eq!(tree_size(&store.0), before);
    assert!(!run(&store.0, &["forget", "17-32"]).status.success());
    assert!(
        !run(&store.0, &["forget", "1048576-1048577"])
            .status
            .success()
    );

    run(
        &store.0,
        &[
            "note",
            "reunião com João em São Paulo: ação aprovada, coração tranquilo",
        ],
    );
    run(
        &store.0,
        &["note", "a plain ascii memory right after the accented one"],
    );
    assert!(stdout(&run(&store.0, &["recall", "coração"])).contains("João"));
    assert!(stdout(&run(&store.0, &["recall", "reunião COM joão"])).contains("São Paulo"));
    assert!(stdout(&run(&store.0, &["recall", "REUNIÃO com joão"])).contains("São Paulo"));
    assert!(
        stdout(&run(
            &store.0,
            &["recall", "plain ascii memory right after"]
        ))
        .contains(&format!("#{} ", N + 2))
    );
    let r = run(&store.0, &["note", &"ã".repeat(150)]);
    assert!(!r.status.success() && stderr(&r).contains("300 bytes"));
    settle(&store.0, "settled");
    assert!(run(&store.0, &["wake"]).status.success());

    let t0 = fs::metadata(store.0.join("LOG.txt")).unwrap().len() / 320;
    let before_wake = run(&store.0, &["wake", "1", &t0.to_string()]);
    assert!(before_wake.status.success());
    run(
        &store.0,
        &["note", "a note that lands between two wake calls"],
    );
    assert_eq!(
        run(&store.0, &["wake", "1", &t0.to_string()]).stdout,
        before_wake.stdout
    );
    assert!(
        !run(&store.0, &["wake", "1", &(t0 + 99).to_string()])
            .status
            .success()
    );
    settle(&store.0, "settled mid-wake");
    let r = run(&store.0, &["wake", "1", &t0.to_string()]);
    assert!(r.status.success() && r.stdout == before_wake.stdout);

    let r = run(&store.0, &["recall", "memory number"]);
    assert!(stdout(&r).len() < CAP_CHARS);
    assert!(stdout(&r).contains("Narrow the regex"));

    // Cross-process id locking.
    let race = TempDir::new("race");
    let mut children: Vec<Child> = (0..16)
        .map(|i| {
            command(&race.0)
                .args(["note", &format!("parallel note {i}")])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap()
        })
        .collect();
    for child in &mut children {
        assert!(child.wait().unwrap().success())
    }
    let mut file = fs::File::open(race.0.join("LOG.txt")).unwrap();
    let mut ids = Vec::new();
    for _ in 0..16 {
        let mut rec = [0; 320];
        file.read_exact(&mut rec).unwrap();
        ids.push(
            String::from_utf8_lossy(&rec)
                .split_whitespace()
                .next()
                .unwrap()
                .to_owned(),
        );
    }
    assert_eq!(ids.len(), 16);
    assert_eq!(ids.iter().collect::<HashSet<_>>().len(), 16);
    let want: HashSet<_> = (0..16).map(|i| format!("#{i}")).collect();
    assert_eq!(ids.into_iter().collect::<HashSet<_>>(), want);

    let mut log = OpenOptions::new()
        .append(true)
        .open(race.0.join("LOG.txt"))
        .unwrap();
    log.write_all(b"#99 2026-01-01 a half-written record killed by a power cut")
        .unwrap();
    drop(log);
    let r = run(&race.0, &["note", "the memory right after a torn write"]);
    assert!(r.status.success() && stdout(&r).contains("Saved as #16"));
    assert_eq!(fs::metadata(race.0.join("LOG.txt")).unwrap().len() % 320, 0);
    assert!(stdout(&run(&race.0, &["recall", "right after a torn write"])).contains("#16 "));
    settle(&race.0, "settled");
    assert!(
        stdout(&run(&race.0, &["wake"]))
            .trim_end()
            .ends_with("You are awake.")
    );
}
