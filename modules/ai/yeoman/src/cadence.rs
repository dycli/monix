//! When the yeoman speaks unasked, after Claude's own practice: one brief a
//! morning as the person's quiet hours end, and check-ins through the day
//! that say nothing unless something needs them, at most `most` a day, the
//! second only once the person has written since the first. What the
//! yeoman would say on its own in quiet hours waits for the brief, unless
//! it is urgent. Reminders and routines the person timed are theirs, and go
//! when they asked.
//!
//! The setting and the day's count live in the book, so a restart neither
//! repeats a brief nor forgets the cap.

use chrono::{Duration, NaiveDate, NaiveDateTime, NaiveTime};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};

pub const CADENCE: &str = "
create table if not exists cadence (key text primary key, value text not null);
create table if not exists held (
    id integer primary key autoincrement,
    at text not null,
    text text not null
);
";

const AT: &str = "%Y-%m-%d %H:%M:%S";

/// The person's numbers; they change them through the `cadence` tool.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Setting {
    /// Quiet hours start (local, HH:MM).
    pub quiet_from: NaiveTime,
    /// Quiet hours end; the brief comes then.
    pub quiet_until: NaiveTime,
    /// Hours between check-ins, the first an hour after the brief.
    pub every: u32,
    /// Most check-ins passed on in a day.
    pub most: u32,
    /// Whether there are briefs and check-ins at all; quiet hours hold
    /// regardless.
    pub on: bool,
}

impl Default for Setting {
    fn default() -> Setting {
        Setting {
            quiet_from: NaiveTime::from_hms_opt(23, 0, 0).unwrap(),
            quiet_until: NaiveTime::from_hms_opt(8, 0, 0).unwrap(),
            every: 3,
            most: 2,
            on: true,
        }
    }
}

impl Setting {
    pub fn quiet(&self, t: NaiveTime) -> bool {
        if self.quiet_from <= self.quiet_until {
            self.quiet_from <= t && t < self.quiet_until
        } else {
            t >= self.quiet_from || t < self.quiet_until
        }
    }

    /// Today's check-in times: an hour after the brief, then every
    /// `every` hours, the last at least an hour before quiet hours.
    fn checkins(&self, day: NaiveDate) -> Vec<NaiveDateTime> {
        let start = day.and_time(self.quiet_until);
        let mut end = day.and_time(self.quiet_from);
        if end <= start {
            end += Duration::days(1);
        }
        let mut at = start + Duration::hours(1);
        let mut out = Vec::new();
        while self.every > 0 && at + Duration::hours(1) <= end {
            out.push(at);
            at += Duration::hours(self.every.into());
        }
        out
    }

    pub fn describe(&self) -> String {
        format!(
            "Quiet hours {}–{}; the brief at {}; check-ins every {} h, at most {} a day passed on{}.",
            self.quiet_from.format("%H:%M"),
            self.quiet_until.format("%H:%M"),
            self.quiet_until.format("%H:%M"),
            self.every,
            self.most,
            if self.on {
                ""
            } else {
                " (briefs and check-ins off)"
            }
        )
    }
}

/// What has happened today.
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct Day {
    pub date: Option<NaiveDate>,
    pub briefed: bool,
    /// The check-in time last dealt with, run or skipped.
    pub looked: Option<NaiveDateTime>,
    /// Check-ins passed on today.
    pub sent: u32,
    /// When the first was passed on.
    pub first: Option<NaiveDateTime>,
    /// When the person last wrote.
    pub wrote: Option<NaiveDateTime>,
}

#[derive(Debug, PartialEq)]
pub enum Due {
    Brief,
    /// A check-in for this time, to run.
    CheckIn(NaiveDateTime),
    /// A check-in for this time, past the cap: counted as dealt with.
    Skip(NaiveDateTime),
}

/// What is due now, given the setting and the day so far.
pub fn due(s: &Setting, d: &Day, now: NaiveDateTime) -> Option<Due> {
    if !s.on || s.quiet(now.time()) {
        return None;
    }
    // The day starts when quiet hours end, so a check-in after midnight
    // belongs to the day before.
    let day = if now.time() < s.quiet_until {
        now.date().pred_opt()?
    } else {
        now.date()
    };
    let today = d.date == Some(day);
    if !(today && d.briefed) {
        return Some(Due::Brief);
    }
    let slot = s.checkins(day).into_iter().rev().find(|t| *t <= now)?;
    if d.looked.is_some_and(|l| l >= slot) {
        return None;
    }
    let free = d.sent < s.most && (d.sent == 0 || d.wrote > d.first);
    Some(if free {
        Due::CheckIn(slot)
    } else {
        Due::Skip(slot)
    })
}

fn get<T: for<'a> Deserialize<'a> + Default>(db: &Connection, key: &str) -> rusqlite::Result<T> {
    let v: Option<String> = db
        .query_row("select value from cadence where key = ?1", [key], |r| {
            r.get(0)
        })
        .optional()?;
    Ok(v.and_then(|v| serde_json::from_str(&v).ok())
        .unwrap_or_default())
}

fn put<T: Serialize>(db: &Connection, key: &str, v: &T) -> rusqlite::Result<()> {
    db.execute(
        "insert into cadence (key, value) values (?1, ?2)
         on conflict (key) do update set value = excluded.value",
        params![key, serde_json::to_string(v).unwrap()],
    )
    .map(drop)
}

