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

/// The most transactions one answer lists; fewer when they won't fit.
const LEDGER_ROWS: usize = 300;

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

    /// The transactions from `from` to `to`, both `YYYY-MM-DD` and
    /// inclusive, filed as the money page files them: spending and income
    /// totals, spending by category, and the transactions newest first.
    /// `category` keeps one category; `merchant` keeps the merchants whose
    /// name holds it, in any case.
    pub fn transactions(
        &self,
        from: &str,
        to: &str,
        category: Option<&str>,
        merchant: Option<&str>,
    ) -> Result<Value, String> {
        for d in [from, to] {
            chrono::NaiveDate::parse_from_str(d, "%Y-%m-%d")
                .map_err(|_| format!("{d} is not a date: YYYY-MM-DD."))?;
        }
        if from > to {
            return Err(format!("{from} is after {to}."));
        }
        let c = self.open()?;
        let e = |e: rusqlite::Error| e.to_string();
        let like = merchant.map(|m| format!("%{m}%"));
        let picked = "l.date BETWEEN ?1 AND ?2
             AND (?3 IS NULL OR l.category = ?3)
             AND (?4 IS NULL OR l.merchant LIKE ?4)";
        let args = rusqlite::params![from, to, category, like];
        let (spent, income, count): (f64, f64, i64) = c
            .query_row(
                &format!(
                    "SELECT coalesce(sum(CASE WHEN l.kind = 'spend' THEN l.amount END), 0),
                     coalesce(sum(CASE WHEN l.kind = 'income' THEN -l.amount END), 0),
                     count(*)
                     FROM ledger l WHERE {picked}"
                ),
                args,
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .map_err(e)?;
        let mut s = c
            .prepare(&format!(
                "SELECT l.category, sum(l.amount), count(*) FROM ledger l
                 WHERE {picked} AND l.kind = 'spend'
                 GROUP BY l.category ORDER BY sum(l.amount) DESC"
            ))
            .map_err(e)?;
        let categories: Vec<Value> = s
            .query_map(args, |r| {
                Ok(json!({
                    "category": r.get::<_, String>(0)?,
                    "amount": r.get::<_, f64>(1)?,
                    "count": r.get::<_, i64>(2)?,
                }))
            })
            .and_then(Iterator::collect)
            .map_err(e)?;
        let mut s = c
            .prepare(&format!(
                "SELECT l.date, l.merchant, l.amount, l.category, l.kind, l.pending, a.mask, a.name
                 FROM ledger l JOIN accounts a ON a.account_id = l.account_id
                 WHERE {picked}
                 ORDER BY l.date DESC, l.transaction_id LIMIT {LEDGER_ROWS}"
            ))
            .map_err(e)?;
        let mut accounts = serde_json::Map::new();
        let mut rows: Vec<Value> = s
            .query_map(args, |r| {
                let mask = r.get::<_, Option<String>>(6)?.unwrap_or_default();
                Ok((
                    json!([
                        r.get::<_, String>(0)?,
                        r.get::<_, Option<String>>(1)?,
                        r.get::<_, f64>(2)?,
                        r.get::<_, String>(3)?,
                        r.get::<_, String>(4)?,
                        r.get::<_, bool>(5)?,
                        mask,
                    ]),
                    (mask, r.get::<_, Option<String>>(7)?),
                ))
            })
            .and_then(Iterator::collect::<Result<Vec<_>, _>>)
            .map_err(e)?
            .into_iter()
            .map(|(row, (mask, name))| {
                accounts.insert(mask, json!(name));
                row
            })
            .collect();
        let answer = |rows: &[Value]| {
            json!({
                "from": from,
                "to": to,
                "category": category,
                "merchant": merchant,
                "spent": spent,
                "income": income,
                "count": count,
                "shown": rows.len(),
                "categories": categories,
                "accounts": accounts,
                "columns": ["date", "merchant", "amount", "category", "kind", "pending", "account"],
                "rows": rows,
            })
        };
        // The newest rows that fit whole, so the card can still read it.
        let fit = |rows: &[Value]| answer(rows).to_string().len() <= crate::model::STEP_MAX - 512;
        let mut keep = rows.len();
        while keep > 0 && !fit(&rows[..keep]) {
            keep -= keep.div_ceil(10);
        }
        rows.truncate(keep);
        Ok(answer(&rows))
    }

    /// The investment accounts: each one's value, what its holdings are
    /// worth against what they cost, and the total on each day we kept
    /// balances. `cash` is the part of an account its holdings don't
    /// account for: cash, or holdings the brokerage doesn't report.
    pub fn markets(&self) -> Result<Value, String> {
        let c = self.open()?;
        let e = |e: rusqlite::Error| e.to_string();
        let mut s = c
            .prepare(
                "SELECT h.account_id, s.ticker, s.name, s.type, h.quantity, h.price,
                 coalesce(h.price_as_of, s.close_price_as_of), h.value, h.cost_basis
                 FROM holdings h LEFT JOIN securities s ON s.security_id = h.security_id
                 ORDER BY h.value DESC",
            )
            .map_err(e)?;
        let holdings: Vec<(String, Value)> = s
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    json!({
                        "ticker": r.get::<_, Option<String>>(1)?,
                        "name": r.get::<_, Option<String>>(2)?,
                        "type": r.get::<_, Option<String>>(3)?,
                        "quantity": r.get::<_, Option<f64>>(4)?,
                        "price": r.get::<_, Option<f64>>(5)?,
                        "as_of": r.get::<_, Option<String>>(6)?,
                        "value": r.get::<_, Option<f64>>(7)?,
                        "cost": r.get::<_, Option<f64>>(8)?,
                    }),
                ))
            })
            .and_then(Iterator::collect)
            .map_err(e)?;
        let mut s = c
            .prepare(
                "SELECT a.account_id, a.name, a.mask, a.subtype, a.current, i.institution
                 FROM accounts a JOIN items i ON i.item_id = a.item_id
                 WHERE a.type = 'investment' ORDER BY a.current DESC",
            )
            .map_err(e)?;
        let accounts: Vec<Value> = s
            .query_map([], |r| {
                let id: String = r.get(0)?;
                let value: f64 = r.get::<_, Option<f64>>(4)?.unwrap_or(0.0);
                let held: Vec<&Value> = holdings
                    .iter()
                    .filter(|(a, _)| *a == id)
                    .map(|(_, h)| h)
                    .collect();
                let sum = |k: &str| held.iter().filter_map(|h| h[k].as_f64()).sum::<f64>();
                // Gain only where the brokerage gave a cost.
                let costed = held.iter().filter(|h| h["cost"].is_f64());
                let (worth, cost) = costed.fold((0.0, 0.0), |(w, c), h| {
                    (
                        w + h["value"].as_f64().unwrap_or(0.0),
                        c + h["cost"].as_f64().unwrap_or(0.0),
                    )
                });
                Ok(json!({
                    "name": r.get::<_, Option<String>>(1)?,
                    "mask": r.get::<_, Option<String>>(2)?,
                    "subtype": r.get::<_, Option<String>>(3)?,
                    "institution": r.get::<_, Option<String>>(5)?,
                    "value": value,
                    "cash": value - sum("value"),
                    "cost": cost,
                    "gain": worth - cost,
                    "holdings": held,
                }))
            })
            .and_then(Iterator::collect)
            .map_err(e)?;
        let mut s = c
            .prepare(
                "SELECT b.date, sum(b.current) FROM balances b
                 JOIN accounts a ON a.account_id = b.account_id
                 WHERE a.type = 'investment' GROUP BY b.date ORDER BY b.date",
            )
            .map_err(e)?;
        let history: Vec<Value> = s
            .query_map([], |r| {
                Ok(json!({ "date": r.get::<_, String>(0)?, "value": r.get::<_, f64>(1)? }))
            })
            .and_then(Iterator::collect)
            .map_err(e)?;
        let total = |k: &str| accounts.iter().filter_map(|a| a[k].as_f64()).sum::<f64>();
        let as_of = holdings
            .iter()
            .filter_map(|(_, h)| h["as_of"].as_str())
            .max()
            .map(str::to_owned);
        Ok(json!({
            "value": total("value"),
            "cost": total("cost"),
            "gain": total("gain"),
            "as_of": as_of,
            "accounts": accounts,
            "history": history,
        }))
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
    fn transactions_and_markets_read_as_the_page_files_them() {
        let dir = std::env::temp_dir().join(format!("yeoman-markets-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("finance.db");
        let w = Connection::open(&path).unwrap();
        w.execute_batch(
            "CREATE TABLE items (item_id TEXT, institution TEXT);
             CREATE TABLE accounts (account_id TEXT, item_id TEXT, name TEXT, mask TEXT,
                 type TEXT, subtype TEXT, current REAL);
             CREATE TABLE ledger (transaction_id TEXT, account_id TEXT, date TEXT,
                 merchant TEXT, amount REAL, pending INTEGER, category TEXT, kind TEXT);
             CREATE TABLE securities (security_id TEXT, ticker TEXT, name TEXT, type TEXT,
                 close_price_as_of TEXT);
             CREATE TABLE holdings (account_id TEXT, security_id TEXT, quantity REAL,
                 price REAL, price_as_of TEXT, value REAL, cost_basis REAL);
             CREATE TABLE balances (account_id TEXT, date TEXT, current REAL);
             INSERT INTO items VALUES ('i', 'Fidelity');
             INSERT INTO accounts VALUES ('chk', 'i', 'Checking', '1', 'depository', 'checking', 900),
                 ('roth', 'i', 'Roth', '2', 'investment', 'roth', 1100),
                 ('ind', 'i', 'Individual', '3', 'investment', 'brokerage', 500);
             INSERT INTO ledger VALUES
                 ('t1', 'chk', '2026-10-02', 'Netflix', 9.59, 0, 'Subscriptions', 'spend'),
                 ('t2', 'chk', '2026-10-05', 'Payroll', -1726.77, 0, 'Income', 'income'),
                 ('t3', 'chk', '2026-10-06', 'ShopRite', 80.0, 1, 'Food', 'spend'),
                 ('t4', 'chk', '2026-10-07', 'Amex', 500.0, 0, 'Card payments', 'move'),
                 ('t5', 'chk', '2026-09-30', 'ShopRite', 50.0, 0, 'Food', 'spend');
             INSERT INTO securities VALUES ('s', 'FZROX', 'Total Market', 'mutual fund', '2026-10-19');
             INSERT INTO holdings VALUES ('roth', 's', 40, 26.0, NULL, 1040.0, 900.0);
             INSERT INTO balances VALUES ('roth', '2026-10-19', 1000), ('ind', '2026-10-19', 480),
                 ('roth', '2026-10-20', 1100), ('ind', '2026-10-20', 500), ('chk', '2026-10-20', 900);",
        )
        .unwrap();
        let f = Finance::new(path);
        let t = f
            .transactions("2026-10-01", "2026-10-31", None, None)
            .unwrap();
        assert_eq!(
            (
                t["spent"].as_f64(),
                t["income"].as_f64(),
                t["count"].as_i64()
            ),
            (Some(89.59), Some(1726.77), Some(4))
        );
        assert_eq!(t["categories"][0]["category"], "Food");
        assert_eq!(t["rows"][0][1], "Amex");
        assert_eq!(t["rows"][0][6], "1");
        assert_eq!(t["accounts"]["1"], "Checking");
        let shop = f
            .transactions("2026-09-01", "2026-10-31", None, Some("shoprite"))
            .unwrap();
        assert_eq!(shop["spent"].as_f64(), Some(130.0));
        let food = f
            .transactions("2026-10-01", "2026-10-31", Some("Food"), None)
            .unwrap();
        assert_eq!(food["count"], 1);
        assert!(
            f.transactions("2026-10-31", "2026-10-01", None, None)
                .is_err()
        );
        assert!(f.transactions("Oct 1", "2026-10-01", None, None).is_err());

        let m = f.markets().unwrap();
        assert_eq!(m["value"].as_f64(), Some(1600.0));
        assert_eq!(m["gain"].as_f64(), Some(140.0));
        assert_eq!(m["as_of"], "2026-10-19");
        assert_eq!(m["accounts"][0]["name"], "Roth");
        assert_eq!(m["accounts"][0]["cash"].as_f64(), Some(60.0));
        assert_eq!(m["accounts"][1]["cash"].as_f64(), Some(500.0));
        assert_eq!(
            m["history"],
            json!([{"date": "2026-10-19", "value": 1480.0}, {"date": "2026-10-20", "value": 1600.0}])
        );
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
