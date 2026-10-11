//! The yeoman's mail: reading over IMAP and sending over SMTP, both plain
//! protocol over one TLS stream. Reading changes nothing: folders open with
//! EXAMINE and bodies come by BODY.PEEK, so nothing is moved, flagged or
//! marked read. Sending has no tool: the model drafts, and the person's 👍
//! brings the draft here (pending.rs). The accounts file is
//! `[{"name","username","password"}, ...]`; the mail is at the server
//! named for IMAP (993) and SMTP (465).

use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use mail_parser::decoders::html::html_to_text;
use mail_parser::{Address, Message, MessageParser, MimeHeaders};
use rustls::{ClientConfig, ClientConnection, RootCertStore, StreamOwned};
use serde::Deserialize;
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::sync::Arc;
use std::time::Duration;

const TIMEOUT: Duration = Duration::from_secs(30);
/// How much of a message's text a read shows.
const BODY: usize = 20_000;
const IMAP_PORT: u16 = 993;
const SMTP_PORT: u16 = 465;

#[derive(Deserialize, Clone)]
pub struct Account {
    pub name: String,
    pub username: String,
    pub password: String,
}

/// The accounts file read; the one account, or the named one.
pub fn accounts(text: &str) -> Result<Vec<Account>, String> {
    serde_json::from_str(text).map_err(|e| format!("mail accounts: {e}"))
}

pub fn pick<'a>(accounts: &'a [Account], name: Option<&str>) -> Result<&'a Account, String> {
    let names = accounts
        .iter()
        .map(|a| a.name.as_str())
        .collect::<Vec<_>>()
        .join(", ");
    match name.filter(|n| !n.is_empty()) {
        Some(name) => accounts
            .iter()
            .find(|a| a.name == name)
            .ok_or(format!("no account '{name}'; there are: {names}")),
        None if accounts.len() == 1 => Ok(&accounts[0]),
        None => Err(format!("say which account: {names}")),
    }
}

type Tls = StreamOwned<ClientConnection, TcpStream>;

/// A TLS connection to a mail server, with the system's trust roots.
fn connect(host: &str, port: u16) -> Result<BufReader<Tls>, String> {
    let roots = RootCertStore {
        roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
    };
    let config = ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    let name = host
        .to_owned()
        .try_into()
        .map_err(|_| format!("mail: bad host {host}"))?;
    let conn = ClientConnection::new(Arc::new(config), name).map_err(|e| format!("tls: {e}"))?;
    let tcp = TcpStream::connect((host, port)).map_err(|e| format!("{host}: {e}"))?;
    tcp.set_read_timeout(Some(TIMEOUT))
        .and(tcp.set_write_timeout(Some(TIMEOUT)))
        .map_err(|e| format!("{host}: {e}"))?;
    Ok(BufReader::new(StreamOwned::new(conn, tcp)))
}

fn line(stream: &mut BufReader<Tls>) -> Result<String, String> {
    let mut buf = Vec::new();
    stream
        .read_until(b'\n', &mut buf)
        .map_err(|e| format!("mail: {e}"))?;
    if buf.is_empty() {
        return Err("mail: the server hung up".into());
    }
    Ok(String::from_utf8_lossy(&buf).trim_end().to_owned())
}

// --- IMAP ---

/// One untagged response: its text, with a literal's bytes held apart.
#[derive(Debug, PartialEq, Default)]
struct Unit {
    text: String,
    data: Vec<u8>,
}

pub struct Imap {
    stream: BufReader<Tls>,
    tag: u32,
}