pub fn setting(db: &Connection) -> rusqlite::Result<Setting> {
    get(db, "setting")
}

pub fn set(db: &Connection, s: &Setting) -> rusqlite::Result<()> {
    put(db, "setting", s)
}

pub fn day(db: &Connection) -> rusqlite::Result<Day> {
    get(db, "day")
}

/// The person wrote.
pub fn wrote(db: &Connection, now: NaiveDateTime) -> rusqlite::Result<()> {
    let mut d = day(db)?;
    d.wrote = Some(now);
    put(db, "day", &d)
}

/// The brief went out: a new day, its check-ins counted from now.
pub fn briefed(db: &Connection, now: NaiveDateTime, upto: i64) -> rusqlite::Result<()> {
    let s = setting(db)?;
    let d = day(db)?;
    let date = if now.time() < s.quiet_until {
        now.date().pred_opt().unwrap_or(now.date())
    } else {
        now.date()
    };
    let looked = s.checkins(date).into_iter().rev().find(|t| *t <= now);
    put(
        db,
        "day",
        &Day {
            date: Some(date),
            briefed: true,
            looked,
            sent: 0,
            first: None,
            wrote: d.wrote,
        },
    )?;
    db.execute("delete from held where id <= ?1", [upto])
        .map(drop)
}

/// A check-in time dealt with; `sent` if something was passed on.
pub fn looked(
    db: &Connection,
    at: NaiveDateTime,
    sent: bool,
    now: NaiveDateTime,
) -> rusqlite::Result<()> {
    let mut d = day(db)?;
    d.looked = Some(at);
    if sent {
        d.sent += 1;
        d.first = d.first.or(Some(now));
    }
    put(db, "day", &d)
}

/// Keeps what would have been said in quiet hours, for the brief.
pub fn hold(db: &Connection, text: &str, now: NaiveDateTime) -> rusqlite::Result<()> {
    db.execute(
        "insert into held (at, text) values (?1, ?2)",
        params![now.format(AT).to_string(), text],
    )
    .map(drop)
}

/// What waits for the brief, oldest first, with the last id.
pub fn held(db: &Connection) -> rusqlite::Result<(Vec<(String, String)>, i64)> {
    let mut st = db.prepare("select id, at, text from held order by id")?;
    let mut last = 0;
    let rows = st
        .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get(1)?, r.get(2)?)))?
        .map(|r| {
            r.map(|(id, at, text): (i64, String, String)| {
                last = last.max(id);
                (at, text)
            })
        })
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok((rows, last))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(d: u32, h: u32, m: u32) -> NaiveDateTime {
        NaiveDate::from_ymd_opt(2026, 10, d)
            .unwrap()
            .and_hms_opt(h, m, 0)
            .unwrap()
    }

    use chrono::Timelike;

    #[test]
    fn quiet_hours_wrap_midnight() {
        let s = Setting::default();
        assert!(s.quiet(NaiveTime::from_hms_opt(23, 30, 0).unwrap()));
        assert!(s.quiet(NaiveTime::from_hms_opt(3, 0, 0).unwrap()));
        assert!(!s.quiet(NaiveTime::from_hms_opt(8, 0, 0).unwrap()));
        assert!(!s.quiet(NaiveTime::from_hms_opt(22, 59, 0).unwrap()));
    }

    #[test]
    fn checkins_run_nine_to_twenty_one() {
        let hours: Vec<u32> = Setting::default()
            .checkins(at(26, 0, 0).date())
            .iter()
            .map(|t| t.hour())
            .collect();
        assert_eq!(hours, [9, 12, 15, 18, 21]);
    }

    #[test]
    fn brief_then_checkins_then_cap() {
        let s = Setting::default();
        let mut d = Day::default();
        assert_eq!(due(&s, &d, at(26, 7, 59)), None);
        assert_eq!(due(&s, &d, at(26, 8, 0)), Some(Due::Brief));
        d.date = Some(at(26, 0, 0).date());
        d.briefed = true;
        assert_eq!(due(&s, &d, at(26, 8, 30)), None);
        assert_eq!(due(&s, &d, at(26, 9, 1)), Some(Due::CheckIn(at(26, 9, 0))));
        // Nothing worth saying at 9: dealt with, not counted.
        d.looked = Some(at(26, 9, 0));
        assert_eq!(due(&s, &d, at(26, 11, 0)), None);
        // Passed on at 12.
        d.looked = Some(at(26, 12, 0));
        d.sent = 1;
        d.first = Some(at(26, 12, 1));
        // Not written since: the 15:00 one is skipped unrun.
        assert_eq!(due(&s, &d, at(26, 15, 0)), Some(Due::Skip(at(26, 15, 0))));
        d.wrote = Some(at(26, 13, 0));
        assert_eq!(
            due(&s, &d, at(26, 15, 0)),
            Some(Due::CheckIn(at(26, 15, 0)))
        );
        d.sent = 2;
        assert_eq!(due(&s, &d, at(26, 18, 0)), Some(Due::Skip(at(26, 18, 0))));
        // Next morning, a new brief.
        assert_eq!(due(&s, &d, at(27, 8, 0)), Some(Due::Brief));
    }

    #[test]
    fn off_means_no_brief() {
        let s = Setting {
            on: false,
            ..Setting::default()
        };
        assert_eq!(due(&s, &Day::default(), at(26, 8, 0)), None);
    }
}
