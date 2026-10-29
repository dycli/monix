//! Watches: tests on what arrives (mail, transactions, calendar events) that
//! wake the yeoman when something passes them. A source only lists its
//! recent items as flat fields; the tests, what has already fired and when
//! an item is due are the same for every source, so a new source is one
//! more arm of `Sources::items`.

use crate::fastmail::{self, Fastmail};
use crate::finance::Finance;
use chrono::{DateTime, Duration, Local, NaiveDate, NaiveDateTime};
use rusqlite::{Connection, OptionalExtension, params};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

const AT: &str = "%Y-%m-%d %H:%M";

pub const WATCHES: &str = "
create table if not exists watches (
    id integer primary key autoincrement,
    source text not null,
    tests text not null,
    text text not null,
    before integer not null default 0,
    share_with text not null default '[]',
    primed integer not null default 0
);
create table if not exists watch_seen (
    watch integer not null,
    key text not null,
    at text not null,
    primary key (watch, key)
);
";

/// Where a watch looks.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    /// New mail in the inbox: from, subject, and the rest Fastmail gives.
    Mail,
    /// New transactions: merchant, amount (spending positive), category,
    /// kind (spend, income, transfer…), account, pending.
    Money,
    /// Calendar events as they come up: title, start, location, and the
    /// rest Fastmail gives; `before` sets how many minutes ahead.
    Calendar,
}

impl Source {
    fn name(self) -> &'static str {
        match self {
            Source::Mail => "mail",
            Source::Money => "money",
            Source::Calendar => "calendar",
        }
    }

    fn parse(s: &str) -> Option<Self> {
        serde_json::from_value(json!(s)).ok()
    }
}

#[derive(Clone, Copy, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Op {
    /// The field equals the value, in any case.
    Is,
    /// The field holds the value, in any case.
    Has,
    /// The field is a number above the value.
    Over,
    /// The field is a number below the value.
    Under,
}

/// One test on an item's field; a watch fires when all of them pass.
#[derive(Clone, Serialize, Deserialize, JsonSchema)]
pub struct Test {
    pub field: String,
    pub op: Op,
    pub value: String,
}

impl Test {
    fn passes(&self, fields: &Map<String, Value>) -> bool {
        let Some(f) = fields.get(&self.field) else {
            return false;
        };
        let text = match f {
            Value::String(s) => s.to_lowercase(),
            other => other.to_string().to_lowercase(),
        };
        let want = self.value.trim().to_lowercase();
        let num = || {
            Some((
                f.as_f64()?,
                want.trim_start_matches('$').parse::<f64>().ok()?,
            ))
        };
        match self.op {
            Op::Is => text == want,
            Op::Has => text.contains(&want),
            Op::Over => num().is_some_and(|(n, v)| n > v),
            Op::Under => num().is_some_and(|(n, v)| n < v),
        }
    }
}

#[derive(Clone)]
pub struct Watch {
    pub id: u64,
    pub source: Source,
    pub tests: Vec<Test>,
    /// What the person wants done when it fires, in their words.
    pub text: String,
    /// Minutes ahead of an item's time it fires: for calendar events.
    pub before: i64,
    /// Who else its answer goes to, each by name.
    pub share_with: Vec<String>,
    /// Whether the items there were when it was set are already counted.
    primed: bool,
}

impl Watch {
    /// The watch as `watches` lists it.
    pub fn show(&self) -> String {
        let tests: Vec<String> = self
            .tests
            .iter()
            .map(|t| {
                let op = serde_json::to_value(t.op).unwrap();
                format!("{} {} {:?}", t.field, op.as_str().unwrap_or(""), t.value)
            })
            .collect();
        let mut out = format!("{}: {}", self.id, self.source.name());
        if !tests.is_empty() {
            out.push_str(&format!(" where {}", tests.join(" and ")));
        }
        if self.before > 0 {
            out.push_str(&format!(", {} min ahead", self.before));
        }
        out.push_str(&format!(": {}", self.text));
        if !self.share_with.is_empty() {
            out.push_str(&format!(" (shared with {})", self.share_with.join(", ")));
        }
        out
    }
}

/// Something a source has: its own key, its time (when it arrived, or when
/// it happens) and the fields the tests read.
#[derive(Clone)]
pub struct Item {
    pub key: String,
    pub at: NaiveDateTime,
    pub fields: Map<String, Value>,
}

