//! The money page's side of `finance.db`: our own short category list, the
//! choices we make on top of Plaid's guesses, a daily balance per account
//! (Plaid only ever gives today's), and the reads the page draws from.
//!
//! A transaction's category is, in order: the one picked for it on the
//! page, the rule for its merchant, then Plaid's guess mapped onto our list.
//! The `ledger` view does that once, so the page and the yeomen (who read
//! `finance.db` directly) always agree.

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

/// What a category does to the month's totals: `spend` counts as spending,
/// `income` as income, and `move` is money between our own accounts (card
/// payments, transfers), which counted would show twice.
const CATEGORIES: &[(&str, &str)] = &[
    ("Income", "income"),
    ("Housing", "spend"),
    ("Utilities", "spend"),
    ("Groceries", "spend"),
    ("Dining", "spend"),
    ("Transport", "spend"),
    ("Travel", "spend"),
    ("Shopping", "spend"),
    ("Entertainment", "spend"),
    ("Health", "spend"),
    ("Personal care", "spend"),
    ("Services", "spend"),
    ("Home", "spend"),
    ("Fees", "spend"),
    ("Taxes & giving", "spend"),
    ("Other", "spend"),
    ("Card payments", "move"),
    ("Loan payments", "move"),
    ("Transfers", "move"),
];

/// Plaid's personal finance categories onto ours. A detailed code wins over
/// its primary; anything unlisted lands in Other.
const PLAID: &[(&str, &str)] = &[
    ("INCOME", "Income"),
    ("TRANSFER_IN", "Transfers"),
    ("TRANSFER_OUT", "Transfers"),
    ("LOAN_DISBURSEMENTS", "Transfers"),
    ("LOAN_PAYMENTS", "Loan payments"),
    ("LOAN_PAYMENTS_CREDIT_CARD_PAYMENT", "Card payments"),
    ("BANK_FEES", "Fees"),
    ("ENTERTAINMENT", "Entertainment"),
    ("FOOD_AND_DRINK", "Dining"),
    ("FOOD_AND_DRINK_GROCERIES", "Groceries"),
    ("GENERAL_MERCHANDISE", "Shopping"),
    ("HOME_IMPROVEMENT", "Home"),
    ("MEDICAL", "Health"),
    ("PERSONAL_CARE", "Personal care"),
    ("GENERAL_SERVICES", "Services"),
    ("GOVERNMENT_AND_NON_PROFIT", "Taxes & giving"),
    ("TRANSPORTATION", "Transport"),
    ("TRAVEL", "Travel"),
    ("RENT_AND_UTILITIES", "Utilities"),
    ("RENT_AND_UTILITIES_RENT", "Housing"),
];

