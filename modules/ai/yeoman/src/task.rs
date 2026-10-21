//! Subagents, as in Unii: the yeoman spawns named agents that work on
//! their own, in parallel, with no clock on them. Each has a log, its
//! chat with the yeoman: what it is, its task, every call it made and
//! what came back, its replies, and whatever the yeoman told it after.
//! Every run reads the whole log, so a told agent goes on from where it
//! was, even after a restart. Its reply goes back to the yeoman as a work
//! message, never to the person; the yeoman decides what they hear.
//!
//! The files under `task/<name>/` are the whole state, shared by the
//! tools (which spawn, tell and cancel) and the tick loop (which runs):
//! `log.jsonl`, `go` while a run waits to start, `running` while one
//! runs, `told/` for words to a running agent, and `cancel`.

use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// The most of a tool's result an agent's log keeps; the model read it
/// whole while it worked.
const ECHO_MAX: usize = 4000;

/// Names handed out in turn, as Unii names its agents.
const NAMES: [&str; 24] = [
    "Ada", "Basil", "Cleo", "Dara", "Ezra", "Fern", "Gus", "Hana", "Ivo", "Juno", "Kit", "Lark",
    "Milo", "Nell", "Otto", "Pia", "Quin", "Rosa", "Sol", "Tess", "Uma", "Vic", "Wren", "Zed",
];

/// One entry of an agent's log.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Line {
    pub kind: String,
    pub text: String,
}

fn root(state: &Path) -> PathBuf {
    state.join("task")
}

fn dir(state: &Path, name: &str) -> Result<PathBuf, String> {
    let known = !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric());
    let d = root(state).join(name);
    if known && d.join("log.jsonl").is_file() {
        Ok(d)
    } else {
        Err(format!("No agent {name}."))
    }
}

fn stamp() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos())
}

fn put(p: &Path, text: &str) -> Result<(), String> {
    let tmp = p.with_extension("tmp");
    fs::write(&tmp, text)
        .and_then(|()| fs::rename(&tmp, p))
        .map_err(|e| format!("{}: {e}", p.display()))
}

/// Starts an agent on `task`, returning its name.
pub fn spawn(state: &Path, task: &str) -> Result<String, String> {
    fs::create_dir_all(root(state)).map_err(|e| e.to_string())?;
    let taken = |n: &str| root(state).join(n).exists();
    let name = (0..)
        .flat_map(|round| {
            NAMES.iter().map(move |n| match round {
                0 => n.to_string(),
                _ => format!("{n}{}", round + 1),
            })
        })
        .find(|n| !taken(n))
        .unwrap();
    let d = root(state).join(&name);
    fs::create_dir_all(d.join("told")).map_err(|e| format!("{}: {e}", d.display()))?;
    push(state, &name, "note", "subagent")?;
    push(state, &name, "user", task)?;
    put(&d.join("go"), "")?;
    Ok(name)
}

/// Sends `text` to agent `name`: a running one reads it between its tool
/// calls; an idle one goes on from its log.
pub fn tell(state: &Path, name: &str, text: &str) -> Result<String, String> {
    let d = dir(state, name)?;
    if d.join("running").exists() {
        put(&d.join("told").join(format!("{}.txt", stamp())), text)?;
        return Ok(format!(
            "Sent. {name} reads it between its tool calls, and its report answers it."
        ));
    }
    push(state, name, "user", text)?;
    put(&d.join("go"), "")?;
    Ok(format!("Sent. {name}'s reply will reach you as a message."))
}

/// Asks agent `name` to stop, on the next tick.
pub fn cancel(state: &Path, name: &str) -> Result<(), String> {
    let d = dir(state, name)?;
    if d.join("running").exists() {
        return put(&d.join("cancel"), "");
    }
    // One waiting to start just doesn't.
    fs::remove_file(d.join("go")).map_err(|_| format!("{name} is not at work."))
}

/// Whether a stop was asked for; asking is answered once.
pub fn cancelled(state: &Path, name: &str) -> bool {
    fs::remove_file(root(state).join(name).join("cancel")).is_ok()
}

/// Adds an entry to agent `name`'s log.
pub fn push(state: &Path, name: &str, kind: &str, text: &str) -> Result<(), String> {
    let p = root(state).join(name).join("log.jsonl");
    let line = serde_json::to_string(&Line {
        kind: kind.into(),
        text: text.into(),
    })
    .map_err(|e| e.to_string())?;
    fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&p)
        .and_then(|mut f| writeln!(f, "{line}"))
        .map_err(|e| format!("{}: {e}", p.display()))
}

/// Logs a tool call or its result, the result cut to ECHO_MAX.
pub fn step(state: &Path, name: &str, step: &crate::model::Step) {
    use crate::model::Step;
    let (kind, text) = match step {
        Step::Call { name, input, .. } => ("tool", format!("{name} {input}")),
        Step::Result { text, error, .. } => {
            let mut t: String = text.chars().take(ECHO_MAX).collect();
            if t.len() < text.len() {
                t.push_str(" …");
            }
            ("echo", if *error { format!("(error) {t}") } else { t })
        }
        Step::Answer { text } => ("talk", text.clone()),
        Step::Text { .. } => return,
    };
    if let Err(e) = push(state, name, kind, &text) {
        eprintln!("yeoman: agent {name}: {e}");
    }
}

