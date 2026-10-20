//! The household's money, read from the money service's finance.db: accounts,
//! transactions, holdings and card statements. Opened read-only; the file's
//! group is the only grant, and the bank tokens live elsewhere. Changes go
//! to the service itself, through `Ledger`.

use rusqlite::types::ValueRef;
use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Rows one answer carries; past it the model narrows or aggregates.
const ROWS: usize = 200;

pub struct Finance {
    db: PathBuf,
}

impl Finance {
    pub fn new(db: PathBuf) -> Self {
        Self { db }
    }

    fn open(&self) -> Result<Connection, String> {
        let c = Connection::open_with_flags(
            &self.db,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .map_err(|e| format!("finance: {e}"))?;
        // A sync may be writing; wait it out rather than fail.
        c.busy_timeout(Duration::from_secs(10))
            .and_then(|()| c.pragma_update(None, "query_only", true))
            .map_err(|e| format!("finance: {e}"))?;
        Ok(c)
    }

    /// The tables, as the CREATE statements that made them.
    pub fn schema(&self) -> Result<String, String> {
        let c = self.open()?;
        let mut s = c
            .prepare(
                "SELECT sql FROM sqlite_schema WHERE type IN ('table', 'view') AND sql IS NOT NULL",
            )
            .map_err(|e| e.to_string())?;
        let tables: Vec<String> = s
            .query_map([], |r| r.get(0))
            .and_then(Iterator::collect)
            .map_err(|e| e.to_string())?;
        Ok(tables.join(";\n\n") + ";")
    }

    /// One SELECT, answered as columns and rows, at most ROWS of them.
    pub fn query(&self, sql: &str) -> Result<String, String> {
        query(&self.open()?, sql).map(|v| v.to_string())
    }
}

fn query(c: &Connection, sql: &str) -> Result<Value, String> {
    let mut s = c.prepare(sql).map_err(|e| e.to_string())?;
    if !s.readonly() {
        return Err("Only reading: SELECT or WITH.".into());
    }
    let columns: Vec<String> = s.column_names().iter().map(|n| n.to_string()).collect();
    let width = columns.len();
    let mut rows = Vec::new();
    let mut more = false;
    let mut found = s.query([]).map_err(|e| e.to_string())?;
    while let Some(row) = found.next().map_err(|e| e.to_string())? {
        if rows.len() == ROWS {
            more = true;
            break;
        }
        let cells = (0..width)
            .map(|i| {
                row.get_ref(i).map(|v| match v {
                    ValueRef::Null => Value::Null,
                    ValueRef::Integer(n) => json!(n),
                    ValueRef::Real(x) => json!(x),
                    ValueRef::Text(t) => json!(String::from_utf8_lossy(t)),
                    ValueRef::Blob(b) => json!(format!("<{} bytes>", b.len())),
                })
            })
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?;
        rows.push(cells);
    }
    Ok(json!({ "columns": columns, "rows": rows, "more": more }))
}

/// Where finance.db is, when YEOMAN_FINANCE names it.
pub fn from_env() -> Option<Finance> {
    std::env::var_os("YEOMAN_FINANCE").map(|p| Finance::new(Path::new(&p).to_path_buf()))
}

/// The money page's write side, asked over the money service's socket. The
/// service checks every change, so this only carries them.
pub struct Ledger {
    sock: PathBuf,
}

impl Ledger {
    /// POSTs one change to `/api/<what>` and answers the service's JSON, or
    /// its refusal.
    pub fn change(&self, what: &str, body: &Value) -> Result<String, String> {
        let mut conn = UnixStream::connect(&self.sock)
            .map_err(|e| format!("money at {}: {e}", self.sock.display()))?;
        conn.set_read_timeout(Some(Duration::from_secs(30)))
            .map_err(|e| e.to_string())?;
        let body = body.to_string();
        write!(
            conn,
            "POST /api/{what} HTTP/1.1\r\nHost: money\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
        .map_err(|e| e.to_string())?;
        let mut raw = String::new();
        conn.read_to_string(&mut raw).map_err(|e| e.to_string())?;
        let (head, text) = raw.split_once("\r\n\r\n").ok_or("money: no reply")?;
        let status = head.split(' ').nth(1).unwrap_or("");
        if status.starts_with('2') {
            Ok(if text.is_empty() {
                "{}".into()
            } else {
                text.into()
            })
        } else {
            Err(format!("money refused ({status}): {text}"))
        }
    }
}

pub fn ledger_from_env() -> Option<Ledger> {
    std::env::var_os("YEOMAN_MONEY").map(|p| Ledger {
        sock: PathBuf::from(p),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_but_never_writes() {
        let dir = std::env::temp_dir().join(format!("yeoman-finance-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("finance.db");
        let w = Connection::open(&path).unwrap();
        w.execute_batch(
            "CREATE TABLE accounts (name TEXT, balance REAL);
             INSERT INTO accounts VALUES ('Checking', 12.5), ('Card', NULL);",
        )
        .unwrap();
        let f = Finance::new(path);
        assert!(f.schema().unwrap().contains("CREATE TABLE accounts"));
        let v: Value = serde_json::from_str(&f.query("SELECT * FROM accounts").unwrap()).unwrap();
        assert_eq!(v["rows"], json!([["Checking", 12.5], ["Card", null]]));
        assert_eq!(v["more"], json!(false));
        assert!(f.query("DELETE FROM accounts").is_err());
        assert!(f.query("UPDATE accounts SET balance = 0").is_err());
        let all = (0..ROWS + 5)
            .map(|i| format!("SELECT {i}"))
            .collect::<Vec<_>>()
            .join(" UNION ALL ");
        let v: Value = serde_json::from_str(&f.query(&all).unwrap()).unwrap();
        assert_eq!(v["rows"].as_array().unwrap().len(), ROWS);
        assert_eq!(v["more"], json!(true));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn carries_changes_and_refusals() {
        use std::io::{BufRead, BufReader};
        use std::os::unix::net::UnixListener;
        let sock = std::env::temp_dir().join(format!("yeoman-money-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&sock);
        let listener = UnixListener::bind(&sock).unwrap();
        let server = std::thread::spawn(move || {
            let mut asked = Vec::new();
            for reply in [
                "HTTP/1.1 200 OK\r\ncontent-length: 11\r\n\r\n{\"id\":\"m1\"}",
                "HTTP/1.1 400 Bad Request\r\ncontent-length: 12\r\n\r\nno such kind",
            ] {
                let (mut c, _) = listener.accept().unwrap();
                let mut r = BufReader::new(c.try_clone().unwrap());
                let mut line = String::new();
                r.read_line(&mut line).unwrap();
                asked.push(line);
                c.write_all(reply.as_bytes()).unwrap();
                // Closing with the body unread would reset the connection.
                c.shutdown(std::net::Shutdown::Write).unwrap();
                r.read_to_end(&mut Vec::new()).unwrap();
            }
            asked
        });
        let l = Ledger { sock: sock.clone() };
        assert_eq!(
            l.change("manual", &json!({"name": "House"})).unwrap(),
            "{\"id\":\"m1\"}"
        );
        let e = l.change("manual", &json!({"kind": "boat"})).unwrap_err();
        assert!(e.contains("400") && e.contains("no such kind"), "{e}");
        assert_eq!(server.join().unwrap()[0], "POST /api/manual HTTP/1.1\r\n");
        std::fs::remove_file(sock).unwrap();
    }
}
