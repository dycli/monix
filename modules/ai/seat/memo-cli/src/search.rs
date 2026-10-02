//! Disposable full-text index over the canonical append-only log.

use super::{Entry, Lock, log_len, log_slice};
use rusqlite::{Connection, params};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

const SCHEMA_VERSION: i64 = 1;
const INDEX_FILE: &str = "SEARCH.sqlite";

pub struct Found {
    pub hits: Vec<Entry>,
    pub total: usize,
}

fn path(d: &Path) -> PathBuf {
    d.join(INDEX_FILE)
}

fn initialize(conn: &Connection) -> Result<(), String> {
    conn.execute_batch(
        "DROP TABLE IF EXISTS memories;
         DROP TABLE IF EXISTS search_meta;
         CREATE VIRTUAL TABLE memories USING fts5(
             date UNINDEXED,
             text,
             tokenize = 'unicode61 remove_diacritics 2'
         );
         CREATE TABLE search_meta (
             singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
             indexed_records INTEGER NOT NULL
         );
         INSERT INTO search_meta VALUES (1, 0);
         PRAGMA user_version = 1;",
    )
    .map_err(|e| e.to_string())
}

fn open(d: &Path) -> Result<Connection, String> {
    let conn = Connection::open(path(d)).map_err(|e| e.to_string())?;
    conn.busy_timeout(Duration::from_secs(5))
        .map_err(|e| e.to_string())?;
    let version: i64 = conn
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .map_err(|e| e.to_string())?;
    if version == 0 {
        initialize(&conn)?;
    } else if version != SCHEMA_VERSION {
        return Err(format!(
            "search index schema is {version}, expected {SCHEMA_VERSION}"
        ));
    }
    Ok(conn)
}

fn sync(d: &Path, conn: &mut Connection) -> Result<(), String> {
    let now = log_len(d);
    let indexed: usize = conn
        .query_row(
            "SELECT indexed_records FROM search_meta WHERE singleton = 1",
            [],
            |row| row.get(0),
        )
        .map_err(|e| e.to_string())?;
    if indexed > now {
        return Err(format!(
            "search index has {indexed} records but the log has {now}"
        ));
    }
    if indexed == now {
        return Ok(());
    }

    let entries = log_slice(d, indexed, now)?;
    let tx = conn.transaction().map_err(|e| e.to_string())?;
    {
        let mut insert = tx
            .prepare("INSERT INTO memories(rowid, date, text) VALUES (?1, ?2, ?3)")
            .map_err(|e| e.to_string())?;
        for e in entries {
            insert
                .execute(params![e.id + 1, e.date, e.text])
                .map_err(|e| e.to_string())?;
        }
    }
    tx.execute(
        "UPDATE search_meta SET indexed_records = ?1 WHERE singleton = 1",
        [now],
    )
    .map_err(|e| e.to_string())?;
    tx.commit().map_err(|e| e.to_string())
}

/// Quote every whitespace-delimited piece so callers never need FTS5 syntax.
/// FTS5's tokenizer still splits punctuation inside each piece, preserving
/// useful technical queries such as `Q4/Q5` without exposing operators.
fn plain_query(input: &str) -> String {
    input
        .split_whitespace()
        .filter(|word| word.chars().any(char::is_alphanumeric))
        .map(|word| format!("\"{}\"", word.replace('"', "\"\"")))
        .collect::<Vec<_>>()
        .join(" OR ")
}

fn find_once(d: &Path, input: &str, limit: usize) -> Result<Found, String> {
    let query = plain_query(input);
    if query.is_empty() {
        return Ok(Found {
            hits: Vec::new(),
            total: 0,
        });
    }

    let mut conn = open(d)?;
    sync(d, &mut conn)?;
    let total: usize = conn
        .query_row(
            "SELECT count(*) FROM memories WHERE memories MATCH ?1",
            [&query],
            |row| row.get(0),
        )
        .map_err(|e| e.to_string())?;
    let mut stmt = conn
        .prepare(
            "SELECT rowid - 1, date, text
             FROM memories
             WHERE memories MATCH ?1
             ORDER BY bm25(memories), rowid DESC
             LIMIT ?2",
        )
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map(params![query, limit], |row| {
            Ok(Entry {
                id: row.get(0)?,
                date: row.get(1)?,
                text: row.get(2)?,
            })
        })
        .map_err(|e| e.to_string())?;
    let hits = rows
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;
    Ok(Found { hits, total })
}

fn clear(d: &Path) -> Result<(), String> {
    for suffix in ["", "-journal", "-wal", "-shm"] {
        let mut raw = path(d).into_os_string();
        raw.push(suffix);
        let p = PathBuf::from(raw);
        match fs::remove_file(&p) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(format!("{}: {e}", p.display())),
        }
    }
    Ok(())
}

/// The index is a cache: any failure gets one clean rebuild before surfacing.
pub fn find(d: &Path, input: &str, limit: usize) -> Result<Found, String> {
    // Serialize cache maintenance with append/repair operations. Search is
    // short, and one ship-wide lock avoids a second concurrency protocol.
    let _lock = Lock::take(d)?;
    match find_once(d, input, limit) {
        Ok(found) => Ok(found),
        Err(first) => {
            clear(d)?;
            find_once(d, input, limit).map_err(|second| {
                format!("search failed after rebuilding: {second} (first: {first})")
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::plain_query;

    #[test]
    fn plain_words_become_an_or_query_without_operators() {
        assert_eq!(plain_query("Fire Q4/Q5"), "\"Fire\" OR \"Q4/Q5\"");
        assert_eq!(
            plain_query("AND \"quoted\""),
            "\"AND\" OR \"\"\"quoted\"\"\""
        );
        assert_eq!(plain_query("---"), "");
    }
}
