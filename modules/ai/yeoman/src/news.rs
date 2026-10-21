//! The feed reader: what is followed and what is unread, through Miniflux's
//! API on loopback with the reader's own key. Articles are text from
//! strangers, so this reaches only the reader: following, sorting, reading
//! and marking.

use mail_parser::decoders::html::html_to_text;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::time::Duration;
use ureq::Agent;

const TIMEOUT: Duration = Duration::from_secs(30);
/// An article longer than this is cut, which keeps one long read from
/// filling the context.
const ARTICLE_MAX: usize = 40_000;
/// The opening of each entry in a list, enough to judge it by.
const SNIPPET: usize = 280;

pub struct News {
    url: String,
    key: String,
    agent: Agent,
}

impl News {
    pub fn new(url: String, key: String) -> Self {
        let config = Agent::config_builder()
            .timeout_global(Some(TIMEOUT))
            .http_status_as_error(false)
            .build();
        News {
            url,
            key: key.trim().to_owned(),
            agent: Agent::new_with_config(config),
        }
    }

    fn call(&self, method: &str, path: &str, body: Option<Value>) -> Result<Value, String> {
        let url = format!("{}/v1{path}", self.url);
        let key = self.key.as_str();
        let mut resp = match (method, body) {
            ("GET", _) => self.agent.get(&url).header("X-Auth-Token", key).call(),
            ("DELETE", _) => self.agent.delete(&url).header("X-Auth-Token", key).call(),
            ("POST", b) => self
                .agent
                .post(&url)
                .header("X-Auth-Token", key)
                .send_json(b.unwrap_or(Value::Null)),
            (_, b) => self
                .agent
                .put(&url)
                .header("X-Auth-Token", key)
                .send_json(b.unwrap_or(Value::Null)),
        }
        .map_err(|e| format!("reader: {e}"))?;
        let status = resp.status().as_u16();
        let text = resp
            .body_mut()
            .read_to_string()
            .map_err(|e| format!("reader: {e}"))?;
        let v: Value = if text.trim().is_empty() {
            Value::Null
        } else {
            serde_json::from_str(&text).map_err(|e| format!("reader: {e}"))?
        };
        if status >= 400 {
            let msg = v["error_message"].as_str().unwrap_or(&text);
            return Err(format!("reader: {status} {msg}"));
        }
        Ok(v)
    }

    /// Every feed by category, with its unread count and whether its last
    /// fetches failed.
    pub fn feeds(&self) -> Result<String, String> {
        let feeds = self.call("GET", "/feeds", None)?;
        let counters = self.call("GET", "/feeds/counters", None)?;
        Ok(feeds_view(&feeds, &counters).to_string())
    }

    /// Follow what a URL offers: a feed's own address, or a site whose page
    /// names its feed. Filed under the category so named, made if new.
    pub fn follow(&self, url: &str, category: Option<&str>) -> Result<String, String> {
        let found = self.call("POST", "/discover", Some(json!({ "url": url })))?;
        let feed = found
            .as_array()
            .and_then(|a| a.first())
            .and_then(|f| f["url"].as_str())
            .ok_or_else(|| format!("No feed found at {url}."))?
            .to_owned();
        let category_id = self.category(category)?;
        let made = self.call(
            "POST",
            "/feeds",
            Some(json!({ "feed_url": feed, "category_id": category_id })),
        )?;
        Ok(format!("Following {feed} (feed {}).", made["feed_id"]))
    }

    pub fn unfollow(&self, feed_id: u64) -> Result<String, String> {
        self.call("DELETE", &format!("/feeds/{feed_id}"), None)?;
        Ok(format!("Stopped following feed {feed_id}."))
    }

