//! `yeoman tools DIR`: the yeoman's own tools, an MCP server on stdio that the
//! claude CLI starts for each model call. They reach only the book in DIR,
//! the memory (hippo at HIPPO_DIR) and the household's shared lists and
//! mailboxes, never the Matrix keys, so text pulled in by a web search
//! cannot steer them anywhere else.

use crate::book::{self, Book, Repeat, Shelf};
use crate::calendar::{Calendar, Change, NewEvent};
use crate::files::{self, Library};
use crate::finance::{self, Finance, Ledger};
use crate::hippo::Hippo;
use crate::house::House;
use crate::keep;
use crate::mail::{self, Account, Imap};
use crate::media::Seerr;
use crate::news::{self, News};
use crate::pending::{self, Act};
use crate::run;
use crate::task;
use crate::watch::{self, Source, Test};
use crate::weather::Weather;
use crate::web::Web;
use crate::x;
use crate::youtube::Youtube;
use chrono::{NaiveDate, NaiveDateTime, Timelike};
use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::{ServiceExt, tool, tool_handler, tool_router};
use schemars::JsonSchema;
use serde::Deserialize;
use std::fmt::Write;
use std::fs;
use std::io::Read;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

const AT: &str = "%Y-%m-%d %H:%M";

#[derive(Clone)]
struct Tools {
    dir: PathBuf,
    hippo: Hippo,
    house: Option<Arc<House>>,
    /// The mail accounts and their IMAP server, when there is mail.
    mail: Option<(String, Vec<Account>)>,
    /// The browser's desk, when there is a computer: where its
    /// screenshots and downloads land.
    desk: Option<PathBuf>,
    /// The browser's keeper, which leases it.
    keep: Option<String>,
    /// The runner of code, and the folder it shares with the host.
    run: Option<String>,
    runs: Option<PathBuf>,
    /// The site's directory and its URL, when the assistant has one.
    pages: Option<(PathBuf, String)>,
    /// The household's film and show library (Seerr), when there is one.
    seerr: Option<Seerr>,
    /// The feed reader (Miniflux), when there is a key for it.
    news: Option<Arc<News>>,
    /// The household's CalDAV calendars, when there is a login.
    calendar: Option<Arc<Calendar>>,
    web: Arc<Web>,
    /// YouTube through yt-dlp, when there is a yt-dlp.
    youtube: Option<Arc<Youtube>>,
    /// The X search service's socket, when there is one.
    x: Option<PathBuf>,
    /// The weather, when a place is set.
    weather: Option<Arc<Weather>>,
    /// The household's money, when the money service's database is shared.
    finance: Option<Arc<Finance>>,
    /// Changes to the household's money records, when the service lets us.
    ledger: Option<Arc<Ledger>>,
    tool_router: ToolRouter<Self>,
}

#[derive(Deserialize, JsonSchema)]
struct Remind {
    /// Local time to send it, as YYYY-MM-DD HH:MM.
    at: String,
    /// What to tell them, worded as the reminder itself; for a routine,
    /// the request to carry out, worded as they would ask it.
    text: String,
    /// Repeat after each send; leave out for once.
    repeat: Option<Repeat>,
    /// A routine: at that time the yeoman carries out the text as a request
    /// (check the mail, look at the calendar) and sends its answer.
    #[serde(default)]
    ask: bool,
    /// For a routine: also hand its answer to these, each by name (an
    /// assistant, or a person, whose assistant passes it on).
    #[serde(default)]
    share_with: Vec<String>,
}

/// A reminder must lie ahead: one set in the past would fire at once. The
/// refusal names the time, since a seat has no clock of its own and may
/// have guessed it.
fn ahead(at: NaiveDateTime, now: NaiveDateTime) -> Result<(), String> {
    let minute = now.date().and_hms_opt(now.hour(), now.minute(), 0).unwrap();
    if at < minute {
        return Err(format!(
            "{} has passed; it is now {}.",
            at.format(AT),
            now.format("%a %Y-%m-%d %H:%M")
        ));
    }
    Ok(())
}

#[derive(Deserialize, JsonSchema)]
struct WatchFor {
    source: Source,
    /// Tests on the item's fields, all of which must pass; none to fire on
    /// every item. Mail: account, from, subject. Money: merchant, amount
    /// (spending positive, money in negative), category, kind, account,
    /// pending. Calendar: summary, calendar, location, start, end.
    #[serde(default)]
    tests: Vec<Test>,
    /// What to do when it fires, worded as their request, e.g. "tell me
    /// what Gab wants"; the item comes with it.
    text: String,
    /// For calendar events: how many minutes before the start.
    #[serde(default)]
    before: i64,
    /// Also hand its answer to these, each by name (an assistant, or a
    /// person, whose assistant passes it on).
    #[serde(default)]
    share_with: Vec<String>,
}

#[derive(Deserialize, JsonSchema)]
struct WatchId {
    /// The watch's id, as `watches` shows it.
    id: u64,
}

#[derive(Deserialize, JsonSchema)]
struct Id {
    /// The reminder's id, as `reminders` shows it.
    id: u64,
}

#[derive(Deserialize, JsonSchema)]
struct Items {
    /// The list's name, short and lowercase, e.g. groceries.
    list: String,
    /// One entry per item.
    items: Vec<String>,
    /// Share the list with these, each by name (an assistant, or a
    /// person, whose assistant passes it on): it becomes the household's,
    /// and they hear what was added. Leave out to keep it to yourselves.
    #[serde(default)]
    with: Vec<String>,
}

#[derive(Deserialize, JsonSchema)]
struct ShareList {
    /// The list's name.
    list: String,
    /// Who to share it with, each by name: a person (their assistant
    /// passes it on) or an assistant.
    with: Vec<String>,
}

#[derive(Deserialize, JsonSchema)]
struct Tell {
    /// Who it is for, one or several: a person by first name (their
    /// assistant passes it on), an assistant by its name, or Bridge for the
    /// ship's engineer.
    to: Vec<String>,
    /// What to pass on, as your person put it.
    text: String,
}

#[derive(Deserialize, JsonSchema)]
struct Draft {
    /// The account to send from, by name, when there is more than one.
    account: Option<String>,
    /// The recipient's address; several, comma-separated.
    to: String,
    subject: String,
    /// Plain text, exactly as it will go out.
    body: String,
}