pub fn watch(
    db: &Connection,
    source: Source,
    tests: &[Test],
    text: &str,
    before: i64,
    share_with: &[String],
) -> rusqlite::Result<u64> {
    db.execute(
        "insert into watches (source, tests, text, before, share_with) values (?1, ?2, ?3, ?4, ?5)",
        params![
            source.name(),
            serde_json::to_string(tests).unwrap(),
            text,
            before.max(0),
            serde_json::to_string(share_with).unwrap()
        ],
    )?;
    Ok(db.last_insert_rowid() as u64)
}

pub fn watches(db: &Connection) -> rusqlite::Result<Vec<Watch>> {
    db.prepare(
        "select id, source, tests, text, before, share_with, primed from watches order by id",
    )?
    .query_map([], |r| {
        let source: String = r.get(1)?;
        let tests: String = r.get(2)?;
        Ok((
            source,
            tests,
            r.get(0)?,
            r.get(3)?,
            r.get(4)?,
            r.get(5)?,
            r.get(6)?,
        ))
    })?
    .map(|row| {
        let (source, tests, id, text, before, share, primed): (String, String, _, _, _, String, _) =
            row?;
        Ok(Source::parse(&source).map(|source| Watch {
            id,
            source,
            tests: serde_json::from_str(&tests).unwrap_or_default(),
            text,
            before,
            share_with: crate::book::names(&share),
            primed,
        }))
    })
    .filter_map(Result::transpose)
    .collect()
}

pub fn unwatch(db: &Connection, id: u64) -> rusqlite::Result<bool> {
    db.execute("delete from watch_seen where watch = ?1", [id])?;
    Ok(db.execute("delete from watches where id = ?1", [id])? > 0)
}

/// The items due for a watch now that pass its tests and haven't fired.
/// A watch's first look only counts what is already due, so setting one
/// doesn't fire on the whole inbox.
pub fn fresh(
    db: &Connection,
    w: &Watch,
    items: &[Item],
    now: NaiveDateTime,
) -> rusqlite::Result<Vec<Item>> {
    let due = items
        .iter()
        .filter(|i| i.at - Duration::minutes(w.before) <= now);
    if !w.primed {
        for i in due {
            seen(db, w, i, now)?;
        }
        db.execute("update watches set primed = 1 where id = ?1", [w.id])?;
        return Ok(Vec::new());
    }
    let mut out = Vec::new();
    for i in due {
        if !w.tests.iter().all(|t| t.passes(&i.fields)) {
            continue;
        }
        let known = db
            .query_row(
                "select 1 from watch_seen where watch = ?1 and key = ?2",
                params![w.id, i.key],
                |_| Ok(()),
            )
            .optional()?;
        if known.is_none() {
            out.push(i.clone());
        }
    }
    Ok(out)
}

/// Marks an item done for a watch: once the person has been told, or it
/// was there before the watch.
pub fn seen(db: &Connection, w: &Watch, i: &Item, now: NaiveDateTime) -> rusqlite::Result<()> {
    db.execute(
        "insert or ignore into watch_seen values (?1, ?2, ?3)",
        params![w.id, i.key, now.format(AT).to_string()],
    )?;
    Ok(())
}

/// Forgets what fired long ago; sources only list recent items, so an old
/// key can't come back.
pub fn prune(db: &Connection, now: NaiveDateTime) -> rusqlite::Result<()> {
    let cut = (now - Duration::days(60)).format(AT).to_string();
    db.execute("delete from watch_seen where at < ?1", [cut])?;
    Ok(())
}

/// The item as the turn that answers a watch sees it.
pub fn describe(i: &Item) -> String {
    Value::Object(i.fields.clone()).to_string()
}

/// What the watches can look at, read from the same settings as the tools.
pub struct Sources {
    pub fastmail: Option<Fastmail>,
    pub finance: Option<Finance>,
}

impl Sources {
    /// The items a source has now: the newest mail in the inbox,
    /// transactions from the last ten days, events from now to two days
    /// on. Blocks.
    pub fn items(&self, source: Source, now: NaiveDateTime) -> Result<Vec<Item>, String> {
        match source {
            Source::Mail => self.mail(now),
            Source::Money => self.money(now),
            Source::Calendar => self.calendar(now),
        }
    }