pub const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS categories (
    name TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    rank INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS category_map (
    code TEXT PRIMARY KEY,
    category TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS overrides (
    transaction_id TEXT PRIMARY KEY,
    category TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS rules (
    merchant TEXT PRIMARY KEY,
    category TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS balances (
    account_id TEXT NOT NULL,
    date TEXT NOT NULL,
    current REAL,
    PRIMARY KEY (account_id, date)
);
DROP VIEW IF EXISTS ledger;
CREATE VIEW ledger AS
SELECT t.transaction_id, t.account_id, t.date, t.name,
       coalesce(t.merchant, t.name) AS merchant, t.amount, t.pending,
       coalesce(c.name, 'Other') AS category, coalesce(c.kind, 'spend') AS kind,
       CASE WHEN o.category IS NOT NULL THEN 'picked'
            WHEN r.category IS NOT NULL THEN 'rule'
            ELSE 'plaid' END AS source
FROM transactions t
LEFT JOIN overrides o ON o.transaction_id = t.transaction_id
LEFT JOIN rules r ON r.merchant = coalesce(t.merchant, t.name)
LEFT JOIN category_map d ON d.code = t.detail
LEFT JOIN category_map p ON p.code = t.category
-- A rule naming a category this build no longer has falls to Other.
LEFT JOIN categories c ON c.name = coalesce(o.category, r.category, d.category, p.category);
";

/// Writes the category list and Plaid's mapping as this build has them.
pub fn seed(c: &Connection) -> Result<(), String> {
    let t = c.unchecked_transaction().map_err(|e| e.to_string())?;
    t.execute("DELETE FROM categories", [])
        .and_then(|_| t.execute("DELETE FROM category_map", []))
        .map_err(|e| e.to_string())?;
    for (rank, (name, kind)) in CATEGORIES.iter().enumerate() {
        t.execute(
            "INSERT INTO categories (name, kind, rank) VALUES (?1, ?2, ?3)",
            params![name, kind, rank],
        )
        .map_err(|e| e.to_string())?;
    }
    for (code, category) in PLAID {
        t.execute(
            "INSERT INTO category_map (code, category) VALUES (?1, ?2)",
            params![code, category],
        )
        .map_err(|e| e.to_string())?;
    }
    t.commit().map_err(|e| e.to_string())
}

/// Today's balance for each account, kept once a day (the last sync wins).
pub fn snapshot(c: &Connection) -> Result<(), String> {
    c.execute(
        "INSERT OR REPLACE INTO balances (account_id, date, current)
         SELECT account_id, date('now', 'localtime'), current FROM accounts
         WHERE current IS NOT NULL",
        [],
    )
    .map(drop)
    .map_err(|e| e.to_string())
}

/// Debts are the balances we owe; everything else is an asset.
const DEBT: &str = "type IN ('credit', 'loan')";

/// Files a transaction under a category: just this one, or every one from
/// its merchant, now and later.
pub fn categorize(
    c: &Connection,
    transaction: &str,
    category: &str,
    every: bool,
) -> Result<(), String> {
    let known: bool = c
        .query_row(
            "SELECT 1 FROM categories WHERE name = ?1",
            params![category],
            |_| Ok(true),
        )
        .optional()
        .map_err(|e| e.to_string())?
        .unwrap_or(false);
    if !known {
        return Err(format!("no category {category}"));
    }
    let merchant: String = c
        .query_row(
            "SELECT merchant FROM ledger WHERE transaction_id = ?1",
            params![transaction],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("no transaction {transaction}"))?;
    let t = c.unchecked_transaction().map_err(|e| e.to_string())?;
    if every {
        // The rule decides from now on; a single pick for this merchant
        // would hide it.
        t.execute(
            "INSERT OR REPLACE INTO rules (merchant, category) VALUES (?1, ?2)",
            params![merchant, category],
        )
        .and_then(|_| {
            t.execute(
                "DELETE FROM overrides WHERE transaction_id IN
                 (SELECT transaction_id FROM ledger WHERE merchant = ?1)",
                params![merchant],
            )
        })
    } else {
        t.execute(
            "INSERT OR REPLACE INTO overrides (transaction_id, category) VALUES (?1, ?2)",
            params![transaction, category],
        )
    }
    .map_err(|e| e.to_string())?;
    t.commit().map_err(|e| e.to_string())
}

fn rows(
    c: &Connection,
    sql: &str,
    args: &[&dyn rusqlite::ToSql],
    f: impl Fn(&rusqlite::Row) -> rusqlite::Result<Value>,
) -> Result<Vec<Value>, String> {
    let mut q = c.prepare(sql).map_err(|e| e.to_string())?;
    q.query_map(args, |r| f(r))
        .and_then(Iterator::collect)
        .map_err(|e| e.to_string())
}

/// Everything the page shows, for one month (`YYYY-MM`).
pub fn page(c: &Connection, month: &str) -> Result<Value, String> {
    let accounts = rows(
        c,
        &format!(
            "SELECT a.account_id, a.name, a.mask, a.type, a.subtype, a.current, a.credit_limit,
             i.institution, k.next_due_date, k.minimum_payment, k.last_statement_balance, k.aprs,
             {DEBT}
             FROM accounts a JOIN items i ON i.item_id = a.item_id
             LEFT JOIN credit k ON k.account_id = a.account_id
             ORDER BY {DEBT}, a.type, a.current DESC"
        ),
        &[],
        |r| {
            Ok(json!({
                "id": r.get::<_, String>(0)?,
                "name": r.get::<_, Option<String>>(1)?,
                "mask": r.get::<_, Option<String>>(2)?,
                "type": r.get::<_, Option<String>>(3)?,
                "subtype": r.get::<_, Option<String>>(4)?,
                "balance": r.get::<_, Option<f64>>(5)?,
                "limit": r.get::<_, Option<f64>>(6)?,
                "institution": r.get::<_, Option<String>>(7)?,
                "due": r.get::<_, Option<String>>(8)?,
                "minimum": r.get::<_, Option<f64>>(9)?,
                "statement": r.get::<_, Option<f64>>(10)?,
                "apr": purchase_apr(r.get::<_, Option<String>>(11)?.as_deref()),
                "debt": r.get::<_, bool>(12)?,
            }))
        },
    )?;

    // Net worth on each day we kept balances.
    let worth = rows(
        c,
        &format!(
            "SELECT b.date,
             sum(CASE WHEN a.{DEBT} THEN 0 ELSE b.current END),
             sum(CASE WHEN a.{DEBT} THEN b.current ELSE 0 END)
             FROM balances b JOIN accounts a ON a.account_id = b.account_id
             GROUP BY b.date ORDER BY b.date"
        ),
        &[],
        |r| {
            Ok(json!({
                "date": r.get::<_, String>(0)?,
                "assets": r.get::<_, f64>(1)?,
                "debts": r.get::<_, f64>(2)?,
            }))
        },
    )?;

    // Plaid's amounts are positive for money out; income and spending are
    // both shown as positive numbers.
    let months = rows(
        c,
        "SELECT substr(date, 1, 7) AS m,
         coalesce(sum(CASE WHEN kind = 'income' THEN -amount END), 0),
         coalesce(sum(CASE WHEN kind = 'spend' THEN amount END), 0)
         FROM ledger GROUP BY m ORDER BY m DESC LIMIT 12",
        &[],
        |r| {
            Ok(json!({
                "month": r.get::<_, String>(0)?,
                "income": r.get::<_, f64>(1)?,
                "spending": r.get::<_, f64>(2)?,
            }))
        },
    )?;

    let categories = rows(
        c,
        "SELECT c.name, c.kind, coalesce(sum(l.amount), 0), count(l.transaction_id)
         FROM categories c LEFT JOIN ledger l
           ON l.category = c.name AND substr(l.date, 1, 7) = ?1
         GROUP BY c.name ORDER BY c.rank",
        &[&month],
        |r| {
            Ok(json!({
                "name": r.get::<_, String>(0)?,
                "kind": r.get::<_, String>(1)?,
                "amount": r.get::<_, f64>(2)?,
                "count": r.get::<_, i64>(3)?,
            }))
        },
    )?;

    let transactions = rows(
        c,
        "SELECT l.transaction_id, l.date, l.merchant, l.name, l.amount, l.pending,
         l.category, l.source, a.name, a.mask
         FROM ledger l JOIN accounts a ON a.account_id = l.account_id
         WHERE substr(l.date, 1, 7) = ?1
         ORDER BY l.date DESC, l.transaction_id",
        &[&month],
        |r| {
            Ok(json!({
                "id": r.get::<_, String>(0)?,
                "date": r.get::<_, String>(1)?,
                "merchant": r.get::<_, Option<String>>(2)?,
                "name": r.get::<_, Option<String>>(3)?,
                "amount": r.get::<_, f64>(4)?,
                "pending": r.get::<_, bool>(5)?,
                "category": r.get::<_, String>(6)?,
                "source": r.get::<_, String>(7)?,
                "account": r.get::<_, Option<String>>(8)?,
                "mask": r.get::<_, Option<String>>(9)?,
            }))
        },
    )?;

    let holdings = rows(
        c,
        "SELECT a.name, a.mask, s.ticker, s.name, s.type, h.quantity, h.price, h.value, h.cost_basis
         FROM holdings h JOIN accounts a ON a.account_id = h.account_id
         LEFT JOIN securities s ON s.security_id = h.security_id
         ORDER BY h.value DESC",
        &[],
        |r| {
            Ok(json!({
                "account": r.get::<_, Option<String>>(0)?,
                "mask": r.get::<_, Option<String>>(1)?,
                "ticker": r.get::<_, Option<String>>(2)?,
                "name": r.get::<_, Option<String>>(3)?,
                "type": r.get::<_, Option<String>>(4)?,
                "quantity": r.get::<_, Option<f64>>(5)?,
                "price": r.get::<_, Option<f64>>(6)?,
                "value": r.get::<_, Option<f64>>(7)?,
                "cost": r.get::<_, Option<f64>>(8)?,
            }))
        },
    )?;

    let synced: Option<String> = c
        .query_row("SELECT max(synced) FROM items", [], |r| r.get(0))
        .map_err(|e| e.to_string())?;

    Ok(json!({
        "month": month,
        "synced": synced,
        "accounts": accounts,
        "worth": worth,
        "months": months,
        "categories": categories,
        "transactions": transactions,
        "holdings": holdings,
    }))
}

/// The purchase APR from Plaid's list of a card's APRs, kept as JSON text.
fn purchase_apr(aprs: Option<&str>) -> Option<f64> {
    let list: Value = serde_json::from_str(aprs?).ok()?;
    list.as_array()?
        .iter()
        .find(|a| a["apr_type"] == "purchase_apr")
        .and_then(|a| a["apr_percentage"].as_f64())
}

#[cfg(test)]
mod tests {
    use crate::store::Store;
    use serde_json::json;

    #[test]
    fn picks_and_rules_beat_plaid_and_totals_skip_moves() {
        let dir = std::env::temp_dir().join(format!("money-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut s = Store::prepare(&dir).unwrap();
        s.add("i1", "tok").unwrap();
        s.describe("i1", "Amex", "transactions").unwrap();
        let card = json!({"account_id": "a1", "name": "Blue Cash", "type": "credit",
            "balances": {"current": 300.0}});
        let cash = json!({"account_id": "a2", "name": "Checking", "type": "depository",
            "balances": {"current": 1000.0}});
        s.accounts("i1", &[card, cash]).unwrap();
        let t = |id: &str, merchant: &str, amount: f64, primary: &str, detail: &str| {
            json!({"transaction_id": id, "account_id": "a1", "date": "2026-10-05",
                "merchant_name": merchant, "amount": amount, "pending": false,
                "personal_finance_category": {"primary": primary, "detailed": detail}})
        };
        let list = [
            t(
                "t1",
                "Wegmans",
                80.0,
                "FOOD_AND_DRINK",
                "FOOD_AND_DRINK_GROCERIES",
            ),
            t(
                "t2",
                "Wegmans",
                20.0,
                "FOOD_AND_DRINK",
                "FOOD_AND_DRINK_GROCERIES",
            ),
            t("t3", "Shell", 40.0, "TRANSPORTATION", "TRANSPORTATION_GAS"),
            t(
                "t4",
                "Payment",
                -500.0,
                "LOAN_PAYMENTS",
                "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT",
            ),
            t("t5", "Employer", -2000.0, "INCOME", "INCOME_WAGES"),
            t("t6", "Odd", 5.0, "SOMETHING_NEW", "SOMETHING_NEW_X"),
        ];
        s.transactions("i1", &list, &[], "c1").unwrap();
        let c = &s.finance;

        super::categorize(c, "t3", "Travel", false).unwrap();
        super::categorize(c, "t1", "Dining", true).unwrap();
        assert!(super::categorize(c, "t1", "Nope", false).is_err());

        let p = super::page(c, "2026-10").unwrap();
        let of = |id: &str| {
            p["transactions"]
                .as_array()
                .unwrap()
                .iter()
                .find(|x| x["id"] == id)
                .unwrap()
                .clone()
        };
        assert_eq!(of("t1")["category"], "Dining");
        assert_eq!(of("t2")["source"], "rule");
        assert_eq!(of("t3")["category"], "Travel");
        assert_eq!(of("t3")["source"], "picked");
        assert_eq!(of("t4")["category"], "Card payments");
        assert_eq!(of("t6")["category"], "Other");
        let m = &p["months"][0];
        assert_eq!(m["income"], 2000.0);
        assert_eq!(m["spending"], 145.0);
        let w = &p["worth"][0];
        assert_eq!(
            (w["assets"].as_f64(), w["debts"].as_f64()),
            (Some(1000.0), Some(300.0))
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