#[derive(Deserialize, JsonSchema)]
struct Folders {
    /// The account, by name, when there is more than one.
    account: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct MailSearch {
    /// Words anywhere in the message.
    text: Option<String>,
    /// Part of the sender's name or address.
    sender: Option<String>,
    /// On or after this day, YYYY-MM-DD.
    since: Option<String>,
    /// Only unread ones.
    #[serde(default)]
    unread: bool,
    /// The folder; INBOX if left out.
    folder: Option<String>,
    /// How many of the newest; 20 if left out.
    limit: Option<u32>,
    /// The account, by name, when there is more than one.
    account: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct MailRead {
    /// The message's uid from mail_search.
    uid: u32,
    /// The folder; INBOX if left out.
    folder: Option<String>,
    /// The account, by name, when there is more than one.
    account: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct RunCode {
    /// "python" or "shell" (bash).
    language: String,
    /// The code. It runs in a folder holding copies of `files`, with no
    /// network; every file it writes there is kept as one of your files.
    code: String,
    /// Names of your files the code needs, copied in beside it by name.
    #[serde(default)]
    files: Vec<String>,
    /// Seconds before it is stopped: 120 unless given, at most 300.
    seconds: Option<u64>,
}

#[derive(Deserialize, JsonSchema)]
struct FileName {
    /// The file's name: as kept in your files, or on your computer's desk
    /// as the screenshot or download reported it.
    name: String,
}

#[derive(Deserialize, JsonSchema)]
struct FileFind {
    /// Words the name holds, any case; leave out for every file, newest
    /// first.
    words: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct Page {
    /// The page's name, its path on the site: lowercase letters, digits
    /// and dashes, e.g. trip-plan.
    name: String,
    /// The whole page, one HTML document; styles and scripts inline. It runs
    /// sandboxed: scripts work, but cookies and browser storage do not.
    html: String,
}

#[derive(Deserialize, JsonSchema)]
struct Title {
    /// A film or show title to look for.
    title: String,
}

#[derive(Deserialize, JsonSchema)]
struct FeedUrl {
    /// A feed's address, or a site's or Substack's, whose page names its feed.
    url: String,
    /// The category to file it under, by name; made if new. Leave out for
    /// the default.
    category: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct FeedId {
    /// The feed's id, as news_feeds gives it.
    feed_id: u64,
}

#[derive(Deserialize, JsonSchema)]
struct FeedSort {
    /// The feed's id, as news_feeds gives it.
    feed_id: u64,
    /// Its new name.
    title: Option<String>,
    /// The category to move it to, by name; made if new.
    category: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct EntryId {
    /// The entry's id, as news_entries gives it.
    id: u64,
}

#[derive(Deserialize, JsonSchema)]
struct EntryMark {
    /// The entries' ids, as news_entries gives them.
    ids: Vec<u64>,
    /// true marks them read, false unread; leave out to keep.
    read: Option<bool>,
    /// true stars them, false unstars; leave out to keep.
    starred: Option<bool>,
}

#[derive(Deserialize, JsonSchema)]
struct Tmdb {
    /// The show's tmdb id, as media_search gave it.
    tmdb_id: u64,
}

#[derive(Deserialize, JsonSchema)]
struct Kind {
    /// movie or tv.
    kind: String,
}

#[derive(Deserialize, JsonSchema)]
struct Request {
    /// movie or tv.
    kind: String,
    /// The tmdb id, as media_search gave it.
    tmdb_id: u64,
    /// For a show, the seasons wanted; leave out for all of them.
    seasons: Option<Vec<u64>>,
    /// A quality profile's name from media_profiles; leave out for the default.
    quality: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct Events {
    /// The first day, YYYY-MM-DD.
    start: String,
    /// How many days from it; 7 if left out.
    days: Option<i64>,
    /// One calendar's name; leave out for all.
    calendar: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct AddEvent {
    summary: String,
    /// YYYY-MM-DD HH:MM local, or YYYY-MM-DD for a whole day.
    start: String,
    /// Same form; an hour on, or the next day, if left out.
    end: Option<String>,
    /// Which calendar, when there is more than one.
    calendar: Option<String>,
    location: Option<String>,
    notes: Option<String>,
    /// daily, weekly, monthly or yearly; leave out for once.
    repeat: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct ChangeEvent {
    uid: String,
    summary: Option<String>,
    /// YYYY-MM-DD HH:MM local, or YYYY-MM-DD; a new start alone keeps the length.
    start: Option<String>,
    end: Option<String>,
    location: Option<String>,
    notes: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct Tasks {
    /// One task per subagent, each worded in full.
    tasks: Vec<String>,
}

#[derive(Deserialize, JsonSchema)]
struct ToAgent {
    name: String,
    message: String,
}

#[derive(Deserialize, JsonSchema)]
struct Agent {
    name: String,
}

#[derive(Deserialize, JsonSchema)]
struct Uid {
    uid: String,
}

#[derive(Deserialize, JsonSchema)]
struct VideoSearch {
    query: String,
    /// How many videos; 10 if left out, at most 25.
    count: Option<u64>,
}

#[derive(Deserialize, JsonSchema)]
struct Video {
    /// A youtube.com or youtu.be link.
    url: String,
    /// The captions' language code; en if left out.
    language: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct Query {
    /// What you are trying to find, in a sentence.
    objective: String,
    /// 1-3 keyword queries of 3-6 words.
    search_queries: Vec<String>,
}

#[derive(Deserialize, JsonSchema)]
struct Money {
    /// One SQLite SELECT over finance.db. Leave it out to get the tables.
    sql: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct Spending {
    /// First day, YYYY-MM-DD.
    from: String,
    /// Last day, YYYY-MM-DD, included.
    to: String,
    /// Only this category, by its name in the categories table.
    category: Option<String>,
    /// Only merchants whose name holds this, in any case.
    merchant: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
enum Record {
    /// File a transaction: {transaction, category, scope}. scope is one (just
    /// it), merchant (every one from its merchant, now and later) or amount
    /// (every one from its merchant at exactly this amount).
    Category,
    /// Add, change or remove a budget line: {category, item, monthly, annual,
    /// renews, remove}. annual with renews (YYYY-MM-DD of the last renewal)
    /// is a yearly charge; category and item name the line.
    #[serde(rename = "budget/line")]
    Budget,
    /// Add, change or remove an account kept by hand: {id, name, kind,
    /// balance, remove}. Leave id out to add one; kind is investment, cash,
    /// property or loan; a loan's balance is what is owed, positive.
    Manual,
    /// Say a merchant's charges are not recurring, or with not false put
    /// them back: {merchant, account, not}.
    Recurring,
}

#[derive(Deserialize, JsonSchema)]
struct MoneyChange {
    record: Record,
    /// The change's fields, as the record describes.
    change: serde_json::Map<String, serde_json::Value>,
}

#[derive(Deserialize, JsonSchema)]
struct Fetch {
    /// The pages to read.
    urls: Vec<String>,
    /// What you want from the pages.
    objective: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct Count {
    /// How many of the latest to show; 15 if left out.
    count: Option<u64>,
}

#[derive(Deserialize, JsonSchema)]
struct List {
    /// The list's name; leave out to show every list.
    list: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct Line {
    /// The message id, as a <chat> line's address starts (id+n).
    id: u64,
    /// The line's n; 1 gives the one message whole.
    n: u64,
}

#[derive(Deserialize, JsonSchema)]
struct Search {
    /// A case-insensitive regex, e.g. dentist|teeth.
    regex: String,
}

#[derive(Deserialize, JsonSchema)]
struct Message {
    /// The message id.
    id: u64,
}

#[tool_router]
impl Tools {
    #[tool(
        description = "Open a <chat> line id+n of your memory into its two halves, each in more words; n = 1 gives that one message whole. Zoom down until the detail you need appears."
    )]
    fn memory_zoom(&self, Parameters(Line { id, n }): Parameters<Line>) -> Result<String, String> {
        self.hippo.zoom(id, n)
    }

    #[tool(
        description = "Search every message you and your person ever sent, word for word, with a regex; each hit shows its id, who, when and the words around the match."
    )]
    fn memory_search(
        &self,
        Parameters(Search { regex }): Parameters<Search>,
    ) -> Result<String, String> {
        self.hippo.search(&regex)
    }

    #[tool(description = "When a message of your memory was sent.")]
    fn memory_date(
        &self,
        Parameters(Message { id }): Parameters<Message>,
    ) -> Result<String, String> {
        self.hippo.date(id)
    }

    #[tool(
        description = "Set a reminder: you send the text at that time, or with `ask`, carries it out as a request and sends the answer."
    )]
    fn remind(&self, Parameters(r): Parameters<Remind>) -> Result<String, String> {
        let at = NaiveDateTime::parse_from_str(&r.at, AT)
            .map_err(|_| format!("`at` must be YYYY-MM-DD HH:MM, not {}", r.at))?;
        ahead(at, chrono::Local::now().naive_local())?;
        let share = if r.ask { r.share_with } else { Vec::new() };
        if !share.is_empty() {
            self.household()?.check(&share)?;
        }
        let id = self
            .book()?
            .change(|db| book::remind(db, at, &r.text, r.repeat, r.ask, &share))?;
        Ok(format!(
            "Reminder {id} set for {}.",
            at.format("%a %Y-%m-%d %H:%M")
        ))
    }

    #[tool(description = "Show the reminders still to come.")]
    fn reminders(&self) -> Result<String, String> {
        let all = self.book()?.read(book::reminders)?;
        let mut out = String::new();
        for r in &all {
            let _ = write!(
                out,
                "{}: {} {}",
                r.id,
                r.at.format("%a %Y-%m-%d %H:%M"),
                r.text
            );
            if !r.share_with.is_empty() {
                let _ = write!(out, " (routine shared with {})", r.share_with.join(", "));
            } else if r.ask {
                out.push_str(" (routine)");
            }
            if let Some(rep) = r.repeat {
                let _ = write!(out, " (repeats {})", serde_json::to_value(rep).unwrap());
            }
            out.push('\n');
        }
        if out.is_empty() {
            Ok("No reminders.".into())
        } else {
            Ok(out)
        }
    }

    #[tool(description = "Cancel a reminder, repeating ones included.")]
    fn cancel_reminder(&self, Parameters(Id { id }): Parameters<Id>) -> Result<String, String> {
        let gone = self.book()?.change(|db| book::cancel(db, id))?;
        if gone {
            Ok(format!("Reminder {id} cancelled."))
        } else {
            Err(format!("No reminder {id}."))
        }
    }

    #[tool(
        description = "Watch for something as it comes: new mail, a new transaction, or a calendar event coming up. When an item passes the tests, you get the text with the item and send your answer, or nothing if it doesn't need them. Use it, not a routine, for \"tell me when\"."
    )]
    fn watch(&self, Parameters(w): Parameters<WatchFor>) -> Result<String, String> {
        let there = match w.source {
            Source::Mail => self.mail.is_some(),
            Source::Money => self.finance.is_some(),
            Source::Calendar => self.calendar.is_some(),
        };
        if !there {
            return Err("That isn't connected here.".into());
        }
        if !w.share_with.is_empty() {
            self.household()?.check(&w.share_with)?;
        }
        let id = self
            .book()?
            .change(|db| watch::watch(db, w.source, &w.tests, &w.text, w.before, &w.share_with))?;
        Ok(format!(
            "Watch {id} set; it fires on what comes from now on."
        ))
    }

    #[tool(description = "Show the watches set.")]
    fn watches(&self) -> Result<String, String> {
        let all = self.book()?.read(watch::watches)?;
        if all.is_empty() {
            return Ok("No watches.".into());
        }
        Ok(all.iter().map(|w| w.show() + "\n").collect())
    }

    #[tool(description = "Stop a watch.")]
    fn unwatch(&self, Parameters(WatchId { id }): Parameters<WatchId>) -> Result<String, String> {
        if self.book()?.change(|db| watch::unwatch(db, id))? {
            Ok(format!("Watch {id} stopped."))
        } else {
            Err(format!("No watch {id}."))
        }
    }

    #[tool(
        description = "Add items to a list, making the list if it is new. Name people or assistants in `with` to share it with them: it becomes the household's and they hear what was added; no one else is told."
    )]
    fn list_add(
        &self,
        Parameters(Items { list, items, with }): Parameters<Items>,
    ) -> Result<String, String> {
        let shared = !with.is_empty();
        if shared {
            self.household()?.check(&with)?;
        }
        let shelves = self.shelves();
        let added: Vec<String> = items.clone();
        let (items, shelf) = self.book()?.change(|db| {
            let found = find(db, &shelves, &list)?;
            let (shelf, mut l) = match found {
                Some(found) => found,
                None if shared => (Shelf::House, Vec::new()),
                None => (Shelf::Own, Vec::new()),
            };
            for i in items {
                if !l.iter().any(|x| x.eq_ignore_ascii_case(&i)) {
                    l.push(i);
                }
            }
            // Shared with someone, a list of the person's own moves to
            // the household's.
            if shared && shelf == Shelf::Own {
                book::set_list(db, Shelf::Own, &list, &[])?;
                book::set_list(db, Shelf::House, &list, &l)?;
                return Ok((l, Shelf::House));
            }
            book::set_list(db, shelf, &list, &l)?;
            Ok((l, shelf))
        })?;
        if shared {
            self.announce(&with, &list, &added, &items)?;
        }
        Ok(card(&list, shelf, &items, &[]))
    }

    #[tool(
        description = "Share one of your person's lists with those named (people or assistants): it becomes the household's and they hear of it; no one else is told."
    )]
    fn share_list(
        &self,
        Parameters(ShareList { list, with }): Parameters<ShareList>,
    ) -> Result<String, String> {
        self.household()?.check(&with)?;
        let out = self.book()?.change(|db| {
            if book::list(db, Shelf::House, &list)?.is_some() {
                return Ok(Err(format!("The household already has a list {list}.")));
            }
            let Some(items) = book::list(db, Shelf::Own, &list)? else {
                return Ok(Err(format!("No list {list}.")));
            };
            book::set_list(db, Shelf::House, &list, &items)?;
            book::set_list(db, Shelf::Own, &list, &[])?;
            Ok(Ok(items))
        })??;
        self.announce(&with, &list, &[], &out)?;
        Ok(card(&list, Shelf::House, &out, &[]))
    }

    #[tool(
        description = "Remove items from a list (matched ignoring case); an emptied list goes away."
    )]
    fn list_remove(
        &self,
        Parameters(Items { list, items, .. }): Parameters<Items>,
    ) -> Result<String, String> {
        let shelves = self.shelves();
        self.book()?.change(|db| {
            let Some((shelf, mut l)) = find(db, &shelves, &list)? else {
                return Ok(Err(format!("No list {list}.")));
            };
            let missing: Vec<String> = items
                .iter()
                .filter(|i| !l.iter().any(|x| x.eq_ignore_ascii_case(i)))
                .cloned()
                .collect();
            l.retain(|x| !items.iter().any(|i| x.eq_ignore_ascii_case(i)));
            book::set_list(db, shelf, &list, &l)?;
            Ok(Ok(card(&list, shelf, &l, &missing)))
        })?
    }

    #[tool(description = "Show one list, or every list; shared ones are marked.")]
    fn lists(&self, Parameters(List { list }): Parameters<List>) -> Result<String, String> {
        let book = self.book()?;
        let mut all = Vec::new();
        for (shelf, _) in self.shelves() {
            for (n, l) in book.read(|db| book::lists(db, shelf))? {
                if list.as_ref().is_none_or(|want| *want == n) {
                    all.push(entry(&n, shelf, &l, &[]));
                }
            }
        }
        match list {
            Some(name) if all.is_empty() => Err(format!("No list {name}.")),
            _ => Ok(serde_json::Value::Array(all).to_string()),
        }
    }

    #[tool(
        description = "How much of each AI subscription's limits (Claude, ChatGPT/Codex, OpenCode Go) is used, and when each resets."
    )]
    fn usage(&self) -> Result<String, String> {
        let sock = std::env::var("YEOMAN_USAGE").map_err(|_| "No usage service here.")?;
        let mut out = String::new();
        UnixStream::connect(&sock)
            .and_then(|mut s| {
                s.set_read_timeout(Some(Duration::from_secs(60)))?;
                s.read_to_string(&mut out)
            })
            .map_err(|e| format!("usage: {e}"))?;
        Ok(out)
    }

    #[tool(
        description = "Pass a message to one or more in the household, each by name: a person (their assistant tells them), an assistant, or Bridge, the ship's engineer. It goes only to those named."
    )]
    fn tell(&self, Parameters(Tell { to, text }): Parameters<Tell>) -> Result<String, String> {
        let house = self.house.as_ref().ok_or("There is no household here.")?;
        let who = house.post(
            &to,
            &format!("From {} (through {}): {text}", house.person(), house.name()),
        )?;
        Ok(format!("Left for {}.", who.join(" and ")))
    }

    #[tool(
        description = "Your files: everything your person has sent you, and what you have sent them, kept by name. Lists the names, sizes and dates, newest first."
    )]
    fn files(
        &self,
        Parameters(FileFind { words }): Parameters<FileFind>,
    ) -> Result<String, String> {
        let found = Library::new(&self.dir)
            .find(words.as_deref().unwrap_or_default())
            .map_err(|e| e.to_string())?;
        if found.is_empty() {
            return Ok("No files.".into());
        }
        let mut out = String::new();
        for k in found.iter().take(100) {
            let when = chrono::DateTime::<chrono::Local>::from(k.when).format(AT);
            let _ = writeln!(out, "{} ({}, {when})", k.name, size(k.size));
        }
        if found.len() > 100 {
            let _ = writeln!(
                out,
                "and {} older; give words to narrow it.",
                found.len() - 100
            );
        }
        Ok(out)
    }

    #[tool(description = "Read a kept text file (notes, CSV, Markdown, code) by its name.")]
    fn read_file(
        &self,
        Parameters(FileName { name }): Parameters<FileName>,
    ) -> Result<String, String> {
        let path = Library::new(&self.dir)
            .path(&name)
            .ok_or_else(|| format!("There is no file called {name}."))?;
        let data = fs::read(&path).map_err(|e| e.to_string())?;
        let text = String::from_utf8(data).map_err(|_| format!("{name} is not text."))?;
        let cut: String = text.chars().take(crate::TEXT_MAX).collect();
        Ok(if cut.len() < text.len() {
            format!("{cut}\n(cut: the rest is too long to read here)")
        } else {
            cut
        })
    }

    #[tool(
        description = "Send your person a file: one of your files by name, or a screenshot or download from your computer's desk, which is then kept too. It goes out with your answer."
    )]
    fn send_file(
        &self,
        Parameters(FileName { name }): Parameters<FileName>,
    ) -> Result<String, String> {
        let kept = files::send(
            &Library::new(&self.dir),
            self.desk.as_deref(),
            &self.dir.join("outbox"),
            &name,
        )?;
        Ok(format!("{kept} goes out with your answer."))
    }

    #[tool(
        description = "Run Python or shell code on your computer, for converting, making or reckoning with files: a picture to another kind or size (ImageMagick `magick`, HEIC too), sound and film (ffmpeg), documents (pandoc, pdftotext, qpdf, Ghostscript), archives (zip, unzip, 7z, tar), tables and charts (Python with pandas, matplotlib, openpyxl, Pillow, pypdf, python-docx, reportlab). Give the names of your files it needs; they sit beside it by name, and every file it writes is kept as yours, so send_file can send it. No network: it cannot fetch or install anything."
    )]
    fn run_code(
        &self,
        Parameters(RunCode {
            language,
            code,
            files,
            seconds,
        }): Parameters<RunCode>,
    ) -> Result<String, String> {
        let (url, desk) = self
            .run
            .as_ref()
            .zip(self.runs.as_ref())
            .ok_or("There is no computer here.")?;
        let seconds = seconds.unwrap_or(120).clamp(1, 300);
        run::run(
            url,
            desk,
            &Library::new(&self.dir),
            &language,
            &code,
            &files,
            seconds,
        )
    }

    #[tool(
        description = "Keep your computer's browser open until your person says to close it; otherwise it closes half an hour after its last use."
    )]
    fn computer_keep(&self) -> Result<String, String> {
        let url = self.keep.as_ref().ok_or("There is no computer here.")?;
        keep::hold(url, 0).map(|_| "The browser stays open until closed.".into())
    }

    #[tool(
        description = "Close your computer's browser now; its logins stay, its open pages do not."
    )]
    fn computer_close(&self) -> Result<String, String> {
        let url = self.keep.as_ref().ok_or("There is no computer here.")?;
        keep::release(url).map(|_| "The browser is closed.".into())
    }

    #[tool(
        description = "Publish a page of HTML on your site at a name and get its link; the same name again replaces the page, older versions keep their own links."
    )]
    fn show_page(
        &self,
        Parameters(Page { name, html }): Parameters<Page>,
    ) -> Result<String, String> {
        let (dir, url) = self.pages.as_ref().ok_or("There is no site here.")?;
        publish(dir, url, &name, &html)
    }

    #[tool(description = "The pages on your site, by name.")]
    fn pages(&self) -> Result<String, String> {
        let (dir, url) = self.pages.as_ref().ok_or("There is no site here.")?;
        let mut names: Vec<String> = fs::read_dir(dir)
            .map_err(|e| e.to_string())?
            .filter_map(Result::ok)
            .filter(|d| d.path().join("index.html").is_file())
            .filter_map(|d| d.file_name().into_string().ok())
            .collect();
        names.sort();
        if names.is_empty() {
            return Ok("No pages yet.".into());
        }
        Ok(names
            .iter()
            .map(|n| format!("{url}/{n}/"))
            .collect::<Vec<_>>()
            .join("\n"))
    }

    #[tool(description = "Search the web. Results carry excerpts that usually answer directly.")]
    fn web_search(&self, Parameters(s): Parameters<Query>) -> Result<String, String> {
        self.web.search(&s.objective, &s.search_queries)
    }

    #[tool(
        description = "Read whole pages, when search excerpts are not enough. Only links a web_search in this conversation returned, or that the person sent, can be opened."
    )]
    fn web_fetch(&self, Parameters(f): Parameters<Fetch>) -> Result<String, String> {
        self.web.fetch(&f.urls, f.objective.as_deref())
    }

    #[tool(
        description = "The weather at home: now (temperature, how it feels, wind, humidity), the next 24 hours, and each day's high, low, chance of rain, sunrise and sunset for the week, in °F and mph."
    )]
    fn weather(&self) -> Result<String, String> {
        let weather = self.weather.as_deref().ok_or("There is no weather here.")?;
        let report = weather.report()?;
        serde_json::to_string(&report).map_err(|e| e.to_string())
    }

    #[tool(
        description = "The household's money as the banks report it: accounts and balances, transactions, investment holdings and card statements, synced every six hours. Without sql it gives the tables; with sql it runs one read-only SELECT and returns at most 200 rows, so sum and group in SQL. Transaction amounts are Plaid's: positive is money out. A joint account linked through both our logins appears twice, with the same institution, mask and type; count it once."
    )]
    fn finance(&self, Parameters(m): Parameters<Money>) -> Result<String, String> {
        let finance = self
            .finance
            .as_deref()
            .ok_or("There is no finance data here.")?;
        match m.sql {
            Some(sql) => finance.query(&sql),
            None => finance.schema(),
        }
    }

    #[tool(
        description = "The household's transactions between two days, filed as the money page files them (categories, rules and card-payment matches applied): money spent and money in, spending by category, and the newest transactions, as many as fit (`shown` of `count`), as rows under `columns`. Choose the days from what was asked: \"this month\" is the 1st to today, \"last week\" the seven days before today. Amounts are Plaid's: positive is money out. Card payments, transfers and investing are moves, in the list but in neither total. It is drawn as a card."
    )]
    fn transactions(&self, Parameters(s): Parameters<Spending>) -> Result<String, String> {
        let finance = self
            .finance
            .as_deref()
            .ok_or("There is no finance data here.")?;
        finance
            .transactions(&s.from, &s.to, s.category.as_deref(), s.merchant.as_deref())
            .map(|v| v.to_string())
    }

    #[tool(
        description = "How the household's investment accounts are doing: each account's value, its holdings with what they're worth against what they cost, cash or holdings the brokerage doesn't break down, and the total on each day balances were kept (daily from 2026-10-20). Prices are the last close Plaid reported, as of `as_of`. It is drawn as a card."
    )]
    fn markets(&self) -> Result<String, String> {
        let finance = self
            .finance
            .as_deref()
            .ok_or("There is no finance data here.")?;
        finance.markets().map(|v| v.to_string())
    }

    #[tool(
        description = "Change the household's money records, as the money page at money.su.is would: file a transaction under a category, edit the budget, keep an account by hand, or mark a merchant not recurring. Find ids, merchants and category names with finance first; the categories are the ones in its categories table. The service checks each change and answers why it refuses one. Do what is asked without asking again; say what you changed."
    )]
    fn money_change(&self, Parameters(m): Parameters<MoneyChange>) -> Result<String, String> {
        let ledger = self
            .ledger
            .as_deref()
            .ok_or("Money records can't be changed from here.")?;
        let what = match m.record {
            Record::Category => "category",
            Record::Budget => "budget/line",
            Record::Manual => "manual",
            Record::Recurring => "recurring",
        };
        ledger.change(what, &serde_json::Value::Object(m.change))
    }

    /// Search X: the posts found, with author, date and link. Takes up to
    /// a minute.
    #[tool]
    fn x_search(&self, Parameters(ask): Parameters<x::Ask>) -> Result<String, String> {
        let sock = self.x.as_deref().ok_or("There is no X here.")?;
        x::ask(sock, &ask)
    }

    #[tool(
        description = "Search films and shows: kind, tmdb id, title, year, overview and whether the library has it."
    )]
    fn media_search(
        &self,
        Parameters(Title { title }): Parameters<Title>,
    ) -> Result<String, String> {
        self.seerr()?.search(&title)
    }

    #[tool(
        description = "A show's seasons, with how many episodes each has and which the library already holds."
    )]
    fn media_seasons(
        &self,
        Parameters(Tmdb { tmdb_id }): Parameters<Tmdb>,
    ) -> Result<String, String> {
        self.seerr()?.seasons(tmdb_id)
    }

    #[tool(
        description = "The quality profiles a film (kind movie) or show (kind tv) can be requested in; one is the default."
    )]
    fn media_profiles(
        &self,
        Parameters(Kind { kind }): Parameters<Kind>,
    ) -> Result<String, String> {
        self.seerr()?.profiles(&kind)
    }

    #[tool(
        description = "Request a film (kind movie) or a show (kind tv), the given seasons or, with none, all of them; quality is a profile name from media_profiles, else the default."
    )]
    fn media_request(&self, Parameters(r): Parameters<Request>) -> Result<String, String> {
        self.seerr()?
            .request(&r.kind, r.tmdb_id, r.seasons, r.quality.as_deref())
    }

    #[tool(description = "The latest requests: what was asked for, by whom, and where it stands.")]
    fn media_requests(
        &self,
        Parameters(Count { count }): Parameters<Count>,
    ) -> Result<String, String> {
        self.seerr()?.requests(count.unwrap_or(15))
    }

    #[tool(
        description = "The feeds followed, by category: id, title, site, unread count, and why a feed is failing when it is."
    )]
    fn news_feeds(&self) -> Result<String, String> {
        self.news()?.feeds()
    }

    #[tool(
        description = "Follow a feed: give the feed's address, or a site's or a Substack's and its feed is found."
    )]
    fn news_follow(&self, Parameters(f): Parameters<FeedUrl>) -> Result<String, String> {
        self.news()?.follow(&f.url, f.category.as_deref())
    }

    #[tool(description = "Stop following a feed; its entries go with it.")]
    fn news_unfollow(
        &self,
        Parameters(FeedId { feed_id }): Parameters<FeedId>,
    ) -> Result<String, String> {
        self.news()?.unfollow(feed_id)
    }

    #[tool(description = "Rename a feed or move it to another category.")]
    fn news_sort(&self, Parameters(f): Parameters<FeedSort>) -> Result<String, String> {
        self.news()?
            .sort(f.feed_id, f.title.as_deref(), f.category.as_deref())
    }

    #[tool(
        description = "Entries from the feeds, newest first: id, feed, title, author, when, link, minutes to read, starred, and the opening lines. Unread unless asked otherwise; `total` is how many match."
    )]
    fn news_entries(&self, Parameters(e): Parameters<news::Entries>) -> Result<String, String> {
        self.news()?.entries(&e)
    }

    #[tool(description = "One entry whole, as text: its title, feed, author, date, link and body.")]
    fn news_article(
        &self,
        Parameters(EntryId { id }): Parameters<EntryId>,
    ) -> Result<String, String> {
        self.news()?.article(id)
    }

    #[tool(description = "Mark entries read or unread, starred or not.")]
    fn news_mark(&self, Parameters(m): Parameters<EntryMark>) -> Result<String, String> {
        self.news()?.mark(&m.ids, m.read, m.starred)
    }

    /// Search YouTube: title, channel, length, views and link per video.
    #[tool]
    fn youtube_search(
        &self,
        Parameters(VideoSearch { query, count }): Parameters<VideoSearch>,
    ) -> Result<String, String> {
        self.youtube()?.search(&query, count.unwrap_or(10))
    }

    /// A YouTube video's title, channel, length and captions as plain
    /// text, the uploader's own before automatic ones.
    #[tool]
    fn youtube_transcript(
        &self,
        Parameters(Video { url, language }): Parameters<Video>,
    ) -> Result<String, String> {
        self.youtube()?
            .transcript(&url, language.as_deref().unwrap_or("en"))
    }

    /// The calendars' names.
    #[tool]
    fn calendars(&self) -> Result<String, String> {
        self.calendar()?.names()
    }

    /// The events of some days, repeats expanded, each with its uid.
    #[tool]
    fn events(
        &self,
        Parameters(Events {
            start,
            days,
            calendar,
        }): Parameters<Events>,
    ) -> Result<String, String> {
        self.calendar()?
            .events(&start, days.unwrap_or(7).clamp(1, 366), calendar.as_deref())
    }

    /// Put an event on the calendar.
    #[tool]
    fn add_event(&self, Parameters(e): Parameters<AddEvent>) -> Result<String, String> {
        self.calendar()?.add(NewEvent {
            summary: &e.summary,
            start: &e.start,
            end: e.end.as_deref(),
            calendar: e.calendar.as_deref(),
            location: e.location.as_deref(),
            notes: e.notes.as_deref(),
            repeat: e.repeat.as_deref(),
        })
    }

    /// Change an event's fields; only those given change. A repeating
    /// event changes as a whole.
    #[tool]
    fn change_event(&self, Parameters(e): Parameters<ChangeEvent>) -> Result<String, String> {
        self.calendar()?.change(
            &e.uid,
            Change {
                summary: e.summary.as_deref(),
                start: e.start.as_deref(),
                end: e.end.as_deref(),
                location: e.location.as_deref(),
                notes: e.notes.as_deref(),
            },
        )
    }

    /// Take an event off the calendar.
    #[tool]
    fn cancel_event(&self, Parameters(Uid { uid }): Parameters<Uid>) -> Result<String, String> {
        self.calendar()?.cancel(&uid)
    }

    #[tool(
        description = "Start one subagent per task, in parallel, and return their names at once: for work that takes a while (several sites, a long search, something to fill in on the computer), or parts that can run side by side. Each one's report reaches you as a message \"[Name] report\" when it finishes; your person never sees it, so tell them what they need. A subagent sees your memory, but knows what you want only from its task: say all it needs."
    )]
    fn spawn(&self, Parameters(Tasks { tasks }): Parameters<Tasks>) -> Result<String, String> {
        if tasks.is_empty() {
            return Err("No tasks.".into());
        }
        let mut names = Vec::new();
        for t in &tasks {
            match task::spawn(&self.dir, t) {
                Ok(name) => names.push(name),
                Err(e) if names.is_empty() => return Err(e),
                Err(e) => return Ok(format!("Started {}; the rest not: {e}", names.join(", "))),
            }
        }
        Ok(format!(
            "Started {}. Each one's report will reach you as a message when it finishes.",
            names.join(", ")
        ))
    }

    #[tool(
        description = "Send a message to a subagent, by name. One at work reads it between its tool calls, and its report answers it; an idle one goes on from its chat, and its reply reaches you as a message \"[Name] reply\"."
    )]
    fn tell_agent(
        &self,
        Parameters(ToAgent { name, message }): Parameters<ToAgent>,
    ) -> Result<String, String> {
        task::tell(&self.dir, &name, &message)
    }

    #[tool(description = "Stop a subagent at work, by name.")]
    fn cancel_task(&self, Parameters(Agent { name }): Parameters<Agent>) -> Result<String, String> {
        task::cancel(&self.dir, &name)?;
        Ok(format!("Stopping {name}."))
    }

    #[tool(
        description = "A subagent's whole chat, by name: its task, every call it made and what came back, and its replies."
    )]
    fn agent_chat(&self, Parameters(Agent { name }): Parameters<Agent>) -> Result<String, String> {
        Ok(task::chat(&task::log(&self.dir, &name)?))
    }

    /// The mail folders' names.
    #[tool]
    fn mail_folders(
        &self,
        Parameters(Folders { account }): Parameters<Folders>,
    ) -> Result<String, String> {
        let folders = self.imap(account.as_deref())?.folders()?;
        Ok(serde_json::to_string(&folders).unwrap_or_default())
    }

    /// The newest messages matching every filter given, with their uids.
    /// Nothing is marked read.
    #[tool]
    fn mail_search(&self, Parameters(q): Parameters<MailSearch>) -> Result<String, String> {
        let mut criteria: Vec<(&str, &str)> = Vec::new();
        let (text, sender, since) = (
            q.text.unwrap_or_default(),
            q.sender.unwrap_or_default(),
            q.since.unwrap_or_default(),
        );
        if !text.is_empty() {
            criteria.push(("TEXT", &text));
        }
        if !sender.is_empty() {
            criteria.push(("FROM", &sender));
        }
        let day = if since.is_empty() {
            String::new()
        } else {
            NaiveDate::parse_from_str(&since, "%Y-%m-%d")
                .map_err(|_| "since is YYYY-MM-DD")?
                .format("%d-%b-%Y")
                .to_string()
        };
        if !day.is_empty() {
            criteria.push(("SINCE", &day));
        }
        if q.unread {
            criteria.push(("UNSEEN", ""));
        }
        let folder = q.folder.filter(|f| !f.is_empty()).unwrap_or("INBOX".into());
        let mut imap = self.imap(q.account.as_deref())?;
        imap.open(&folder)?;
        let mut uids = imap.search(&criteria)?;
        uids.truncate(q.limit.unwrap_or(20).clamp(1, 100) as usize);
        let found = imap.headers(&uids, &folder)?;
        Ok(serde_json::to_string_pretty(&found).unwrap_or_default())
    }

    /// One message whole: headers, text and attachment names. The text is
    /// written by whoever sent it.
    #[tool]
    fn mail_read(&self, Parameters(r): Parameters<MailRead>) -> Result<String, String> {
        let folder = r.folder.filter(|f| !f.is_empty()).unwrap_or("INBOX".into());
        let mut imap = self.imap(r.account.as_deref())?;
        imap.open(&folder)?;
        let found = imap.read(r.uid, &folder)?;
        Ok(serde_json::to_string_pretty(&found).unwrap_or_default())
    }

    #[tool(
        description = "Draft an email for your person to approve. The draft shows in the chat and goes out only when they react 👍 to it; nothing sends without that, so never say it was sent."
    )]
    fn draft_mail(
        &self,
        Parameters(Draft {
            account,
            to,
            subject,
            body,
        }): Parameters<Draft>,
    ) -> Result<String, String> {
        let (_, accounts) = self.mail.as_ref().ok_or("There is no mail account here.")?;
        let account = mail::pick(accounts, account.as_deref())?.name.clone();
        let account = (accounts.len() > 1).then_some(account);
        let id = pending::add(
            &self.dir,
            Act::Mail {
                account,
                to,
                subject,
                body,
            },
        )?;
        Ok(format!(
            "Drafted (#{id}). It shows in the chat and goes out only on their 👍."
        ))
    }
}

