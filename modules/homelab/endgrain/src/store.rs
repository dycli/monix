//! `endgrain.db`: the staff, their shifts, which weeks are posted,
//! time-off requests, and the usual week that fills weeks ahead. Days are `YYYY-MM-DD` text and times are minutes after
//! midnight, so SQLite's date functions do the calendar arithmetic. Weeks
//! run Monday to Sunday and are named by their Monday.

use std::io::Read;
use std::path::Path;

use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};

const SCHEMA: &str = "
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS staff (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  color TEXT NOT NULL,
  active INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS shifts (
  id INTEGER PRIMARY KEY,
  staff INTEGER NOT NULL REFERENCES staff(id),
  day TEXT NOT NULL,
  start INTEGER NOT NULL,
  end INTEGER NOT NULL,
  note TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS shifts_day ON shifts(day);
-- A posted week, which staff can see. `edited` marks changes since.
CREATE TABLE IF NOT EXISTS weeks (
  monday TEXT PRIMARY KEY,
  published TEXT NOT NULL,
  edited INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS requests (
  id INTEGER PRIMARY KEY,
  staff INTEGER NOT NULL REFERENCES staff(id),
  first TEXT NOT NULL,
  last TEXT NOT NULL,
  reason TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'denied')),
  made TEXT NOT NULL DEFAULT (datetime('now', 'localtime')),
  decided TEXT
);
";

/// Changes to the schema after the first, run in order once each;
/// `PRAGMA user_version` counts those applied.
const MIGRATIONS: &[&str] = &[
    "
-- The shifts each person works most weeks; weekday 0 is Monday.
CREATE TABLE usual (
  id INTEGER PRIMARY KEY,
  staff INTEGER NOT NULL REFERENCES staff(id),
  weekday INTEGER NOT NULL CHECK (weekday BETWEEN 0 AND 6),
  start INTEGER NOT NULL,
  end INTEGER NOT NULL,
  note TEXT NOT NULL DEFAULT ''
);
-- 1 for a shift the usual week put there and no one has edited.
ALTER TABLE shifts ADD COLUMN usual INTEGER NOT NULL DEFAULT 0;
-- Weeks the usual week has filled, so a shift deleted from one stays gone.
CREATE TABLE filled (monday TEXT PRIMARY KEY);
-- The fewest people each day needs.
CREATE TABLE rules (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  weekday INTEGER NOT NULL,
  weekend INTEGER NOT NULL
);
INSERT INTO rules VALUES (1, 2, 3);
-- Days the manager has agreed to run with fewer than the rules ask.
CREATE TABLE short_ok (day TEXT PRIMARY KEY);
",
    "
-- Per-person links gave way to one shared password; staff loses its token.
CREATE TABLE staff2 (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  color TEXT NOT NULL,
  active INTEGER NOT NULL DEFAULT 1
);
INSERT INTO staff2 SELECT id, name, color, active FROM staff;
DROP TABLE staff;
ALTER TABLE staff2 RENAME TO staff;
-- One password the whole team shares and one for the manager, salted
-- and hashed.
CREATE TABLE password (
  role TEXT PRIMARY KEY CHECK (role IN ('admin', 'staff')),
  salt TEXT NOT NULL,
  hash TEXT NOT NULL
);
-- Signed-in browsers; a new password clears that role's.
CREATE TABLE sessions (
  token TEXT PRIMARY KEY,
  role TEXT NOT NULL,
  made TEXT NOT NULL
);
-- 1 for a shift its person can't work, waiting for someone to take it.
ALTER TABLE shifts ADD COLUMN open INTEGER NOT NULL DEFAULT 0;
",
];

/// How many weeks past this one the usual week fills in.
const AHEAD: i64 = 8;

/// The Monday of the week holding day `?N`: `weekday 0` moves on to Sunday
/// (or stays there), and that Sunday's week began six days before.
macro_rules! monday_of {
    ($day:literal) => {
        concat!("date(", $day, ", 'weekday 0', '-6 days')")
    };
}

/// The longest request staff can make in one go.
const MAX_DAYS: i64 = 60;

#[derive(Debug)]
pub enum Error {
    /// The request itself is wrong; the text says how.
    Bad(String),
    /// No such row.
    Missing,
    Db(rusqlite::Error),
}

impl From<rusqlite::Error> for Error {
    fn from(e: rusqlite::Error) -> Self {
        Error::Db(e)
    }
}

type Result<T> = std::result::Result<T, Error>;

fn bad<T>(why: impl Into<String>) -> Result<T> {
    Err(Error::Bad(why.into()))
}

#[derive(Serialize)]
pub struct Person {
    pub id: i64,
    pub name: String,
    pub color: String,
    pub active: bool,
}

#[derive(Serialize)]
pub struct Shift {
    pub id: i64,
    pub staff: i64,
    pub day: String,
    pub start: i64,
    pub end: i64,
    pub note: String,
    /// Up for anyone to take; it counts toward no one's day.
    pub open: bool,
}

#[derive(Serialize)]
pub struct Off {
    pub id: i64,
    pub staff: i64,
    pub name: String,
    pub first: String,
    pub last: String,
    pub reason: String,
    pub status: String,
    pub made: String,
    pub decided: Option<String>,
    /// Shifts the person already has on those days.
    pub shifts: i64,
}

#[derive(Serialize)]
pub struct Usual {
    pub start: i64,
    pub end: i64,
}

#[derive(Serialize)]
pub struct Week {
    pub monday: String,
    pub published: Option<String>,
    pub edited: bool,
    pub staff: Vec<Person>,
    pub shifts: Vec<Shift>,
    /// Pending and approved requests that touch the week.
    pub off: Vec<Off>,
    /// Pending requests for any week, for the tab's badge.
    pub pending: i64,
    /// The shift times used most lately, offered as one-tap picks.
    pub usual: Vec<Usual>,
    pub rules: Rules,
    /// Days that week the manager agreed to run short.
    pub short_ok: Vec<String>,
}

#[derive(Serialize, Deserialize)]
pub struct Rules {
    pub weekday: i64,
    pub weekend: i64,
}

#[derive(Serialize)]
pub struct Default {
    pub id: i64,
    pub staff: i64,
    pub weekday: i64,
    pub start: i64,
    pub end: i64,
    pub note: String,
}

#[derive(Serialize)]
pub struct UsualWeek {
    pub staff: Vec<Person>,
    pub shifts: Vec<Default>,
    pub rules: Rules,
}

#[derive(Deserialize)]
pub struct DefaultIn {
    pub id: Option<i64>,
    pub staff: i64,
    pub weekday: i64,
    pub start: i64,
    pub end: i64,
    #[serde(default)]
    pub note: String,
}

#[derive(Serialize)]
pub struct Requests {
    pub pending: Vec<Off>,
    pub decided: Vec<Off>,
}

#[derive(Deserialize)]
pub struct ShiftIn {
    pub id: Option<i64>,
    pub staff: i64,
    pub day: String,
    pub start: i64,
    pub end: i64,
    #[serde(default)]
    pub note: String,
    #[serde(default)]
    pub open: bool,
}

#[derive(Deserialize)]
pub struct PersonIn {
    pub id: Option<i64>,
    pub name: String,
    pub color: String,
    pub active: bool,
}

#[derive(Deserialize)]
pub struct OffIn {
    pub first: String,
    pub last: String,
    #[serde(default)]
    pub reason: String,
}

/// Who a signed-in browser is: the manager sees and changes everything;
/// staff see posted weeks, ask for time off and take open shifts.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Admin,
    Staff,
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Role::Admin => "admin",
            Role::Staff => "staff",
        }
    }
}

