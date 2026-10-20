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
  -- The secret in the person's own page, /s/<token>.
  token TEXT NOT NULL UNIQUE,
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
const MIGRATIONS: &[&str] = &["
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
"];

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
    /// No such row, or no such person for a token.
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
    /// Only the manager's staff list carries the link.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
}

#[derive(Serialize)]
pub struct Shift {
    pub id: i64,
    pub staff: i64,
    pub day: String,
    pub start: i64,
    pub end: i64,
    pub note: String,
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

#[derive(Serialize)]
pub struct Mine {
    pub me: Person,
    pub today: String,
    pub monday: String,
    /// Whether the week is posted; an unposted week shows no shifts.
    pub published: bool,
    pub staff: Vec<Person>,
    pub shifts: Vec<Shift>,
    /// The person's own posted shifts from today, four weeks out.
    pub upcoming: Vec<Shift>,
    pub requests: Vec<Off>,
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

pub struct Store {
    db: Connection,
}

const OFF: &str =
    "SELECT r.id, r.staff, s.name, r.first, r.last, r.reason, r.status, r.made, r.decided,
      (SELECT COUNT(*) FROM shifts WHERE staff = r.staff AND day BETWEEN r.first AND r.last)
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
    })
}

fn person(r: &rusqlite::Row) -> rusqlite::Result<Person> {
    Ok(Person {
        id: r.get(0)?,
        name: r.get(1)?,
        color: r.get(2)?,
        active: r.get(3)?,
        token: None,
    })
}

