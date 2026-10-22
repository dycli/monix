//! Code the assistant runs on its computer: a folder of the desk gets the
//! kept files the code needs, the computer's runner runs the code there
//! with no network, and every file it writes is kept by name, so the
//! assistant can send it on. This is how a picture becomes another kind,
//! a table a chart, or a pile of files a zip.

use crate::files::{self, Library};
use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// The desk's folder of runs (computers.runs in lib/computers.nix).
const RUNS: &str = "runs";
/// The most files one run keeps.
const KEEP_MAX: usize = 50;

#[derive(Deserialize)]
struct Ran {
    exit: Option<i32>,
    stdout: String,
    stderr: String,
    timed_out: bool,
}

/// Runs `code` (python or shell) with copies of the kept files `names`
/// beside it, and keeps what it writes. Answers what the model reads: the
/// exit, the output and the names kept.
pub fn run(
    url: &str,
    desk: &Path,
    library: &Library,
    language: &str,
    code: &str,
    names: &[String],
    seconds: u64,
) -> Result<String, String> {
    let stamp = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_millis();
    let dir = desk
        .join(RUNS)
        .join(format!("{stamp}-{}", std::process::id()));
    fs::create_dir(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let ran = (|| {
        // The runner is another user of the desk's group; the service's
        // umask would shut it out. The folder takes the group from the
        // desk; no setgid bit, which the sandbox (RestrictSUIDSGID) refuses,
        // and the runner writes as the group anyway.
        open(&dir, 0o770)?;
        let mut given = HashMap::new();
        for name in names {
            let from = library
                .path(name)
                .ok_or_else(|| format!("There is no file called {name}."))?;
            let to = dir.join(name);
            // Made new, never through a link the computer left in its place.
            let mut out = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&to)
                .map_err(|e| format!("{name}: {e}"))?;
            io::copy(
                &mut fs::File::open(&from).map_err(|e| format!("{name}: {e}"))?,
                &mut out,
            )
            .map_err(|e| format!("{name}: {e}"))?;
            out.set_permissions(fs::Permissions::from_mode(0o660))
                .map_err(|e| format!("{name}: {e}"))?;
            given.insert(to.clone(), stamp_of(&to)?);
        }
        let ran = call(url, &dir, language, code, seconds)?;
        let mut written = Vec::new();
        walk(&dir, &mut written)?;
        // A file counts as written when it is new or the code changed it.
        let mut kept = Vec::new();
        let mut over = 0;
        for path in written {
            if given
                .get(&path)
                .is_some_and(|s| stamp_of(&path).ok() == Some(*s))
            {
                continue;
            }
            if kept.len() == KEEP_MAX {
                over += 1;
                continue;
            }
            let data =
                files::read_inside(&dir, &path).map_err(|e| format!("{}: {e}", path.display()))?;
            let name = path.file_name().unwrap_or_default().to_string_lossy();
            kept.push(library.keep(&name, &data).map_err(|e| e.to_string())?);
        }
        Ok::<_, String>(report(&ran, &kept, over))
    })();
    let _ = fs::remove_dir_all(&dir);
    ran
}

fn call(url: &str, dir: &Path, language: &str, code: &str, seconds: u64) -> Result<Ran, String> {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        // The runner stops the code at `seconds`; this allows for the trip.
        .timeout_global(Some(Duration::from_secs(seconds + 30)))
        .http_status_as_error(false)
        .build()
        .into();
    let mut answer = agent
        .post(format!("{url}/run"))
        .send_json(serde_json::json!({
            "dir": dir.file_name().unwrap_or_default().to_string_lossy(),
            "language": language,
            "code": code,
            "seconds": seconds,
        }))
        .map_err(|e| format!("computer: {e}"))?;
    if answer.status() != 200 {
        let why = answer.body_mut().read_to_string().unwrap_or_default();
        return Err(format!("computer: {} {why}", answer.status()));
    }
    answer
        .body_mut()
        .read_json()
        .map_err(|e| format!("computer: {e}"))
}

fn report(ran: &Ran, kept: &[String], over: usize) -> String {
    let mut out = match (ran.timed_out, ran.exit) {
        (true, _) => "Stopped: it ran out of time.".to_owned(),
        (_, Some(0)) => "Done.".to_owned(),
        (_, Some(code)) => format!("Exited with {code}."),
        (_, None) => "Killed.".to_owned(),
    };
    for (label, text) in [("Output", &ran.stdout), ("Errors", &ran.stderr)] {
        if !text.trim().is_empty() {
            out.push_str(&format!("\n{label}:\n{}", text.trim_end()));
        }
    }
    if !kept.is_empty() {
        out.push_str(&format!(
            "\nKept as your files: {}. send_file sends one.",
            kept.join(", ")
        ));
    }
    if over > 0 {
        out.push_str(&format!("\n{over} more files were not kept."));
    }
    out
}

/// The files under `dir`, past its scratch and hidden ones.
fn walk(dir: &Path, found: &mut Vec<PathBuf>) -> Result<(), String> {
    let mut entries: Vec<_> = fs::read_dir(dir)
        .map_err(|e| e.to_string())?
        .filter_map(Result::ok)
        .collect();
    entries.sort_by_key(|e| e.file_name());
    for entry in entries {
        if entry.file_name().to_string_lossy().starts_with('.') {
            continue;
        }
        let kind = entry.file_type().map_err(|e| e.to_string())?;
        if kind.is_dir() {
            walk(&entry.path(), found)?;
        } else if kind.is_file() {
            found.push(entry.path());
        }
    }
    Ok(())
}

fn stamp_of(path: &Path) -> Result<(SystemTime, u64), String> {
    let meta = fs::metadata(path).map_err(|e| e.to_string())?;
    Ok((meta.modified().map_err(|e| e.to_string())?, meta.len()))
}

fn open(path: &Path, mode: u32) -> Result<(), String> {
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
        .map_err(|e| format!("{}: {e}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reports_outcome_output_and_kept_files() {
        let ran = Ran {
            exit: Some(0),
            stdout: "3 pages\n".into(),
            stderr: String::new(),
            timed_out: false,
        };
        assert_eq!(
            report(&ran, &["scan.png".into()], 0),
            "Done.\nOutput:\n3 pages\nKept as your files: scan.png. send_file sends one."
        );
        let slow = Ran {
            exit: Some(-9),
            stdout: String::new(),
            stderr: "x".into(),
            timed_out: true,
        };
        assert_eq!(
            report(&slow, &[], 2),
            "Stopped: it ran out of time.\nErrors:\nx\n2 more files were not kept."
        );
    }

    #[test]
    fn walks_past_hidden_and_scratch() {
        let dir = std::env::temp_dir().join(format!("yeoman-run-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(".tmp")).unwrap();
        fs::create_dir_all(dir.join("out")).unwrap();
        fs::write(dir.join(".tmp/mpl"), b"").unwrap();
        fs::write(dir.join("a.png"), b"").unwrap();
        fs::write(dir.join("out/b.csv"), b"").unwrap();
        let mut found = Vec::new();
        walk(&dir, &mut found).unwrap();
        let names: Vec<_> = found
            .iter()
            .map(|p| p.strip_prefix(&dir).unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, ["a.png", "out/b.csv"]);
        fs::remove_dir_all(&dir).unwrap();
    }
}