/// A piece of a command: plain text, or a string sent as the server
/// prefers (quoted when it can be, a literal otherwise).
enum Arg<'a> {
    Raw(&'a str),
    Str(&'a str),
}

impl Imap {
    pub fn login(host: &str, account: &Account) -> Result<Self, String> {
        let mut stream = connect(host, IMAP_PORT)?;
        let hello = line(&mut stream)?;
        if !hello.starts_with("* OK") && !hello.starts_with("* PREAUTH") {
            return Err(format!("imap: {hello}"));
        }
        let mut imap = Imap { stream, tag: 0 };
        imap.run(&[
            Arg::Raw("LOGIN "),
            Arg::Str(&account.username),
            Arg::Raw(" "),
            Arg::Str(&account.password),
        ])?;
        Ok(imap)
    }

    /// Sends a command and collects its untagged responses until the
    /// tagged line, which must be OK.
    fn run(&mut self, args: &[Arg]) -> Result<Vec<Unit>, String> {
        self.tag += 1;
        let tag = format!("y{}", self.tag);
        let mut out = format!("{tag} ").into_bytes();
        for arg in args {
            match arg {
                Arg::Raw(s) => out.extend_from_slice(s.as_bytes()),
                Arg::Str(s) if s.is_ascii() && !s.contains(['"', '\\', '\r', '\n']) => {
                    out.extend_from_slice(format!("\"{s}\"").as_bytes());
                }
                Arg::Str(s) => {
                    // A literal: the server must say + before its bytes come.
                    out.extend_from_slice(format!("{{{}}}\r\n", s.len()).as_bytes());
                    self.write(&out)?;
                    let go = line(&mut self.stream)?;
                    if !go.starts_with('+') {
                        return Err(format!("imap: {go}"));
                    }
                    out = s.as_bytes().to_vec();
                }
            }
        }
        out.extend_from_slice(b"\r\n");
        self.write(&out)?;
        let mut units = Vec::new();
        loop {
            let mut unit = self.unit()?;
            if let Some(rest) = unit.text.strip_prefix(&format!("{tag} ")) {
                return match rest.split(' ').next() {
                    Some("OK") => Ok(units),
                    _ => Err(format!("imap: {rest}")),
                };
            }
            if unit.text.starts_with('*') {
                unit.text.drain(..1);
                unit.text = unit.text.trim_start().to_owned();
                units.push(unit);
            }
        }
    }

    fn write(&mut self, bytes: &[u8]) -> Result<(), String> {
        let stream = self.stream.get_mut();
        stream
            .write_all(bytes)
            .and(stream.flush())
            .map_err(|e| format!("imap: {e}"))
    }

    /// One response line with any literals it carries read in whole.
    fn unit(&mut self) -> Result<Unit, String> {
        let mut unit = Unit::default();
        loop {
            let text = line(&mut self.stream)?;
            match literal(&text) {
                Some((head, n)) => {
                    unit.text.push_str(head);
                    let mut data = vec![0; n];
                    self.stream
                        .read_exact(&mut data)
                        .map_err(|e| format!("imap: {e}"))?;
                    unit.data.extend(data);
                }
                None => {
                    unit.text.push_str(&text);
                    return Ok(unit);
                }
            }
        }
    }

    pub fn folders(&mut self) -> Result<Vec<String>, String> {
        let units = self.run(&[Arg::Raw("LIST \"\" \"*\"")])?;
        Ok(units
            .iter()
            .filter(|u| u.text.starts_with("LIST "))
            .filter_map(|u| {
                if !u.data.is_empty() {
                    return Some(String::from_utf8_lossy(&u.data).into_owned());
                }
                folder_name(&u.text)
            })
            .collect())
    }

    pub fn open(&mut self, folder: &str) -> Result<(), String> {
        self.run(&[Arg::Raw("EXAMINE "), Arg::Str(folder)])
            .map(drop)
    }

    /// UIDs matching the criteria, newest first.
    pub fn search(&mut self, criteria: &[(&str, &str)]) -> Result<Vec<u32>, String> {
        let mut args = vec![Arg::Raw("UID SEARCH CHARSET UTF-8")];
        for (key, value) in criteria {
            args.push(Arg::Raw(" "));
            args.push(Arg::Raw(key));
            if !value.is_empty() {
                args.push(Arg::Raw(" "));
                args.push(Arg::Str(value));
            }
        }
        if criteria.is_empty() {
            args.push(Arg::Raw(" ALL"));
        }
        let units = self.run(&args)?;
        let mut uids: Vec<u32> = units
            .iter()
            .filter_map(|u| u.text.strip_prefix("SEARCH"))
            .flat_map(|rest| rest.split_whitespace().filter_map(|n| n.parse().ok()))
            .collect();
        uids.sort_unstable_by(|a, b| b.cmp(a));
        Ok(uids)
    }

    /// Each message's flags and the section asked for, by UID.
    fn fetch(
        &mut self,
        uids: &[u32],
        section: &str,
    ) -> Result<Vec<(u32, String, Vec<u8>)>, String> {
        if uids.is_empty() {
            return Ok(Vec::new());
        }
        let set = uids
            .iter()
            .map(u32::to_string)
            .collect::<Vec<_>>()
            .join(",");
        let cmd = format!("UID FETCH {set} (UID FLAGS BODY.PEEK[{section}])");
        let units = self.run(&[Arg::Raw(&cmd)])?;
        Ok(units
            .into_iter()
            .filter(|u| u.text.contains(" FETCH "))
            .filter_map(|u| {
                let uid = field(&u.text, "UID ")?.parse().ok()?;
                let flags = flags(&u.text).unwrap_or("").to_owned();
                Some((uid, flags, u.data))
            })
            .collect())
    }

    pub fn headers(&mut self, uids: &[u32], folder: &str) -> Result<Vec<Value>, String> {
        let mut found = self.fetch(uids, "HEADER")?;
        found.sort_by_key(|f| std::cmp::Reverse(f.0));
        Ok(found
            .iter()
            .map(|(uid, flags, raw)| {
                let msg = MessageParser::default().parse(raw);
                header(msg.as_ref(), *uid, folder, flags)
            })
            .collect())
    }

    pub fn read(&mut self, uid: u32, folder: &str) -> Result<Value, String> {
        let found = self.fetch(&[uid], "")?;
        let (_, flags, raw) = found
            .into_iter()
            .next()
            .ok_or(format!("no message {uid} in {folder}"))?;
        let msg = MessageParser::default().parse(&raw);
        let mut out = header(msg.as_ref(), uid, folder, &flags);
        let Some(msg) = msg else {
            return Ok(out);
        };
        out["to"] = msg.to().map(address).unwrap_or_default().into();
        let text = text_of(&msg);
        let cut = text.char_indices().nth(BODY).map(|(i, _)| i);
        out["text"] = match cut {
            Some(i) => format!("{}\n[cut]", &text[..i]),
            None => text,
        }
        .into();
        out["attachments"] = msg
            .attachments()
            .map(|p| {
                p.attachment_name().map(str::to_owned).unwrap_or_else(|| {
                    p.content_type()
                        .map(|c| match c.subtype() {
                            Some(sub) => format!("{}/{sub}", c.ctype()),
                            None => c.ctype().to_owned(),
                        })
                        .unwrap_or_else(|| "file".into())
                })
            })
            .collect::<Vec<_>>()
            .into();
        Ok(out)
    }
}

/// A line ending in `{n}`: the text before it and n.
fn literal(text: &str) -> Option<(&str, usize)> {
    let head = text.strip_suffix('}')?;
    let open = head.rfind('{')?;
    let n = head[open + 1..].parse().ok()?;
    Some((&head[..open], n))
}

/// The one word after a key in a FETCH response.
fn field<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    let i = text.find(key)?;
    let rest = &text[i + key.len()..];
    Some(rest.split(' ').next().unwrap_or(rest).trim_end_matches(')'))
}

