//! The calendar: the household's CalDAV accounts, read and written as
//! iCalendar; the only part of the yeoman that holds that login. Times are
//! local to the ship's zone, written YYYY-MM-DD HH:MM, or YYYY-MM-DD for a
//! whole day. New events go up as floating local time, so a repeat keeps
//! its clock time across daylight saving; what comes back in UTC or another
//! zone is shown in the ship's.

use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use chrono::{Duration, NaiveDate, NaiveDateTime, TimeZone, Utc};
use chrono_tz::Tz;
use roxmltree::{Document, Node};
use serde::Deserialize;
use serde_json::{Value, json};
use std::time::{Duration as Wait, SystemTime, UNIX_EPOCH};
use ureq::Agent;
use ureq::http::Request;

const DAV: &str = "DAV:";
const CAL: &str = "urn:ietf:params:xml:ns:caldav";
const TIMEOUT: Wait = Wait::from_secs(30);
pub const REPEATS: [&str; 4] = ["daily", "weekly", "monthly", "yearly"];

#[derive(Deserialize)]
struct Account {
    name: String,
    url: String,
    username: String,
    password: String,
}

pub struct Calendar {
    accounts: Vec<Account>,
    zone: Tz,
    agent: Agent,
}

/// One calendar collection, by the name the person sees.
struct Cal<'a> {
    name: String,
    url: String,
    account: &'a Account,
}

/// An event as stored: where it lives and its text.
struct Found<'a> {
    account: &'a Account,
    href: String,
    etag: Option<String>,
    ics: String,
}

/// A moment as the person writes it: a whole day or a local time.
#[derive(Clone, Copy, PartialEq, Debug)]
enum When {
    Day(NaiveDate),
    Time(NaiveDateTime),
}

/// One iCalendar property line, unfolded.
#[derive(Debug, PartialEq)]
struct Prop {
    name: String,
    params: Vec<(String, String)>,
    value: String,
}

impl Prop {
    fn param(&self, key: &str) -> Option<&str> {
        self.params
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(key))
            .map(|(_, v)| v.as_str())
    }
}

pub struct NewEvent<'a> {
    pub summary: &'a str,
    pub start: &'a str,
    pub end: Option<&'a str>,
    pub calendar: Option<&'a str>,
    pub location: Option<&'a str>,
    pub notes: Option<&'a str>,
    pub repeat: Option<&'a str>,
}

pub struct Change<'a> {
    pub summary: Option<&'a str>,
    pub start: Option<&'a str>,
    pub end: Option<&'a str>,
    pub location: Option<&'a str>,
    pub notes: Option<&'a str>,
}

impl Calendar {
    /// From the accounts file, `[{"name","url","username","password"}, ...]`,
    /// and the zone's name.
    pub fn new(accounts: &str, zone: &str) -> Result<Self, String> {
        let accounts: Vec<Account> =
            serde_json::from_str(accounts).map_err(|e| format!("caldav accounts: {e}"))?;
        let zone: Tz = zone.parse().map_err(|e| format!("YEOMAN_TZ: {e}"))?;
        let config = Agent::config_builder()
            .timeout_global(Some(TIMEOUT))
            .http_status_as_error(false)
            // PROPFIND and REPORT are WebDAV verbs, not HTTP's own.
            .allow_non_standard_methods(true)
            .build();
        Ok(Calendar {
            accounts,
            zone,
            agent: Agent::new_with_config(config),
        })
    }

    fn call(
        &self,
        account: &Account,
        method: &str,
        url: &str,
        headers: &[(&str, &str)],
        body: &str,
    ) -> Result<String, String> {
        let auth = format!(
            "Basic {}",
            B64.encode(format!("{}:{}", account.username, account.password))
        );
        let mut req = Request::builder()
            .method(method)
            .uri(url)
            .header("Authorization", auth);
        for (k, v) in headers {
            req = req.header(*k, *v);
        }
        let req = req.body(body).map_err(|e| format!("caldav: {e}"))?;
        let mut resp = self.agent.run(req).map_err(|e| format!("caldav: {e}"))?;
        let status = resp.status().as_u16();
        let text = resp
            .body_mut()
            .read_to_string()
            .map_err(|e| format!("caldav: {e}"))?;
        if status >= 400 {
            return Err(format!("caldav: {status} on {method} {url}"));
        }
        Ok(text)
    }

