//! `sokka tools DIR`: Sokka's own tools, an MCP server on stdio that the
//! claude CLI starts for each model call. They reach only the book in DIR,
//! the memory (hippo at HIPPO_DIR) and the household's shared lists and
//! mailboxes, never the Matrix keys, so text pulled in by a web search
//! cannot steer them anywhere else.

use crate::book::{self, Book, Repeat, Shelf};
use crate::hippo::Hippo;
use crate::house::House;
use chrono::NaiveDateTime;
use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::{ServiceExt, tool, tool_handler, tool_router};
use schemars::JsonSchema;
use serde::Deserialize;
use std::fmt::Write;
use std::io::Read;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

const AT: &str = "%Y-%m-%d %H:%M";

#[derive(Clone)]
struct Tools {
    dir: PathBuf,
    hippo: Hippo,
    house: Option<Arc<House>>,
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
    /// A routine: at that time Sokka carries out the text as a request
    /// (check the mail, look at the calendar) and sends its answer.
    #[serde(default)]
    ask: bool,
    /// For a routine: also hand its answer to the rest of the household.
    #[serde(default)]
    share: bool,
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
    /// For a new list: share it with the household.
    #[serde(default)]
    shared: bool,
}

#[derive(Deserialize, JsonSchema)]
struct Name {
    /// The list's name.
    list: String,
}

#[derive(Deserialize, JsonSchema)]
struct Tell {
    /// Who it is for, by first name; leave out for everyone.
    to: Option<String>,
    /// What to pass on, as your person put it.
    text: String,
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
        let id = self
            .book()?
            .change(|db| book::remind(db, at, &r.text, r.repeat, r.ask, r.ask && r.share))?;
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
            if r.share {
                out.push_str(" (shared routine)");
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
        description = "Add items to a list, making the list if it is new; a shared list is the household's, and the others hear of it."
    )]
    fn list_add(
        &self,
        Parameters(Items {
            list,
            items,
            shared,
        }): Parameters<Items>,
    ) -> Result<String, String> {
        if shared {
            self.household()?;
        }
        let shelves = self.shelves();
        let (out, fresh) = self.book()?.change(|db| {
            let found = find(db, &shelves, &list)?;
            let fresh = found.is_none() && shared;
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
            book::set_list(db, shelf, &list, &l)?;
            Ok((format!("{list}: {}", l.join(", ")), fresh))
        })?;
        if fresh {
            self.announce(&list, &out)?;
        }
        Ok(out)
    }

    #[tool(
        description = "Share one of your person's lists with the household; the others hear of it."
    )]
    fn share_list(&self, Parameters(Name { list }): Parameters<Name>) -> Result<String, String> {
        self.household()?;
        let out = self.book()?.change(|db| {
            if book::list(db, Shelf::House, &list)?.is_some() {
                return Ok(Err(format!("The household already has a list {list}.")));
            }
            let Some(items) = book::list(db, Shelf::Own, &list)? else {
                return Ok(Err(format!("No list {list}.")));
            };
            book::set_list(db, Shelf::House, &list, &items)?;
            book::set_list(db, Shelf::Own, &list, &[])?;
            Ok(Ok(format!("{list}: {}", items.join(", "))))
        })??;
        self.announce(&list, &out)?;
        Ok(format!("Shared. {out}"))
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
            let missing: Vec<&String> = items
                .iter()
                .filter(|i| !l.iter().any(|x| x.eq_ignore_ascii_case(i)))
                .collect();
            l.retain(|x| !items.iter().any(|i| x.eq_ignore_ascii_case(i)));
            book::set_list(db, shelf, &list, &l)?;
            let mut out = if l.is_empty() {
                format!("{list} is now empty and gone.")
            } else {
                format!("{list}: {}", l.join(", "))
            };
            if !missing.is_empty() {
                let missing: Vec<&str> = missing.iter().map(|s| s.as_str()).collect();
                let _ = write!(out, " Not on it: {}.", missing.join(", "));
            }
            Ok(Ok(out))
        })?
    }

    #[tool(description = "Show one list, or every list; shared ones are marked.")]
    fn lists(&self, Parameters(List { list }): Parameters<List>) -> Result<String, String> {
        let book = self.book()?;
        let mut all = Vec::new();
        for (shelf, mark) in self.shelves() {
            for (n, l) in book.read(|db| book::lists(db, shelf))? {
                if list.as_ref().is_none_or(|want| *want == n) {
                    all.push(format!("{n}{mark}: {}", l.join(", ")));
                }
            }
        }
        match list {
            Some(name) if all.is_empty() => Err(format!("No list {name}.")),
            None if all.is_empty() => Ok("No lists.".into()),
            _ => Ok(all.join("\n")),
        }
    }

    #[tool(
        description = "How much of each AI subscription's limits (Claude, ChatGPT/Codex, OpenCode Go) is used, and when each resets."
    )]
    fn usage(&self) -> Result<String, String> {
        let sock = std::env::var("SOKKA_USAGE").map_err(|_| "No usage service here.")?;
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
        description = "Pass a message to someone else in the household (or everyone); their assistant tells them."
    )]
    fn tell(&self, Parameters(Tell { to, text }): Parameters<Tell>) -> Result<String, String> {
        let house = self.house.as_ref().ok_or("There is no household here.")?;
        let who = house.post(to.as_deref(), &format!("From {}: {text}", house.person()))?;
        Ok(format!("Left for {}.", who.join(" and ")))
    }
}

impl Tools {
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

    fn announce(&self, list: &str, out: &str) -> Result<(), String> {
        let house = self.house.as_ref().ok_or("There is no household here.")?;
        house.post(
            None,
            &format!(
                "{} shared a list, {list}, with the household. {out}",
                house.person()
            ),
        )?;
        Ok(())
    }
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

pub async fn serve(dir: PathBuf) -> Result<(), String> {
    let hippo = std::env::var("HIPPO_DIR").map_err(|_| "HIPPO_DIR is not set")?;
    let tools = Tools {
        dir,
        hippo: Hippo {
            sock: PathBuf::from(hippo).join("hippo.sock"),
        },
        house: House::from_env().map(Arc::new),
        tool_router: Tools::tool_router(),
    };
    let running = tools
        .serve(rmcp::transport::stdio())
        .await
        .map_err(|e| format!("tools: {e}"))?;
    running.waiting().await.map_err(|e| format!("tools: {e}"))?;
    Ok(())
}