#[derive(Serialize)]
pub struct Passwords {
    pub admin: bool,
    pub staff: bool,
}

pub struct Store {
    db: Connection,
}

const OFF: &str =
    "SELECT r.id, r.staff, s.name, r.first, r.last, r.reason, r.status, r.made, r.decided,
      (SELECT COUNT(*) FROM shifts
        WHERE staff = r.staff AND NOT open AND day BETWEEN r.first AND r.last)
    FROM requests r JOIN staff s ON s.id = r.staff";

fn off(r: &rusqlite::Row) -> rusqlite::Result<Off> {
    Ok(Off {
        id: r.get(0)?,
        staff: r.get(1)?,
        name: r.get(2)?,
        first: r.get(3)?,
        last: r.get(4)?,
        reason: r.get(5)?,
        status: r.get(6)?,
        made: r.get(7)?,
        decided: r.get(8)?,
        shifts: r.get(9)?,
    })
}

fn shift(r: &rusqlite::Row) -> rusqlite::Result<Shift> {
    Ok(Shift {
        id: r.get(0)?,
        staff: r.get(1)?,
        day: r.get(2)?,
        start: r.get(3)?,
        end: r.get(4)?,
        note: r.get(5)?,
        open: r.get(6)?,
    })
}

fn person(r: &rusqlite::Row) -> rusqlite::Result<Person> {
    Ok(Person {
        id: r.get(0)?,
        name: r.get(1)?,
        color: r.get(2)?,
        active: r.get(3)?,
    })
}

/// 128 random bits as hex, for a sign-in session or a password's salt.
fn token() -> String {
    let mut bytes = [0u8; 16];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut bytes))
        .expect("/dev/urandom");
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn hash(salt: &str, password: &str) -> String {
    use sha2::{Digest, Sha256};
    let d = Sha256::digest(format!("{salt}:{password}"));
    d.iter().map(|b| format!("{b:02x}")).collect()
}

fn text(what: &str, s: &str, max: usize) -> Result<String> {
    let s = s.trim();
    if s.chars().count() > max {
        return bad(format!("{what} is over {max} characters"));
    }
    Ok(s.to_owned())
}

impl Store {
    pub fn open(path: &Path) -> Result<Store> {
        let db = Connection::open(path)?;
        db.execute_batch(SCHEMA)?;
        let done: usize = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        // Rebuilding a table needs foreign keys off, and the pragma only
        // takes effect outside a transaction.
        db.pragma_update(None, "foreign_keys", false)?;
        for (i, m) in MIGRATIONS.iter().enumerate().skip(done) {
            let tx = db.unchecked_transaction()?;
            tx.execute_batch(m)?;
            tx.pragma_update(None, "user_version", i + 1)?;
            tx.commit()?;
        }
        db.pragma_update(None, "foreign_keys", true)?;
        Ok(Store { db })
    }

    fn day(&self, day: &str) -> Result<()> {
        let ok: bool = self
            .db
            .query_row("SELECT date(?1) IS ?1", [day], |r| r.get(0))?;
        if ok {
            Ok(())
        } else {
            bad(format!("not a date: {day}"))
        }
    }

    fn monday(&self, day: &str) -> Result<()> {
        self.day(day)?;
        let ok: bool = self
            .db
            .query_row("SELECT strftime('%w', ?1) = '1'", [day], |r| r.get(0))?;
        if ok {
            Ok(())
        } else {
            bad(format!("not a Monday: {day}"))
        }
    }

    fn plus(&self, day: &str, days: i64) -> Result<String> {
        Ok(self
            .db
            .query_row("SELECT date(?1, ?2 || ' days')", params![day, days], |r| {
                r.get(0)
            })?)
    }

    pub fn today(&self) -> Result<String> {
        Ok(self
            .db
            .query_row("SELECT date('now', 'localtime')", [], |r| r.get(0))?)
    }

    /// Marks the posted week holding `day` as changed since posting.
    fn touch(&self, day: &str) -> Result<()> {
        self.db.execute(
            concat!(
                "UPDATE weeks SET edited = 1 WHERE monday = ",
                monday_of!("?1")
            ),
            [day],
        )?;
        Ok(())
    }

