//! The household: what the assistants share. One directory their common
//! group can write holds the shared lists (a book like each one's own) and
//! a mailbox per assistant. Each assistant's memory stays its own; only
//! what one hands to another's mailbox crosses over.
//!
//! Every message names who it is for: one assistant or several, by its own
//! name, or a person by theirs, which reaches that person's door (the one
//! assistant that takes their messages). There is no "everyone": a note
//! goes where it was sent and nowhere else.
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

/// One of the household's assistants.
#[derive(Clone, Debug, PartialEq)]
pub struct Agent {
    /// Its unit name, which names its mailbox.
    pub unit: String,
    /// What it is called, e.g. Sokka.
    pub name: String,
    /// Whose assistant it is.
    pub person: String,
    /// Whether it takes its person's messages: what is sent to them by
    /// name comes here. One per person.
    pub door: bool,
}

pub struct House {
    pub dir: PathBuf,
    /// This assistant's unit name.
    me: String,
    /// Every assistant, this one's included.
    agents: Vec<Agent>,
    /// What the seat is called, when the household has one.
    seat: Option<String>,
}

impl House {
    /// From YEOMAN_HOUSE (the directory), YEOMAN_UNIT, YEOMAN_MEMBERS (see
    /// `agents`) and YEOMAN_SEAT (the seat's name, if any); None when the
    /// assistant lives alone.
    pub fn from_env() -> Option<House> {
        let dir = env::var_os("YEOMAN_HOUSE")?;
        let me = env::var("YEOMAN_UNIT").ok()?;
        let agents = agents(&env::var("YEOMAN_MEMBERS").ok()?);
        agents.iter().any(|a| a.unit == me).then_some(())?;
        let seat = env::var("YEOMAN_SEAT").ok().filter(|s| !s.is_empty());
        Some(House {
            dir: dir.into(),
            me,
            agents,
            seat,
        })
    }

