//! Sokka's book: the reminders and lists its tools keep, one SQLite file in
//! its state directory. The tool server (one per model call) and the bot
//! both change it, each change one transaction. The household's shared
//! lists are a book of the same kind in the household directory, attached
//! as `house`, so moving a list between the two is one transaction too.
//!
//! A due reminder stays in the book until it is delivered: the bot marks it
//! done only after Matrix takes the message, and a routine's answer is kept
//! until then, so a failed send neither loses it nor asks the model again.

use crate::house;
use chrono::{Days, Months, NaiveDateTime};
use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

const AT: &str = "%Y-%m-%d %H:%M:%S";

const SCHEMA: &str = "
create table if not exists SCHEMA.lists (name text primary key, items text not null);
";
const REMINDERS: &str = "
create table if not exists reminders (
    id integer primary key autoincrement,
    at text not null,
    text text not null,
    repeat text,
    ask integer not null default 0,
    share integer not null default 0,
    answer text
);
";

/// Which book a list lives in.
#[derive(Clone, Copy, PartialEq)]
pub enum Shelf {
    Own,
    House,
}

impl Shelf {
    fn schema(self) -> &'static str {
        match self {
            Shelf::Own => "main",
            Shelf::House => "house",
        }
    }
}

#[derive(Clone)]
pub struct Reminder {
    pub id: u64,
    /// Local time.
    pub at: NaiveDateTime,
    pub text: String,
    pub repeat: Option<Repeat>,
    /// A routine: at `at`, Sokka carries out `text` as a request and sends
    /// its answer, instead of sending `text` itself.
    pub ask: bool,
    /// A routine whose answer also goes to the rest of the household.
    pub share: bool,
    /// A routine's answer, kept until it is delivered.
    pub answer: Option<String>,
}

#[derive(Serialize, Deserialize, JsonSchema, Clone, Copy)]
#[serde(rename_all = "lowercase")]
pub enum Repeat {
    Daily,
    Weekly,
    Monthly,
}

impl Repeat {
    fn after(self, t: NaiveDateTime) -> NaiveDateTime {
        match self {
            Repeat::Daily => t + Days::new(1),
            Repeat::Weekly => t + Days::new(7),
            Repeat::Monthly => t + Months::new(1),
        }
    }

    fn name(self) -> String {
        serde_json::to_value(self)
            .unwrap()
            .as_str()
            .unwrap()
            .to_owned()
    }

    fn parse(s: &str) -> Option<Repeat> {
        serde_json::from_value(serde_json::Value::String(s.into())).ok()
    }
}

pub struct Book {
    db: Connection,
}

/// Opens (making if new) the book in `dir`; the database file is made
/// group-writable when the directory is, as the household's is.
fn open_file(dir: &Path) -> Result<PathBuf, String> {
    let path = dir.join("book.db");
    if !path.exists() {
        Connection::open(&path).map_err(|e| format!("book: {e}"))?;
        if house::is_shared(dir) {
            let _ = house::shared(&path);
        }
    }
    Ok(path)
}

impl Book {
    /// The book in `dir`, with the household's in `house` attached.
    pub fn open(dir: &Path, house: Option<&Path>) -> Result<Book, String> {
        let db = Connection::open(open_file(dir)?).map_err(|e| format!("book: {e}"))?;
        db.busy_timeout(Duration::from_secs(10))
            .map_err(|e| format!("book: {e}"))?;
        db.execute_batch(&(SCHEMA.replace("SCHEMA", "main") + REMINDERS))
            .map_err(|e| format!("book: {e}"))?;
        if let Some(h) = house {
            let path = open_file(h)?;
            db.execute("attach ?1 as house", [path.to_string_lossy()])
                .map_err(|e| format!("household book: {e}"))?;
            db.execute_batch(&SCHEMA.replace("SCHEMA", "house"))
                .map_err(|e| format!("household book: {e}"))?;
        }
        let mut book = Book { db };
        book.import(dir, "main")?;
        if let Some(h) = house {
            book.import(h, "house")?;
        }
        Ok(book)
    }