/// The flag list of a FETCH response.
fn flags(text: &str) -> Option<&str> {
    let i = text.find("FLAGS (")?;
    text[i + 7..].split(')').next()
}

/// The mailbox name at the end of a LIST line: quoted or bare.
fn folder_name(text: &str) -> Option<String> {
    let rest = text.strip_prefix("LIST ")?;
    let after_flags = rest.find(')').map_or(rest, |i| rest[i + 1..].trim_start());
    // The delimiter: a quoted character or NIL, then the name.
    let name = match after_flags.strip_prefix('"') {
        Some(q) => q.split_once('"').map(|(_, n)| n.trim_start())?,
        None => after_flags.split_once(' ').map(|(_, n)| n.trim_start())?,
    };
    Some(match name.strip_prefix('"') {
        Some(q) => q
            .strip_suffix('"')
            .unwrap_or(q)
            .replace("\\\"", "\"")
            .replace("\\\\", "\\"),
        None => name.to_owned(),
    })
}

fn address(a: &Address) -> String {
    let one = |addr: &mail_parser::Addr| match (&addr.name, &addr.address) {
        (Some(n), Some(a)) => format!("{n} <{a}>"),
        (None, Some(a)) => a.to_string(),
        (Some(n), None) => n.to_string(),
        (None, None) => String::new(),
    };
    match a {
        Address::List(list) => list.iter().map(one).collect::<Vec<_>>().join(", "),
        Address::Group(groups) => groups
            .iter()
            .flat_map(|g| g.addresses.iter())
            .map(one)
            .collect::<Vec<_>>()
            .join(", "),
    }
}