    fn propfind(
        &self,
        account: &Account,
        url: &str,
        depth: &str,
        props: &str,
    ) -> Result<String, String> {
        let body = format!(
            r#"<?xml version="1.0" encoding="utf-8"?><D:propfind xmlns:D="DAV:" xmlns:C="{CAL}"><D:prop>{props}</D:prop></D:propfind>"#
        );
        let headers = [
            ("Depth", depth),
            ("Content-Type", "application/xml; charset=utf-8"),
        ];
        self.call(account, "PROPFIND", url, &headers, &body)
    }

    fn report(&self, account: &Account, url: &str, body: &str) -> Result<String, String> {
        let headers = [
            ("Depth", "1"),
            ("Content-Type", "application/xml; charset=utf-8"),
        ];
        self.call(account, "REPORT", url, &headers, body)
    }

    fn put(&self, found: &Found, ics: &str, fresh: bool) -> Result<(), String> {
        let guard = match (&found.etag, fresh) {
            (_, true) => ("If-None-Match", "*".to_owned()),
            (Some(etag), false) => ("If-Match", etag.clone()),
            (None, false) => ("Content-Type", "text/calendar; charset=utf-8".to_owned()),
        };
        let headers = [
            ("Content-Type", "text/calendar; charset=utf-8"),
            (guard.0, guard.1.as_str()),
        ];
        self.call(found.account, "PUT", &found.href, &headers, ics)
            .map(drop)
    }