    pub fn has(&self, source: Source) -> bool {
        match source {
            Source::Mail | Source::Calendar => self.fastmail.is_some(),
            Source::Money => self.finance.is_some(),
        }
    }

    fn fastmail(&self) -> Result<&Fastmail, String> {
        self.fastmail
            .as_ref()
            .ok_or("There is no mail or calendar here.".into())
    }

    fn mail(&self, now: NaiveDateTime) -> Result<Vec<Item>, String> {
        // The newest fifty: a watch looks every other minute, and what it
        // has seen it keeps for sixty days.
        let found = self
            .fastmail()?
            .call("search_email", json!({"query": "in:inbox", "limit": 50}))?;
        Ok(keyed(fastmail::records(&found)?)?
            .into_iter()
            .map(|(key, fields)| Item {
                key,
                at: now,
                fields,
            })
            .collect())
    }

    fn money(&self, now: NaiveDateTime) -> Result<Vec<Item>, String> {
        let finance = self.finance.as_ref().ok_or("There is no money here.")?;
        let since = (now.date() - Duration::days(10))
            .format("%Y-%m-%d")
            .to_string();
        finance.recent(&since).map(|rows| {
            rows.into_iter()
                .map(|(key, fields)| Item {
                    key,
                    at: now,
                    fields,
                })
                .collect()
        })
    }

    fn calendar(&self, now: NaiveDateTime) -> Result<Vec<Item>, String> {
        let found = self.fastmail()?.call(
            "search_events",
            json!({"after": "now", "before": "2 days from now", "limit": 50}),
        )?;
        let events: Vec<_> = keyed(fastmail::records(&found)?)?
            .into_iter()
            .map(|(key, fields)| {
                let at = fields.get("start").and_then(Value::as_str).and_then(start);
                (key, at, fields)
            })
            .collect();
        // Events none of whose starts read would never fire: say so.
        if !events.is_empty() && events.iter().all(|(_, at, _)| at.is_none()) {
            return Err(format!(
                "fastmail: events without a start I can read: {}",
                found.to_string().chars().take(300).collect::<String>()
            ));
        }
        let items = events
            .into_iter()
            .filter_map(|(key, at, fields)| {
                let at = at?;
                // Only what is still ahead: the rest has had its turn.
                (at >= now).then(|| Item {
                    // A repeat keeps its id; its start tells it apart.
                    key: format!("{key}/{at}"),
                    at,
                    fields,
                })
            })
            .collect();
        Ok(items)
    }
}

type Keyed = (String, Map<String, Value>);

/// Records with their ids, the id taken out of the fields the model sees.
/// Records without one could never be told apart, so they are an error.
fn keyed(records: Vec<Map<String, Value>>) -> Result<Vec<Keyed>, String> {
    records
        .into_iter()
        .map(|mut fields| {
            let id = fields.remove("id").ok_or_else(|| {
                let seen = Value::Object(fields.clone()).to_string();
                format!(
                    "fastmail: a record without an id: {}",
                    seen.chars().take(300).collect::<String>()
                )
            })?;
            Ok((
                id.as_str().map(str::to_owned).unwrap_or(id.to_string()),
                fields,
            ))
        })
        .collect()
}

