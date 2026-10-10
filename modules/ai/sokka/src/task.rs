//! Work that outlives the turn. The model starts a task with the request
//! worded as the person's; the tick loop runs it as a turn of its own with
//! no clock on it and sends the answer when it is done. Along the way the
//! task can say something, and the person can cancel it. One task at a
//! time: the files under `task/` are the whole state, so a restart loses
//! only the run in flight.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

fn dir(state: &Path) -> PathBuf {
    state.join("task")
}

/// Files the request; refused while another waits or runs.
pub fn start(state: &Path, text: &str) -> Result<(), String> {
    let d = dir(state);
    fs::create_dir_all(d.join("said")).map_err(|e| format!("{}: {e}", d.display()))?;
    if let Some(running) = running(state) {
        return Err(format!("A task is already running: {running}"));
    }
    let tmp = d.join("new.tmp");
    fs::write(&tmp, text)
        .and_then(|()| fs::rename(&tmp, d.join("new")))
        .map_err(|e| format!("{}: {e}", tmp.display()))
}

/// The request under way, waiting or running.
pub fn running(state: &Path) -> Option<String> {
    let d = dir(state);
    fs::read_to_string(d.join("running"))
        .or_else(|_| fs::read_to_string(d.join("new")))
        .ok()
}

/// Claims the waiting request to run it.
pub fn take(state: &Path) -> Option<String> {
    let d = dir(state);
    fs::rename(d.join("new"), d.join("running")).ok()?;
    fs::read_to_string(d.join("running")).ok()
}

/// Asks for the running task to stop.
pub fn cancel(state: &Path) -> Result<(), String> {
    let running = running(state).ok_or("No task is running.")?;
    let p = dir(state).join("cancel");
    fs::write(&p, "").map_err(|e| format!("{}: {e}", p.display()))?;
    Ok(format!("Stopping: {running}")).map(|_: String| ())
}

/// Whether a stop was asked for; asking is answered once.
pub fn cancelled(state: &Path) -> bool {
    fs::remove_file(dir(state).join("cancel")).is_ok()
}

/// Something the task tells the person now, before its answer.
pub fn say(state: &Path, text: &str) -> Result<(), String> {
    running(state).ok_or("No task is running; just answer.")?;
    let d = dir(state).join("said");
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_nanos();
    let tmp = d.join(format!("{stamp}.tmp"));
    fs::write(&tmp, text)
        .and_then(|()| fs::rename(&tmp, d.join(format!("{stamp}.txt"))))
        .map_err(|e| format!("{}: {e}", tmp.display()))
}

/// What the task said and was not yet sent, oldest first, with the
/// file to remove once it is.
pub fn said(state: &Path) -> Vec<(PathBuf, String)> {
    let Ok(entries) = fs::read_dir(dir(state).join("said")) else {
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

/// The task is over, answered or stopped.
pub fn finish(state: &Path) {
    let d = dir(state);
    let _ = fs::remove_file(d.join("running"));
    let _ = fs::remove_file(d.join("cancel"));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_task_at_a_time_from_start_to_finish() {
        let state = std::env::temp_dir().join(format!("sokka-task-{}", std::process::id()));
        fs::create_dir_all(&state).unwrap();
        assert!(say(&state, "hi").is_err());
        start(&state, "find a plumber").unwrap();
        assert!(start(&state, "another").is_err());
        assert_eq!(running(&state).as_deref(), Some("find a plumber"));
        assert_eq!(take(&state).as_deref(), Some("find a plumber"));
        assert!(take(&state).is_none());
        say(&state, "three found so far").unwrap();
        let said = said(&state);
        assert_eq!(said[0].1, "three found so far");
        assert!(!cancelled(&state));
        cancel(&state).unwrap();
        assert!(cancelled(&state));
        assert!(!cancelled(&state));
        finish(&state);
        assert!(running(&state).is_none());
        assert!(cancel(&state).is_err());
        fs::remove_dir_all(&state).unwrap();
    }
}