    /// Every calendar on every account, by the name the person sees.
    fn calendars(&self) -> Result<Vec<Cal<'_>>, String> {
        let mut found = Vec::new();
        for account in &self.accounts {
            for (name, url) in self.collections(account)? {
                let name = if self.accounts.len() > 1 {
                    format!("{}/{name}", account.name)
                } else {
                    name
                };
                found.push(Cal { name, url, account });
            }
        }
        Ok(found)
    }

    /// The calendars of one account, `(name, url)`: the account's URL if
    /// it is itself a calendar, else those under its calendar home.
    fn collections(&self, account: &Account) -> Result<Vec<(String, String)>, String> {
        const PROPS: &str =
            "<D:resourcetype/><D:displayname/><D:current-user-principal/><C:calendar-home-set/>";
        let xml = self.propfind(account, &account.url, "0", PROPS)?;
        let doc = parse(&xml)?;
        let answers = responses(&doc);
        let (href, me) = answers.first().ok_or("caldav: empty answer")?;
        if is_calendar(*me) {
            return Ok(vec![(label(href, *me), join(&account.url, href))]);
        }
        let mut home = href_in(*me, CAL, "calendar-home-set").map(|h| join(&account.url, &h));
        if home.is_none()
            && let Some(principal) = href_in(*me, DAV, "current-user-principal")
        {
            let url = join(&account.url, &principal);
            let xml = self.propfind(account, &url, "0", "<C:calendar-home-set/>")?;
            let doc = parse(&xml)?;
            home = responses(&doc)
                .first()
                .and_then(|(_, n)| href_in(*n, CAL, "calendar-home-set"))
                .map(|h| join(&url, &h));
        }
        let home = home.ok_or("caldav: no calendar home")?;
        let xml = self.propfind(account, &home, "1", "<D:resourcetype/><D:displayname/>")?;
        let doc = parse(&xml)?;
        Ok(responses(&doc)
            .into_iter()
            .filter(|(_, n)| is_calendar(*n))
            .map(|(href, n)| (label(&href, n), join(&home, &href)))
            .collect())
    }

    fn pick(&self, name: Option<&str>) -> Result<Cal<'_>, String> {
        let mut cals = self.calendars()?;
        let names = cals
            .iter()
            .map(|c| c.name.as_str())
            .collect::<Vec<_>>()
            .join(", ");
        match name.filter(|n| !n.is_empty()) {
            Some(name) => cals
                .into_iter()
                .find(|c| c.name == name)
                .ok_or(format!("no calendar '{name}'; there are: {names}")),
            None if cals.len() == 1 => Ok(cals.remove(0)),
            None => Err(format!("say which calendar: {names}")),
        }
    }

    /// Local midnight of a day, as CalDAV wants it: UTC, `YYYYMMDDTHHMMSSZ`.
    fn stamp(&self, day: NaiveDate) -> String {
        let midnight = day.and_hms_opt(0, 0, 0).expect("midnight exists");
        let utc = self
            .zone
            .from_local_datetime(&midnight)
            .earliest()
            .map_or(midnight, |t| t.with_timezone(&Utc).naive_utc());
        utc.format("%Y%m%dT%H%M%SZ").to_string()
    }

    pub fn names(&self) -> Result<String, String> {
        let names: Vec<String> = self.calendars()?.into_iter().map(|c| c.name).collect();
        Ok(serde_json::to_string(&names).unwrap_or_default())
    }

    /// Events from a day for so many days, repeats expanded, on one
    /// calendar or all of them.
    pub fn events(&self, start: &str, days: i64, calendar: Option<&str>) -> Result<String, String> {
        let first = NaiveDate::parse_from_str(start.trim(), "%Y-%m-%d")
            .map_err(|_| "start is YYYY-MM-DD")?;
        let (from, to) = (self.stamp(first), self.stamp(first + Duration::days(days)));
        let chosen = match calendar.filter(|n| !n.is_empty()) {
            Some(name) => vec![self.pick(Some(name))?],
            None => self.calendars()?,
        };
        let body = format!(
            r#"<?xml version="1.0" encoding="utf-8"?><C:calendar-query xmlns:D="DAV:" xmlns:C="{CAL}"><D:prop><C:calendar-data><C:expand start="{from}" end="{to}"/></C:calendar-data></D:prop><C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:time-range start="{from}" end="{to}"/></C:comp-filter></C:comp-filter></C:filter></C:calendar-query>"#
        );
        let mut found = Vec::new();
        for cal in &chosen {
            let xml = self.report(cal.account, &cal.url, &body)?;
            let doc = parse(&xml)?;
            for (_, node) in responses(&doc) {
                let Some(ics) = text_in(node, CAL, "calendar-data") else {
                    continue;
                };
                for event in vevents(&ics) {
                    found.push(self.describe(&event, &cal.name));
                }
            }
        }
        found.sort_by(|a, b| a["start"].as_str().cmp(&b["start"].as_str()));
        Ok(serde_json::to_string_pretty(&found).unwrap_or_default())
    }

    fn describe(&self, event: &[Prop], calendar: &str) -> Value {
        let time = |name: &str| {
            get(event, name)
                .and_then(|p| moment(p, self.zone))
                .map(show)
        };
        let text = |name: &str| {
            get(event, name)
                .map(|p| unescape(&p.value))
                .filter(|t| !t.is_empty())
        };
        json!({
            "uid": text("UID").unwrap_or_default(),
            "calendar": calendar,
            "start": time("DTSTART"),
            "end": time("DTEND"),
            "summary": text("SUMMARY").unwrap_or_default(),
            "location": text("LOCATION"),
            "repeats": get(event, "RRULE").is_some() || get(event, "RECURRENCE-ID").is_some(),
        })
    }

    /// The stored event with this UID, on whichever calendar has it.
    fn find(&self, uid: &str) -> Result<Found<'_>, String> {
        let body = format!(
            r#"<?xml version="1.0" encoding="utf-8"?><C:calendar-query xmlns:D="DAV:" xmlns:C="{CAL}"><D:prop><D:getetag/><C:calendar-data/></D:prop><C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:prop-filter name="UID"><C:text-match collation="i;octet">{}</C:text-match></C:prop-filter></C:comp-filter></C:comp-filter></C:filter></C:calendar-query>"#,
            xml_escape(uid)
        );
        for cal in self.calendars()? {
            let xml = self.report(cal.account, &cal.url, &body)?;
            let doc = parse(&xml)?;
            for (href, node) in responses(&doc) {
                let Some(ics) = text_in(node, CAL, "calendar-data") else {
                    continue;
                };
                if !vevents(&ics)
                    .iter()
                    .any(|e| get(e, "UID").is_some_and(|p| p.value == uid))
                {
                    continue;
                }
                return Ok(Found {
                    account: cal.account,
                    href: join(&cal.url, &href),
                    etag: text_in(node, DAV, "getetag"),
                    ics,
                });
            }
        }
        Err(format!("no event {uid}"))
    }

    pub fn add(&self, event: NewEvent) -> Result<String, String> {
        let begin = when(event.start)?;
        let finish = match event.end.filter(|e| !e.is_empty()) {
            Some(end) => when(end)?,
            None => later(begin),
        };
        let repeat = event.repeat.filter(|r| !r.is_empty());
        if let Some(r) = repeat
            && !REPEATS.contains(&r)
        {
            return Err(format!("repeat is one of {}", REPEATS.join(", ")));
        }
        let cal = self.pick(event.calendar)?;
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        let uid = format!("{nanos}-{}@yeoman", std::process::id());
        let ics = render(
            &uid,
            begin,
            finish,
            event.summary,
            event.location,
            event.notes,
            repeat,
        );
        let found = Found {
            account: cal.account,
            href: format!("{}{uid}.ics", cal.url),
            etag: None,
            ics: String::new(),
        };
        self.put(&found, &ics, true)?;
        Ok(json!({"uid": uid, "start": show(begin), "end": show(finish)}).to_string())
    }

    /// Only the fields given change; a repeating event changes as a whole
    /// series.
    pub fn change(&self, uid: &str, change: Change) -> Result<String, String> {
        let found = self.find(uid)?;
        let ics = edit(&found.ics, self.zone, &change)?;
        self.put(&found, &ics, false)?;
        Ok("changed".into())
    }

    pub fn cancel(&self, uid: &str) -> Result<String, String> {
        let found = self.find(uid)?;
        let guard = found.etag.clone().unwrap_or_else(|| "*".into());
        let headers = [("If-Match", guard.as_str())];
        self.call(found.account, "DELETE", &found.href, &headers, "")?;
        Ok("cancelled".into())
    }
}

