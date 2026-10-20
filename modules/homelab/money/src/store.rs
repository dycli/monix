//! Two SQLite files. `vault/vault.db` holds each Item's access token and
//! sync cursor and is read by this service alone. `finance.db` holds what the
//! banks said, with no secret in it, so the household's assistants read it
//! through the group.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::Value;

const VAULT: &str = "
CREATE TABLE IF NOT EXISTS items (
    item_id TEXT PRIMARY KEY,
    access_token TEXT NOT NULL,
    cursor TEXT,
    created TEXT NOT NULL DEFAULT (datetime('now'))
);
-- Removed logins. Their rows stay in items: on the Trial plan a removed
-- login keeps its slot, so the count of used slots still holds them.
CREATE TABLE IF NOT EXISTS gone (
    item_id TEXT PRIMARY KEY,
    at TEXT NOT NULL DEFAULT (datetime('now'))
);";

const FINANCE: &str = "
CREATE TABLE IF NOT EXISTS items (
    item_id TEXT PRIMARY KEY,
    institution TEXT,
    products TEXT,
    status TEXT NOT NULL DEFAULT 'new',
    error TEXT,
    synced TEXT
);
CREATE TABLE IF NOT EXISTS accounts (
    account_id TEXT PRIMARY KEY,
    item_id TEXT NOT NULL,
    name TEXT,
    official_name TEXT,
    mask TEXT,
    type TEXT,
    subtype TEXT,
    current REAL,
    available REAL,
    credit_limit REAL,
    currency TEXT,
    updated TEXT
);
-- Plaid's sign: positive is money out of the account.
CREATE TABLE IF NOT EXISTS transactions (
    transaction_id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL,
    date TEXT NOT NULL,
    authorized_date TEXT,
    name TEXT,
    merchant TEXT,
    amount REAL NOT NULL,
    currency TEXT,
    category TEXT,
    detail TEXT,
    pending INTEGER NOT NULL,
    channel TEXT
);
CREATE INDEX IF NOT EXISTS transactions_date ON transactions(date);
CREATE TABLE IF NOT EXISTS securities (
    security_id TEXT PRIMARY KEY,
    ticker TEXT,
    name TEXT,
    type TEXT,
    close_price REAL,
    close_price_as_of TEXT
);
CREATE TABLE IF NOT EXISTS holdings (
    account_id TEXT NOT NULL,
    security_id TEXT NOT NULL,
    quantity REAL,
    price REAL,
    price_as_of TEXT,
    value REAL,
    cost_basis REAL,
    currency TEXT,
    PRIMARY KEY (account_id, security_id)
);
CREATE TABLE IF NOT EXISTS credit (
    account_id TEXT PRIMARY KEY,
    last_statement_balance REAL,
    last_statement_date TEXT,
    minimum_payment REAL,
    next_due_date TEXT,
    last_payment_amount REAL,
    last_payment_date TEXT,
    is_overdue INTEGER,
    aprs TEXT
);";

pub struct Store {
    pub vault: Connection,
    pub finance: Connection,
}

fn text(v: &Value) -> Option<&str> {
    v.as_str()
}

impl Store {
    pub fn open(dir: &Path) -> Result<Self, String> {
        let open = |name: &str, schema: &str| -> Result<Connection, String> {
            let c = Connection::open(dir.join(name)).map_err(|e| format!("{name}: {e}"))?;
            c.busy_timeout(std::time::Duration::from_secs(10))
                .and_then(|()| c.execute_batch(schema))
                .map_err(|e| format!("{name}: {e}"))?;
            Ok(c)
        };
        // The group may enter the state folder but not the vault folder;
        // SQLite's journals sit beside their database, so the tokens' journal
        // stays private too.
        let mode = |path: &Path, bits: u32| {
            fs::set_permissions(path, fs::Permissions::from_mode(bits))
                .map_err(|e| format!("{}: {e}", path.display()))
        };
        mode(dir, 0o750)?;
        let vault = dir.join("vault");
        fs::create_dir_all(&vault).map_err(|e| format!("{}: {e}", vault.display()))?;
        mode(&vault, 0o700)?;
        // Before the vault had its own folder it sat beside finance.db.
        if dir.join("vault.db").exists() && !vault.join("vault.db").exists() {
            fs::rename(dir.join("vault.db"), vault.join("vault.db")).map_err(|e| e.to_string())?;
        }
        let finance = open("finance.db", FINANCE)?;
        // A rollback journal, not WAL: a WAL reader needs write access to
        // the shared-memory file, and readers here only get to read.
        finance
            .pragma_update(None, "journal_mode", "delete")
            .map_err(|e| e.to_string())?;
        mode(&dir.join("finance.db"), 0o640)?;
        Ok(Self {
            vault: open("vault/vault.db", VAULT)?,
            finance,
        })
    }