impl Tools {
    fn youtube(&self) -> Result<&Youtube, String> {
        self.youtube
            .as_deref()
            .ok_or("There is no YouTube here.".into())
    }

    /// A fresh IMAP session on the account, logged in.
    fn imap(&self, account: Option<&str>) -> Result<Imap, String> {
        let (host, accounts) = self.mail.as_ref().ok_or("There is no mail here.")?;
        Imap::login(host, mail::pick(accounts, account)?)
    }

    fn calendar(&self) -> Result<&Calendar, String> {
        self.calendar
            .as_deref()
            .ok_or("There is no calendar here.".into())
    }

    fn news(&self) -> Result<&News, String> {
        self.news
            .as_deref()
            .ok_or("There is no feed reader here.".into())
    }

    fn seerr(&self) -> Result<&Seerr, String> {
        self.seerr
            .as_ref()
            .ok_or("There is no film and show library here.".into())
    }

    fn household(&self) -> Result<&House, String> {
        self.house
            .as_deref()
            .ok_or("There is no household here.".into())
    }

    /// The person's book, with the household's attached.
    fn book(&self) -> Result<Book, String> {
        Book::open(&self.dir, self.house.as_ref().map(|h| h.dir.as_path()))
    }

    /// The shelves to look on: the person's own, then the household's.
    fn shelves(&self) -> Vec<(Shelf, &'static str)> {
        let mut v = vec![(Shelf::Own, "")];
        if self.house.is_some() {
            v.push((Shelf::House, " (shared)"));
        }
        v
    }

