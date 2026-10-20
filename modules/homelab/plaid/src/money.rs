//! The money page's side of `finance.db`: our own short category list, the
//! choices we make on top of Plaid's guesses, a daily balance per account
//! (Plaid only ever gives today's), and the reads the page draws from.
//!
//! A transaction's category is, in order: the one picked for it on the
//! page, the rule for its merchant at that exact amount, the rule for its
//! merchant, a card payment matched from the other side, income for an
//! outside transfer into a bank account, then Plaid's guess mapped onto our
//! list.
//! The `ledger` view does that once, so the page and the yeomen (who read
//! `finance.db` directly) always agree.

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

/// What a category does to the month's totals: `spend` counts as spending,
/// `income` as income, and `move` is money between our own accounts (card
/// payments, transfers, investing), which counted would show twice. The
/// spending groups follow the household budget sheet; the four after
/// Discretionary are for spending the budget doesn't plan.
const CATEGORIES: &[(&str, &str)] = &[
    ("Income", "income"),
    ("Home", "spend"),
    ("Auto", "spend"),
    ("Health", "spend"),
    ("Food", "spend"),
    ("Utilities", "spend"),
    ("Pets", "spend"),
    ("Subscriptions", "spend"),
    ("Tech Infra", "spend"),
    ("Card Fees", "spend"),
    ("Discretionary", "spend"),
    ("Shopping", "spend"),
    ("Travel", "spend"),
    ("Taxes & giving", "spend"),
    ("Other", "spend"),
    ("Invest", "move"),
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
    ("TRANSFER_OUT_INVESTMENT_AND_RETIREMENT_FUNDS", "Invest"),
    ("LOAN_DISBURSEMENTS", "Transfers"),
    ("LOAN_PAYMENTS", "Loan payments"),
    ("LOAN_PAYMENTS_CREDIT_CARD_PAYMENT", "Card payments"),
    ("LOAN_PAYMENTS_CAR_PAYMENT", "Auto"),
    ("LOAN_PAYMENTS_MORTGAGE_PAYMENT", "Home"),
    ("BANK_FEES", "Card Fees"),
    ("ENTERTAINMENT", "Discretionary"),
    ("ENTERTAINMENT_TV_AND_MOVIES", "Subscriptions"),
    ("ENTERTAINMENT_MUSIC_AND_AUDIO", "Subscriptions"),
    ("FOOD_AND_DRINK", "Food"),
    ("GENERAL_MERCHANDISE", "Shopping"),
    ("GENERAL_MERCHANDISE_PET_SUPPLIES", "Pets"),
    ("HOME_IMPROVEMENT", "Home"),
    ("MEDICAL", "Health"),
    ("MEDICAL_VETERINARY_SERVICES", "Pets"),
    ("PERSONAL_CARE", "Discretionary"),
    ("PERSONAL_CARE_GYMS_AND_FITNESS_CENTERS", "Health"),
    ("GENERAL_SERVICES", "Other"),
    ("GENERAL_SERVICES_AUTOMOTIVE", "Auto"),
    ("GOVERNMENT_AND_NON_PROFIT", "Taxes & giving"),
    ("TRANSPORTATION", "Auto"),
    ("TRANSPORTATION_PUBLIC_TRANSIT", "Travel"),
    ("TRANSPORTATION_TAXIS_AND_RIDE_SHARES", "Travel"),
    ("TRAVEL", "Travel"),
    ("RENT_AND_UTILITIES", "Utilities"),
    ("RENT_AND_UTILITIES_RENT", "Home"),
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
-- Banks name every transfer alike ('Online Transfer / Payment'), so the
-- mortgage and a paycheck differ only in amount; these rules key on both.
CREATE TABLE IF NOT EXISTS amount_rules (
    merchant TEXT NOT NULL,
    cents INTEGER NOT NULL,
    category TEXT NOT NULL,
    PRIMARY KEY (merchant, cents)
);
CREATE INDEX IF NOT EXISTS transactions_amount ON transactions(amount);
CREATE TABLE IF NOT EXISTS balances (
    account_id TEXT NOT NULL,
    date TEXT NOT NULL,
    current REAL,
    PRIMARY KEY (account_id, date)
);
-- The plan: each line is a monthly amount, a yearly one, or both; a
-- category's month is its monthly lines plus a twelfth of its yearly ones.
CREATE TABLE IF NOT EXISTS budget (
    category TEXT NOT NULL,
    item TEXT NOT NULL,
    monthly REAL NOT NULL DEFAULT 0,
    annual REAL NOT NULL DEFAULT 0,
    renews TEXT,
    rank INTEGER NOT NULL
);
DROP VIEW IF EXISTS ledger;
CREATE VIEW ledger AS
SELECT t.transaction_id, t.account_id, t.date, t.name,
       coalesce(t.merchant, t.name) AS merchant, t.amount, t.pending,
       coalesce(c.name, 'Other') AS category, coalesce(c.kind, 'spend') AS kind,
       CASE WHEN o.category IS NOT NULL THEN 'picked'
            WHEN a.category IS NOT NULL OR r.category IS NOT NULL THEN 'rule'
            WHEN m.paid IS NOT NULL THEN 'match'
            WHEN i.transaction_id IS NOT NULL THEN 'deposit'
            ELSE 'plaid' END AS source
FROM transactions t
LEFT JOIN overrides o ON o.transaction_id = t.transaction_id
LEFT JOIN amount_rules a ON a.merchant = coalesce(t.merchant, t.name)
    AND a.cents = CAST(round(t.amount * 100) AS INTEGER)
LEFT JOIN rules r ON r.merchant = coalesce(t.merchant, t.name)
-- Money leaving a bank account that a linked card received within five
-- days, to the cent, is that card's payment whatever the bank called it.
LEFT JOIN (
    SELECT DISTINCT t2.transaction_id, 'Card payments' AS paid
    FROM transactions t2
    JOIN accounts ta ON ta.account_id = t2.account_id AND ta.type = 'depository'
    JOIN transactions x ON x.amount BETWEEN -t2.amount - 0.005 AND -t2.amount + 0.005
        AND abs(julianday(x.date) - julianday(t2.date)) <= 5
    JOIN accounts xa ON xa.account_id = x.account_id AND xa.type = 'credit'
    WHERE t2.amount > 0
) m ON m.transaction_id = t.transaction_id
LEFT JOIN category_map d ON d.code = t.detail
LEFT JOIN category_map p ON p.code = t.category
-- A transfer into a bank account that no other linked account sent is
-- income: banks call paychecks and outside deposits plain transfers.
LEFT JOIN (
    SELECT t3.transaction_id
    FROM transactions t3
    JOIN accounts ia ON ia.account_id = t3.account_id AND ia.type = 'depository'
    LEFT JOIN category_map d3 ON d3.code = t3.detail
    LEFT JOIN category_map p3 ON p3.code = t3.category
    WHERE t3.amount < 0 AND coalesce(d3.category, p3.category) = 'Transfers'
      AND NOT EXISTS (
        SELECT 1 FROM transactions y
        WHERE y.account_id != t3.account_id
          AND y.amount BETWEEN -t3.amount - 0.005 AND -t3.amount + 0.005
          AND abs(julianday(y.date) - julianday(t3.date)) <= 5)
) i ON i.transaction_id = t.transaction_id
-- A rule naming a category this build no longer has falls to Other.
LEFT JOIN categories c
    ON c.name = coalesce(o.category, a.category, r.category, m.paid,
        CASE WHEN i.transaction_id IS NOT NULL THEN 'Income' END, d.category, p.category);
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

/// How far a category choice reaches.
#[derive(serde::Deserialize, Clone, Copy)]
#[serde(rename_all = "lowercase")]
pub enum Scope {
    /// Just this transaction.
    One,
    /// Every transaction from its merchant, now and later.
    Merchant,
    /// Every one from its merchant at exactly this amount, now and later.
    Amount,
}

/// Files a transaction under a category, as far as `scope` reaches.
pub fn categorize(
    c: &Connection,
    transaction: &str,
    category: &str,
    scope: Scope,
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
    let (merchant, amount): (String, f64) = c
        .query_row(
            "SELECT merchant, amount FROM ledger WHERE transaction_id = ?1",
            params![transaction],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("no transaction {transaction}"))?;
    let t = c.unchecked_transaction().map_err(|e| e.to_string())?;
    let cents = (amount * 100.0).round() as i64;
    // A rule decides from now on, so single picks it covers would hide it;
    // a merchant rule likewise clears that merchant's amount rules.
    match scope {
        Scope::Merchant => t
            .execute(
                "INSERT OR REPLACE INTO rules (merchant, category) VALUES (?1, ?2)",
                params![merchant, category],
            )
            .and_then(|_| {
                t.execute(
                    "DELETE FROM amount_rules WHERE merchant = ?1",
                    params![merchant],
                )
            })
            .and_then(|_| {
                t.execute(
                    "DELETE FROM overrides WHERE transaction_id IN
                     (SELECT transaction_id FROM ledger WHERE merchant = ?1)",
                    params![merchant],
                )
            }),
        Scope::Amount => t
            .execute(
                "INSERT OR REPLACE INTO amount_rules (merchant, cents, category)
                 VALUES (?1, ?2, ?3)",
                params![merchant, cents, category],
            )
            .and_then(|_| {
                t.execute(
                    "DELETE FROM overrides WHERE transaction_id IN
                     (SELECT transaction_id FROM ledger WHERE merchant = ?1
                      AND CAST(round(amount * 100) AS INTEGER) = ?2)",
                    params![merchant, cents],
                )
            }),
        Scope::One => t.execute(
            "INSERT OR REPLACE INTO overrides (transaction_id, category) VALUES (?1, ?2)",
            params![transaction, category],
        ),
    }
    .map_err(|e| e.to_string())?;
    t.commit().map_err(|e| e.to_string())
}

/// One line of the budget as the page sends it.
#[derive(serde::Deserialize)]
pub struct Line {
    pub category: String,
    pub item: String,
    #[serde(default)]
    pub monthly: f64,
    #[serde(default)]
    pub annual: f64,
    /// `YYYY-MM-DD` of a yearly charge's last renewal.
    pub renews: Option<String>,
}

/// Replaces the whole budget; it is small and edited as one sheet.
pub fn set_budget(c: &Connection, lines: &[Line]) -> Result<(), String> {
    let t = c.unchecked_transaction().map_err(|e| e.to_string())?;
    t.execute("DELETE FROM budget", [])
        .map_err(|e| e.to_string())?;
    for (rank, l) in lines.iter().enumerate() {
        let known = t
            .query_row(
                "SELECT 1 FROM categories WHERE name = ?1",
                params![l.category],
                |_| Ok(()),
            )
            .optional()
            .map_err(|e| e.to_string())?;
        if known.is_none() {
            return Err(format!("no category {}", l.category));
        }
        t.execute(
            "INSERT INTO budget (category, item, monthly, annual, renews, rank)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![l.category, l.item, l.monthly, l.annual, l.renews, rank],
        )
        .map_err(|e| e.to_string())?;
    }
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

    let budget = rows(
        c,
        "SELECT category, item, monthly, annual, renews FROM budget ORDER BY rank",
        &[],
        |r| {
            Ok(json!({
                "category": r.get::<_, String>(0)?,
                "item": r.get::<_, String>(1)?,
                "monthly": r.get::<_, f64>(2)?,
                "annual": r.get::<_, f64>(3)?,
                "renews": r.get::<_, Option<String>>(4)?,
            }))
        },
    )?;

    // Each account's month: what went on it, what paid it down (for cards
    // and loans), and `net`, every posted change, so the page can walk
    // today's balance back to each month's end.
    let flows = rows(
        c,
        "SELECT l.account_id, substr(l.date, 1, 7) AS m,
             coalesce(sum(CASE WHEN l.kind != 'move' THEN l.amount END), 0),
             coalesce(sum(CASE WHEN l.kind = 'move' AND l.amount < 0 THEN -l.amount END), 0),
             coalesce(sum(l.amount), 0)
             FROM ledger l WHERE NOT l.pending
             GROUP BY l.account_id, m ORDER BY m, l.account_id",
        &[],
        |r| {
            Ok(json!({
                "account": r.get::<_, String>(0)?,
                "month": r.get::<_, String>(1)?,
                "charges": r.get::<_, f64>(2)?,
                "payments": r.get::<_, f64>(3)?,
                "net": r.get::<_, f64>(4)?,
            }))
        },
    )?;

    // A year of fees on cards and loans: late fees are the ones to catch.
    let fees = rows(
        c,
        &format!(
            "SELECT l.account_id, l.date, l.name, l.amount
             FROM ledger l JOIN accounts a ON a.account_id = l.account_id
             WHERE a.{DEBT} AND l.category = 'Card Fees' AND l.date >= date('now', '-1 year')
             ORDER BY l.date DESC"
        ),
        &[],
        |r| {
            Ok(json!({
                "account": r.get::<_, String>(0)?,
                "date": r.get::<_, String>(1)?,
                "name": r.get::<_, Option<String>>(2)?,
                "amount": r.get::<_, f64>(3)?,
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
        "budget": budget,
        "flows": flows,
        "fees": fees,
        "recurring": recurring(c)?,
    }))
}

/// One posted charge, as the recurring finder sees it.
#[derive(Clone)]
struct Charge {
    day: f64,
    date: String,
    merchant: String,
    amount: f64,
    category: String,
    account: String,
}

/// How often a bill comes, with the gaps (in days) that count as on
/// schedule, and how many charges it takes to believe it.
const CADENCES: [(&str, f64, f64, f64, usize); 5] = [
    ("weekly", 7.0, 5.0, 9.0, 4),
    ("every two weeks", 14.0, 12.0, 16.0, 4),
    ("monthly", 30.44, 26.0, 35.0, 3),
    ("quarterly", 91.3, 80.0, 100.0, 3),
    ("yearly", 365.25, 350.0, 380.0, 2),
];

/// A run of charges at one merchant on one schedule.
struct Chain {
    cadence: Option<usize>,
    list: Vec<Charge>,
}

impl Chain {
    /// Whether `x` is this bill's next charge: on schedule, or one cycle
    /// late after a skipped or refunded month, and the amount within a
    /// quarter of the last (a price change, not another purchase) unless
    /// `any_amount`.
    fn takes(&self, x: &Charge, any_amount: bool) -> Option<usize> {
        let last = self.list.last()?;
        let (gap, ratio) = (x.day - last.day, x.amount / last.amount);
        if !any_amount
            && !(0.75..=1.0 / 0.75).contains(&ratio)
            && (x.amount - last.amount).abs() > 2.0
        {
            return None;
        }
        let fits = |i: usize, skips: bool| {
            let (_, _, lo, hi, _) = CADENCES[i];
            (lo..=hi).contains(&gap) || (skips && (2.0 * lo..=2.0 * hi).contains(&gap))
        };
        match self.cadence {
            Some(i) => fits(i, true).then_some(i),
            None => (0..CADENCES.len()).find(|&i| fits(i, false)),
        }
    }
}

/// A same-price run judged by its usual gap, so a bill paid by hand a week
/// early one month and late the next still counts, as long as no gap is
/// more than two cycles.
fn steady_price(list: &[Charge], need_more: usize) -> Option<usize> {
    let mut gaps: Vec<f64> = list.windows(2).map(|w| w[1].day - w[0].day).collect();
    gaps.sort_by(f64::total_cmp);
    let (median, widest) = (*gaps.get(gaps.len() / 2)?, *gaps.last()?);
    (0..CADENCES.len()).find(|&i| {
        let (_, days, lo, hi, need) = CADENCES[i];
        list.len() >= need + need_more && (lo..=hi).contains(&median) && widest <= 2.2 * days
    })
}

/// Recurring charges in the spending history, found the way Copilot and
/// Rocket Money do: one merchant's charges on one account at a steady
/// interval. A merchant that bills only on a schedule is followed through
/// price changes and the odd missed month; at a shop visited more often
/// than that, only a run at one exact price counts (Prime, not groceries).
fn find_recurring(charges: &[Charge], today: f64) -> Vec<Value> {
    let mut by: std::collections::BTreeMap<(&str, &str), Vec<&Charge>> = Default::default();
    for x in charges {
        by.entry((&x.merchant, &x.account)).or_default().push(x);
    }
    let mut found = Vec::new();
    for list in by.into_values() {
        let span = list.last().unwrap().day - list[0].day;
        let busy = (list.len() - 1) as f64 > 1.5 * (span / 30.44).max(1.0);
        let mut chains: Vec<Chain> = Vec::new();
        if busy {
            let mut prices: std::collections::BTreeMap<i64, Vec<Charge>> = Default::default();
            for x in &list {
                prices
                    .entry((x.amount * 100.0).round() as i64)
                    .or_default()
                    .push((*x).clone());
            }
            for run in prices.into_values() {
                // Yearly needs three years here; a pair is chance.
                if let Some(i) = steady_price(&run, 1).filter(|&i| CADENCES[i].0 != "yearly") {
                    chains.push(Chain {
                        cadence: Some(i),
                        list: run,
                    });
                }
            }
        } else {
            // Power and water swing past a quarter month to month; a merchant
            // that only ever bills on one schedule is one bill whatever it costs.
            let mut whole = Chain {
                cadence: None,
                list: vec![],
            };
            let mut steady = true;
            for x in list.iter().copied() {
                if !whole.list.is_empty() {
                    match whole.takes(x, true) {
                        Some(i) => whole.cadence = Some(i),
                        None => steady = false,
                    }
                }
                whole.list.push(x.clone());
            }
            if steady && list.len() >= 2 {
                chains.push(whole);
            } else {
                for x in list.iter().copied() {
                    let near = |c: &Chain| (x.amount / c.list.last().unwrap().amount).ln().abs();
                    let best = chains
                        .iter_mut()
                        .filter_map(|c| c.takes(x, false).map(|i| (near(c), i, c)))
                        .min_by(|a, b| a.0.total_cmp(&b.0));
                    match best {
                        Some((_, i, c)) => {
                            c.cadence = Some(i);
                            c.list.push(x.clone());
                        }
                        None => chains.push(Chain {
                            cadence: None,
                            list: vec![x.clone()],
                        }),
                    }
                }
            }
        }
        for c in chains {
            let Some(i) = c.cadence else { continue };
            let (name, days, _, _, need) = CADENCES[i];
            if c.list.len() < need {
                continue;
            }
            let last = c.list.last().unwrap();
            // Gone more than half a year: history, not a bill.
            if today - last.day > days.max(180.0) + 30.0 {
                continue;
            }
            let recent = &c.list[c.list.len().saturating_sub(3)..];
            let fixed = recent.iter().all(|x| (x.amount - last.amount).abs() < 0.5);
            // Two shop visits a year apart look yearly; a real yearly or
            // quarterly bill (a domain, a card's fee) repeats to the cent.
            if days > 60.0 && !fixed {
                continue;
            }
            let usual = recent.iter().map(|x| x.amount).sum::<f64>() / recent.len() as f64;
            found.push(json!({
                "merchant": last.merchant,
                "category": last.category,
                "account": last.account,
                "cadence": name,
                "days": days,
                "count": c.list.len(),
                "first": c.list[0].date,
                "last": last.date,
                "amount": last.amount,
                "fixed": fixed,
                "monthly": usual * 30.44 / days,
                // Missed one and a bit: probably cancelled.
                "active": today - last.day <= days * 1.5 + 5.0,
            }));
        }
    }
    let monthly = |x: &Value| x["monthly"].as_f64().unwrap_or(0.0);
    found.sort_by(|a, b| monthly(b).total_cmp(&monthly(a)));
    found
}

/// Every recurring payment in the history, biggest monthly cost first.
pub fn recurring(c: &Connection) -> Result<Vec<Value>, String> {
    let mut q = c
        .prepare(
            "SELECT julianday(l.date), l.date, l.merchant, l.amount, l.category,
             coalesce(a.name, 'Account') || coalesce(' ··' || a.mask, ''), julianday('now')
             FROM ledger l JOIN accounts a ON a.account_id = l.account_id
             WHERE l.kind = 'spend' AND NOT l.pending AND l.amount > 0
             ORDER BY l.date",
        )
        .map_err(|e| e.to_string())?;
    let mut today = 0.0;
    let charges = q
        .query_map([], |r| {
            today = r.get(6)?;
            Ok(Charge {
                day: r.get(0)?,
                date: r.get(1)?,
                merchant: r.get(2)?,
                amount: r.get(3)?,
                category: r.get(4)?,
                account: r.get(5)?,
            })
        })
        .and_then(Iterator::collect::<rusqlite::Result<Vec<_>>>)
        .map_err(|e| e.to_string())?;
    Ok(find_recurring(&charges, today))
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
        let bank = |id: &str, date: &str, amount: f64| {
            json!({"transaction_id": id, "account_id": "a2", "date": date,
                "name": "Online Transfer / Payment", "amount": amount, "pending": false,
                "personal_finance_category": {"primary": "TRANSFER_OUT", "detailed": "TRANSFER_OUT_ACCOUNT_TRANSFER"}})
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
            // The checking side: the card payment, then two mortgage
            // payments and a transfer the bank names the same.
            bank("t7", "2026-10-08", 500.0),
            bank("t8", "2026-10-01", 3373.94),
            bank("t9", "2026-10-28", 3373.94),
            bank("t10", "2026-10-12", 100.0),
            // Money in: a paycheck, and cash a linked card sent over.
            bank("t11", "2026-10-16", -1726.77),
            bank("t12", "2026-10-06", -40.0),
        ];
        s.transactions("i1", &list, &[], "c1").unwrap();
        let c = &s.finance;

        use super::Scope;
        super::categorize(c, "t3", "Travel", Scope::One).unwrap();
        super::categorize(c, "t1", "Discretionary", Scope::Merchant).unwrap();
        super::categorize(c, "t8", "Home", Scope::Amount).unwrap();
        let line = |category: &str, item: &str, monthly: f64, annual: f64| super::Line {
            category: category.into(),
            item: item.into(),
            monthly,
            annual,
            renews: None,
        };
        super::set_budget(
            c,
            &[
                line("Food", "Food", 600.0, 0.0),
                line("Card Fees", "Green", 0.0, 150.0),
            ],
        )
        .unwrap();
        assert!(super::set_budget(c, &[line("Nope", "x", 1.0, 0.0)]).is_err());
        assert!(super::categorize(c, "t1", "Nope", Scope::One).is_err());

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
        assert_eq!(of("t1")["category"], "Discretionary");
        assert_eq!(of("t2")["source"], "rule");
        assert_eq!(of("t3")["category"], "Travel");
        assert_eq!(of("t3")["source"], "picked");
        assert_eq!(of("t4")["category"], "Card payments");
        assert_eq!(of("t6")["category"], "Other");
        assert_eq!(of("t7")["category"], "Card payments");
        assert_eq!(of("t7")["source"], "match");
        assert_eq!(of("t9")["category"], "Home");
        assert_eq!(of("t10")["category"], "Transfers");
        assert_eq!(of("t11")["category"], "Income");
        assert_eq!(of("t11")["source"], "deposit");
        assert_eq!(of("t12")["category"], "Transfers");
        let d = &p["flows"][0];
        assert_eq!(
            (d["account"].as_str(), d["payments"].as_f64()),
            (Some("a1"), Some(500.0))
        );
        // A failed load leaves the old budget alone.
        assert_eq!(p["budget"].as_array().unwrap().len(), 2);
        assert_eq!(p["budget"][1]["annual"], 150.0);
        let m = &p["months"][0];
        assert_eq!(m["income"], 2000.0 + 1726.77);
        assert_eq!(m["spending"], 145.0 + 2.0 * 3373.94);
        let w = &p["worth"][0];
        assert_eq!(
            (w["assets"].as_f64(), w["debts"].as_f64()),
            (Some(1000.0), Some(300.0))
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn recurring_finds_steady_bills_and_skips_noise() {
        let mut list = Vec::new();
        let mut add = |day: f64, merchant: &str, amount: f64| {
            list.push(super::Charge {
                day,
                date: format!("d{day}"),
                merchant: merchant.into(),
                amount,
                category: "Subscriptions".into(),
                account: "Card".into(),
            })
        };
        for m in 0..6 {
            let day = 30.0 * m as f64;
            // Two plans billed the same day at one merchant.
            add(day, "Netflix", 15.49);
            add(day + 0.0, "Netflix", 7.99);
            // Power moves with the season.
            add(day + 3.0, "Eversource", 110.0 + 20.0 * m as f64);
        }
        // Spotify changed price twice; Hulu skipped a month for a refund.
        for (m, amount) in [18.12, 20.25, 20.25, 20.25, 15.98, 15.98]
            .into_iter()
            .enumerate()
        {
            add(30.0 * m as f64 + 5.0, "Spotify", amount);
        }
        for m in [0, 1, 3, 4, 5] {
            add(30.0 * m as f64 + 9.0, "Hulu", 100.58);
        }
        // Cancelled after three months.
        for m in 0..3 {
            add(30.0 * m as f64, "Peacock", 9.99);
        }
        // Coffee at no steady interval, twice the same price a month apart.
        for (day, amount) in [
            (1.0, 6.2),
            (4.0, 7.7),
            (13.0, 6.16),
            (14.0, 7.69),
            (31.0, 6.2),
        ] {
            add(day, "Starbucks", amount);
        }
        list.sort_by(|a, b| a.day.total_cmp(&b.day));
        let found = super::find_recurring(&list, 160.0);
        let names: Vec<_> = found
            .iter()
            .map(|x| {
                (
                    x["merchant"].as_str().unwrap(),
                    x["amount"].as_f64().unwrap(),
                    x["active"].as_bool().unwrap(),
                )
            })
            .collect();
        assert_eq!(names.len(), 6, "{names:?}");
        assert!(names.contains(&("Spotify", 15.98, true)));
        assert!(names.contains(&("Hulu", 100.58, true)));
        assert!(names.contains(&("Netflix", 15.49, true)));
        assert!(names.contains(&("Netflix", 7.99, true)));
        assert!(names.contains(&("Eversource", 210.0, true)));
        assert!(names.contains(&("Peacock", 9.99, false)));
        assert_eq!(found[0]["merchant"], "Eversource");
        assert_eq!(found[0]["fixed"], false);
    }
}