// --- WebDAV answers ---

fn parse(xml: &str) -> Result<Document<'_>, String> {
    Document::parse(xml).map_err(|e| format!("caldav: bad xml: {e}"))
}

/// Each `response` of a multistatus: its href and the node to read props from.
fn responses<'a, 'i>(doc: &'a Document<'i>) -> Vec<(String, Node<'a, 'i>)> {
    doc.descendants()
        .filter(|n| n.has_tag_name((DAV, "response")))
        .filter_map(|n| {
            let href = n
                .children()
                .find(|c| c.has_tag_name((DAV, "href")))?
                .text()?
                .trim()
                .to_owned();
            Some((href, n))
        })
        .collect()
}

fn find<'a, 'i>(node: Node<'a, 'i>, ns: &str, name: &str) -> Option<Node<'a, 'i>> {
    node.descendants().find(|n| n.has_tag_name((ns, name)))
}

fn text_in(node: Node, ns: &str, name: &str) -> Option<String> {
    find(node, ns, name)?.text().map(|t| t.trim().to_owned())
}

/// The href inside a property such as calendar-home-set.
fn href_in(node: Node, ns: &str, name: &str) -> Option<String> {
    text_in(find(node, ns, name)?, DAV, "href").filter(|h| !h.is_empty())
}

fn is_calendar(node: Node) -> bool {
    find(node, DAV, "resourcetype").is_some_and(|r| find(r, CAL, "calendar").is_some())
}

/// A collection's name: its display name, else the last part of its path.
fn label(href: &str, node: Node) -> String {
    text_in(node, DAV, "displayname")
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| {
            href.trim_end_matches('/')
                .rsplit('/')
                .next()
                .unwrap_or("")
                .to_owned()
        })
}

/// An href against its base: absolute as is, a path on the base's host;
/// a collection's URL ends in a slash.
fn join(base: &str, href: &str) -> String {
    if href.starts_with("http://") || href.starts_with("https://") {
        return href.to_owned();
    }
    let origin = base
        .find("://")
        .and_then(|i| base[i + 3..].find('/').map(|j| &base[..i + 3 + j]))
        .unwrap_or(base.trim_end_matches('/'));
    format!("{origin}{href}")
}