    /// Tells those `with` names of a list shared with them: what was
    /// added, and all it holds.
    fn announce(
        &self,
        with: &[String],
        list: &str,
        added: &[String],
        all: &[String],
    ) -> Result<(), String> {
        let house = self.household()?;
        let added = if added.is_empty() {
            String::new()
        } else {
            format!(" Added: {}.", added.join(", "))
        };
        house.post(
            with,
            &format!(
                "{} shared the list {list} with you.{added} It holds: {}.",
                house.person(),
                all.join(", ")
            ),
        )?;
        Ok(())
    }
}

/// A list as the list tools report it, in JSON the web page draws as a
/// card: an emptied list is gone, and `missing` holds what was asked
/// off but wasn't on it.
fn entry(list: &str, shelf: Shelf, items: &[String], missing: &[String]) -> serde_json::Value {
    let mut v = serde_json::json!({
        "list": list,
        "shared": shelf == Shelf::House,
        "items": items,
    });
    if !missing.is_empty() {
        v["missing"] = missing.into();
    }
    v
}

fn card(list: &str, shelf: Shelf, items: &[String], missing: &[String]) -> String {
    entry(list, shelf, items, missing).to_string()
}

/// The shelf that holds `list`, and its items, if one does.
fn find(
    db: &rusqlite::Connection,
    shelves: &[(Shelf, &str)],
    list: &str,
) -> rusqlite::Result<Option<(Shelf, Vec<String>)>> {
    for &(shelf, _) in shelves {
        if let Some(items) = book::list(db, shelf, list)? {
            return Ok(Some((shelf, items)));
        }
    }
    Ok(None)
}

