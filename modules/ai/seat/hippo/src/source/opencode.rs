//! OpenCode: one SQLite database, read-only, as the seat. Parts are
//! rewritten while they stream, so a message is read only once it is done.

use super::{Event, Item, call_text, runs_memory, str_at, text_of};
use crate::store::{Kind, Src};
use chrono::{DateTime, Local};
use rusqlite::{Connection, OpenFlags};
use serde_json::Value;
use std::path::Path;

pub struct Session {
    pub id: String,
    /// Each event with the creation time of its message, in ms.
    pub events: Vec<(i64, Event)>,
}

fn date(ms: i64) -> DateTime<Local> {
    DateTime::from_timestamp_millis(ms)
        .unwrap_or_default()
        .with_timezone(&Local)
}

pub fn open(db: &Path) -> Result<Connection, String> {
    let conn = Connection::open_with_flags(
        db,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| format!("{}: {e}", db.display()))?;
    conn.busy_timeout(std::time::Duration::from_secs(5))
        .map_err(|e| e.to_string())?;
    Ok(conn)
}

/// Newest change in the database, in ms.
pub fn watermark(conn: &Connection) -> Result<i64, String> {
    conn.query_row(
        "SELECT max(t) FROM (SELECT max(time_updated) t FROM session
           UNION ALL SELECT max(time_updated) FROM message
           UNION ALL SELECT max(time_updated) FROM part)",
        [],
        |r| r.get::<_, Option<i64>>(0),
    )
    .map(|t| t.unwrap_or(0))
    .map_err(|e| e.to_string())
}

/// Sessions with any row changed after `since` (ms), each read whole.
pub fn changed(conn: &Connection, since: i64) -> Result<Vec<Session>, String> {
    let err = |e: rusqlite::Error| e.to_string();
    let mut ids = conn
        .prepare(
            "SELECT id FROM session WHERE time_updated > ?1
             UNION SELECT session_id FROM message WHERE time_updated > ?1
             UNION SELECT session_id FROM part WHERE time_updated > ?1",
        )
        .map_err(err)?;
    let ids: Vec<String> = ids
        .query_map([since], |r| r.get(0))
        .map_err(err)?
        .collect::<Result<_, _>>()
        .map_err(err)?;
    ids.into_iter().map(|id| session(conn, id)).collect()
}

pub fn session(conn: &Connection, id: String) -> Result<Session, String> {
    let err = |e: rusqlite::Error| e.to_string();
    let mut events = Vec::new();
    let head = conn.query_row(
        "SELECT title, directory, parent_id FROM session WHERE id = ?1",
        [&id],
        |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, Option<String>>(2)?,
            ))
        },
    );
    let Ok((title, cwd, parent)) = head else {
        // Deleted since it changed.
        return Ok(Session { id, events });
    };
    if parent.is_some() {
        events.push((0, Event::Foreign));
    }
    events.push((
        0,
        Event::Info {
            cwd: Some(cwd),
            title: Some(title),
        },
    ));
    let mut msgs = conn
        .prepare(
            "SELECT id, time_created, data FROM message WHERE session_id = ?1
             ORDER BY time_created, id",
        )
        .map_err(err)?;
    let mut parts = conn
        .prepare("SELECT id, data FROM part WHERE message_id = ?1 ORDER BY time_created, id")
        .map_err(err)?;
    let rows: Vec<(String, i64, String)> = msgs
        .query_map([&id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .map_err(err)?
        .collect::<Result<_, _>>()
        .map_err(err)?;
    for (mid, created, data) in rows {
        let Ok(m) = serde_json::from_str::<Value>(&data) else {
            events.push((
                created,
                Event::Unparsed(format!("message {mid} is not JSON")),
            ));
            continue;
        };
        let role = str_at(&m, "/role");
        let done = m.pointer("/time/completed").is_some() || m.get("error").is_some();
        if role == Some("assistant") && !done {
            // Still streaming: it and everything after wait for the next read.
            break;
        }
        let at = date(created);
        let ps: Vec<(String, String)> = parts
            .query_map([&mid], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(err)?
            .collect::<Result<_, _>>()
            .map_err(err)?;
        let item = |pid: &str, kind, text: String, opens, call: Option<&str>| Item {
            kind,
            text,
            date: at,
            src: Src {
                h: "opencode".into(),
                s: id.clone(),
                e: pid.to_owned(),
            },
            opens,
            call: call.map(str::to_owned),
            memory: false,
        };
        let mut said = Vec::new();
        let mut first = None;
        for (pid, pdata) in ps {
            let Ok(p) = serde_json::from_str::<Value>(&pdata) else {
                events.push((created, Event::Unparsed(format!("part {pid} is not JSON"))));
                continue;
            };
            if p.get("synthetic") == Some(&Value::Bool(true)) {
                continue;
            }
            match (role, str_at(&p, "/type")) {
                (Some("user"), Some("text")) => {
                    first.get_or_insert(pid.clone());
                    said.push(str_at(&p, "/text").unwrap_or("").to_owned());
                }
                (Some("user"), Some("file")) => {
                    first.get_or_insert(pid.clone());
                    said.push(format!("[file] {}", str_at(&p, "/filename").unwrap_or("")));
                }
                (Some("assistant"), Some("text")) => {
                    let t = str_at(&p, "/text").unwrap_or("");
                    if !t.trim().is_empty() {
                        let it = item(&pid, Kind::Talk, t.to_owned(), false, None);
                        events.push((created, Event::Item(it)));
                    }
                }
                (Some("assistant"), Some("tool")) => {
                    let input = p.pointer("/state/input").unwrap_or(&Value::Null);
                    let call = str_at(&p, "/callID");
                    let mut it = item(
                        &pid,
                        Kind::Tool,
                        call_text(str_at(&p, "/tool").unwrap_or("?"), input),
                        false,
                        call,
                    );
                    it.memory = runs_memory(input);
                    events.push((created, Event::Item(it)));
                    let result = p
                        .pointer("/state/output")
                        .or_else(|| p.pointer("/state/error"));
                    if let Some(result) = result {
                        let it = item(
                            &format!("{pid}.out"),
                            Kind::Echo,
                            text_of(result),
                            false,
                            call,
                        );
                        events.push((created, Event::Item(it)));
                    }
                }
                (
                    _,
                    Some(
                        "reasoning" | "step-start" | "step-finish" | "snapshot" | "patch"
                        | "compaction" | "agent" | "retry",
                    ),
                ) => {}
                (_, other) => {
                    let what = format!(
                        "{} part {}",
                        role.unwrap_or("?"),
                        other.unwrap_or("without a type")
                    );
                    events.push((created, Event::Unparsed(what)));
                }
            }
        }
        if let Some(pid) = first {
            let text = said.join("\n");
            if !text.trim().is_empty() {
                let it = item(&pid, Kind::User, text, true, None);
                events.push((created, Event::Item(it)));
            }
        }
        if role == Some("assistant") && str_at(&m, "/finish") != Some("tool-calls") {
            events.push((created, Event::TurnEnd));
        }
    }
    Ok(Session { id, events })
}