fn xml_escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

// --- iCalendar ---

/// Lines with their continuations joined and line ends dropped.
fn unfold(text: &str) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    for raw in text.split('\n') {
        let raw = raw.strip_suffix('\r').unwrap_or(raw);
        if let Some(rest) = raw.strip_prefix([' ', '\t'])
            && let Some(last) = lines.last_mut()
        {
            last.push_str(rest);
        } else if !raw.is_empty() {
            lines.push(raw.to_owned());
        }
    }
    lines
}

/// A line folded to short pieces, as the format asks.
fn fold(line: &str) -> String {
    let chars: Vec<char> = line.chars().collect();
    chars
        .chunks(70)
        .map(|c| c.iter().collect::<String>())
        .collect::<Vec<_>>()
        .join("\r\n ")
}

/// `NAME;PARAM=value:value`, the first colon outside quotes splitting.
fn prop(line: &str) -> Option<Prop> {
    let mut quoted = false;
    let colon = line.char_indices().find_map(|(i, c)| {
        match c {
            '"' => quoted = !quoted,
            ':' if !quoted => return Some(i),
            _ => {}
        }
        None
    })?;
    let (head, value) = (&line[..colon], &line[colon + 1..]);
    let mut parts = head.split(';');
    let name = parts.next()?.trim().to_ascii_uppercase();
    let params = parts
        .filter_map(|p| p.split_once('='))
        .map(|(k, v)| {
            (
                k.trim().to_ascii_uppercase(),
                v.trim_matches('"').to_owned(),
            )
        })
        .collect();
    Some(Prop {
        name,
        params,
        value: value.to_owned(),
    })
}

/// Each VEVENT's own properties, nested alarms left out.
fn vevents(ics: &str) -> Vec<Vec<Prop>> {
    let mut events = Vec::new();
    let mut current: Option<Vec<Prop>> = None;
    let mut nested = 0;
    for line in unfold(ics) {
        let upper = line.to_ascii_uppercase();
        match (upper.as_str(), &mut current) {
            ("BEGIN:VEVENT", _) => current = Some(Vec::new()),
            ("END:VEVENT", Some(_)) => events.push(current.take().unwrap_or_default()),
            (l, Some(_)) if l.starts_with("BEGIN:") => nested += 1,
            (l, Some(_)) if l.starts_with("END:") => nested -= 1,
            (_, Some(props)) if nested == 0 => props.extend(prop(&line)),
            _ => {}
        }
    }
    events
}

fn get<'a>(props: &'a [Prop], name: &str) -> Option<&'a Prop> {
    props.iter().find(|p| p.name == name)
}

fn unescape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n' | 'N') => out.push('\n'),
            Some(other) => out.push(other),
            None => out.push('\\'),
        }
    }
    out
}

fn escape(text: &str) -> String {
    text.replace('\\', "\\\\")
        .replace(';', "\\;")
        .replace(',', "\\,")
        .replace('\n', "\\n")
}

/// A stored time in the ship's zone: a date, a UTC time, a time in a
/// named zone, or a floating one taken as already local.
fn moment(prop: &Prop, zone: Tz) -> Option<When> {
    let v = prop.value.trim();
    if v.len() == 8 || prop.param("VALUE") == Some("DATE") {
        return NaiveDate::parse_from_str(v, "%Y%m%d").ok().map(When::Day);
    }
    if let Some(utc) = v.strip_suffix('Z') {
        let t = NaiveDateTime::parse_from_str(utc, "%Y%m%dT%H%M%S").ok()?;
        return Some(When::Time(
            Utc.from_utc_datetime(&t).with_timezone(&zone).naive_local(),
        ));
    }
    let t = NaiveDateTime::parse_from_str(v, "%Y%m%dT%H%M%S").ok()?;
    let named: Option<Tz> = prop.param("TZID").and_then(|z| z.parse().ok());
    Some(When::Time(match named {
        Some(tz) => tz
            .from_local_datetime(&t)
            .earliest()?
            .with_timezone(&zone)
            .naive_local(),
        None => t,
    }))
}