#[tool_handler(router = self.tool_router)]
impl rmcp::ServerHandler for Tools {}

/// A byte count as people read it.
fn size(n: u64) -> String {
    match n {
        0..1_000 => format!("{n} B"),
        1_000..1_000_000 => format!("{:.0} KB", n as f64 / 1e3),
        _ => format!("{:.1} MB", n as f64 / 1e6),
    }
}

/// Writes a page under its name: a dated copy that stays, and index.html
/// swapped in whole. The name is the only path the model chooses, so it is
/// held to one plain label; the web server reads as the group.
fn publish(dir: &Path, url: &str, name: &str, html: &str) -> Result<String, String> {
    use std::os::unix::fs::PermissionsExt;
    let plain = !name.is_empty()
        && name.len() <= 40
        && name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        && !name.starts_with('-');
    if !plain {
        return Err("The name is lowercase letters, digits and dashes, 40 at most.".into());
    }
    // The web chat shares the host and owns this path.
    if name == "api" {
        return Err(format!("{name} is taken; choose another name."));
    }
    // The site directory is the assistant's and the proxy's alone, so
    // inside it everything is world-readable: the sandbox's uid map
    // cannot hand files to the proxy's group.
    let page = dir.join(name);
    fs::create_dir_all(&page).map_err(|e| e.to_string())?;
    fs::set_permissions(&page, fs::Permissions::from_mode(0o755)).map_err(|e| e.to_string())?;
    let stamp = chrono::Local::now().format("%Y%m%d-%H%M%S").to_string();
    let readable = fs::Permissions::from_mode(0o644);
    let kept = page.join(format!("{stamp}.html"));
    fs::write(&kept, html).map_err(|e| e.to_string())?;
    fs::set_permissions(&kept, readable.clone()).map_err(|e| e.to_string())?;
    let tmp = page.join(".index.html");
    fs::write(&tmp, html).map_err(|e| e.to_string())?;
    fs::set_permissions(&tmp, readable).map_err(|e| e.to_string())?;
    fs::rename(&tmp, page.join("index.html")).map_err(|e| e.to_string())?;
    Ok(format!(
        "Published: {url}/{name}/ (this version stays at {url}/{name}/{stamp}.html)"
    ))
}

