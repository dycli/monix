//! A yeoman that forgets (YEOMAN_FORGET, amnesia): every minute, what is
//! older than the window goes, oldest first. hippo drops the messages and
//! the summaries that read them; files, pages and the rest of the state go
//! once untouched for the window. The person picks the window on the page.

use crate::hippo::Hippo;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

/// The windows the page offers, in minutes: 10 minutes to a week.
pub const CHOICES: [u64; 8] = [10, 30, 60, 180, 720, 1440, 4320, 10080];

/// What the state keeps whatever its age: sign-ins, push keys, the
/// person's picks, and hippo's store, which forgets on its own.
const KEEP: [&str; 6] = ["site", "vapid", "push.json", "model", "forget", "hippo"];

/// The window in minutes: the person's pick, else YEOMAN_FORGET; None for
/// a yeoman that remembers.
pub fn window(state: &Path) -> Option<u64> {
    let default = std::env::var("YEOMAN_FORGET").ok()?.parse().ok()?;
    let picked = fs::read_to_string(state.join("forget"))
        .ok()
        .and_then(|m| m.trim().parse().ok())
        .filter(|m| CHOICES.contains(m));
    Some(picked.unwrap_or(default))
}

pub fn pick(state: &Path, minutes: u64) -> Result<(), String> {
    if std::env::var_os("YEOMAN_FORGET").is_none() {
        return Err("this one remembers".into());
    }
    if !CHOICES.contains(&minutes) {
        return Err(format!("{minutes} minutes is not among the choices"));
    }
    fs::write(state.join("forget"), minutes.to_string()).map_err(|e| e.to_string())
}

/// Forgets every minute; `forgot` hears when messages went, so the pages
/// drop them too.
pub async fn run(state: PathBuf, pages: Option<PathBuf>, hippo: Arc<Hippo>, forgot: impl Fn()) {
    let mut tick = tokio::time::interval(Duration::from_secs(60));
    loop {
        tick.tick().await;
        let Some(minutes) = window(&state) else {
            return;
        };
        let (s, p, h) = (state.clone(), pages.clone(), hippo.clone());
        let gone = tokio::task::spawn_blocking(move || {
            let cutoff = SystemTime::now() - Duration::from_secs(minutes * 60);
            sweep(&s, cutoff, &KEEP);
            if let Some(p) = p {
                sweep(&p, cutoff, &[]);
            }
            h.forget(minutes)
        })
        .await;
        match gone {
            Ok(Ok(0)) => {}
            Ok(Ok(_)) => forgot(),
            Ok(Err(e)) => eprintln!("yeoman: forgetting: {e}"),
            Err(e) => eprintln!("yeoman: forgetting: {e}"),
        }
    }
}

/// Removes the files under `dir` last changed before `cutoff`, then the
/// directories left empty; the names in `keep` stay, at the top.
fn sweep(dir: &Path, cutoff: SystemTime, keep: &[&str]) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for e in entries.flatten() {
        if keep.iter().any(|k| e.file_name() == *k) {
            continue;
        }
        let path = e.path();
        let Ok(meta) = fs::symlink_metadata(&path) else {
            continue;
        };
        if meta.is_dir() {
            sweep(&path, cutoff, &[]);
            let _ = fs::remove_dir(&path);
        } else if meta.modified().is_ok_and(|m| m < cutoff) {
            let _ = fs::remove_file(&path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sweep_takes_the_old_and_keeps_the_new_and_the_kept() {
        let dir = std::env::temp_dir().join(format!("yeoman-forget-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("files/sub")).unwrap();
        fs::create_dir_all(dir.join("site")).unwrap();
        for f in [
            "files/old.png",
            "files/sub/old.txt",
            "files/new.png",
            "site/sessions",
            "vapid",
        ] {
            fs::write(dir.join(f), b"x").unwrap();
        }
        let hour_ago = SystemTime::now() - Duration::from_secs(3600);
        for f in [
            "files/old.png",
            "files/sub/old.txt",
            "site/sessions",
            "vapid",
        ] {
            fs::File::options()
                .write(true)
                .open(dir.join(f))
                .unwrap()
                .set_modified(hour_ago)
                .unwrap();
        }
        sweep(&dir, SystemTime::now() - Duration::from_secs(600), &KEEP);
        assert!(!dir.join("files/old.png").exists());
        assert!(!dir.join("files/sub").exists());
        assert!(dir.join("files/new.png").exists());
        assert!(dir.join("site/sessions").exists() && dir.join("vapid").exists());
    }
}
