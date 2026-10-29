//! Acts that wait for the person's word. The model can only draft: a draft
//! lands here as a file, the tick loop shows it in the room, and the Matrix
//! handler carries it out when an allowed user reacts 👍 to that message,
//! or drops it on 👎. No tool the model holds can act, so no text it reads
//! can make it.

use crate::fastmail;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Act {
    Mail {
        /// The address it goes from; Fastmail picks when left out.
        #[serde(default)]
        from: Option<String>,
        to: String,
        subject: String,
        body: String,
        /// The id of the email it answers, when it is a reply.
        #[serde(default)]
        reply: Option<String>,
    },
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Pending {
    pub id: u64,
    pub act: Act,
    /// The room event that shows it, once posted.
    pub event: Option<String>,
}

impl Act {
    /// What the room sees, verbatim.
    pub fn show(&self) -> String {
        match self {
            Act::Mail {
                from,
                to,
                subject,
                body,
                reply,
            } => {
                let from = from
                    .as_ref()
                    .map(|a| format!(" from {a}"))
                    .unwrap_or_default();
                let what = if reply.is_some() { "Reply" } else { "Draft" };
                format!(
                    "{what} to {to}{from}\nSubject: {subject}\n\n{body}\n\n👍 sends it, 👎 drops it."
                )
            }
        }
    }

    /// Carries the act out; the model never reaches this. Mail goes out
    /// through Fastmail's send tool, with the token at YEOMAN_FASTMAIL.
    pub fn carry_out(&self) -> Result<String, String> {
        match self {
            Act::Mail { to, .. } => {
                let fastmail = fastmail::from_env()?.ok_or("no mail here")?;
                fastmail.call("send_email", self.arguments())?;
                Ok(format!("Sent to {to}."))
            }
        }
    }

    /// Fastmail's send_email arguments: the body goes as plain text,
    /// exactly as the room saw it.
    fn arguments(&self) -> Value {
        match self {
            Act::Mail {
                from,
                to,
                subject,
                body,
                reply,
            } => {
                let to: Vec<Value> = to
                    .split(',')
                    .map(str::trim)
                    .filter(|a| !a.is_empty())
                    .map(|a| json!({"email": a}))
                    .collect();
                let mut v = json!({"to": to, "subject": subject, "body": body, "format": "text"});
                if let Some(f) = from {
                    v["from"] = json!(f);
                }
                if let Some(id) = reply {
                    v["mode"] = json!("reply");
                    v["emailId"] = json!(id);
                }
                v
            }
        }
    }
}

/// The reaction's meaning: 👍 yes, 👎 no, anything else nothing. Clients
/// append a variation selector to some emoji.
pub fn verdict(key: &str) -> Option<bool> {
    match key.trim_end_matches('\u{fe0f}') {
        "👍" => Some(true),
        "👎" => Some(false),
        _ => None,
    }
}

fn dir(state: &Path) -> PathBuf {
    state.join("pending")
}

fn path(state: &Path, id: u64) -> PathBuf {
    dir(state).join(format!("{id}.json"))
}

/// Files a new act and returns its id.
pub fn add(state: &Path, act: Act) -> Result<u64, String> {
    let mut id = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_millis() as u64;
    // Two acts in one millisecond, from the turn and the tools alike, each
    // claim an id of their own: the first free one from now on.
    let d = dir(state);
    fs::create_dir_all(&d).map_err(|e| format!("{}: {e}", d.display()))?;
    loop {
        match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(path(state, id))
        {
            Ok(_) => break,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => id += 1,
            Err(e) => return Err(format!("{}: {e}", d.display())),
        }
    }
    let p = Pending {
        id,
        act,
        event: None,
    };
    save(state, &p)?;
    Ok(id)
}

/// Writes the act whole or not at all.
pub fn save(state: &Path, p: &Pending) -> Result<(), String> {
    let d = dir(state);
    fs::create_dir_all(&d).map_err(|e| format!("{}: {e}", d.display()))?;
    let tmp = d.join(format!("{}.tmp", p.id));
    let text = serde_json::to_vec(p).map_err(|e| e.to_string())?;
    fs::write(&tmp, text)
        .and_then(|()| fs::rename(&tmp, path(state, p.id)))
        .map_err(|e| format!("{}: {e}", tmp.display()))
}

pub fn remove(state: &Path, id: u64) -> Result<(), String> {
    let p = path(state, id);
    fs::remove_file(&p).map_err(|e| format!("{}: {e}", p.display()))
}

/// Every act waiting, oldest first.
pub fn all(state: &Path) -> Result<Vec<Pending>, String> {
    let d = dir(state);
    let Ok(entries) = fs::read_dir(&d) else {
        return Ok(Vec::new());
    };
    let mut v = Vec::new();
    for e in entries {
        let p = e.map_err(|e| format!("{}: {e}", d.display()))?.path();
        if p.extension().is_some_and(|x| x == "json") {
            let text = fs::read(&p).map_err(|e| format!("{}: {e}", p.display()))?;
            // Claimed by add, not yet written.
            if text.is_empty() {
                continue;
            }
            v.push(serde_json::from_slice(&text).map_err(|e| format!("{}: {e}", p.display()))?);
        }
    }
    v.sort_by_key(|p: &Pending| p.id);
    Ok(v)
}

/// The act a reaction to `event` answers, if any.
pub fn by_event(state: &Path, event: &str) -> Option<Pending> {
    all(state)
        .ok()?
        .into_iter()
        .find(|p| p.event.as_deref() == Some(event))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mail() -> Act {
        Act::Mail {
            from: None,
            to: "a@b.c".into(),
            subject: "Hi".into(),
            body: "Hello.".into(),
            reply: None,
        }
    }

    #[test]
    fn a_draft_waits_until_posted_then_answers_to_its_event() {
        let dir = tempdir();
        let id = add(&dir, mail()).unwrap();
        let mut p = all(&dir).unwrap().remove(0);
        assert_eq!((p.id, p.event.as_deref()), (id, None));
        assert!(by_event(&dir, "$e").is_none());
        p.event = Some("$e".into());
        save(&dir, &p).unwrap();
        assert_eq!(by_event(&dir, "$e").unwrap().act, mail());
        remove(&dir, id).unwrap();
        assert!(all(&dir).unwrap().is_empty());
    }

    #[test]
    fn acts_filed_at_once_keep_their_own_ids() {
        let dir = tempdir();
        let ids: Vec<u64> = (0..5).map(|_| add(&dir, mail()).unwrap()).collect();
        let mut seen = ids.clone();
        seen.dedup();
        assert_eq!(seen.len(), 5);
        assert_eq!(all(&dir).unwrap().len(), 5);
    }

    #[test]
    fn a_thumb_decides_with_or_without_its_selector() {
        assert_eq!(verdict("👍"), Some(true));
        assert_eq!(verdict("👍\u{fe0f}"), Some(true));
        assert_eq!(verdict("👎"), Some(false));
        assert_eq!(verdict("❤️"), None);
    }

    #[test]
    fn the_room_sees_the_whole_draft() {
        let s = mail().show();
        assert!(s.starts_with("Draft to a@b.c\nSubject: Hi\n\nHello.\n\n👍"));
    }

    #[test]
    fn a_reply_goes_to_each_address_as_plain_text() {
        let act = Act::Mail {
            from: Some("me@x.org".into()),
            to: "a@b.c, d@e.f".into(),
            subject: "Re: Hi".into(),
            body: "Yes.".into(),
            reply: Some("M1".into()),
        };
        let v = act.arguments();
        assert_eq!(v["to"], json!([{"email": "a@b.c"}, {"email": "d@e.f"}]));
        assert_eq!(
            (v["mode"].as_str(), v["emailId"].as_str()),
            (Some("reply"), Some("M1"))
        );
        assert_eq!(
            (v["format"].as_str(), v["from"].as_str()),
            (Some("text"), Some("me@x.org"))
        );
        assert!(mail().arguments().get("mode").is_none());
    }

    fn tempdir() -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "yeoman-pending-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&d).unwrap();
        d
    }
}