/// The library, when YEOMAN_REQUESTS names the Seerr key's file.
fn seerr() -> Result<Option<Seerr>, String> {
    let Some(file) = std::env::var_os("YEOMAN_REQUESTS") else {
        return Ok(None);
    };
    let key = fs::read_to_string(&file).map_err(|e| format!("seerr key: {e}"))?;
    let url = std::env::var("YEOMAN_SEERR").map_err(|_| "YEOMAN_SEERR is not set")?;
    let person = std::env::var("YEOMAN_PERSON").unwrap_or_default();
    Ok(Some(Seerr::new(url, key, person)))
}

/// The feed reader, when YEOMAN_NEWS names its key's file.
fn news() -> Result<Option<News>, String> {
    let Some(file) = std::env::var_os("YEOMAN_NEWS") else {
        return Ok(None);
    };
    let key = fs::read_to_string(&file).map_err(|e| format!("reader key: {e}"))?;
    let url = std::env::var("YEOMAN_MINIFLUX").map_err(|_| "YEOMAN_MINIFLUX is not set")?;
    Ok(Some(News::new(url, key)))
}

/// Parallel's account key, when YEOMAN_SEARCH_KEY names its file.
fn search_key() -> Result<Option<String>, String> {
    let Some(file) = std::env::var_os("YEOMAN_SEARCH_KEY") else {
        return Ok(None);
    };
    let key = fs::read_to_string(&file).map_err(|e| format!("search key: {e}"))?;
    Ok(Some(key.trim().to_string()))
}

