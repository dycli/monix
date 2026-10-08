//! The few Matrix client-server calls Sokka needs, against the local
//! homeserver over plain HTTP: log in, sync, join, send, show typing.
//! Rooms are unencrypted.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::fs;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// How long one sync waits on the server for news.
const POLL_MS: u64 = 30_000;

/// What survives a restart: the access token, so restarts do not pile up
/// devices, and the sync position, so no message is answered twice.
#[derive(Serialize, Deserialize, Default)]
struct Session {
    token: String,
    user_id: String,
    since: Option<String>,
}

pub struct Matrix {
    hs: String,
    user: String,
    password: String,
    file: PathBuf,
    session: Session,
    txn: u64,
}

/// A text message from someone else in a joined room.
pub struct Message {
    pub room: String,
    pub sender: String,
    pub body: String,
}

/// One sync's news: rooms Sokka was invited to (with who invited it) and
/// new messages.
#[derive(Default)]
pub struct News {
    pub invites: Vec<(String, String)>,
    pub messages: Vec<Message>,
}

pub enum Fail {
    /// The access token is no longer valid; log in again.
    Token,
    Other(String),
}

impl From<String> for Fail {
    fn from(e: String) -> Fail {
        Fail::Other(e)
    }
}

impl Matrix {
    pub fn new(hs: String, user: String, password: String, file: PathBuf) -> Matrix {
        let session = fs::read_to_string(&file)
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default();
        Matrix {
            hs,
            user,
            password,
            file,
            session,
            txn: 0,
        }
    }

    fn save(&self) -> Result<(), String> {
        let tmp = self.file.with_extension("tmp");
        let raw = serde_json::to_string(&self.session).map_err(|e| e.to_string())?;
        fs::write(&tmp, raw).map_err(|e| format!("{}: {e}", tmp.display()))?;
        fs::rename(&tmp, &self.file).map_err(|e| format!("{}: {e}", self.file.display()))
    }

    pub fn logged_in(&self) -> bool {
        !self.session.token.is_empty()
    }

    pub fn login(&mut self) -> Result<(), String> {
        let v = self
            .call(
                "POST",
                "/login",
                Some(json!({
                    "type": "m.login.password",
                    "identifier": {"type": "m.id.user", "user": self.user},
                    "password": self.password,
                    "initial_device_display_name": "sokka",
                })),
                &[],
            )
            .map_err(|e| match e {
                Fail::Token => "login refused".to_owned(),
                Fail::Other(e) => e,
            })?;
        let field = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_owned);
        self.session.token = field("access_token").ok_or(format!("login: {v}"))?;
        self.session.user_id = field("user_id").ok_or(format!("login: {v}"))?;
        self.save()
    }

    pub fn forget_token(&mut self) {
        self.session.token.clear();
    }

    fn call(
        &self,
        method: &str,
        path: &str,
        body: Option<Value>,
        query: &[(&str, &str)],
    ) -> Result<Value, Fail> {
        let url = format!("{}/_matrix/client/v3{path}", self.hs);
        let auth = format!("Bearer {}", self.session.token);
        let timeout = Some(Duration::from_millis(POLL_MS + 30_000));
        let resp = match method {
            "GET" => {
                let mut req = ureq::get(&url).header("Authorization", &auth);
                for (k, v) in query {
                    req = req.query(*k, *v);
                }
                req.config()
                    .http_status_as_error(false)
                    .timeout_global(timeout)
                    .build()
                    .call()
            }
            _ => {
                let req = match method {
                    "PUT" => ureq::put(&url),
                    _ => ureq::post(&url),
                };
                req.header("Authorization", &auth)
                    .config()
                    .http_status_as_error(false)
                    .timeout_global(timeout)
                    .build()
                    .send_json(body.unwrap_or_else(|| json!({})))
            }
        };
        let mut resp = resp.map_err(|e| Fail::Other(format!("{path}: {e}")))?;
        let status = resp.status().as_u16();
        let v: Value = resp
            .body_mut()
            .read_json()
            .map_err(|e| Fail::Other(format!("{path}: {e}")))?;
        if status == 401 {
            return Err(Fail::Token);
        }
        if status >= 400 {
            return Err(Fail::Other(format!("{path}: {status} {v}")));
        }
        Ok(v)
    }

    /// Waits for news. The first sync after a fresh start only finds the
    /// position: old messages are history, not requests.
    pub fn sync(&mut self) -> Result<News, Fail> {
        let filter = json!({
            "presence": {"not_types": ["*"]},
            "account_data": {"not_types": ["*"]},
            "room": {
                "state": {"lazy_load_members": true},
                "ephemeral": {"not_types": ["*"]},
                "timeline": {"types": ["m.room.message"], "limit": 50},
            },
        })
        .to_string();
        let poll = POLL_MS.to_string();
        let mut query = vec![("filter", filter.as_str()), ("timeout", poll.as_str())];
        let since = self.session.since.clone();
        if let Some(s) = &since {
            query.push(("since", s));
        }
        let v = self.call("GET", "/sync", None, &query)?;
        let news = news(&v, &self.session.user_id, since.is_some());
        self.session.since = v
            .get("next_batch")
            .and_then(Value::as_str)
            .map(str::to_owned);
        self.save()?;
        Ok(news)
    }

    pub fn join(&self, room: &str) -> Result<(), Fail> {
        self.call("POST", &format!("/join/{room}"), None, &[])
            .map(|_| ())
    }

    pub fn leave(&self, room: &str) -> Result<(), Fail> {
        self.call("POST", &format!("/rooms/{room}/leave"), None, &[])
            .map(|_| ())
    }

    pub fn send(&mut self, room: &str, body: &str) -> Result<(), Fail> {
        self.txn += 1;
        let millis = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_millis());
        let path = format!("/rooms/{room}/send/m.room.message/{millis}.{}", self.txn);
        self.call(
            "PUT",
            &path,
            Some(json!({"msgtype": "m.text", "body": body})),
            &[],
        )
        .map(|_| ())
    }

    pub fn typing(&self, room: &str, on: bool) -> Result<(), Fail> {
        let path = format!("/rooms/{room}/typing/{}", self.session.user_id);
        let body = if on {
            json!({"typing": true, "timeout": 120_000})
        } else {
            json!({"typing": false})
        };
        self.call("PUT", &path, Some(body), &[]).map(|_| ())
    }
}