/// YYYY-MM-DD HH:MM in local time, or YYYY-MM-DD for a whole day.
fn when(text: &str) -> Result<When, String> {
    let text = text.trim();
    if text.len() == 10 {
        return NaiveDate::parse_from_str(text, "%Y-%m-%d")
            .map(When::Day)
            .map_err(|_| format!("'{text}' is not YYYY-MM-DD"));
    }
    NaiveDateTime::parse_from_str(text, "%Y-%m-%d %H:%M")
        .map(When::Time)
        .map_err(|_| format!("'{text}' is not YYYY-MM-DD HH:MM"))
}

fn show(w: When) -> String {
    match w {
        When::Day(d) => d.format("%Y-%m-%d").to_string(),
        When::Time(t) => t.format("%Y-%m-%d %H:%M").to_string(),
    }
}

/// The default end: an hour on, or the next day.
fn later(w: When) -> When {
    match w {
        When::Day(d) => When::Day(d + Duration::days(1)),
        When::Time(t) => When::Time(t + Duration::hours(1)),
    }
}

/// A new end keeping the old one's distance from the start, when both
/// are of the same kind; else the default.
fn shifted(begin: When, old_start: Option<When>, old_end: Option<When>) -> When {
    match (begin, old_start, old_end) {
        (When::Time(b), Some(When::Time(s)), Some(When::Time(e))) => When::Time(b + (e - s)),
        (When::Day(b), Some(When::Day(s)), Some(When::Day(e))) => When::Day(b + (e - s)),
        _ => later(begin),
    }
}

/// A date or time property line, floating local time.
fn stamp(name: &str, w: When) -> String {
    match w {
        When::Day(d) => format!("{name};VALUE=DATE:{}", d.format("%Y%m%d")),
        When::Time(t) => format!("{name}:{}", t.format("%Y%m%dT%H%M%S")),
    }
}

fn render(
    uid: &str,
    begin: When,
    finish: When,
    summary: &str,
    location: Option<&str>,
    notes: Option<&str>,
    repeat: Option<&str>,
) -> String {
    let mut lines = vec![
        "BEGIN:VCALENDAR".to_owned(),
        "VERSION:2.0".to_owned(),
        "PRODID:-//yeoman//EN".to_owned(),
        "BEGIN:VEVENT".to_owned(),
        format!("UID:{uid}"),
        format!("DTSTAMP:{}", Utc::now().format("%Y%m%dT%H%M%SZ")),
        stamp("DTSTART", begin),
        stamp("DTEND", finish),
        format!("SUMMARY:{}", escape(summary)),
    ];
    if let Some(l) = location.filter(|l| !l.is_empty()) {
        lines.push(format!("LOCATION:{}", escape(l)));
    }
    if let Some(n) = notes.filter(|n| !n.is_empty()) {
        lines.push(format!("DESCRIPTION:{}", escape(n)));
    }
    if let Some(r) = repeat {
        lines.push(format!("RRULE:FREQ={}", r.to_ascii_uppercase()));
    }
    lines.push("END:VEVENT".to_owned());
    lines.push("END:VCALENDAR".to_owned());
    lines.iter().map(|l| fold(l) + "\r\n").collect()
}