    /// Opens the databases and brings the money page's tables, view and
    /// category list up to this build. Once at start, not per request:
    /// rebuilding the view is a write.
    pub fn prepare(dir: &Path) -> Result<Self, String> {
        let s = Self::open(dir)?;
        s.finance
            .execute_batch(crate::money::SCHEMA)
            .map_err(|e| format!("finance.db: {e}"))?;
        crate::money::seed(&s.finance)?;
        Ok(s)
    }

    /// Every Item ever linked; on the Trial plan this is the count of used slots.
    pub fn slots(&self) -> Result<i64, String> {
        self.vault
            .query_row("SELECT count(*) FROM items", [], |r| r.get(0))
            .map_err(|e| e.to_string())
    }

    pub fn add(&self, item: &str, token: &str) -> Result<(), String> {
        self.vault
            .execute(
                "INSERT OR REPLACE INTO items (item_id, access_token) VALUES (?1, ?2)",
                params![item, token],
            )
            .and_then(|_| {
                self.finance.execute(
                    "INSERT OR IGNORE INTO items (item_id) VALUES (?1)",
                    params![item],
                )
            })
            .map(drop)
            .map_err(|e| e.to_string())
    }

    pub fn items(&self) -> Result<Vec<String>, String> {
        let mut q = self
            .vault
            .prepare(
                "SELECT item_id FROM items WHERE item_id NOT IN (SELECT item_id FROM gone)
                 ORDER BY created",
            )
            .map_err(|e| e.to_string())?;
        q.query_map([], |r| r.get(0))
            .and_then(Iterator::collect)
            .map_err(|e| e.to_string())
    }

    /// Forgets a removed login: its token, and every row its accounts
    /// brought, so nothing it held is counted.
    pub fn remove(&mut self, item: &str) -> Result<(), String> {
        let e = |e: rusqlite::Error| e.to_string();
        let t = self.finance.transaction().map_err(e)?;
        let mine = "(SELECT account_id FROM accounts WHERE item_id = ?1)";
        t.execute(
            &format!(
                "DELETE FROM overrides WHERE transaction_id IN
                 (SELECT transaction_id FROM transactions WHERE account_id IN {mine})"
            ),
            params![item],
        )
        .map_err(e)?;
        for table in [
            "transactions",
            "holdings",
            "credit",
            "balances",
            "not_recurring",
        ] {
            t.execute(
                &format!("DELETE FROM {table} WHERE account_id IN {mine}"),
                params![item],
            )
            .map_err(e)?;
        }
        t.execute("DELETE FROM accounts WHERE item_id = ?1", params![item])
            .map_err(e)?;
        t.execute("DELETE FROM items WHERE item_id = ?1", params![item])
            .map_err(e)?;
        t.commit().map_err(e)?;
        self.vault
            .execute(
                "INSERT OR IGNORE INTO gone (item_id) VALUES (?1)",
                params![item],
            )
            .and_then(|_| {
                self.vault.execute(
                    "UPDATE items SET access_token = '', cursor = NULL WHERE item_id = ?1",
                    params![item],
                )
            })
            .map(drop)
            .map_err(e)
    }

