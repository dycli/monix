//! The household: what the assistants share. One directory their common
//! group can write holds the shared lists (a book like each one's own) and
//! a mailbox per assistant. Each assistant's memory stays its own; only
//! what one hands to another's mailbox crosses over.
//!
//! The ship's seat (the engineer's model) is in the household too, under
//! `seat/`: notes to it append to one file, `seat/inbox`, which its
//! sessions load whole; notes from it to an assistant wait in
//! `seat/<unit>/`, a directory like a mailbox, drained the same way.

use std::env;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub struct House {
    pub dir: PathBuf,
    /// This assistant's unit name, which names its mailbox.
    me: String,
    /// This assistant's own name, as it signs notes to the seat.
    name: String,
    /// Every assistant's unit name and its person, this one's included.
    people: Vec<(String, String)>,
    /// What the seat is called, when the household has one.
    seat: Option<String>,
}

impl House {
    /// From YEOMAN_HOUSE (the directory), YEOMAN_UNIT, YEOMAN_PEOPLE
    /// (unit=Person,...) and YEOMAN_SEAT (the seat's name, if any); None
    /// when the assistant lives alone.
    pub fn from_env() -> Option<House> {
        let dir = env::var_os("YEOMAN_HOUSE")?;
        let me = env::var("YEOMAN_UNIT").ok()?;
        let name = env::var("YEOMAN_NAME").unwrap_or_else(|_| me.clone());
        let people = people(&env::var("YEOMAN_PEOPLE").ok()?);
        let seat = env::var("YEOMAN_SEAT").ok().filter(|s| !s.is_empty());
        Some(House {
            dir: dir.into(),
            me,
            name,
            people,
            seat,
        })
    }

    /// Where messages for this assistant wait.
    pub fn mailbox(&self) -> PathBuf {
        self.dir.join("mail").join(&self.me)
    }

    /// Where the seat's notes to this assistant wait, if it has a seat.
    pub fn seatbox(&self) -> Option<PathBuf> {
        self.seat
            .as_ref()
            .map(|_| self.dir.join("seat").join(&self.me))
    }

    /// This assistant's person.
    pub fn person(&self) -> &str {
        self.people
            .iter()
            .find(|(u, _)| *u == self.me)
            .map_or("", |(_, n)| n)
    }

    /// The other people, by first name.
    pub fn others(&self) -> Vec<&str> {
        self.people
            .iter()
            .filter(|(u, _)| *u != self.me)
            .map(|(_, n)| n.as_str())
            .collect()
    }

    /// Leaves `text` in the mailboxes of `to` (first names, any case), or
    /// of everyone else when `to` is None; returns who it went to. A note
    /// to the seat, by its name, appends to its inbox under a dated heading
    /// signed by this assistant.
    pub fn post(&self, to: Option<&str>, text: &str) -> Result<Vec<String>, String> {
        if let (Some(seat), Some(t)) = (&self.seat, to)
            && seat.eq_ignore_ascii_case(t)
        {
            let note = format!(
                "## {} from {} ({}'s assistant)\n{}\n\n",
                chrono::Local::now().format("%Y-%m-%d %H:%M"),
                self.name,
                self.person(),
                text.trim()
            );
            fs::OpenOptions::new()
                .append(true)
                .open(self.dir.join("seat").join("inbox"))
                .and_then(|mut f| std::io::Write::write_all(&mut f, note.as_bytes()))
                .map_err(|e| format!("inbox: {e}"))?;
            return Ok(vec![seat.clone()]);
        }
        let them: Vec<&(String, String)> = self
            .people
            .iter()
            .filter(|(u, n)| *u != self.me && to.is_none_or(|t| n.eq_ignore_ascii_case(t)))
            .collect();
        if them.is_empty() {
            return Err(format!(
                "No one called {}; the household is {}.",
                to.unwrap_or("that"),
                self.others().join(", ")
            ));
        }
        for (unit, _) in &them {
            leave(&self.dir.join("mail").join(unit), &self.me, text)
                .map_err(|e| format!("mailbox {unit}: {e}"))?;
        }
        Ok(them.into_iter().map(|(_, n)| n.clone()).collect())
    }
}

/// `unit=Person,...` as pairs.
fn people(s: &str) -> Vec<(String, String)> {
    s.split(',')
        .filter_map(|p| p.split_once('='))
        .map(|(u, n)| (u.trim().to_owned(), n.trim().to_owned()))
        .collect()
}

/// Leaves `text` as a new file in `dir`, named by the time and `from`,
/// whole before it is seen.
fn leave(dir: &Path, from: &str, text: &str) -> std::io::Result<()> {
    let ns = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    let name = format!("{ns}-{from}");
    let tmp = dir.join(format!(".{name}"));
    fs::write(&tmp, text)?;
    shared(&tmp)?;
    fs::rename(&tmp, dir.join(&name))
}