    /// Rename a feed or move it to another category, made if new.
    pub fn sort(
        &self,
        feed_id: u64,
        title: Option<&str>,
        category: Option<&str>,
    ) -> Result<String, String> {
        let mut change = serde_json::Map::new();
        if let Some(t) = title {
            change.insert("title".into(), json!(t));
        }
        if category.is_some() {
            change.insert("category_id".into(), json!(self.category(category)?));
        }
        if change.is_empty() {
            return Err("Give a title or a category.".into());
        }
        self.call(
            "PUT",
            &format!("/feeds/{feed_id}"),
            Some(Value::Object(change)),
        )?;
        Ok(format!("Feed {feed_id} updated."))
    }

    /// The id of the category so named, made if there is none; with no
    /// name, the first one.
    fn category(&self, name: Option<&str>) -> Result<i64, String> {
        let all = self.call("GET", "/categories", None)?;
        let list = all.as_array().cloned().unwrap_or_default();
        let found = match name {
            None => list.first(),
            Some(n) => list.iter().find(|c| {
                c["title"]
                    .as_str()
                    .is_some_and(|t| t.eq_ignore_ascii_case(n))
            }),
        };
        if let Some(id) = found.and_then(|c| c["id"].as_i64()) {
            return Ok(id);
        }
        let n = name.ok_or("The reader has no categories.")?;
        let made = self.call("POST", "/categories", Some(json!({ "title": n })))?;
        made["id"]
            .as_i64()
            .ok_or_else(|| "reader: no category id".into())
    }

    pub fn entries(&self, ask: &Entries) -> Result<String, String> {
        let mut query = vec![
            format!("limit={}", ask.limit.unwrap_or(30).clamp(1, 100)),
            "order=published_at".to_owned(),
            "direction=desc".to_owned(),
        ];
        match ask.status.as_deref().unwrap_or("unread") {
            "all" => {}
            s @ ("unread" | "read") => query.push(format!("status={s}")),
            s => return Err(format!("status is unread, read or all, not {s}")),
        }
        if ask.starred {
            query.push("starred=true".into());
        }
        if let Some(f) = ask.feed_id {
            query.push(format!("feed_id={f}"));
        }
        if let Some(c) = ask.category.as_deref() {
            query.push(format!("category_id={}", self.category(Some(c))?));
        }
        if let Some(s) = ask.search.as_deref() {
            query.push(format!("search={}", url_encode(s)));
        }
        let v = self.call("GET", &format!("/entries?{}", query.join("&")), None)?;
        Ok(entries_view(&v).to_string())
    }

    pub fn article(&self, id: u64) -> Result<String, String> {
        let e = self.call("GET", &format!("/entries/{id}"), None)?;
        Ok(article_view(&e))
    }

    pub fn mark(
        &self,
        ids: &[u64],
        read: Option<bool>,
        starred: Option<bool>,
    ) -> Result<String, String> {
        if ids.is_empty() {
            return Err("Give the entries' ids.".into());
        }
        if read.is_none() && starred.is_none() {
            return Err("Say read or starred.".into());
        }
        let mut change = json!({ "entry_ids": ids });
        if let Some(r) = read {
            change["status"] = json!(if r { "read" } else { "unread" });
        }
        if let Some(s) = starred {
            change["starred"] = json!(s);
        }
        self.call("PUT", "/entries", Some(change))?;
        Ok(format!("Marked {} entries.", ids.len()))
    }
}

#[derive(serde::Deserialize, schemars::JsonSchema)]
pub struct Entries {
    /// unread (the default), read, or all.
    pub status: Option<String>,
    /// Only starred entries.
    #[serde(default)]
    pub starred: bool,
    /// Only this feed's, by id from news_feeds.
    pub feed_id: Option<u64>,
    /// Only this category's, by name.
    pub category: Option<String>,
    /// Words to search titles and text for.
    pub search: Option<String>,
    /// How many, newest first: 30 unless given, at most 100.
    pub limit: Option<u64>,
}