    fn shifts(&self, monday: &str, only: Option<i64>) -> Result<Vec<Shift>> {
        let mut q = self.db.prepare(
            "SELECT id, staff, day, start, end, note, open FROM shifts
             WHERE day BETWEEN ?1 AND date(?1, '+6 days') AND (?2 IS NULL OR staff = ?2)
             ORDER BY day, start, end",
        )?;
        Ok(q.query_map(params![monday, only], shift)?
            .collect::<rusqlite::Result<_>>()?)
    }

    /// Active staff, plus anyone archived who still has a shift that week.
    fn people(&self, monday: &str, working_only: bool) -> Result<Vec<Person>> {
        let mut q = self.db.prepare(
            "SELECT id, name, color, active FROM staff s
             WHERE (active AND NOT ?2) OR EXISTS (SELECT 1 FROM shifts
               WHERE staff = s.id AND day BETWEEN ?1 AND date(?1, '+6 days'))
             ORDER BY name COLLATE NOCASE",
        )?;
        Ok(q.query_map(params![monday, working_only], person)?
            .collect::<rusqlite::Result<_>>()?)
    }

    pub fn week(&self, monday: &str) -> Result<Week> {
        self.monday(monday)?;
        self.fill_ahead()?;
        let posted: Option<(String, bool)> = self
            .db
            .query_row(
                "SELECT published, edited FROM weeks WHERE monday = ?1",
                [monday],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let mut q = self.db.prepare(&format!(
            "{OFF} WHERE r.status != 'denied' AND r.first <= date(?1, '+6 days') AND r.last >= ?1
             ORDER BY r.first"
        ))?;
        let off = q
            .query_map([monday], off)?
            .collect::<rusqlite::Result<_>>()?;
        let mut q = self.db.prepare(
            "SELECT start, end FROM shifts WHERE day >= date(?1, '-56 days')
             GROUP BY start, end ORDER BY COUNT(*) DESC, start LIMIT 6",
        )?;
        let usual = q
            .query_map([monday], |r| {
                Ok(Usual {
                    start: r.get(0)?,
                    end: r.get(1)?,
                })
            })?
            .collect::<rusqlite::Result<_>>()?;
        Ok(Week {
            monday: monday.to_owned(),
            edited: posted.as_ref().is_some_and(|p| p.1),
            published: posted.map(|p| p.0),
            staff: self.people(monday, false)?,
            shifts: self.shifts(monday, None)?,
            off,
            pending: self.db.query_row(
                "SELECT COUNT(*) FROM requests WHERE status = 'pending'",
                [],
                |r| r.get(0),
            )?,
            usual,
            rules: self.rules()?,
            short_ok: {
                let mut q = self.db.prepare(
                    "SELECT day FROM short_ok WHERE day BETWEEN ?1 AND date(?1, '+6 days')",
                )?;
                q.query_map([monday], |r| r.get(0))?
                    .collect::<rusqlite::Result<_>>()?
            },
        })
    }

    pub fn rules(&self) -> Result<Rules> {
        Ok(self
            .db
            .query_row("SELECT weekday, weekend FROM rules", [], |r| {
                Ok(Rules {
                    weekday: r.get(0)?,
                    weekend: r.get(1)?,
                })
            })?)
    }

    pub fn set_rules(&self, r: &Rules) -> Result<()> {
        if !(0..=20).contains(&r.weekday) || !(0..=20).contains(&r.weekend) {
            return bad("between 0 and 20 people");
        }
        self.db.execute(
            "UPDATE rules SET weekday = ?1, weekend = ?2",
            params![r.weekday, r.weekend],
        )?;
        Ok(())
    }

    pub fn short_ok(&self, day: &str, ok: bool) -> Result<()> {
        self.day(day)?;
        let sql = if ok {
            "INSERT OR IGNORE INTO short_ok VALUES (?1)"
        } else {
            "DELETE FROM short_ok WHERE day = ?1"
        };
        self.db.execute(sql, [day])?;
        Ok(())
    }

    /// Puts each person's usual shifts, or only usual shift `only`, on the
    /// days from `first` to `last`, except where they already have a shift
    /// or have the day off.
    fn fill(&self, first: &str, last: &str, only: Option<i64>) -> Result<usize> {
        let n = self.db.execute(
            "WITH RECURSIVE days(day) AS (
               SELECT ?1 UNION ALL SELECT date(day, '+1 day') FROM days WHERE day < ?2)
             INSERT INTO shifts (staff, day, start, end, note, usual)
             SELECT u.staff, days.day, u.start, u.end, u.note, 1
             FROM days
             JOIN usual u ON u.weekday = (CAST(strftime('%w', days.day) AS INTEGER) + 6) % 7
             JOIN staff s ON s.id = u.staff AND s.active
             WHERE (?3 IS NULL OR u.id = ?3)
               AND NOT EXISTS (SELECT 1 FROM shifts h WHERE h.staff = u.staff AND h.day = days.day)
               AND NOT EXISTS (SELECT 1 FROM requests r WHERE r.staff = u.staff
                 AND r.status = 'approved' AND days.day BETWEEN r.first AND r.last)
             ORDER BY days.day, u.start",
            params![first, last, only],
        )?;
        self.touch(first)?;
        Ok(n)
    }