/// The calendars, when YEOMAN_CALDAV names the accounts file.
pub fn calendar() -> Result<Option<Calendar>, String> {
    let Some(file) = std::env::var_os("YEOMAN_CALDAV") else {
        return Ok(None);
    };
    let accounts = fs::read_to_string(&file).map_err(|e| format!("caldav accounts: {e}"))?;
    let zone = std::env::var("YEOMAN_TZ").map_err(|_| "YEOMAN_TZ is not set")?;
    Calendar::new(&accounts, &zone).map(Some)
}

/// The weather, when YEOMAN_WEATHER gives the place as `latitude,longitude`;
/// days in the ship's zone (YEOMAN_TZ).
fn weather() -> Result<Option<Weather>, String> {
    let Some(place) = std::env::var_os("YEOMAN_WEATHER") else {
        return Ok(None);
    };
    let place = place.to_string_lossy();
    let zone = std::env::var("YEOMAN_TZ").map_err(|_| "YEOMAN_TZ is not set")?;
    Weather::new(&place, &zone).map(Some)
}

/// The mail, when YEOMAN_MAIL names the accounts file and YEOMAN_IMAP the server.
pub fn mail() -> Result<Option<(String, Vec<Account>)>, String> {
    let Some(file) = std::env::var_os("YEOMAN_MAIL") else {
        return Ok(None);
    };
    let text = fs::read_to_string(&file).map_err(|e| format!("mail accounts: {e}"))?;
    let host = std::env::var("YEOMAN_IMAP").map_err(|_| "YEOMAN_IMAP is not set")?;
    Ok(Some((host, mail::accounts(&text)?)))
}