/// An event's start in local time: with an offset, converted; without,
/// taken as local; a bare day, its midnight.
fn start(s: &str) -> Option<NaiveDateTime> {
    if let Ok(t) = DateTime::parse_from_rfc3339(s) {
        return Some(t.with_timezone(&Local).naive_local());
    }
    ["%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M", AT]
        .iter()
        .find_map(|f| NaiveDateTime::parse_from_str(s, f).ok())
        .or_else(|| {
            NaiveDate::parse_from_str(s, "%Y-%m-%d")
                .ok()
                .and_then(|d| d.and_hms_opt(0, 0, 0))
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(s: &str) -> NaiveDateTime {
        NaiveDateTime::parse_from_str(s, AT).unwrap()
    }

    fn item(key: &str, at: &str, fields: Value) -> Item {
        let Value::Object(fields) = fields else {
            panic!()
        };
        Item {
            key: key.into(),
            at: t(at),
            fields,
        }
    }

    fn db() -> Connection {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch(WATCHES).unwrap();
        db
    }

    #[test]
    fn an_event_starts_in_local_time_in_any_of_its_forms() {
        assert_eq!(start("2026-10-29T09:30:00"), Some(t("2026-10-29 09:30")));
        assert_eq!(start("2026-10-29"), Some(t("2026-10-29 00:00")));
        let utc = DateTime::parse_from_rfc3339("2026-10-29T13:30:00Z").unwrap();
        assert_eq!(
            start("2026-10-29T13:30:00Z"),
            Some(utc.with_timezone(&Local).naive_local())
        );
        assert_eq!(start("soon"), None);
    }

    #[test]
    fn records_keep_their_id_as_the_key_only() {
        let Value::Object(r) = json!({"id": "M1", "subject": "Hi"}) else {
            panic!()
        };
        let (key, fields) = keyed(vec![r]).unwrap().remove(0);
        assert_eq!((key.as_str(), fields.len()), ("M1", 1));
        assert!(keyed(vec![Map::new()]).is_err());
    }

    #[test]
    fn tests_read_text_in_any_case_and_numbers() {
        let i = item(
            "a",
            "2026-10-20 09:00",
            json!({"from": "Gab <gab@x.org>", "amount": 240.5}),
        );
        let test = |field: &str, op, value: &str| Test {
            field: field.into(),
            op,
            value: value.into(),
        };
        assert!(test("from", Op::Has, "GAB").passes(&i.fields));
        assert!(!test("from", Op::Is, "gab").passes(&i.fields));
        assert!(test("amount", Op::Over, "$200").passes(&i.fields));
        assert!(!test("amount", Op::Under, "200").passes(&i.fields));
        assert!(!test("from", Op::Over, "1").passes(&i.fields));
        assert!(!test("missing", Op::Has, "").passes(&i.fields));
    }

    #[test]
    fn a_watch_skips_what_was_there_then_fires_once_per_item() {
        let db = db();
        let big = [Test {
            field: "amount".into(),
            op: Op::Over,
            value: "200".into(),
        }];
        let id = watch(&db, Source::Money, &big, "tell me", 0, &[]).unwrap();
        let w = || {
            watches(&db)
                .unwrap()
                .into_iter()
                .find(|w| w.id == id)
                .unwrap()
        };
        let now = t("2026-10-20 09:00");
        let old = item("old", "2026-10-20 09:00", json!({"amount": 500}));
        assert!(
            fresh(&db, &w(), std::slice::from_ref(&old), now)
                .unwrap()
                .is_empty()
        );
        let new = item("new", "2026-10-20 09:02", json!({"amount": 300}));
        let small = item("small", "2026-10-20 09:02", json!({"amount": 5}));
        let later = t("2026-10-20 09:02");
        let all = [old, new, small];
        let fired = fresh(&db, &w(), &all, later).unwrap();
        assert_eq!(
            fired.iter().map(|i| i.key.as_str()).collect::<Vec<_>>(),
            ["new"]
        );
        // Until it is marked told, it stays due.
        assert_eq!(fresh(&db, &w(), &all, later).unwrap().len(), 1);
        seen(&db, &w(), &fired[0], later).unwrap();
        assert!(fresh(&db, &w(), &all, later).unwrap().is_empty());
        assert!(unwatch(&db, id).unwrap());
        assert!(watches(&db).unwrap().is_empty());
    }

    #[test]
    fn an_event_fires_its_minutes_ahead_even_if_it_was_listed_when_set() {
        let db = db();
        let id = watch(&db, Source::Calendar, &[], "remind me", 15, &[]).unwrap();
        let w = || {
            watches(&db)
                .unwrap()
                .into_iter()
                .find(|w| w.id == id)
                .unwrap()
        };
        let ev = [item(
            "e/10:00",
            "2026-10-20 10:00",
            json!({"summary": "Dentist"}),
        )];
        assert!(
            fresh(&db, &w(), &ev, t("2026-10-20 09:00"))
                .unwrap()
                .is_empty()
        );
        assert!(
            fresh(&db, &w(), &ev, t("2026-10-20 09:44"))
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            fresh(&db, &w(), &ev, t("2026-10-20 09:45")).unwrap().len(),
            1
        );
    }
}