    /// One transaction that takes the write lock at once, so a read and the
    /// change it decides on cannot interleave with another process's.
    pub fn change<T>(
        &mut self,
        f: impl FnOnce(&Transaction) -> rusqlite::Result<T>,
    ) -> Result<T, String> {
        let t = self
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|e| format!("book: {e}"))?;
        let out = f(&t).map_err(|e| format!("book: {e}"))?;
        t.commit().map_err(|e| format!("book: {e}"))?;
        Ok(out)
    }

    /// Reads without taking the write lock.
    pub fn read<T>(&self, f: impl FnOnce(&Connection) -> rusqlite::Result<T>) -> Result<T, String> {
        f(&self.db).map_err(|e| format!("book: {e}"))
    }

    /// One-time import of the JSON book this replaced, into `schema` unless
    /// that already holds something; delete after the switch has run on
    /// Water.
    fn import(&mut self, dir: &Path, schema: &str) -> Result<(), String> {
        #[derive(Deserialize, Default)]
        struct Old {
            #[serde(default)]
            reminders: Vec<OldReminder>,
            #[serde(default)]
            lists: std::collections::BTreeMap<String, Vec<String>>,
        }
        #[derive(Deserialize)]
        struct OldReminder {
            at: NaiveDateTime,
            text: String,
            repeat: Option<Repeat>,
            #[serde(default)]
            ask: bool,
            #[serde(default)]
            share: bool,
        }
        let path = dir.join("book.json");
        let Ok(bytes) = fs::read(&path) else {
            return Ok(());
        };
        let old: Old = serde_json::from_slice(&bytes).map_err(|e| format!("old book: {e}"))?;
        self.change(|db| {
            let reminders = schema == "main";
            let held: i64 = db.query_row(
                &format!(
                    "select (select count(*) from {schema}.lists){}",
                    if reminders {
                        " + (select count(*) from reminders)"
                    } else {
                        ""
                    }
                ),
                [],
                |r| r.get(0),
            )?;
            if held > 0 {
                return Ok(());
            }
            if reminders {
                for r in &old.reminders {
                    remind(db, r.at, &r.text, r.repeat, r.ask, r.share)?;
                }
            }
            for (name, items) in &old.lists {
                db.execute(
                    &format!("insert into {schema}.lists values (?1, ?2)"),
                    params![name, serde_json::to_string(items).unwrap()],
                )?;
            }
            Ok(())
        })?;
        match fs::rename(&path, dir.join("book.json.imported")) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(format!("old book: {e}")),
            _ => Ok(()),
        }
    }
}

fn row(r: &rusqlite::Row) -> rusqlite::Result<Reminder> {
    let at: String = r.get(1)?;
    let repeat: Option<String> = r.get(3)?;
    Ok(Reminder {
        id: r.get(0)?,
        at: NaiveDateTime::parse_from_str(&at, AT).unwrap_or_default(),
        text: r.get(2)?,
        repeat: repeat.as_deref().and_then(Repeat::parse),
        ask: r.get(4)?,
        share: r.get(5)?,
        answer: r.get(6)?,
    })
}

const COLUMNS: &str = "id, at, text, repeat, ask, share, answer";

pub fn remind(
    db: &Connection,
    at: NaiveDateTime,
    text: &str,
    repeat: Option<Repeat>,
    ask: bool,
    share: bool,
) -> rusqlite::Result<u64> {
    db.execute(
        "insert into reminders (at, text, repeat, ask, share) values (?1, ?2, ?3, ?4, ?5)",
        params![
            at.format(AT).to_string(),
            text,
            repeat.map(Repeat::name),
            ask,
            share
        ],
    )?;
    Ok(db.last_insert_rowid() as u64)
}

/// The reminders still to come, soonest first.
pub fn reminders(db: &Connection) -> rusqlite::Result<Vec<Reminder>> {
    db.prepare(&format!("select {COLUMNS} from reminders order by at, id"))?
        .query_map([], row)?
        .collect()
}

pub fn cancel(db: &Connection, id: u64) -> rusqlite::Result<bool> {
    Ok(db.execute("delete from reminders where id = ?1", [id])? > 0)
}

/// The reminders due by `now`; they stay in the book until `done`.
pub fn due(db: &Connection, now: NaiveDateTime) -> rusqlite::Result<Vec<Reminder>> {
    db.prepare(&format!(
        "select {COLUMNS} from reminders where at <= ?1 order by at, id"
    ))?
    .query_map([now.format(AT).to_string()], row)?
    .collect()
}

/// Keeps a routine's answer until it is delivered.
pub fn keep_answer(db: &Connection, r: &Reminder, answer: &str) -> rusqlite::Result<()> {
    db.execute(
        "update reminders set answer = ?2 where id = ?1",
        params![r.id, answer],
    )?;
    Ok(())
}

/// A due reminder was delivered: a one-off leaves the book, a repeat moves
/// to its next time after `now`, so a missed stretch fires once. Only the
/// occurrence that was due is touched, should it have changed meanwhile.
pub fn done(db: &Connection, r: &Reminder, now: NaiveDateTime) -> rusqlite::Result<()> {
    let was = r.at.format(AT).to_string();
    match r.repeat {
        Some(rep) => {
            let mut at = r.at;
            while at <= now {
                at = rep.after(at);
            }
            db.execute(
                "update reminders set at = ?3, answer = null where id = ?1 and at = ?2",
                params![r.id, was, at.format(AT).to_string()],
            )?
        }
        None => db.execute(
            "delete from reminders where id = ?1 and at = ?2",
            params![r.id, was],
        )?,
    };
    Ok(())
}