fn header(msg: Option<&Message>, uid: u32, folder: &str, flags: &str) -> Value {
    let unread = !flags.split(' ').any(|f| f.eq_ignore_ascii_case("\\Seen"));
    json!({
        "uid": uid,
        "folder": folder,
        "date": msg.and_then(|m| m.date()).map(|d| d.to_rfc3339()).unwrap_or_default(),
        "from": msg.and_then(|m| m.from()).map(address).unwrap_or_default(),
        "subject": msg.and_then(|m| m.subject()).unwrap_or_default(),
        "unread": unread,
    })
}

/// The message's plain text, or its HTML as text, blank lines dropped.
fn text_of(msg: &Message) -> String {
    let body = msg
        .body_text(0)
        .map(|t| t.into_owned())
        .or_else(|| msg.body_html(0).map(|h| html_to_text(&h)))
        .unwrap_or_default();
    body.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

// --- SMTP ---

/// Sends plain text from the account's address; the person approved it.
pub fn send(
    host: &str,
    account: &Account,
    to: &str,
    subject: &str,
    body: &str,
) -> Result<String, String> {
    let mut stream = connect(host, SMTP_PORT)?;
    expect(&mut stream, 220)?;
    let mut say = |cmd: String, code: u16| -> Result<(), String> {
        let s = stream.get_mut();
        s.write_all(format!("{cmd}\r\n").as_bytes())
            .and(s.flush())
            .map_err(|e| format!("smtp: {e}"))?;
        expect(&mut stream, code)
    };
    say("EHLO yeoman".into(), 250)?;
    let plain = B64.encode(format!("\0{}\0{}", account.username, account.password));
    say(format!("AUTH PLAIN {plain}"), 235)?;
    say(format!("MAIL FROM:<{}>", account.username), 250)?;
    let recipients = addresses(to);
    if recipients.is_empty() {
        return Err("smtp: no recipient".into());
    }
    for r in &recipients {
        say(format!("RCPT TO:<{r}>"), 250)?;
    }
    say("DATA".into(), 354)?;
    let text = message(&account.username, to, subject, body);
    say(format!("{text}\r\n."), 250)?;
    say("QUIT".into(), 221)?;
    Ok(format!("Sent to {to}."))
}

/// Reads one SMTP reply, which may run several lines, and checks its code.
fn expect(stream: &mut BufReader<Tls>, code: u16) -> Result<(), String> {
    loop {
        let text = line(stream)?;
        let got: u16 = text.get(..3).and_then(|c| c.parse().ok()).unwrap_or(0);
        if text.len() > 3 && &text[3..4] == "-" {
            continue;
        }
        return if got == code {
            Ok(())
        } else {
            Err(format!("smtp: {text}"))
        };
    }
}

/// The bare addresses in a To line: `Name <a@b>, c@d`.
fn addresses(to: &str) -> Vec<String> {
    to.split(',')
        .map(|part| {
            let part = part.trim();
            part.rfind('<')
                .and_then(|i| part[i + 1..].strip_suffix('>'))
                .unwrap_or(part)
                .trim()
                .to_owned()
        })
        .filter(|a| a.contains('@'))
        .collect()
}

/// A header value, encoded if it is not plain ASCII.
fn encoded(text: &str) -> String {
    if text.is_ascii() && !text.contains(['\r', '\n']) {
        text.to_owned()
    } else {
        format!("=?utf-8?B?{}?=", B64.encode(text))
    }
}

/// The message as sent: text in base64 so any character goes, and the
/// line that is a lone dot doubled, as the protocol asks.
fn message(from: &str, to: &str, subject: &str, body: &str) -> String {
    let now = chrono::Local::now();
    let id = format!(
        "<{}.{}@yeoman>",
        now.timestamp_nanos_opt().unwrap_or(0),
        std::process::id()
    );
    let content = B64.encode(body);
    let wrapped = content
        .as_bytes()
        .chunks(76)
        .map(|c| String::from_utf8_lossy(c).into_owned())
        .collect::<Vec<_>>()
        .join("\r\n");
    let head = [
        format!("From: {from}"),
        format!("To: {}", encoded(to)),
        format!("Subject: {}", encoded(subject)),
        format!("Date: {}", now.to_rfc2822()),
        format!("Message-ID: {id}"),
        "MIME-Version: 1.0".to_owned(),
        "Content-Type: text/plain; charset=utf-8".to_owned(),
        "Content-Transfer-Encoding: base64".to_owned(),
    ]
    .join("\r\n");
    format!("{head}\r\n\r\n{wrapped}")
        .lines()
        .map(|l| {
            if l == "." {
                "..".to_owned()
            } else {
                l.to_owned()
            }
        })
        .collect::<Vec<_>>()
        .join("\r\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_accounts_file_names_one_or_asks_which() {
        let two = accounts(
            r#"[{"name":"a","username":"a@x","password":"p"},{"name":"b","username":"b@x","password":"q"}]"#,
        )
        .unwrap();
        assert_eq!(pick(&two, Some("b")).unwrap().username, "b@x");
        let err = |r: Result<&Account, String>| r.err().unwrap_or_default();
        assert!(err(pick(&two, None)).starts_with("say which account"));
        assert!(err(pick(&two, Some("c"))).starts_with("no account"));
        assert_eq!(pick(&two[..1], Some("")).unwrap().name, "a");
        assert!(accounts("nope").is_err());
    }

    #[test]
    fn literals_fields_and_list_lines_parse() {
        assert_eq!(
            literal("* 1 FETCH (UID 7 BODY[HEADER] {123}"),
            Some(("* 1 FETCH (UID 7 BODY[HEADER] ", 123))
        );
        assert_eq!(literal("* 1 FETCH (UID 7)"), None);
        let text = "* 1 FETCH (UID 7 FLAGS (\\Seen \\Flagged) BODY[HEADER] )";
        assert_eq!(field(text, "UID "), Some("7"));
        assert_eq!(flags(text), Some("\\Seen \\Flagged"));
        assert_eq!(flags("* 2 FETCH (UID 8 FLAGS () BODY[] )"), Some(""));
        assert_eq!(
            folder_name(r#"LIST (\HasNoChildren) "/" "Sent Items""#).as_deref(),
            Some("Sent Items")
        );
        assert_eq!(
            folder_name(r#"LIST (\HasNoChildren \Junk) "." INBOX.Junk"#).as_deref(),
            Some("INBOX.Junk")
        );
        assert_eq!(
            folder_name(r#"LIST () NIL "Odd \"Name\"""#).as_deref(),
            Some("Odd \"Name\"")
        );
    }

    #[test]
    fn a_message_yields_its_header_and_text() {
        let raw = b"From: Ann <ann@example.com>\r\nTo: bob@example.com\r\nSubject: =?utf-8?B?SMOpbGxv?=\r\nDate: Sat, 11 Oct 2026 10:00:00 -0400\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>Hi <b>Bob</b></p><script>x()</script><p>bye</p>\r\n";
        let msg = MessageParser::default().parse(raw).unwrap();
        let h = header(Some(&msg), 7, "INBOX", "\\Flagged");
        assert_eq!(h["from"], "Ann <ann@example.com>");
        assert_eq!(h["subject"], "Héllo");
        assert_eq!(h["unread"], true);
        assert!(h["date"].as_str().unwrap().starts_with("2026-10-11"));
        assert_eq!(text_of(&msg), "Hi Bob\nbye");
        assert_eq!(header(None, 7, "INBOX", "\\Seen")["unread"], false);
    }

    #[test]
    fn a_sent_message_is_well_formed() {
        assert_eq!(
            addresses("Ann <ann@x.org>, bob@y.org, nobody"),
            ["ann@x.org", "bob@y.org"]
        );
        assert_eq!(encoded("plain"), "plain");
        assert_eq!(encoded("Héllo"), "=?utf-8?B?SMOpbGxv?=");
        let m = message("me@x.org", "you@y.org", "Hi", "line\n.\nend");
        assert!(m.starts_with("From: me@x.org\r\nTo: you@y.org\r\nSubject: Hi\r\nDate: "));
        assert!(m.contains("\r\nContent-Transfer-Encoding: base64\r\n\r\n"));
        let body = m.rsplit("\r\n\r\n").next().unwrap();
        assert_eq!(
            B64.decode(body.replace("\r\n", "")).unwrap(),
            b"line\n.\nend"
        );
        assert!(!m.lines().any(|l| l == "."));
    }
}