    pub fn token(&self, item: &str) -> Result<(String, Option<String>), String> {
        self.vault
            .query_row(
                "SELECT access_token, cursor FROM items WHERE item_id = ?1",
                params![item],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .map_err(|e| format!("{item}: {e}"))
    }

    pub fn known_institution(&self, item: &str) -> Option<String> {
        self.finance
            .query_row(
                "SELECT institution FROM items WHERE item_id = ?1",
                params![item],
                |r| r.get(0),
            )
            .optional()
            .ok()
            .flatten()
            .flatten()
    }

    pub fn describe(&self, item: &str, institution: &str, products: &str) -> Result<(), String> {
        self.finance
            .execute(
                "UPDATE items SET institution = ?2, products = ?3 WHERE item_id = ?1",
                params![item, institution, products],
            )
            .map(drop)
            .map_err(|e| e.to_string())
    }

    /// How the last sync went: `ok`, `login` (the bank wants a fresh login,
    /// through update mode) or `error`.
    pub fn status(&self, item: &str, status: &str, error: Option<&str>) -> Result<(), String> {
        self.finance
            .execute(
                "UPDATE items SET status = ?2, error = ?3,
                 synced = CASE WHEN ?2 = 'ok' THEN datetime('now') ELSE synced END
                 WHERE item_id = ?1",
                params![item, status, error],
            )
            .map(drop)
            .map_err(|e| e.to_string())
    }

    pub fn accounts(&self, item: &str, accounts: &[Value]) -> Result<(), String> {
        let mut q = self
            .finance
            .prepare(
                "INSERT INTO accounts (account_id, item_id, name, official_name, mask, type,
                 subtype, current, available, credit_limit, currency, updated)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, datetime('now'))
                 ON CONFLICT (account_id) DO UPDATE SET name = ?3, official_name = ?4,
                 mask = ?5, type = ?6, subtype = ?7, current = ?8, available = ?9,
                 credit_limit = ?10, currency = ?11, updated = datetime('now')",
            )
            .map_err(|e| e.to_string())?;
        for a in accounts {
            let b = &a["balances"];
            q.execute(params![
                text(&a["account_id"]),
                item,
                text(&a["name"]),
                text(&a["official_name"]),
                text(&a["mask"]),
                text(&a["type"]),
                text(&a["subtype"]),
                b["current"].as_f64(),
                b["available"].as_f64(),
                b["limit"].as_f64(),
                text(&b["iso_currency_code"]),
            ])
            .map_err(|e| e.to_string())?;
        }
        crate::money::snapshot(&self.finance)
    }

    /// One `/transactions/sync` run's changes and the cursor after them, in
    /// one transaction, so a crash never saves a cursor past unsaved rows.
    pub fn transactions(
        &mut self,
        item: &str,
        changed: &[Value],
        removed: &[Value],
        cursor: &str,
    ) -> Result<(), String> {
        let t = self.finance.transaction().map_err(|e| e.to_string())?;
        {
            let mut put = t
                .prepare(
                    "INSERT OR REPLACE INTO transactions (transaction_id, account_id, date,
                     authorized_date, name, merchant, amount, currency, category, detail,
                     pending, channel)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                )
                .map_err(|e| e.to_string())?;
            for x in changed {
                let pfc = &x["personal_finance_category"];
                put.execute(params![
                    text(&x["transaction_id"]),
                    text(&x["account_id"]),
                    text(&x["date"]),
                    text(&x["authorized_date"]),
                    text(&x["name"]),
                    text(&x["merchant_name"]),
                    x["amount"].as_f64(),
                    text(&x["iso_currency_code"]),
                    text(&pfc["primary"]),
                    text(&pfc["detailed"]),
                    x["pending"].as_bool().unwrap_or(false),
                    text(&x["payment_channel"]),
                ])
                .map_err(|e| e.to_string())?;
            }
            let mut drop_ = t
                .prepare("DELETE FROM transactions WHERE transaction_id = ?1")
                .map_err(|e| e.to_string())?;
            for x in removed {
                drop_
                    .execute(params![text(&x["transaction_id"])])
                    .map_err(|e| e.to_string())?;
            }
        }
        t.commit().map_err(|e| e.to_string())?;
        self.vault
            .execute(
                "UPDATE items SET cursor = ?2 WHERE item_id = ?1",
                params![item, cursor],
            )
            .map(drop)
            .map_err(|e| e.to_string())
    }

    /// Replaces the Item's holdings with Plaid's current list.
    pub fn holdings(
        &mut self,
        item: &str,
        holdings: &[Value],
        securities: &[Value],
    ) -> Result<(), String> {
        let t = self.finance.transaction().map_err(|e| e.to_string())?;
        {
            let mut sec = t
                .prepare(
                    "INSERT OR REPLACE INTO securities (security_id, ticker, name, type,
                     close_price, close_price_as_of) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                )
                .map_err(|e| e.to_string())?;
            for s in securities {
                sec.execute(params![
                    text(&s["security_id"]),
                    text(&s["ticker_symbol"]),
                    text(&s["name"]),
                    text(&s["type"]),
                    s["close_price"].as_f64(),
                    text(&s["close_price_as_of"]),
                ])
                .map_err(|e| e.to_string())?;
            }
            t.execute(
                "DELETE FROM holdings WHERE account_id IN
                 (SELECT account_id FROM accounts WHERE item_id = ?1)",
                params![item],
            )
            .map_err(|e| e.to_string())?;
            let mut put = t
                .prepare(
                    "INSERT OR REPLACE INTO holdings (account_id, security_id, quantity, price,
                     price_as_of, value, cost_basis, currency)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                )
                .map_err(|e| e.to_string())?;
            for h in holdings {
                put.execute(params![
                    text(&h["account_id"]),
                    text(&h["security_id"]),
                    h["quantity"].as_f64(),
                    h["institution_price"].as_f64(),
                    text(&h["institution_price_as_of"]),
                    h["institution_value"].as_f64(),
                    h["cost_basis"].as_f64(),
                    text(&h["iso_currency_code"]),
                ])
                .map_err(|e| e.to_string())?;
            }
        }
        t.commit().map_err(|e| e.to_string())
    }

    pub fn credit(&self, cards: &[Value]) -> Result<(), String> {
        let mut q = self
            .finance
            .prepare(
                "INSERT OR REPLACE INTO credit (account_id, last_statement_balance,
                 last_statement_date, minimum_payment, next_due_date, last_payment_amount,
                 last_payment_date, is_overdue, aprs)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            )
            .map_err(|e| e.to_string())?;
        for c in cards {
            q.execute(params![
                text(&c["account_id"]),
                c["last_statement_balance"].as_f64(),
                text(&c["last_statement_issue_date"]),
                c["minimum_payment_amount"].as_f64(),
                text(&c["next_payment_due_date"]),
                c["last_payment_amount"].as_f64(),
                text(&c["last_payment_date"]),
                c["is_overdue"].as_bool(),
                c["aprs"].to_string(),
            ])
            .map_err(|e| e.to_string())?;
        }
        Ok(())
    }

    /// The page's view: each Item with its accounts, and accounts that look
    /// like the same account linked through two logins (a joint card linked
    /// by both of us), which would count its money twice.
    pub fn overview(&self) -> Result<Value, String> {
        let mut q = self
            .finance
            .prepare(
                "SELECT i.item_id, i.institution, i.products, i.status, i.error, i.synced,
                 a.name, a.mask, a.type, a.subtype, a.current, a.currency,
                 EXISTS (SELECT 1 FROM accounts b JOIN items j ON j.item_id = b.item_id
                         WHERE b.item_id != a.item_id AND j.institution = i.institution
                         AND b.mask = a.mask AND b.type = a.type AND b.subtype IS a.subtype),
                 (SELECT count(*) FROM transactions t WHERE t.account_id = a.account_id),
                 (SELECT count(*) FROM holdings h WHERE h.account_id = a.account_id)
                 FROM items i LEFT JOIN accounts a ON a.item_id = i.item_id
                 WHERE i.item_id != 'manual'
                 ORDER BY i.rowid, a.type, a.name",
            )
            .map_err(|e| e.to_string())?;
        let rows = q
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    serde_json::json!({
                        "institution": r.get::<_, Option<String>>(1)?,
                        "products": r.get::<_, Option<String>>(2)?,
                        "status": r.get::<_, String>(3)?,
                        "error": r.get::<_, Option<String>>(4)?,
                        "synced": r.get::<_, Option<String>>(5)?,
                    }),
                    r.get::<_, Option<String>>(6)?
                        .map(|name| -> rusqlite::Result<Value> {
                            Ok(serde_json::json!({
                                "name": name,
                                "mask": r.get::<_, Option<String>>(7)?,
                                "type": r.get::<_, Option<String>>(8)?,
                                "subtype": r.get::<_, Option<String>>(9)?,
                                "balance": r.get::<_, Option<f64>>(10)?,
                                "currency": r.get::<_, Option<String>>(11)?,
                                "duplicate": r.get::<_, bool>(12)?,
                                "transactions": r.get::<_, i64>(13)?,
                                "holdings": r.get::<_, i64>(14)?,
                            }))
                        }),
                ))
            })
            .map_err(|e| e.to_string())?;
        let mut items: Vec<(String, Value)> = Vec::new();
        for row in rows {
            let (id, item, account) = row.map_err(|e| e.to_string())?;
            if items.last().is_none_or(|(last, _)| *last != id) {
                let mut item = item;
                item["id"] = Value::from(id.clone());
                item["accounts"] = Value::Array(Vec::new());
                items.push((id, item));
            }
            if let Some(account) = account {
                let account = account.map_err(|e| e.to_string())?;
                if let Some(list) = items
                    .last_mut()
                    .and_then(|(_, i)| i["accounts"].as_array_mut())
                {
                    list.push(account);
                }
            }
        }
        Ok(Value::Array(items.into_iter().map(|(_, i)| i).collect()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn sync_keeps_rows_and_flags_joint_accounts() {
        let dir = std::env::temp_dir().join(format!("money-store-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut s = Store::prepare(&dir).unwrap();
        for (item, inst) in [("i1", "Amex"), ("i2", "Amex")] {
            s.add(item, "tok").unwrap();
            s.describe(item, inst, "transactions").unwrap();
            let card = json!({"account_id": format!("{item}-a"), "name": "Gold", "mask": "1001",
                "type": "credit", "subtype": "credit card", "balances": {"current": 12.5}});
            s.accounts(item, &[card]).unwrap();
        }
        let t = json!({"transaction_id": "t1", "account_id": "i1-a", "date": "2026-10-01",
            "amount": 4.25, "pending": false, "personal_finance_category": {"primary": "FOOD_AND_DRINK"}});
        s.transactions(
            "i1",
            &[
                t.clone(),
                json!({"transaction_id": "t2", "account_id": "i1-a",
            "date": "2026-10-02", "amount": 1.0, "pending": true}),
            ],
            &[],
            "c1",
        )
        .unwrap();
        s.transactions("i1", &[], &[json!({"transaction_id": "t2"})], "c2")
            .unwrap();
        let n: i64 = s
            .finance
            .query_row("SELECT count(*) FROM transactions", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1);
        assert_eq!(s.token("i1").unwrap().1.as_deref(), Some("c2"));
        assert_eq!(s.slots().unwrap(), 2);
        let o = s.overview().unwrap();
        assert_eq!(o.as_array().unwrap().len(), 2);
        assert_eq!(o[0]["accounts"][0]["duplicate"], json!(true));

        s.remove("i1").unwrap();
        let o = s.overview().unwrap();
        assert_eq!(o.as_array().unwrap().len(), 1);
        assert_eq!(o[0]["accounts"][0]["duplicate"], json!(false));
        let n: i64 = s
            .finance
            .query_row("SELECT count(*) FROM transactions", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 0);
        assert_eq!(s.items().unwrap(), ["i2"]);
        assert_eq!(s.slots().unwrap(), 2, "a removed login keeps its slot");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