/// Reads one sync response: invites to Sokka, and text messages from
/// others when `fresh` (not the first sync).
fn news(v: &Value, me: &str, fresh: bool) -> News {
    let mut out = News::default();
    let rooms = |k: &str| {
        v.pointer(&format!("/rooms/{k}"))
            .and_then(Value::as_object)
            .into_iter()
            .flatten()
    };
    for (room, r) in rooms("invite") {
        let events = r.pointer("/invite_state/events").and_then(Value::as_array);
        let inviter = events.into_iter().flatten().find(|e| {
            e["type"] == "m.room.member"
                && e["state_key"] == me
                && e.pointer("/content/membership") == Some(&json!("invite"))
        });
        if let Some(sender) = inviter.and_then(|e| e["sender"].as_str()) {
            out.invites.push((room.clone(), sender.to_owned()));
        }
    }
    if !fresh {
        return out;
    }
    for (room, r) in rooms("join") {
        let events = r.pointer("/timeline/events").and_then(Value::as_array);
        for e in events.into_iter().flatten() {
            let sender = e["sender"].as_str().unwrap_or("");
            if e["type"] != "m.room.message" || sender == me {
                continue;
            }
            if e.pointer("/content/msgtype") != Some(&json!("m.text")) {
                continue;
            }
            if let Some(body) = e.pointer("/content/body").and_then(Value::as_str) {
                out.messages.push(Message {
                    room: room.clone(),
                    sender: sender.to_owned(),
                    body: body.to_owned(),
                });
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_invites_and_messages() {
        let v = json!({
            "next_batch": "s2",
            "rooms": {
                "invite": {"!a:x": {"invite_state": {"events": [
                    {"type": "m.room.member", "state_key": "@sokka:x",
                     "sender": "@dylan:x", "content": {"membership": "invite"}},
                ]}}},
                "join": {"!b:x": {"timeline": {"events": [
                    {"type": "m.room.message", "sender": "@dylan:x",
                     "content": {"msgtype": "m.text", "body": "hi"}},
                    {"type": "m.room.message", "sender": "@sokka:x",
                     "content": {"msgtype": "m.text", "body": "hello"}},
                    {"type": "m.room.message", "sender": "@dylan:x",
                     "content": {"msgtype": "m.image", "body": "cat.png"}},
                ]}}},
            },
        });
        let n = news(&v, "@sokka:x", true);
        assert_eq!(n.invites, vec![("!a:x".to_owned(), "@dylan:x".to_owned())]);
        assert_eq!(n.messages.len(), 1);
        assert_eq!(n.messages[0].body, "hi");
        assert!(news(&v, "@sokka:x", false).messages.is_empty());
    }
}