fn feeds_view(feeds: &Value, counters: &Value) -> Value {
    let mut by: BTreeMap<String, Vec<Value>> = BTreeMap::new();
    for f in feeds.as_array().into_iter().flatten() {
        let id = f["id"].as_i64().unwrap_or(0).to_string();
        let mut feed = json!({
            "id": f["id"],
            "title": f["title"],
            "site": f["site_url"],
            "unread": counters["unreads"][&id].as_u64().unwrap_or(0),
        });
        if f["parsing_error_count"].as_u64().unwrap_or(0) > 0 {
            feed["failing"] = f["parsing_error_message"].clone();
        }
        let category = f["category"]["title"].as_str().unwrap_or("").to_owned();
        by.entry(category).or_default().push(feed);
    }
    json!(by)
}

fn entries_view(v: &Value) -> Value {
    let list: Vec<Value> = v["entries"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|e| {
            json!({
                "id": e["id"],
                "feed": e["feed"]["title"],
                "title": e["title"],
                "author": e["author"],
                "published": e["published_at"],
                "url": e["url"],
                "minutes": e["reading_time"],
                "starred": e["starred"],
                "opening": cut(&text(e["content"].as_str().unwrap_or("")), SNIPPET),
            })
        })
        .collect();
    json!({ "total": v["total"], "entries": list })
}

fn article_view(e: &Value) -> String {
    format!(
        "{}\n{} · {} · {}\n{}\n\n{}",
        e["title"].as_str().unwrap_or(""),
        e["feed"]["title"].as_str().unwrap_or(""),
        e["author"].as_str().unwrap_or(""),
        e["published_at"].as_str().unwrap_or(""),
        e["url"].as_str().unwrap_or(""),
        cut(&text(e["content"].as_str().unwrap_or("")), ARTICLE_MAX),
    )
}

fn text(html: &str) -> String {
    html_to_text(html).trim().to_owned()
}

/// At most `max` bytes, cut at a character boundary, marked when cut.
fn cut(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_owned();
    }
    let mut end = max;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", &s[..end])
}

fn url_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn feeds_group_by_category_with_unread_and_failures() {
        let feeds = json!([
            {"id": 1, "title": "Stratechery", "site_url": "https://s", "category": {"title": "Tech"}, "parsing_error_count": 0},
            {"id": 2, "title": "Broken", "site_url": "https://b", "category": {"title": "Tech"}, "parsing_error_count": 3, "parsing_error_message": "404"},
            {"id": 3, "title": "Local", "site_url": "https://l", "category": {"title": "All"}, "parsing_error_count": 0}
        ]);
        let counters = json!({"reads": {}, "unreads": {"1": 4}});
        let v = feeds_view(&feeds, &counters);
        assert_eq!(v["Tech"][0]["unread"], 4);
        assert_eq!(v["Tech"][1]["unread"], 0);
        assert_eq!(v["Tech"][1]["failing"], "404");
        assert!(v["Tech"][0].get("failing").is_none());
        assert_eq!(v["All"][0]["title"], "Local");
    }

    #[test]
    fn entries_carry_a_plain_opening() {
        let long = format!(
            "<p>Hello <b>there</b></p><script>x()</script><p>{}</p>",
            "é".repeat(400)
        );
        let v = json!({"total": 1, "entries": [{"id": 9, "title": "T", "feed": {"title": "F"}, "content": long}]});
        let out = entries_view(&v);
        let opening = out["entries"][0]["opening"].as_str().unwrap();
        assert!(opening.starts_with("Hello there"));
        assert!(!opening.contains("x()"));
        assert!(opening.ends_with('…'));
        assert!(opening.len() <= SNIPPET + '…'.len_utf8());
        assert_eq!(out["entries"][0]["feed"], "F");
    }

    #[test]
    fn article_is_text_under_its_heading() {
        let e = json!({"title": "T", "feed": {"title": "F"}, "author": "A", "published_at": "2026-10-21", "url": "https://x", "content": "<h1>Big</h1><p>Body</p>"});
        let a = article_view(&e);
        assert!(a.starts_with("T\nF · A · 2026-10-21\nhttps://x\n\n"));
        assert!(a.contains("Big") && a.contains("Body") && !a.contains("<p>"));
    }
}