pub fn list(db: &Connection, shelf: Shelf, name: &str) -> rusqlite::Result<Option<Vec<String>>> {
    let items: Option<String> = db
        .query_row(
            &format!("select items from {}.lists where name = ?1", shelf.schema()),
            [name],
            |r| r.get(0),
        )
        .optional()?;
    Ok(items.map(|s| serde_json::from_str(&s).unwrap_or_default()))
}

/// Every list on a shelf, by name.
pub fn lists(db: &Connection, shelf: Shelf) -> rusqlite::Result<Vec<(String, Vec<String>)>> {
    db.prepare(&format!(
        "select name, items from {}.lists order by name",
        shelf.schema()
    ))?
    .query_map([], |r| {
        let items: String = r.get(1)?;
        Ok((r.get(0)?, serde_json::from_str(&items).unwrap_or_default()))
    })?
    .collect()
}

/// Saves a list; an empty one goes away.
pub fn set_list(
    db: &Connection,
    shelf: Shelf,
    name: &str,
    items: &[String],
) -> rusqlite::Result<()> {
    let s = shelf.schema();
    if items.is_empty() {
        db.execute(&format!("delete from {s}.lists where name = ?1"), [name])?;
    } else {
        db.execute(
            &format!("insert or replace into {s}.lists values (?1, ?2)"),
            params![name, serde_json::to_string(items).unwrap()],
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(s: &str) -> NaiveDateTime {
        NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M").unwrap()
    }

    fn dir(name: &str) -> PathBuf {
        let d: PathBuf =
            std::env::temp_dir().join(format!("sokka-book-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn due_stays_until_done_then_one_offs_go_and_repeats_move() {
        let d = dir("due");
        let mut b = Book::open(&d, None).unwrap();
        b.change(|db| {
            remind(db, t("2026-10-08 09:00"), "once", None, false, false)?;
            remind(
                db,
                t("2026-10-01 18:00"),
                "weekly",
                Some(Repeat::Weekly),
                true,
                false,
            )?;
            remind(db, t("2026-10-09 09:00"), "later", None, false, false)
        })
        .unwrap();
        let now = t("2026-10-08 12:00");
        let fired = b.read(|db| due(db, now)).unwrap();
        assert_eq!(fired.len(), 2);
        // Undelivered, they are due again on the next tick.
        assert_eq!(b.read(|db| due(db, now)).unwrap().len(), 2);
        let weekly = fired.iter().find(|r| r.ask).unwrap().clone();
        b.change(|db| keep_answer(db, &weekly, "all quiet"))
            .unwrap();
        assert_eq!(
            b.read(|db| due(db, now)).unwrap()[0].answer.as_deref(),
            Some("all quiet")
        );
        for r in &fired {
            b.change(|db| done(db, r, now)).unwrap();
        }
        let left = b.read(reminders).unwrap();
        assert_eq!(left.len(), 2);
        assert_eq!(left[0].at, t("2026-10-08 18:00"));
        assert!(left[0].ask && left[0].answer.is_none());
        assert!(
            b.read(|db| due(db, t("2026-10-08 12:01")))
                .unwrap()
                .is_empty()
        );
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn a_list_moves_to_the_household_in_one_transaction() {
        let (own, house) = (dir("own"), dir("house"));
        let mut b = Book::open(&own, Some(&house)).unwrap();
        b.change(|db| set_list(db, Shelf::Own, "groceries", &["milk".into()]))
            .unwrap();
        b.change(|db| {
            let items = list(db, Shelf::Own, "groceries")?.unwrap();
            set_list(db, Shelf::House, "groceries", &items)?;
            set_list(db, Shelf::Own, "groceries", &[])
        })
        .unwrap();
        // Another assistant's book sees it in the household.
        let other = Book::open(&dir("other"), Some(&house)).unwrap();
        assert_eq!(
            other
                .read(|db| list(db, Shelf::House, "groceries"))
                .unwrap(),
            Some(vec!["milk".to_string()])
        );
        assert!(b.read(|db| lists(db, Shelf::Own)).unwrap().is_empty());
    }

    #[test]
    fn imports_the_json_book_once() {
        let d = dir("import");
        fs::write(
            d.join("book.json"),
            r#"{"reminders":[{"id":3,"at":"2026-10-10T08:00:00","text":"mail digest","repeat":"daily","ask":true}],"lists":{"groceries":["milk"]},"next_id":3}"#,
        )
        .unwrap();
        let b = Book::open(&d, None).unwrap();
        let r = b.read(reminders).unwrap();
        assert_eq!(r.len(), 1);
        assert!(r[0].ask && matches!(r[0].repeat, Some(Repeat::Daily)));
        assert_eq!(b.read(|db| lists(db, Shelf::Own)).unwrap().len(), 1);
        assert!(!d.join("book.json").exists());
        drop(b);
        assert_eq!(
            Book::open(&d, None).unwrap().read(reminders).unwrap().len(),
            1
        );
        fs::remove_dir_all(&d).unwrap();
    }
}