/// The tools that start, tell, stop and read subagents.
/// What a seat's claude gets of the yeoman: its agents, its reminders
/// and routines, which outlive the turn as Claude Code's own timers can't,
/// and X, which Claude Code's own web tools can't read.
pub const SEAT: [&str; 8] = [
    "x_search",
    "spawn",
    "tell_agent",
    "cancel_task",
    "agent_chat",
    "remind",
    "reminders",
    "cancel_reminder",
];

/// Serves the tools, or with `only` just those named.
pub async fn serve(dir: PathBuf, only: Option<&[&str]>) -> Result<(), String> {
    let hippo = std::env::var("HIPPO_DIR").map_err(|_| "HIPPO_DIR is not set")?;
    let hippo = Hippo {
        sock: PathBuf::from(hippo).join("hippo.sock"),
        seat: None,
    };
    // With `only`, none of the services: the settings in the environment
    // may be the caller's (a seat's claude), not a yeoman's tools'.
    let full = only.is_none();
    let mut tools = Tools {
        dir,
        web: Arc::new(Web::new(
            hippo.clone(),
            if full { search_key()? } else { None },
        )),
        hippo,
        house: House::from_env().filter(|_| full).map(Arc::new),
        mail: if full { mail()? } else { None },
        desk: std::env::var_os("YEOMAN_DESK").map(PathBuf::from),
        keep: std::env::var("YEOMAN_KEEP").ok(),
        run: std::env::var("YEOMAN_RUN").ok(),
        runs: std::env::var_os("YEOMAN_RUNS").map(PathBuf::from),
        pages: std::env::var("YEOMAN_PAGES")
            .ok()
            .zip(std::env::var("YEOMAN_PAGES_URL").ok())
            .map(|(d, u)| (PathBuf::from(d), u)),
        seerr: if full { seerr()? } else { None },
        news: if full { news()?.map(Arc::new) } else { None },
        calendar: if full {
            calendar()?.map(Arc::new)
        } else {
            None
        },
        youtube: std::env::var_os("YEOMAN_YTDLP").map(|b| Arc::new(Youtube::new(PathBuf::from(b)))),
        x: std::env::var_os("YEOMAN_X").map(PathBuf::from),
        weather: if full { weather()?.map(Arc::new) } else { None },
        finance: finance::from_env().filter(|_| full).map(Arc::new),
        ledger: finance::ledger_from_env().filter(|_| full).map(Arc::new),
        tool_router: Tools::tool_router(),
    };
    if let Some(only) = only {
        for t in tools.tool_router.list_all() {
            if !only.contains(&t.name.as_ref()) {
                tools.tool_router.remove_route(&t.name);
            }
        }
    }
    let running = tools
        .serve(rmcp::transport::stdio())
        .await
        .map_err(|e| format!("tools: {e}"))?;
    running.waiting().await.map_err(|e| format!("tools: {e}"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reminder_in_the_past_is_refused_with_the_time() {
        let t = |s| NaiveDateTime::parse_from_str(s, AT).unwrap();
        let now = t("2026-10-22 15:14") + chrono::Duration::seconds(50);
        let err = ahead(t("2026-10-22 15:03"), now).unwrap_err();
        assert!(err.contains("15:14"), "{err}");
        assert!(ahead(t("2026-10-22 15:14"), now).is_ok());
        assert!(ahead(t("2026-10-22 15:16"), now).is_ok());
    }

    #[test]
    fn a_page_is_published_under_a_plain_name_only() {
        let dir = std::env::temp_dir().join(format!("yeoman-pages-{}", std::process::id()));
        let url = "https://sokka.example";
        assert!(publish(&dir, url, "trip-plan", "<p>hi</p>").is_ok());
        assert!(dir.join("trip-plan/index.html").is_file());
        assert_eq!(fs::read_dir(dir.join("trip-plan")).unwrap().count(), 2);
        assert!(publish(&dir, url, "trip-plan", "<p>again</p>").is_ok());
        assert_eq!(
            fs::read_to_string(dir.join("trip-plan/index.html")).unwrap(),
            "<p>again</p>"
        );
        assert!(publish(&dir, url, "../etc", "x").is_err());
        assert!(publish(&dir, url, "Trip", "x").is_err());
        assert!(publish(&dir, url, "", "x").is_err());
        assert!(publish(&dir, url, "-x", "x").is_err());
        fs::remove_dir_all(&dir).unwrap();
    }
}