/// Agent `name`'s whole log.
pub fn log(state: &Path, name: &str) -> Result<Vec<Line>, String> {
    let p = dir(state, name)?.join("log.jsonl");
    let text = fs::read_to_string(&p).map_err(|e| format!("{}: {e}", p.display()))?;
    Ok(text
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect())
}

/// A log as the agent reads it: one `i|kind: text` line per entry.
pub fn chat(log: &[Line]) -> String {
    log.iter()
        .enumerate()
        .map(|(i, l)| format!("{i}|{}: {}", l.kind, l.text))
        .collect::<Vec<_>>()
        .join("\n")
}

/// The agents at work, waiting to run or running, by name, with their
/// tasks, oldest first.
pub fn working(state: &Path) -> Vec<(String, String)> {
    let Ok(entries) = fs::read_dir(root(state)) else {
        return Vec::new();
    };
    let mut v: Vec<(SystemTime, String)> = entries
        .filter_map(|e| e.ok())
        .filter(|e| {
            let p = e.path();
            p.join("go").exists() || p.join("running").exists()
        })
        .filter_map(|e| {
            let made = e.metadata().and_then(|m| m.modified()).ok()?;
            Some((made, e.file_name().to_string_lossy().into_owned()))
        })
        .collect();
    v.sort();
    v.into_iter()
        .filter_map(|(_, name)| {
            let task = log(state, &name)
                .ok()?
                .into_iter()
                .find(|l| l.kind == "user")?
                .text;
            Some((name, task))
        })
        .collect()
}

/// Claims agent `name`'s waiting run, if it has one.
pub fn take(state: &Path, name: &str) -> bool {
    let d = root(state).join(name);
    fs::rename(d.join("go"), d.join("running")).is_ok()
}

/// Runs cut short by a restart wait to start again: their logs hold what
/// they did, so they go on from there.
pub fn resume(state: &Path) {
    let Ok(entries) = fs::read_dir(root(state)) else {
        return;
    };
    for d in entries.filter_map(|e| e.ok()).map(|e| e.path()) {
        let _ = fs::rename(d.join("running"), d.join("go"));
    }
}

/// Words told to running agent `name` and not yet passed on, oldest
/// first, with the file to remove once they are.
pub fn told(state: &Path, name: &str) -> Vec<(PathBuf, String)> {
    let Ok(entries) = fs::read_dir(root(state).join(name).join("told")) else {
        return Vec::new();
    };
    let mut v: Vec<PathBuf> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "txt"))
        .collect();
    v.sort();
    v.into_iter()
        .filter_map(|p| fs::read_to_string(&p).ok().map(|t| (p, t)))
        .collect()
}

/// Agent `name`'s run is over. Words told too late for it are logged, and
/// it goes on to answer them.
pub fn finish(state: &Path, name: &str) {
    let d = root(state).join(name);
    let _ = fs::remove_file(d.join("cancel"));
    let late = told(state, name);
    for (file, text) in &late {
        if push(state, name, "user", text).is_ok() {
            let _ = fs::remove_file(file);
        }
    }
    if late.is_empty() {
        let _ = fs::remove_file(d.join("running"));
    } else {
        let _ = fs::rename(d.join("running"), d.join("go"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agents_work_apart_and_go_on_from_their_logs() {
        let state = std::env::temp_dir().join(format!("yeoman-task-{}", std::process::id()));
        let _ = fs::remove_dir_all(&state);
        fs::create_dir_all(&state).unwrap();
        let a = spawn(&state, "find a plumber").unwrap();
        let b = spawn(&state, "price flights").unwrap();
        assert_eq!((a.as_str(), b.as_str()), ("Ada", "Basil"));
        assert_eq!(working(&state).len(), 2);
        assert!(take(&state, &a) && !take(&state, &a));
        // Told while running, it reads the words between calls.
        assert!(
            tell(&state, &a, "only licensed ones")
                .unwrap()
                .contains("between")
        );
        assert_eq!(told(&state, &a)[0].1, "only licensed ones");
        // A restart puts the cut run back to wait.
        resume(&state);
        assert!(take(&state, &a));
        // Words that came too late for the run start the next one.
        finish(&state, &a);
        assert!(take(&state, &a));
        push(&state, &a, "talk", "Two found.").unwrap();
        finish(&state, &a);
        assert_eq!(working(&state), vec![(b.clone(), "price flights".into())]);
        // Idle, it goes on from its log.
        assert!(
            tell(&state, &a, "and their prices?")
                .unwrap()
                .contains("reply")
        );
        let kinds: Vec<_> = log(&state, &a)
            .unwrap()
            .into_iter()
            .map(|l| l.kind)
            .collect();
        assert_eq!(kinds, ["note", "user", "user", "talk", "user"]);
        assert!(chat(&log(&state, &a).unwrap()).starts_with("0|note: subagent\n1|user: find"));
        cancel(&state, &b).unwrap();
        assert!(working(&state).iter().all(|(n, _)| n != &b));
        assert!(tell(&state, "../x", "hi").is_err() && cancel(&state, "Zed").is_err());
        fs::remove_dir_all(&state).unwrap();
    }
}
