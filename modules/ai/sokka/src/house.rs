//! The household: what the assistants share. One directory their common
//! group can write holds the shared lists (a book like each one's own) and
//! a mailbox per assistant. Each assistant's memory stays its own; only
//! what one hands to another's mailbox crosses over.

use std::env;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub struct House {
    pub dir: PathBuf,
    /// This assistant's unit name, which names its mailbox.
    me: String,
    /// Every assistant's unit name and its person, this one's included.
    people: Vec<(String, String)>,
}

impl House {
    /// From SOKKA_HOUSE (the directory), SOKKA_UNIT and SOKKA_PEOPLE
    /// (unit=Person,...); None when the assistant lives alone.
    pub fn from_env() -> Option<House> {
        let dir = env::var_os("SOKKA_HOUSE")?;
        let me = env::var("SOKKA_UNIT").ok()?;
        let people = env::var("SOKKA_PEOPLE")
            .ok()?
            .split(',')
            .filter_map(|p| p.split_once('='))
            .map(|(u, n)| (u.trim().to_owned(), n.trim().to_owned()))
            .collect();
        Some(House {
            dir: dir.into(),
            me,
            people,
        })
    }

    /// Where messages for this assistant wait.
    pub fn mailbox(&self) -> PathBuf {
        self.dir.join("mail").join(&self.me)
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
    /// of everyone else when `to` is None; returns who it went to.
    pub fn post(&self, to: Option<&str>, text: &str) -> Result<Vec<String>, String> {
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
        let ns = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        let name = format!("{ns}-{}", self.me);
        for (unit, _) in &them {
            let dir = self.dir.join("mail").join(unit);
            let tmp = dir.join(format!(".{name}"));
            fs::write(&tmp, text)
                .and_then(|()| shared(&tmp))
                .and_then(|()| fs::rename(&tmp, dir.join(&name)))
                .map_err(|e| format!("mailbox {unit}: {e}"))?;
        }
        Ok(them.into_iter().map(|(_, n)| n.clone()).collect())
    }
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
        let dir = env::temp_dir().join(format!("sokka-house-{}", std::process::id()));
        for u in ["sokka", "suki"] {
            fs::create_dir_all(dir.join("mail").join(u)).unwrap();
        }
        let h = House {
            dir: dir.clone(),
            me: "sokka".into(),
            people: vec![
                ("sokka".into(), "Dylan".into()),
                ("suki".into(), "Gab".into()),
            ],
        };
        assert_eq!(h.person(), "Dylan");
        assert_eq!(h.post(Some("gab"), "hi").unwrap(), ["Gab"]);
        assert_eq!(h.post(None, "hi").unwrap(), ["Gab"]);
        assert!(h.post(Some("Dylan"), "hi").is_err());
        assert_eq!(fs::read_dir(dir.join("mail/suki")).unwrap().count(), 2);
        assert_eq!(fs::read_dir(dir.join("mail/sokka")).unwrap().count(), 0);
        fs::remove_dir_all(&dir).unwrap();
    }
}
