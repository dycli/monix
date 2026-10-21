//! Watches: tests on what arrives (mail, transactions, calendar events) that
//! wake the yeoman when something passes them. A source only lists its
//! recent items as flat fields; the tests, what has already fired and when
//! an item is due are the same for every source, so a new source is one
//! more arm of `Sources::items`.

use crate::calendar::Calendar;
use crate::finance::Finance;
use crate::mail::{Account, Imap};
use chrono::{Duration, NaiveDate, NaiveDateTime};
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
    share integer not null default 0,
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
    /// New mail in the inbox: account, from, subject.
    Mail,
    /// New transactions: merchant, amount (spending positive), category,
    /// kind (spend, income, transfer…), account, pending.
    Money,
    /// Calendar events as they come up: summary, calendar, location,
    /// start, end; `before` sets how many minutes ahead.
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
    pub share: bool,
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
        if self.share {
            out.push_str(" (shared)");
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
    share: bool,
) -> rusqlite::Result<u64> {
    db.execute(
        "insert into watches (source, tests, text, before, share) values (?1, ?2, ?3, ?4, ?5)",
        params![
            source.name(),
            serde_json::to_string(tests).unwrap(),
            text,
            before.max(0),
            share
        ],
    )?;
    Ok(db.last_insert_rowid() as u64)
}

pub fn watches(db: &Connection) -> rusqlite::Result<Vec<Watch>> {
    db.prepare("select id, source, tests, text, before, share, primed from watches order by id")?
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
            let (source, tests, id, text, before, share, primed) = row?;
            Ok(Source::parse(&source).map(|source| Watch {
                id,
                source,
                tests: serde_json::from_str(&tests).unwrap_or_default(),
                text,
                before,
                share,
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
    pub mail: Option<(String, Vec<Account>)>,
    pub calendar: Option<Calendar>,
    pub finance: Option<Finance>,
}

impl Sources {
    /// The items a source has now: mail since yesterday, transactions from
    /// the last ten days, events from now to two days on. Blocks.
    pub fn items(&self, source: Source, now: NaiveDateTime) -> Result<Vec<Item>, String> {
        match source {
            Source::Mail => self.mail(now),
            Source::Money => self.money(now),
            Source::Calendar => self.calendar(now),
        }
    }

    pub fn has(&self, source: Source) -> bool {
        match source {
            Source::Mail => self.mail.is_some(),
            Source::Money => self.finance.is_some(),
            Source::Calendar => self.calendar.is_some(),
        }
    }

    fn mail(&self, now: NaiveDateTime) -> Result<Vec<Item>, String> {
        let (host, accounts) = self.mail.as_ref().ok_or("There is no mail here.")?;
        let since = (now.date() - Duration::days(1))
            .format("%d-%b-%Y")
            .to_string();
        let mut out = Vec::new();
        for a in accounts {
            let mut imap = Imap::login(host, a)?;
            imap.open("INBOX")?;
            let uids = imap.search(&[("SINCE", &since)])?;
            for h in imap.headers(&uids, "INBOX")? {
                let mut fields = Map::new();
                fields.insert("account".into(), json!(a.name));
                for k in ["from", "subject", "date", "uid"] {
                    fields.insert(k.into(), h[k].clone());
                }
                out.push(Item {
                    key: format!("{}/{}", a.name, h["uid"]),
                    at: now,
                    fields,
                });
            }
        }
        Ok(out)
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
        let cal = self.calendar.as_ref().ok_or("There is no calendar here.")?;
        let today = now.date().format("%Y-%m-%d").to_string();
        let events: Vec<Value> =
            serde_json::from_str(&cal.events(&today, 2, None)?).map_err(|e| e.to_string())?;
        Ok(events
            .into_iter()
            .filter_map(|e| {
                let start = e["start"].as_str()?;
                let at = NaiveDateTime::parse_from_str(start, AT)
                    .or_else(|_| {
                        NaiveDate::parse_from_str(start, "%Y-%m-%d")
                            .map(|d| d.and_hms_opt(0, 0, 0).unwrap())
                    })
                    .ok()?;
                // Only what is still ahead: the rest has had its turn.
                if at < now {
                    return None;
                }
                let key = format!("{}/{start}", e["uid"].as_str().unwrap_or_default());
                let Value::Object(mut fields) = e else {
                    return None;
                };
                fields.remove("uid");
                Some(Item { key, at, fields })
            })
            .collect())
    }
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
        let id = watch(&db, Source::Money, &big, "tell me", 0, false).unwrap();
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
        let id = watch(&db, Source::Calendar, &[], "remind me", 15, false).unwrap();
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