/// 128 random bits as hex, for a person's link.
fn token() -> String {
    let mut bytes = [0u8; 16];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut bytes))
        .expect("/dev/urandom");
    bytes.iter().map(|b| format!("{b:02x}")).collect()
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
        for (i, m) in MIGRATIONS.iter().enumerate().skip(done) {
            let tx = db.unchecked_transaction()?;
            tx.execute_batch(m)?;
            tx.pragma_update(None, "user_version", i + 1)?;
            tx.commit()?;
        }
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
            "SELECT id, staff, day, start, end, note FROM shifts
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

    /// Puts each person's usual shifts on the days from `first` to `last`,
    /// except where they already have a shift or have the day off.
    fn fill(&self, first: &str, last: &str) -> Result<usize> {
        let n = self.db.execute(
            "WITH RECURSIVE days(day) AS (
               SELECT ?1 UNION ALL SELECT date(day, '+1 day') FROM days WHERE day < ?2)
             INSERT INTO shifts (staff, day, start, end, note, usual)
             SELECT u.staff, days.day, u.start, u.end, u.note, 1
             FROM days
             JOIN usual u ON u.weekday = (CAST(strftime('%w', days.day) AS INTEGER) + 6) % 7
             JOIN staff s ON s.id = u.staff AND s.active
             WHERE NOT EXISTS (SELECT 1 FROM shifts h WHERE h.staff = u.staff AND h.day = days.day)
               AND NOT EXISTS (SELECT 1 FROM requests r WHERE r.staff = u.staff
                 AND r.status = 'approved' AND days.day BETWEEN r.first AND r.last)
             ORDER BY days.day, u.start",
            params![first, last],
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

    /// Fills each week in reach the first time it comes into reach, unless
    /// the manager already posted it.
    fn fill_ahead(&self) -> Result<()> {
        for (monday, from) in self.horizon()? {
            let new = self.db.execute(
                "INSERT INTO filled SELECT ?1
                 WHERE NOT EXISTS (SELECT 1 FROM filled WHERE monday = ?1)
                   AND NOT EXISTS (SELECT 1 FROM weeks WHERE monday = ?1)",
                [&monday],
            )?;
            if new == 1 {
                self.fill(&from, &self.plus(&monday, 6)?)?;
            }
        }
        Ok(())
    }

    /// After the usual week changes: the coming days of every unposted week
    /// in reach lose their untouched usual shifts and take the new ones.
    /// Posted weeks and hand-made shifts stay as they are.
    fn refill(&self) -> Result<()> {
        let tx = self.db.unchecked_transaction()?;
        for (monday, from) in self.horizon()? {
            let posted: bool = tx.query_row(
                "SELECT EXISTS (SELECT 1 FROM weeks WHERE monday = ?1)",
                [&monday],
                |r| r.get(0),
            )?;
            tx.execute("INSERT OR IGNORE INTO filled VALUES (?1)", [&monday])?;
            if posted {
                continue;
            }
            tx.execute(
                "DELETE FROM shifts WHERE usual AND day BETWEEN ?1 AND date(?2, '+6 days')",
                params![from, monday],
            )?;
            self.fill(&from, &self.plus(&monday, 6)?)?;
        }
        tx.commit()?;
        Ok(())
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
        let n = self.fill(monday, &self.plus(monday, 6)?)?;
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
        let id = match d.id {
            Some(id) => {
                let n = self.db.execute(
                    "UPDATE usual SET staff = ?2, weekday = ?3, start = ?4, end = ?5, note = ?6
                     WHERE id = ?1",
                    params![id, d.staff, d.weekday, d.start, d.end, note],
                )?;
                if n == 0 {
                    return Err(Error::Missing);
                }
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
        self.refill()?;
        Ok(id)
    }

    pub fn delete_default(&self, id: i64) -> Result<()> {
        let n = self.db.execute("DELETE FROM usual WHERE id = ?1", [id])?;
        if n == 0 {
            return Err(Error::Missing);
        }
        self.refill()
    }

    /// Takes the person off their coming shifts on days they now have off;
    /// days already past keep the record of who worked.
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
            &format!("DELETE FROM shifts WHERE id IN (SELECT h.id {MATCH})"),
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
                    "UPDATE shifts SET staff = ?2, day = ?3, start = ?4, end = ?5, note = ?6,
                       usual = 0 WHERE id = ?1",
                    params![id, s.staff, s.day, s.start, s.end, note],
                )?;
                self.touch(&was)?;
                id
            }
            None => {
                self.db.execute(
                    "INSERT INTO shifts (staff, day, start, end, note) VALUES (?1, ?2, ?3, ?4, ?5)",
                    params![s.staff, s.day, s.start, s.end, note],
                )?;
                self.db.last_insert_rowid()
            }
        };
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
            "SELECT id, name, color, active, token FROM staff
             ORDER BY NOT active, name COLLATE NOCASE",
        )?;
        Ok(q.query_map([], |r| {
            Ok(Person {
                token: Some(r.get(4)?),
                ..person(r)?
            })
        })?
        .collect::<rusqlite::Result<_>>()?)
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
                    "INSERT INTO staff (name, color, token, active) VALUES (?1, ?2, ?3, ?4)",
                    params![name, p.color, token(), p.active],
                )?;
                Ok(self.db.last_insert_rowid())
            }
        }
    }

    /// A new link for the person; the old one stops working.
    pub fn relink(&self, id: i64) -> Result<String> {
        let t = token();
        let n = self
            .db
            .execute("UPDATE staff SET token = ?2 WHERE id = ?1", params![id, t])?;
        if n == 0 { Err(Error::Missing) } else { Ok(t) }
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

    /// The person a link belongs to; archived staff lose their page.
    pub fn me(&self, token: &str) -> Result<Person> {
        self.db
            .query_row(
                "SELECT id, name, color, active FROM staff WHERE token = ?1 AND active",
                [token],
                person,
            )
            .optional()?
            .ok_or(Error::Missing)
    }

    pub fn mine(&self, token: &str, monday: &str) -> Result<Mine> {
        let me = self.me(token)?;
        self.monday(monday)?;
        self.fill_ahead()?;
        let today = self.today()?;
        let published: bool = self.db.query_row(
            "SELECT EXISTS (SELECT 1 FROM weeks WHERE monday = ?1)",
            [monday],
            |r| r.get(0),
        )?;
        let mut q = self.db.prepare(concat!(
            "SELECT h.id, h.staff, h.day, h.start, h.end, h.note FROM shifts h
             JOIN weeks w ON w.monday = ",
            monday_of!("h.day"),
            " WHERE h.staff = ?1 AND h.day BETWEEN ?2 AND date(?2, '+27 days')
             ORDER BY h.day, h.start"
        ))?;
        let upcoming = q
            .query_map(params![me.id, today], shift)?
            .collect::<rusqlite::Result<_>>()?;
        let mut q = self.db.prepare(&format!(
            "{OFF} WHERE r.staff = ?1 ORDER BY r.first DESC LIMIT 30"
        ))?;
        let requests = q
            .query_map([me.id], off)?
            .collect::<rusqlite::Result<_>>()?;
        Ok(Mine {
            staff: if published {
                self.people(monday, true)?
            } else {
                Vec::new()
            },
            shifts: if published {
                self.shifts(monday, None)?
            } else {
                Vec::new()
            },
            me,
            today,
            monday: monday.to_owned(),
            published,
            upcoming,
            requests,
        })
    }

    pub fn ask_off(&self, token: &str, o: &OffIn) -> Result<i64> {
        let me = self.me(token)?;
        let reason = self.check_off(o)?;
        if o.first < self.today()? {
            return bad("that day has passed");
        }
        self.db.execute(
            "INSERT INTO requests (staff, first, last, reason) VALUES (?1, ?2, ?3, ?4)",
            params![me.id, o.first, o.last, reason],
        )?;
        Ok(self.db.last_insert_rowid())
    }

    /// Staff can withdraw a request until it is decided.
    pub fn withdraw(&self, token: &str, id: i64) -> Result<()> {
        let me = self.me(token)?;
        let n = self.db.execute(
            "DELETE FROM requests WHERE id = ?1 AND staff = ?2 AND status = 'pending'",
            params![id, me.id],
        )?;
        if n == 0 { Err(Error::Missing) } else { Ok(()) }
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
    fn staff_see_only_posted_weeks_and_their_own_requests() {
        let s = store();
        let a = add(&s, "Ana");
        add(&s, "Ben");
        let token = s.staff().unwrap()[0].token.clone().unwrap();
        let today = s.today().unwrap();
        let monday: String =
            s.db.query_row(concat!("SELECT ", monday_of!("?1")), [&today], |r| r.get(0))
                .unwrap();
        put(&s, a, &today);
        let m = s.mine(&token, &monday).unwrap();
        assert!(!m.published && m.shifts.is_empty() && m.upcoming.is_empty());
        s.publish(&monday).unwrap();
        let m = s.mine(&token, &monday).unwrap();
        assert_eq!((m.shifts.len(), m.upcoming.len(), m.staff.len()), (1, 1, 1));

        let id = s
            .ask_off(
                &token,
                &OffIn {
                    first: today.clone(),
                    last: today.clone(),
                    reason: "dentist".into(),
                },
            )
            .unwrap();
        assert_eq!(s.requests().unwrap().pending.len(), 1);
        s.decide(id, "approved").unwrap();
        assert!(matches!(s.withdraw(&token, id), Err(Error::Missing)));
        assert!(matches!(s.mine("nope", &monday), Err(Error::Missing)));
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
    fn approved_time_off_clears_the_shifts_and_is_left_unfilled() {
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
        assert_eq!(s.week(&monday).unwrap().shifts.len(), 5);
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
}