    /// The Mondays of this week and the weeks ahead the usual week covers,
    /// each with the first day still to come.
    fn horizon(&self) -> Result<Vec<(String, String)>> {
        let today = self.today()?;
        let mut q = self.db.prepare(concat!(
            "WITH RECURSIVE w(monday, k) AS (SELECT ",
            monday_of!("?1"),
            ", 0 UNION ALL SELECT date(monday, '+7 days'), k + 1 FROM w WHERE k < ?2)
             SELECT monday, max(monday, ?1) FROM w"
        ))?;
        Ok(
            q.query_map(params![today, AHEAD], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<rusqlite::Result<_>>()?,
        )
    }

    /// Fills each week the first time it comes into reach, unless the
    /// manager already posted it or planned it by hand: a gap in a planned
    /// week, like a holiday, is on purpose.
    fn fill_ahead(&self) -> Result<()> {
        for (monday, from) in self.horizon()? {
            let new = self.db.execute(
                "INSERT INTO filled SELECT ?1
                 WHERE NOT EXISTS (SELECT 1 FROM filled WHERE monday = ?1)
                   AND NOT EXISTS (SELECT 1 FROM weeks WHERE monday = ?1)
                   AND NOT EXISTS (SELECT 1 FROM shifts WHERE day BETWEEN ?1 AND date(?1, '+6 days'))",
                [&monday],
            )?;
            if new == 1 {
                self.fill(&from, &self.plus(&monday, 6)?, None)?;
            }
        }
        Ok(())
    }

    /// Carries one change to the usual week into the coming days of the
    /// unposted weeks in reach: the shifts `old` put there go, and usual
    /// shift `new` goes in where the person is free. Everything else in
    /// those weeks stays, so a gap left on purpose stays a gap.
    fn carry(&self, old: Option<&Default>, new: Option<i64>) -> Result<()> {
        let tx = self.db.unchecked_transaction()?;
        for (monday, from) in self.horizon()? {
            let posted: bool = tx.query_row(
                "SELECT EXISTS (SELECT 1 FROM weeks WHERE monday = ?1)",
                [&monday],
                |r| r.get(0),
            )?;
            if posted {
                continue;
            }
            let last = self.plus(&monday, 6)?;
            if let Some(o) = old {
                tx.execute(
                    "DELETE FROM shifts WHERE usual AND staff = ?3 AND start = ?4 AND end = ?5
                       AND (CAST(strftime('%w', day) AS INTEGER) + 6) % 7 = ?6
                       AND day BETWEEN ?1 AND ?2",
                    params![from, last, o.staff, o.start, o.end, o.weekday],
                )?;
            }
            if let Some(id) = new {
                self.fill(&from, &last, Some(id))?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    fn default(&self, id: i64) -> Result<Default> {
        self.db
            .query_row(
                "SELECT id, staff, weekday, start, end, note FROM usual WHERE id = ?1",
                [id],
                |r| {
                    Ok(Default {
                        id: r.get(0)?,
                        staff: r.get(1)?,
                        weekday: r.get(2)?,
                        start: r.get(3)?,
                        end: r.get(4)?,
                        note: r.get(5)?,
                    })
                },
            )
            .optional()?
            .ok_or(Error::Missing)
    }

    /// Replaces the week's shifts with the usual week.
    pub fn use_usual(&self, monday: &str) -> Result<usize> {
        self.monday(monday)?;
        let tx = self.db.unchecked_transaction()?;
        tx.execute(
            "DELETE FROM shifts WHERE day BETWEEN ?1 AND date(?1, '+6 days')",
            [monday],
        )?;
        tx.execute("INSERT OR IGNORE INTO filled VALUES (?1)", [monday])?;
        let n = self.fill(monday, &self.plus(monday, 6)?, None)?;
        tx.commit()?;
        Ok(n)
    }

    pub fn usual_week(&self) -> Result<UsualWeek> {
        let mut q = self.db.prepare(
            "SELECT id, staff, weekday, start, end, note FROM usual ORDER BY weekday, start",
        )?;
        let shifts = q
            .query_map([], |r| {
                Ok(Default {
                    id: r.get(0)?,
                    staff: r.get(1)?,
                    weekday: r.get(2)?,
                    start: r.get(3)?,
                    end: r.get(4)?,
                    note: r.get(5)?,
                })
            })?
            .collect::<rusqlite::Result<_>>()?;
        let mut q = self.db.prepare(
            "SELECT id, name, color, active FROM staff WHERE active ORDER BY name COLLATE NOCASE",
        )?;
        let staff = q.query_map([], person)?.collect::<rusqlite::Result<_>>()?;
        Ok(UsualWeek {
            staff,
            shifts,
            rules: self.rules()?,
        })
    }

    pub fn save_default(&self, d: &DefaultIn) -> Result<i64> {
        if !(0..=6).contains(&d.weekday) {
            return bad("weekday is 0 (Monday) to 6");
        }
        if !(0 <= d.start && d.start < d.end && d.end <= 24 * 60) {
            return bad("a shift ends after it starts, within the day");
        }
        let note = text("The note", &d.note, 200)?;
        let old = d.id.map(|id| self.default(id)).transpose()?;
        let id = match d.id {
            Some(id) => {
                self.db.execute(
                    "UPDATE usual SET staff = ?2, weekday = ?3, start = ?4, end = ?5, note = ?6
                     WHERE id = ?1",
                    params![id, d.staff, d.weekday, d.start, d.end, note],
                )?;
                id
            }
            None => {
                self.db.execute(
                    "INSERT INTO usual (staff, weekday, start, end, note) VALUES (?1, ?2, ?3, ?4, ?5)",
                    params![d.staff, d.weekday, d.start, d.end, note],
                )?;
                self.db.last_insert_rowid()
            }
        };
        self.carry(old.as_ref(), Some(id))?;
        Ok(id)
    }

    pub fn delete_default(&self, id: i64) -> Result<()> {
        let old = self.default(id)?;
        self.db.execute("DELETE FROM usual WHERE id = ?1", [id])?;
        self.carry(Some(&old), None)
    }

    /// Opens the person's coming shifts on days they now have off, for
    /// someone else to take; days already past keep the record of who
    /// worked.
    fn clear_off(&self, request: i64) -> Result<usize> {
        const MATCH: &str = "FROM shifts h JOIN requests r ON r.id = ?1
            WHERE h.staff = r.staff AND h.day BETWEEN max(r.first, ?2) AND r.last";
        let today = self.today()?;
        let days: Vec<String> = {
            let mut q = self.db.prepare(&format!("SELECT DISTINCT h.day {MATCH}"))?;
            q.query_map(params![request, today], |r| r.get(0))?
                .collect::<rusqlite::Result<_>>()?
        };
        let n = self.db.execute(
            &format!("UPDATE shifts SET open = 1, usual = 0 WHERE id IN (SELECT h.id {MATCH})"),
            params![request, today],
        )?;
        for d in days {
            self.touch(&d)?;
        }
        Ok(n)
    }

    pub fn save_shift(&self, s: &ShiftIn) -> Result<i64> {
        self.day(&s.day)?;
        if !(0 <= s.start && s.start < s.end && s.end <= 24 * 60) {
            return bad("a shift ends after it starts, within the day");
        }
        let note = text("The note", &s.note, 200)?;
        let known: bool = self.db.query_row(
            "SELECT EXISTS (SELECT 1 FROM staff WHERE id = ?1)",
            [s.staff],
            |r| r.get(0),
        )?;
        if !known {
            return bad("no such person");
        }
        let id = match s.id {
            Some(id) => {
                let was: String = self
                    .db
                    .query_row("SELECT day FROM shifts WHERE id = ?1", [id], |r| r.get(0))
                    .optional()?
                    .ok_or(Error::Missing)?;
                self.db.execute(
                    "UPDATE shifts SET staff = ?2, day = ?3, start = ?4, end = ?5, note = ?6, open = ?7
                     WHERE id = ?1",
                    params![id, s.staff, s.day, s.start, s.end, note, s.open],
                )?;
                self.touch(&was)?;
                id
            }
            None => {
                self.db.execute(
                    "INSERT INTO shifts (staff, day, start, end, note, open)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                    params![s.staff, s.day, s.start, s.end, note, s.open],
                )?;
                self.db.last_insert_rowid()
            }
        };
        // A shift the same as that person's usual one that weekday counts
        // as usual, so changes to the usual week carry into it.
        self.db.execute(
            "UPDATE shifts SET usual = NOT open AND EXISTS (SELECT 1 FROM usual u WHERE u.staff = shifts.staff
               AND u.start = shifts.start AND u.end = shifts.end
               AND u.weekday = (CAST(strftime('%w', shifts.day) AS INTEGER) + 6) % 7)
             WHERE id = ?1",
            [id],
        )?;
        self.touch(&s.day)?;
        Ok(id)
    }

    pub fn delete_shift(&self, id: i64) -> Result<()> {
        let day: String = self
            .db
            .query_row("SELECT day FROM shifts WHERE id = ?1", [id], |r| r.get(0))
            .optional()?
            .ok_or(Error::Missing)?;
        self.db.execute("DELETE FROM shifts WHERE id = ?1", [id])?;
        self.touch(&day)
    }

    /// Replaces the week's shifts with the week before's, leaving out
    /// anyone archived since.
    pub fn copy_week(&self, monday: &str) -> Result<usize> {
        self.monday(monday)?;
        let tx = self.db.unchecked_transaction()?;
        tx.execute(
            "DELETE FROM shifts WHERE day BETWEEN ?1 AND date(?1, '+6 days')",
            [monday],
        )?;
        let n = tx.execute(
            "INSERT INTO shifts (staff, day, start, end, note)
             SELECT h.staff, date(h.day, '+7 days'), h.start, h.end, h.note
             FROM shifts h JOIN staff s ON s.id = h.staff AND s.active
             WHERE h.day BETWEEN date(?1, '-7 days') AND date(?1, '-1 days')
             ORDER BY h.day, h.start",
            [monday],
        )?;
        tx.execute("UPDATE weeks SET edited = 1 WHERE monday = ?1", [monday])?;
        tx.commit()?;
        Ok(n)
    }

    pub fn publish(&self, monday: &str) -> Result<()> {
        self.monday(monday)?;
        self.db.execute(
            "INSERT INTO weeks (monday, published) VALUES (?1, datetime('now', 'localtime'))
             ON CONFLICT (monday) DO UPDATE SET published = excluded.published, edited = 0",
            [monday],
        )?;
        Ok(())
    }

    pub fn staff(&self) -> Result<Vec<Person>> {
        let mut q = self.db.prepare(
            "SELECT id, name, color, active FROM staff
             ORDER BY NOT active, name COLLATE NOCASE",
        )?;
        Ok(q.query_map([], person)?.collect::<rusqlite::Result<_>>()?)
    }

    pub fn save_person(&self, p: &PersonIn) -> Result<i64> {
        let name = text("The name", &p.name, 40)?;
        if name.is_empty() {
            return bad("a person needs a name");
        }
        let hex = p.color.len() == 7
            && p.color.starts_with('#')
            && p.color[1..].chars().all(|c| c.is_ascii_hexdigit());
        if !hex {
            return bad("colour is #rrggbb");
        }
        match p.id {
            Some(id) => {
                let n = self.db.execute(
                    "UPDATE staff SET name = ?2, color = ?3, active = ?4 WHERE id = ?1",
                    params![id, name, p.color, p.active],
                )?;
                if n == 0 {
                    return Err(Error::Missing);
                }
                Ok(id)
            }
            None => {
                self.db.execute(
                    "INSERT INTO staff (name, color, active) VALUES (?1, ?2, ?3)",
                    params![name, p.color, p.active],
                )?;
                Ok(self.db.last_insert_rowid())
            }
        }
    }

    pub fn requests(&self) -> Result<Requests> {
        let mut q = self.db.prepare(&format!(
            "{OFF} WHERE r.status = 'pending' ORDER BY r.first"
        ))?;
        let pending = q.query_map([], off)?.collect::<rusqlite::Result<_>>()?;
        let mut q = self.db.prepare(&format!(
            "{OFF} WHERE r.status != 'pending' ORDER BY r.first DESC LIMIT 40"
        ))?;
        let decided = q.query_map([], off)?.collect::<rusqlite::Result<_>>()?;
        Ok(Requests { pending, decided })
    }

    fn check_off(&self, o: &OffIn) -> Result<String> {
        self.day(&o.first)?;
        self.day(&o.last)?;
        let days: i64 = self.db.query_row(
            "SELECT julianday(?2) - julianday(?1) + 1",
            params![o.first, o.last],
            |r| r.get::<_, f64>(0).map(|d| d as i64),
        )?;
        if days < 1 {
            return bad("the last day comes before the first");
        }
        if days > MAX_DAYS {
            return bad(format!("at most {MAX_DAYS} days at a time"));
        }
        text("The note", &o.reason, 500)
    }

    /// Time off the manager enters; it needs no approval.
    pub fn add_off(&self, staff: i64, o: &OffIn) -> Result<i64> {
        let reason = self.check_off(o)?;
        self.db.execute(
            "INSERT INTO requests (staff, first, last, reason, status, decided)
             VALUES (?1, ?2, ?3, ?4, 'approved', datetime('now', 'localtime'))",
            params![staff, o.first, o.last, reason],
        )?;
        let id = self.db.last_insert_rowid();
        self.clear_off(id)?;
        Ok(id)
    }

    pub fn decide(&self, id: i64, status: &str) -> Result<()> {
        if !matches!(status, "approved" | "denied") {
            return bad("approved or denied");
        }
        let n = self.db.execute(
            "UPDATE requests SET status = ?2, decided = datetime('now', 'localtime') WHERE id = ?1",
            params![id, status],
        )?;
        if n == 0 {
            return Err(Error::Missing);
        }
        if status == "approved" {
            self.clear_off(id)?;
        }
        Ok(())
    }

    pub fn delete_off(&self, id: i64) -> Result<()> {
        let n = self
            .db
            .execute("DELETE FROM requests WHERE id = ?1", [id])?;
        if n == 0 { Err(Error::Missing) } else { Ok(()) }
    }

    fn active(&self, staff: i64) -> Result<()> {
        let active: bool = self
            .db
            .query_row("SELECT active FROM staff WHERE id = ?1", [staff], |r| {
                r.get(0)
            })
            .optional()?
            .ok_or(Error::Missing)?;
        if active { Ok(()) } else { Err(Error::Missing) }
    }

    /// The week as staff see it: empty until posted, and without anyone's
    /// reasons for time off.
    pub fn board(&self, monday: &str) -> Result<Week> {
        let mut w = self.week(monday)?;
        if w.published.is_none() {
            w.shifts.clear();
        }
        for o in &mut w.off {
            o.reason.clear();
        }
        w.pending = 0;
        w.usual.clear();
        Ok(w)
    }

    /// A request for time off, waiting for the manager.
    pub fn ask_off(&self, staff: i64, o: &OffIn) -> Result<i64> {
        self.active(staff)?;
        let reason = self.check_off(o)?;
        if o.first < self.today()? {
            return bad("that day has passed");
        }
        self.db.execute(
            "INSERT INTO requests (staff, first, last, reason) VALUES (?1, ?2, ?3, ?4)",
            params![staff, o.first, o.last, reason],
        )?;
        Ok(self.db.last_insert_rowid())
    }

    /// Someone takes an open shift in a posted week, from today on.
    pub fn take(&self, shift: i64, staff: i64) -> Result<()> {
        self.active(staff)?;
        let (day, start, end, open, posted): (String, i64, i64, bool, bool) = self
            .db
            .query_row(
                concat!(
                    "SELECT day, start, end, open, EXISTS (SELECT 1 FROM weeks WHERE monday = ",
                    monday_of!("h.day"),
                    ") FROM shifts h WHERE id = ?1"
                ),
                [shift],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )
            .optional()?
            .ok_or(Error::Missing)?;
        if !open {
            return bad("someone already took that shift");
        }
        if !posted {
            return Err(Error::Missing);
        }
        if day < self.today()? {
            return bad("that day has passed");
        }
        let busy: bool = self.db.query_row(
            "SELECT EXISTS (SELECT 1 FROM shifts WHERE staff = ?1 AND day = ?2 AND NOT open
               AND start < ?4 AND ?3 < end)",
            params![staff, day, start, end],
            |r| r.get(0),
        )?;
        if busy {
            return bad("you already work then");
        }
        let off: bool = self.db.query_row(
            "SELECT EXISTS (SELECT 1 FROM requests WHERE staff = ?1 AND status = 'approved'
               AND ?2 BETWEEN first AND last)",
            params![staff, day],
            |r| r.get(0),
        )?;
        if off {
            return bad("you have that day off");
        }
        self.db.execute(
            "UPDATE shifts SET staff = ?2, open = 0, usual = 0 WHERE id = ?1",
            params![shift, staff],
        )?;
        Ok(())
    }

    pub fn passwords(&self) -> Result<Passwords> {
        let set = |role: Role| -> Result<bool> {
            Ok(self.db.query_row(
                "SELECT EXISTS (SELECT 1 FROM password WHERE role = ?1)",
                [role.as_str()],
                |r| r.get(0),
            )?)
        };
        Ok(Passwords {
            admin: set(Role::Admin)?,
            staff: set(Role::Staff)?,
        })
    }

    fn matches(&self, password: &str) -> Result<Option<Role>> {
        let mut q = self.db.prepare("SELECT role, salt, hash FROM password")?;
        let rows: Vec<(String, String, String)> = q
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
            .collect::<rusqlite::Result<_>>()?;
        Ok(rows
            .into_iter()
            .find(|(_, salt, h)| hash(salt, password) == *h)
            .map(|(role, ..)| {
                if role == "admin" {
                    Role::Admin
                } else {
                    Role::Staff
                }
            }))
    }

    /// Sets one role's password and signs that role out everywhere. The two
    /// differ, since the password alone says who is signing in.
    pub fn set_password(&self, role: Role, password: &str) -> Result<()> {
        if password.chars().count() < 6 {
            return bad("the password needs at least 6 characters");
        }
        if self.matches(password)?.is_some_and(|r| r != role) {
            return bad("the staff and manager passwords must differ");
        }
        let salt = token();
        self.db.execute(
            "INSERT OR REPLACE INTO password (role, salt, hash) VALUES (?1, ?2, ?3)",
            params![role.as_str(), salt, hash(&salt, password)],
        )?;
        self.db
            .execute("DELETE FROM sessions WHERE role = ?1", [role.as_str()])?;
        Ok(())
    }

    /// A new session and its role if the password is either one.
    pub fn sign_in(&self, password: &str) -> Result<Option<(String, Role)>> {
        let Some(role) = self.matches(password)? else {
            return Ok(None);
        };
        let t = token();
        self.db.execute(
            "INSERT INTO sessions (token, role, made) VALUES (?1, ?2, datetime('now', 'localtime'))",
            params![t, role.as_str()],
        )?;
        Ok(Some((t, role)))
    }

    /// Who a browser is. Until the manager's password is set, everyone is
    /// the manager, so the first visit can set things up.
    pub fn role(&self, session: Option<&str>) -> Result<Option<Role>> {
        if !self.passwords()?.admin {
            return Ok(Some(Role::Admin));
        }
        let Some(t) = session else { return Ok(None) };
        let role: Option<String> = self
            .db
            .query_row("SELECT role FROM sessions WHERE token = ?1", [t], |r| {
                r.get(0)
            })
            .optional()?;
        Ok(role.map(|r| {
            if r == "admin" {
                Role::Admin
            } else {
                Role::Staff
            }
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> Store {
        Store::open(Path::new(":memory:")).unwrap()
    }

    fn add(s: &Store, name: &str) -> i64 {
        s.save_person(&PersonIn {
            id: None,
            name: name.into(),
            color: "#b0482a".into(),
            active: true,
        })
        .unwrap()
    }

    fn put(s: &Store, staff: i64, day: &str) -> i64 {
        s.save_shift(&ShiftIn {
            id: None,
            staff,
            day: day.into(),
            start: 390,
            end: 840,
            note: String::new(),
            open: false,
        })
        .unwrap()
    }

    #[test]
    fn weeks_start_on_monday() {
        let s = store();
        assert!(s.week("2026-10-19").is_ok());
        assert!(matches!(s.week("2026-10-20"), Err(Error::Bad(_))));
        assert!(matches!(s.week("2026-02-30"), Err(Error::Bad(_))));
    }

    #[test]
    fn editing_a_posted_week_marks_it() {
        let s = store();
        let a = add(&s, "Ana");
        put(&s, a, "2026-10-25");
        s.publish("2026-10-19").unwrap();
        assert!(!s.week("2026-10-19").unwrap().edited);
        // Sunday belongs to the week before it.
        put(&s, a, "2026-10-25");
        assert!(s.week("2026-10-19").unwrap().edited);
        s.publish("2026-10-19").unwrap();
        put(&s, a, "2026-10-26");
        assert!(!s.week("2026-10-19").unwrap().edited);
    }

    #[test]
    fn copy_replaces_the_week_and_skips_archived_staff() {
        let s = store();
        let a = add(&s, "Ana");
        let b = add(&s, "Ben");
        put(&s, a, "2026-10-12");
        put(&s, b, "2026-10-18");
        put(&s, a, "2026-10-21");
        s.save_person(&PersonIn {
            id: Some(b),
            name: "Ben".into(),
            color: "#b0482a".into(),
            active: false,
        })
        .unwrap();
        assert_eq!(s.copy_week("2026-10-19").unwrap(), 1);
        let w = s.week("2026-10-19").unwrap();
        assert_eq!(w.shifts.len(), 1);
        assert_eq!(w.shifts[0].day, "2026-10-19");
    }

    #[test]
    fn staff_see_posted_weeks_and_take_open_shifts() {
        let s = store();
        let a = add(&s, "Ana");
        let b = add(&s, "Ben");
        let monday = s.plus(&this_monday(&s), 7).unwrap();
        let day = s.plus(&monday, 2).unwrap();
        let id = put(&s, a, &day);
        assert!(s.board(&monday).unwrap().shifts.is_empty());
        s.publish(&monday).unwrap();
        assert_eq!(s.board(&monday).unwrap().shifts.len(), 1);

        let off = OffIn {
            first: day.clone(),
            last: day.clone(),
            reason: "dentist".into(),
        };
        let r = s.ask_off(a, &off).unwrap();
        let w = s.board(&monday).unwrap();
        assert_eq!((w.off.len(), w.off[0].reason.as_str()), (1, ""));
        assert!(matches!(s.take(id, b), Err(Error::Bad(_))));

        // Approving opens Ana's shift rather than dropping it.
        s.decide(r, "approved").unwrap();
        assert!(s.week(&monday).unwrap().shifts[0].open);
        assert!(matches!(s.take(id, a), Err(Error::Bad(_))));
        s.take(id, b).unwrap();
        let h = &s.week(&monday).unwrap().shifts[0];
        assert_eq!((h.staff, h.open), (b, false));
        assert!(matches!(s.take(id, b), Err(Error::Bad(_))));
    }

    #[test]
    fn the_password_says_who_signs_in() {
        let s = store();
        assert_eq!(s.role(None).unwrap(), Some(Role::Admin));
        assert!(matches!(
            s.set_password(Role::Staff, "short"),
            Err(Error::Bad(_))
        ));
        s.set_password(Role::Staff, "macchiato").unwrap();
        s.set_password(Role::Admin, "cortado").unwrap();
        assert!(matches!(
            s.set_password(Role::Staff, "cortado"),
            Err(Error::Bad(_))
        ));
        assert_eq!(s.role(None).unwrap(), None);
        assert!(s.sign_in("espresso").unwrap().is_none());
        let (staff, role) = s.sign_in("macchiato").unwrap().unwrap();
        assert_eq!(role, Role::Staff);
        let (admin, _) = s.sign_in("cortado").unwrap().unwrap();
        assert_eq!(s.role(Some(&admin)).unwrap(), Some(Role::Admin));
        s.set_password(Role::Staff, "flat white").unwrap();
        assert_eq!(s.role(Some(&staff)).unwrap(), None);
        assert_eq!(s.role(Some(&admin)).unwrap(), Some(Role::Admin));
    }

    #[test]
    fn an_old_database_keeps_its_staff_and_shifts() {
        let path = std::env::temp_dir().join(format!("endgrain-old-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let old = Connection::open(&path).unwrap();
        old.execute_batch(
            "CREATE TABLE staff (id INTEGER PRIMARY KEY, name TEXT NOT NULL,
               color TEXT NOT NULL, token TEXT NOT NULL UNIQUE, active INTEGER NOT NULL DEFAULT 1);
             CREATE TABLE shifts (id INTEGER PRIMARY KEY, staff INTEGER NOT NULL REFERENCES staff(id),
               day TEXT NOT NULL, start INTEGER NOT NULL, end INTEGER NOT NULL, note TEXT NOT NULL DEFAULT '');
             INSERT INTO staff VALUES (1, 'Ana', '#b0482a', 'abc', 1);
             INSERT INTO shifts VALUES (1, 1, '2026-10-20', 465, 900, '');",
        )
        .unwrap();
        drop(old);
        let s = Store::open(&path).unwrap();
        assert_eq!(s.staff().unwrap()[0].name, "Ana");
        assert_eq!(s.shifts("2026-10-19", None).unwrap().len(), 1);
        assert_eq!(add(&s, "Ben"), 2);
        drop(s);
        let _ = std::fs::remove_file(&path);
    }

    fn this_monday(s: &Store) -> String {
        let today = s.today().unwrap();
        s.db.query_row(concat!("SELECT ", monday_of!("?1")), [&today], |r| r.get(0))
            .unwrap()
    }

    fn usual(s: &Store, staff: i64, weekday: i64) -> i64 {
        s.save_default(&DefaultIn {
            id: None,
            staff,
            weekday,
            start: 7 * 60,
            end: 15 * 60,
            note: String::new(),
        })
        .unwrap()
    }

    #[test]
    fn the_usual_week_fills_the_weeks_ahead_but_not_the_past() {
        let s = store();
        let a = add(&s, "Ana");
        usual(&s, a, 0);
        let today = s.today().unwrap();
        let next = s.plus(&this_monday(&s), 7).unwrap();
        let w = s.week(&next).unwrap();
        assert_eq!(w.shifts.len(), 1);
        assert_eq!(w.shifts[0].day, next);
        let far = s.plus(&this_monday(&s), 7 * (AHEAD + 1)).unwrap();
        assert!(s.week(&far).unwrap().shifts.is_empty());
        let past: i64 =
            s.db.query_row(
                "SELECT COUNT(*) FROM shifts WHERE day < ?1",
                [&today],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(past, 0);
    }

    #[test]
    fn changing_the_usual_week_keeps_hand_made_shifts_and_posted_weeks() {
        let s = store();
        let a = add(&s, "Ana");
        let b = add(&s, "Ben");
        let monday = s.plus(&this_monday(&s), 7).unwrap();
        let posted = s.plus(&monday, 7).unwrap();
        let tuesday = s.plus(&monday, 1).unwrap();
        s.publish(&posted).unwrap();
        put(&s, b, &tuesday);
        let id = usual(&s, a, 0);
        usual(&s, b, 1);
        assert_eq!(s.week(&monday).unwrap().shifts.len(), 2);
        assert!(s.week(&posted).unwrap().shifts.is_empty());
        s.delete_default(id).unwrap();
        let w = s.week(&monday).unwrap();
        assert_eq!(w.shifts.len(), 1);
        assert_eq!((w.shifts[0].staff, w.shifts[0].start), (b, 390));
    }

    #[test]
    fn approved_time_off_opens_the_shifts_and_the_usual_week_skips_it() {
        let s = store();
        let a = add(&s, "Ana");
        let monday = s.plus(&this_monday(&s), 7).unwrap();
        for d in 0..7 {
            usual(&s, a, d);
        }
        let first = s.plus(&monday, 2).unwrap();
        let last = s.plus(&monday, 3).unwrap();
        let id = s
            .add_off(
                a,
                &OffIn {
                    first: first.clone(),
                    last,
                    reason: String::new(),
                },
            )
            .unwrap();
        let w = s.week(&monday).unwrap();
        assert_eq!(w.shifts.len(), 7);
        assert_eq!(w.shifts.iter().filter(|h| h.open).count(), 2);
        s.decide(id, "approved").unwrap();
        assert_eq!(s.use_usual(&monday).unwrap(), 5);
        assert!(
            s.week(&monday)
                .unwrap()
                .shifts
                .iter()
                .all(|h| h.day != first)
        );
    }

    #[test]
    fn short_days_and_rules_round_trip() {
        let s = store();
        let monday = this_monday(&s);
        assert_eq!(s.week(&monday).unwrap().rules.weekend, 3);
        s.set_rules(&Rules {
            weekday: 1,
            weekend: 4,
        })
        .unwrap();
        s.short_ok(&monday, true).unwrap();
        let w = s.week(&monday).unwrap();
        assert_eq!((w.rules.weekday, w.short_ok.len()), (1, 1));
        s.short_ok(&monday, false).unwrap();
        assert!(s.week(&monday).unwrap().short_ok.is_empty());
    }

    #[test]
    fn a_week_planned_by_hand_keeps_its_gaps() {
        let s = store();
        let a = add(&s, "Ana");
        let b = add(&s, "Ben");
        let monday = s.plus(&this_monday(&s), 14).unwrap();
        put(&s, a, &monday);
        // As if the usual week had been set before this week came in reach.
        s.db.execute(
            "INSERT INTO usual (staff, weekday, start, end) VALUES (?1, 1, 420, 900)",
            [b],
        )
        .unwrap();
        assert_eq!(s.week(&monday).unwrap().shifts.len(), 1);
    }

    #[test]
    fn a_hand_made_shift_like_the_usual_one_follows_the_usual_week() {
        let s = store();
        let a = add(&s, "Ana");
        let monday = s.plus(&this_monday(&s), 7).unwrap();
        let id = usual(&s, a, 0);
        let w = s.week(&monday).unwrap();
        s.delete_shift(w.shifts[0].id).unwrap();
        s.save_shift(&ShiftIn {
            id: None,
            staff: a,
            day: monday.clone(),
            start: 7 * 60,
            end: 15 * 60,
            note: String::new(),
            open: false,
        })
        .unwrap();
        s.delete_default(id).unwrap();
        assert!(s.week(&monday).unwrap().shifts.is_empty());
    }
}