    fn me(&self) -> &Agent {
        self.agents.iter().find(|a| a.unit == self.me).unwrap()
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

    /// Whether this assistant is its person's door, the one that speaks
    /// to them unasked.
    pub fn is_door(&self) -> bool {
        self.me().door
    }

    /// This assistant's person.
    pub fn person(&self) -> &str {
        &self.me().person
    }

    /// This assistant's name.
    pub fn name(&self) -> &str {
        &self.me().name
    }

    /// The other people's doors, by name: what "the rest of the household"
    /// meant before sharing named anyone (book.rs).
    pub fn others(&self) -> Vec<String> {
        self.agents
            .iter()
            .filter(|a| a.door && a.person != self.person())
            .map(|a| a.name.clone())
            .collect()
    }

    /// Who can be sent to, for an error that names them.
    fn roster(&self) -> String {
        let mut v: Vec<String> = self
            .agents
            .iter()
            .filter(|a| a.unit != self.me)
            .map(|a| format!("{} ({}'s)", a.name, a.person))
            .collect();
        v.extend(self.seat.clone());
        v.join(", ")
    }

    /// Whom `to` names: the seat, and the assistants, each once.
    fn find(&self, to: &[String]) -> Result<(bool, Vec<&Agent>), String> {
        if to.is_empty() {
            return Err(format!("Name who it is for: {}.", self.roster()));
        }
        let mut seat = false;
        let mut them: Vec<&Agent> = Vec::new();
        for t in to {
            let t = t.trim();
            if self
                .seat
                .as_ref()
                .is_some_and(|s| s.eq_ignore_ascii_case(t))
            {
                seat = true;
                continue;
            }
            let found = self
                .agents
                .iter()
                .find(|a| a.name.eq_ignore_ascii_case(t) || a.unit.eq_ignore_ascii_case(t))
                .or_else(|| {
                    self.agents
                        .iter()
                        .find(|a| a.door && a.person.eq_ignore_ascii_case(t))
                })
                .ok_or_else(|| format!("No one called {t}; the household is {}.", self.roster()))?;
            if found.unit == self.me {
                return Err(format!("{t} is you; tell them yourself."));
            }
            if !them.contains(&found) {
                them.push(found);
            }
        }
        Ok((seat, them))
    }

    /// Checks that each of `to` can be sent to, for something that sends
    /// to them later.
    pub fn check(&self, to: &[String]) -> Result<(), String> {
        self.find(to).map(drop)
    }

    /// Leaves `text` for each of `to`: an assistant by name, a person by
    /// theirs (their door), or the seat; returns who it went to. All are
    /// found before any is sent. A note to the seat appends to its inbox
    /// under a dated heading signed by this assistant.
    pub fn post(&self, to: &[String], text: &str) -> Result<Vec<String>, String> {
        let (seat, them) = self.find(to)?;
        let mut sent = Vec::new();
        if seat {
            let note = format!(
                "## {} from {} ({}'s assistant)\n{}\n\n",
                chrono::Local::now().format("%Y-%m-%d %H:%M"),
                self.name(),
                self.person(),
                text.trim()
            );
            fs::OpenOptions::new()
                .append(true)
                .open(self.dir.join("seat").join("inbox"))
                .and_then(|mut f| std::io::Write::write_all(&mut f, note.as_bytes()))
                .map_err(|e| format!("inbox: {e}"))?;
            sent.extend(self.seat.clone());
        }
        for a in them {
            leave(&self.dir.join("mail").join(&a.unit), &self.me, text)
                .map_err(|e| format!("mailbox {}: {e}", a.unit))?;
            sent.push(a.name.clone());
        }
        Ok(sent)
    }
}

/// `unit=Name=Person[=door],...` as agents.
fn agents(s: &str) -> Vec<Agent> {
    s.split(',')
        .filter_map(|p| {
            let mut f = p.split('=').map(str::trim);
            let (unit, name, person) = (f.next()?, f.next()?, f.next()?);
            Some(Agent {
                unit: unit.to_owned(),
                name: name.to_owned(),
                person: person.to_owned(),
                door: f.next() == Some("door"),
            })
        })
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

/// `yeoman tell NAME[,NAME...] TEXT`, run from the seat: leaves the note
/// for each assistant named, or the door of each person named (any case),
/// in `seat/<unit>/`, where its tick picks it up. All are found before any
/// is sent. Needs YEOMAN_HOUSE and YEOMAN_MEMBERS.
pub fn tell(to: &str, text: &str) -> Result<(), String> {
    let dir = PathBuf::from(env::var_os("YEOMAN_HOUSE").ok_or("YEOMAN_HOUSE is not set")?);
    let all = agents(&env::var("YEOMAN_MEMBERS").map_err(|_| "YEOMAN_MEMBERS is not set")?);
    let them = to
        .split(',')
        .map(str::trim)
        .map(|t| {
            all.iter()
                .find(|a| a.name.eq_ignore_ascii_case(t) || a.unit.eq_ignore_ascii_case(t))
                .or_else(|| {
                    all.iter()
                        .find(|a| a.door && a.person.eq_ignore_ascii_case(t))
                })
                .ok_or_else(|| {
                    format!(
                        "No assistant called {t}; the household has {}.",
                        all.iter()
                            .map(|a| format!("{} ({}'s)", a.name, a.person))
                            .collect::<Vec<_>>()
                            .join(", ")
                    )
                })
        })
        .collect::<Result<Vec<_>, _>>()?;
    for a in them {
        leave(&dir.join("seat").join(&a.unit), "seat", text.trim())
            .map_err(|e| format!("{}: {e}", a.unit))?;
    }
    Ok(())
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

    fn roster() -> Vec<Agent> {
        let a = |unit: &str, name: &str, person: &str, door| Agent {
            unit: unit.into(),
            name: name.into(),
            person: person.into(),
            door,
        };
        vec![
            a("sokka", "Sokka", "Dylan", true),
            a("suki", "Suki", "Gab", true),
            a("raava", "Raava", "Dylan", false),
        ]
    }

    #[test]
    fn posts_only_to_whom_it_names() {
        let dir = env::temp_dir().join(format!("yeoman-house-{}", std::process::id()));
        for u in ["sokka", "suki", "raava"] {
            fs::create_dir_all(dir.join("mail").join(u)).unwrap();
        }
        fs::create_dir_all(dir.join("seat/sokka")).unwrap();
        fs::write(dir.join("seat/inbox"), "").unwrap();
        let h = House {
            dir: dir.clone(),
            me: "sokka".into(),
            agents: roster(),
            seat: Some("Bridge".into()),
        };
        let n = |u: &str| fs::read_dir(dir.join("mail").join(u)).unwrap().count();
        assert_eq!(h.person(), "Dylan");
        // No one named is no one, not everyone.
        assert!(
            h.post(&[], "hi")
                .unwrap_err()
                .starts_with("Name who it is for")
        );
        // A person by name reaches their door.
        assert_eq!(h.post(&["gab".into()], "hi").unwrap(), ["Suki"]);
        // An assistant by its name, and several at once, each once.
        assert_eq!(
            h.post(&["Raava".into(), "suki".into(), "Gab".into()], "hi")
                .unwrap(),
            ["Raava", "Suki"]
        );
        assert_eq!((n("suki"), n("raava"), n("sokka")), (2, 1, 0));
        // Its own person's door is itself.
        assert!(h.post(&["Dylan".into()], "hi").is_err());
        // An unknown name sends nothing at all.
        assert!(h.post(&["suki".into(), "Olivia".into()], "hi").is_err());
        assert_eq!(n("suki"), 2);
        // The seat by name; a note to it appends to its inbox.
        assert_eq!(h.post(&["bridge".into()], " done ").unwrap(), ["Bridge"]);
        h.post(&["Bridge".into()], "and this").unwrap();
        let inbox = fs::read_to_string(dir.join("seat/inbox")).unwrap();
        assert!(inbox.contains(" from Sokka (Dylan's assistant)\ndone\n\n## "));
        assert!(inbox.ends_with("and this\n\n"));
        assert_eq!(h.seatbox().unwrap(), dir.join("seat/sokka"));
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn another_assistant_of_a_person_reaches_their_door() {
        let dir = env::temp_dir().join(format!("yeoman-raava-{}", std::process::id()));
        for u in ["sokka", "suki"] {
            fs::create_dir_all(dir.join("mail").join(u)).unwrap();
        }
        let h = House {
            dir: dir.clone(),
            me: "raava".into(),
            agents: roster(),
            seat: None,
        };
        assert_eq!(h.post(&["dylan".into()], "hi").unwrap(), ["Sokka"]);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_seat_leaves_notes_by_first_name() {
        let dir = env::temp_dir().join(format!("yeoman-seat-{}", std::process::id()));
        fs::create_dir_all(dir.join("seat/sokka")).unwrap();
        // SAFETY: the test's own process, before any thread reads these.
        unsafe {
            env::set_var("YEOMAN_HOUSE", &dir);
            env::set_var(
                "YEOMAN_MEMBERS",
                "sokka=Sokka=Dylan=door,suki=Suki=Gab=door",
            );
        }
        tell("dylan", " check the pump ").unwrap();
        let note = fs::read_dir(dir.join("seat/sokka"))
            .unwrap()
            .next()
            .unwrap()
            .unwrap();
        assert!(note.file_name().to_string_lossy().ends_with("-seat"));
        assert_eq!(fs::read_to_string(note.path()).unwrap(), "check the pump");
        fs::create_dir_all(dir.join("seat/suki")).unwrap();
        tell("sokka, Gab", "again").unwrap();
        let n = |u: &str| fs::read_dir(dir.join("seat").join(u)).unwrap().count();
        assert_eq!((n("sokka"), n("suki")), (2, 1));
        assert!(tell("suki,Olivia", "x").is_err());
        assert_eq!(n("suki"), 1);
        assert!(
            tell("Olivia", "x")
                .unwrap_err()
                .starts_with("No assistant called Olivia")
        );
        fs::remove_dir_all(&dir).unwrap();
    }
}