/// The stored text with the given fields replaced in its first VEVENT;
/// a new start without a new end keeps the event's length.
fn edit(ics: &str, zone: Tz, change: &Change) -> Result<String, String> {
    let lines = unfold(ics);
    let open = lines
        .iter()
        .position(|l| l.eq_ignore_ascii_case("BEGIN:VEVENT"))
        .ok_or("caldav: no event in the stored text")?;
    let close = lines[open..]
        .iter()
        .position(|l| l.eq_ignore_ascii_case("END:VEVENT"))
        .map(|i| open + i)
        .ok_or("caldav: unterminated event")?;
    let event = vevents(ics).into_iter().next().unwrap_or_default();
    let old = |name: &str| get(&event, name).and_then(|p| moment(p, zone));

    let mut drop: Vec<&str> = Vec::new();
    let mut add: Vec<String> = Vec::new();
    if let Some(start) = change.start.filter(|s| !s.is_empty()) {
        let begin = when(start)?;
        drop.push("DTSTART");
        add.push(stamp("DTSTART", begin));
        if change.end.filter(|e| !e.is_empty()).is_none() && old("DTEND").is_some() {
            drop.push("DTEND");
            add.push(stamp("DTEND", shifted(begin, old("DTSTART"), old("DTEND"))));
        }
    }
    if let Some(end) = change.end.filter(|e| !e.is_empty()) {
        drop.push("DTEND");
        add.push(stamp("DTEND", when(end)?));
    }
    for (name, value) in [
        ("SUMMARY", change.summary),
        ("LOCATION", change.location),
        ("DESCRIPTION", change.notes),
    ] {
        if let Some(v) = value.filter(|v| !v.is_empty()) {
            drop.push(name);
            add.push(format!("{name}:{}", escape(v)));
        }
    }

    let mut out: Vec<String> = lines[..=open].to_vec();
    let mut nested = 0;
    for line in &lines[open + 1..close] {
        let upper = line.to_ascii_uppercase();
        if upper.starts_with("BEGIN:") {
            nested += 1;
        }
        let name = prop(line).map(|p| p.name).unwrap_or_default();
        if nested > 0 || !drop.contains(&name.as_str()) {
            out.push(line.clone());
        }
        if upper.starts_with("END:") {
            nested -= 1;
        }
    }
    out.extend(add);
    out.extend(lines[close..].iter().cloned());
    Ok(out.iter().map(|l| fold(l) + "\r\n").collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    const NY: Tz = chrono_tz::America::New_York;

    #[test]
    fn folded_lines_unfold_and_fold_back() {
        let text = "BEGIN:VEVENT\r\nSUMMARY:a long\r\n  summary\r\n\tmore\r\nEND:VEVENT\r\n";
        assert_eq!(
            unfold(text),
            ["BEGIN:VEVENT", "SUMMARY:a long summarymore", "END:VEVENT"]
        );
        let long = format!("SUMMARY:{}", "x".repeat(100));
        let folded = fold(&long);
        assert!(folded.lines().all(|l| l.chars().count() <= 70));
        assert_eq!(unfold(&folded), [long]);
    }

    #[test]
    fn a_property_splits_at_the_first_colon_outside_quotes() {
        let p = prop(r#"ATTENDEE;CN="Dr. Who: Tardis";ROLE=REQ:mailto:a@b"#).unwrap();
        assert_eq!(p.name, "ATTENDEE");
        assert_eq!(p.param("cn"), Some("Dr. Who: Tardis"));
        assert_eq!(p.param("ROLE"), Some("REQ"));
        assert_eq!(p.value, "mailto:a@b");
        assert_eq!(prop("no colon"), None);
    }

    #[test]
    fn stored_times_come_out_in_the_ships_zone() {
        let t = |line: &str| moment(&prop(line).unwrap(), NY).map(show);
        assert_eq!(t("DTSTART;VALUE=DATE:20261011"), Some("2026-10-11".into()));
        assert_eq!(
            t("DTSTART:20261011T170000Z"),
            Some("2026-10-11 13:00".into())
        );
        assert_eq!(
            t("DTSTART;TZID=Europe/Paris:20261011T190000"),
            Some("2026-10-11 13:00".into())
        );
        assert_eq!(
            t("DTSTART:20261011T130000"),
            Some("2026-10-11 13:00".into())
        );
        assert_eq!(t("DTSTART:garbage"), None);
    }

    #[test]
    fn the_persons_times_parse_and_default_ends_follow() {
        let day = when("2026-10-11").unwrap();
        let time = when(" 2026-10-11 09:30 ").unwrap();
        assert_eq!(show(later(day)), "2026-10-12");
        assert_eq!(show(later(time)), "2026-10-11 10:30");
        assert!(when("tomorrow").is_err());
        assert_eq!(stamp("DTSTART", day), "DTSTART;VALUE=DATE:20261011");
        assert_eq!(stamp("DTEND", time), "DTEND:20261011T093000");
    }

    #[test]
    fn a_new_event_renders_with_its_fields_escaped() {
        let ics = render(
            "u1",
            when("2026-10-11 09:00").unwrap(),
            when("2026-10-11 10:00").unwrap(),
            "Dentist; teeth, gums",
            Some("Main St"),
            None,
            Some("weekly"),
        );
        let lines = unfold(&ics);
        assert!(lines.contains(&"UID:u1".to_owned()));
        assert!(lines.contains(&"SUMMARY:Dentist\\; teeth\\, gums".to_owned()));
        assert!(lines.contains(&"LOCATION:Main St".to_owned()));
        assert!(lines.contains(&"RRULE:FREQ=WEEKLY".to_owned()));
        assert!(!lines.iter().any(|l| l.starts_with("DESCRIPTION")));
        let event = &vevents(&ics)[0];
        assert_eq!(
            unescape(&get(event, "SUMMARY").unwrap().value),
            "Dentist; teeth, gums"
        );
    }

    #[test]
    fn an_edit_replaces_fields_keeps_length_and_leaves_alarms() {
        let ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:u1\r\nDTSTART;TZID=America/New_York:20261011T090000\r\nDTEND;TZID=America/New_York:20261011T103000\r\nSUMMARY:Old\r\nBEGIN:VALARM\r\nDESCRIPTION:ring\r\nEND:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
        let change = Change {
            summary: Some("New"),
            start: Some("2026-10-12 14:00"),
            end: None,
            location: None,
            notes: Some("bring forms"),
        };
        let out = edit(ics, NY, &change).unwrap();
        let lines = unfold(&out);
        assert!(lines.contains(&"DTSTART:20261012T140000".to_owned()));
        assert!(lines.contains(&"DTEND:20261012T153000".to_owned()));
        assert!(lines.contains(&"SUMMARY:New".to_owned()));
        assert!(lines.contains(&"DESCRIPTION:bring forms".to_owned()));
        assert!(lines.contains(&"DESCRIPTION:ring".to_owned()));
        assert!(!lines.contains(&"SUMMARY:Old".to_owned()));
        assert_eq!(lines.iter().filter(|l| l.starts_with("DTSTART")).count(), 1);
        assert_eq!(
            vevents(&out)[0]
                .iter()
                .filter(|p| p.name == "DESCRIPTION")
                .count(),
            1
        );
    }

    #[test]
    fn a_multistatus_yields_calendars_homes_and_names() {
        let xml = r#"<?xml version="1.0"?><D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
          <D:response><D:href>/home/calendars/</D:href><D:propstat><D:prop>
            <D:resourcetype><D:collection/></D:resourcetype>
            <C:calendar-home-set><D:href>/home/calendars/</D:href></C:calendar-home-set>
          </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
          <D:response><D:href>/home/calendars/family/</D:href><D:propstat><D:prop>
            <D:resourcetype><D:collection/><C:calendar/></D:resourcetype>
            <D:displayname>Family</D:displayname>
          </D:prop></D:propstat></D:response>
          <D:response><D:href>/home/calendars/work/</D:href><D:propstat><D:prop>
            <D:resourcetype><D:collection/><C:calendar/></D:resourcetype>
            <D:displayname/>
          </D:prop></D:propstat></D:response>
        </D:multistatus>"#;
        let doc = parse(xml).unwrap();
        let answers = responses(&doc);
        assert_eq!(answers.len(), 3);
        assert!(!is_calendar(answers[0].1));
        assert_eq!(
            href_in(answers[0].1, CAL, "calendar-home-set").as_deref(),
            Some("/home/calendars/")
        );
        assert!(is_calendar(answers[1].1));
        assert_eq!(label(&answers[1].0, answers[1].1), "Family");
        assert_eq!(label(&answers[2].0, answers[2].1), "work");
        assert_eq!(
            join("https://cdav.example.com/home/", "/home/calendars/family/"),
            "https://cdav.example.com/home/calendars/family/"
        );
        assert_eq!(join("https://a.b/x/", "https://c.d/y"), "https://c.d/y");
    }
}