/// `yeoman tell NAME TEXT`, run from the seat: leaves the note for the
/// assistant NAME, or the assistant of the person NAME (any case), in
/// `seat/<unit>/`, where its tick picks it up. Needs YEOMAN_HOUSE and
/// YEOMAN_PEOPLE.
pub fn tell(to: &str, text: &str) -> Result<(), String> {
    let dir = PathBuf::from(env::var_os("YEOMAN_HOUSE").ok_or("YEOMAN_HOUSE is not set")?);
    let people = people(&env::var("YEOMAN_PEOPLE").map_err(|_| "YEOMAN_PEOPLE is not set")?);
    let (unit, _) = people
        .iter()
        .find(|(u, n)| u.eq_ignore_ascii_case(to) || n.eq_ignore_ascii_case(to))
        .ok_or_else(|| {
            format!(
                "No assistant called {to}; the household has {}.",
                people
                    .iter()
                    .map(|(u, n)| format!("{u} ({n}'s)"))
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        })?;
    leave(&dir.join("seat").join(unit), "seat", text.trim()).map_err(|e| format!("{unit}: {e}"))
}

/// Whether `dir` is the household's, open to its group.
pub fn is_shared(dir: &Path) -> bool {
    fs::metadata(dir).is_ok_and(|m| m.permissions().mode() & 0o020 != 0)
}

/// Opens a file this assistant made to the household's group (the unit's
/// umask keeps new files private). Fails on another's file, which its
/// maker has already opened.
pub fn shared(path: &Path) -> std::io::Result<()> {
    fs::set_permissions(path, fs::Permissions::from_mode(0o660))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn posts_only_to_the_others() {
        let dir = env::temp_dir().join(format!("yeoman-house-{}", std::process::id()));
        for u in ["sokka", "suki"] {
            fs::create_dir_all(dir.join("mail").join(u)).unwrap();
        }
        fs::create_dir_all(dir.join("seat/sokka")).unwrap();
        fs::write(dir.join("seat/inbox"), "").unwrap();
        let h = House {
            dir: dir.clone(),
            me: "sokka".into(),
            name: "Sokka".into(),
            people: vec![
                ("sokka".into(), "Dylan".into()),
                ("suki".into(), "Gab".into()),
            ],
            seat: Some("Bridge".into()),
        };
        assert_eq!(h.person(), "Dylan");
        assert_eq!(h.post(Some("gab"), "hi").unwrap(), ["Gab"]);
        assert_eq!(h.post(None, "hi").unwrap(), ["Gab"]);
        assert!(h.post(Some("Dylan"), "hi").is_err());
        assert_eq!(fs::read_dir(dir.join("mail/suki")).unwrap().count(), 2);
        assert_eq!(fs::read_dir(dir.join("mail/sokka")).unwrap().count(), 0);
        // The seat is not "everyone"; a note to it appends to its inbox.
        assert_eq!(fs::read_to_string(dir.join("seat/inbox")).unwrap(), "");
        assert_eq!(h.post(Some("bridge"), " done ").unwrap(), ["Bridge"]);
        h.post(Some("Bridge"), "and this").unwrap();
        let inbox = fs::read_to_string(dir.join("seat/inbox")).unwrap();
        assert!(inbox.contains(" from Sokka (Dylan's assistant)\ndone\n\n## "));
        assert!(inbox.ends_with("and this\n\n"));
        assert_eq!(h.seatbox().unwrap(), dir.join("seat/sokka"));
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_seat_leaves_notes_by_first_name() {
        let dir = env::temp_dir().join(format!("yeoman-seat-{}", std::process::id()));
        fs::create_dir_all(dir.join("seat/sokka")).unwrap();
        // SAFETY: the test's own process, before any thread reads these.
        unsafe {
            env::set_var("YEOMAN_HOUSE", &dir);
            env::set_var("YEOMAN_PEOPLE", "sokka=Dylan,suki=Gab");
        }
        tell("dylan", " check the pump ").unwrap();
        let note = fs::read_dir(dir.join("seat/sokka"))
            .unwrap()
            .next()
            .unwrap()
            .unwrap();
        assert!(note.file_name().to_string_lossy().ends_with("-seat"));
        assert_eq!(fs::read_to_string(note.path()).unwrap(), "check the pump");
        tell("sokka", "again").unwrap();
        assert_eq!(
            fs::read_dir(dir.join("seat").join("sokka"))
                .unwrap()
                .count(),
            2
        );
        assert!(
            tell("Olivia", "x")
                .unwrap_err()
                .starts_with("No assistant called Olivia")
        );
        fs::remove_dir_all(&dir).unwrap();
    }
}
