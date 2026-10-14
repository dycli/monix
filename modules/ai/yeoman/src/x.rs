//! X, read through Grok's `x_search` on xAI's Responses API, paid by the
//! household's X subscription. The service (`yeoman x`, one per
//! connection on the socket) alone holds the subscription's sign-in, a
//! Grok CLI login made once with `yeoman x login`; the tools reach only
//! its socket. Grok runs the searches and answers with the posts it found
//! and their links. It reads X and nothing else, so it acts on nothing.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::fs::{self, File};
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use ureq::Agent;

const AUTH: &str = "https://auth.x.ai/oauth2";
/// The Grok CLI's public client, whose sign-in the subscription covers.
const CLIENT: &str = "b1a00492-073a-47ea-816f-4c329264a828";
const SCOPE: &str = "openid profile email offline_access grok-cli:access api:access";
const API: &str = "https://api.x.ai/v1/responses";
const MODEL: &str = "grok-4.7";
const TIMEOUT: Duration = Duration::from_secs(300);
/// Refresh the access token this long before it expires.
const MARGIN: u64 = 300;
const INSTRUCTIONS: &str = "Search X for the request below. Report what \
you found, newest first: for each post that matters, the author's handle, \
the date, what it says (quoted when short) and its link. Report, do not \
editorialize; if nothing relevant turns up, say so plainly.";

/// A search, as the tool takes it and the socket carries it.
#[derive(Serialize, Deserialize, JsonSchema)]
pub struct Ask {
    /// What to look for on X, in a sentence.
    pub query: String,
    /// Only posts from these handles (no @), at most 20.
    #[serde(default)]
    pub handles: Vec<String>,
    /// Leave out posts from these handles (no @), at most 20; not with handles.
    #[serde(default)]
    pub exclude: Vec<String>,
    /// Only posts from this day on, YYYY-MM-DD.
    pub from: Option<String>,
    /// Only posts up to this day, YYYY-MM-DD.
    pub to: Option<String>,
}

/// The tools' side: one search over the service's socket.
pub fn ask(sock: &Path, ask: &Ask) -> Result<String, String> {
    let mut s = UnixStream::connect(sock).map_err(|e| format!("x: {e}"))?;
    s.set_read_timeout(Some(TIMEOUT + Duration::from_secs(30)))
        .map_err(|e| e.to_string())?;
    let body = serde_json::to_vec(ask).map_err(|e| e.to_string())?;
    s.write_all(&body).map_err(|e| format!("x: {e}"))?;
    s.shutdown(std::net::Shutdown::Write)
        .map_err(|e| format!("x: {e}"))?;
    let mut reply = String::new();
    s.read_to_string(&mut reply)
        .map_err(|e| format!("x: {e}"))?;
    let reply: Value = serde_json::from_str(&reply).map_err(|e| format!("x: {e}"))?;
    match (reply["ok"].as_str(), reply["err"].as_str()) {
        (Some(text), _) => Ok(text.to_owned()),
        (_, Some(err)) => Err(format!("x: {err}")),
        _ => Err("x: no answer".into()),
    }
}

/// The service's side: one search from stdin, its answer to stdout.
pub fn serve() -> Result<(), String> {
    let mut body = Vec::new();
    std::io::stdin()
        .take(64 * 1024)
        .read_to_end(&mut body)
        .map_err(|e| e.to_string())?;
    let reply = match serde_json::from_slice::<Ask>(&body)
        .map_err(|e| e.to_string())
        .and_then(|a| search(&a))
    {
        Ok(text) => json!({ "ok": text }),
        Err(e) => {
            eprintln!("yeoman-x: {e}");
            json!({ "err": e })
        }
    };
    std::io::stdout()
        .write_all(reply.to_string().as_bytes())
        .map_err(|e| e.to_string())
}

fn agent() -> Agent {
    Agent::new_with_config(
        Agent::config_builder()
            .timeout_global(Some(TIMEOUT))
            .http_status_as_error(false)
            .build(),
    )
}

fn search(ask: &Ask) -> Result<String, String> {
    let token = token()?;
    let body = json!({
        "model": MODEL,
        "store": false,
        "input": [
            {"role": "system", "content": INSTRUCTIONS},
            {"role": "user", "content": request(ask)},
        ],
        "tools": [tool(ask)?],
    });
    let mut resp = agent()
        .post(API)
        .header("Authorization", &format!("Bearer {token}"))
        .send_json(&body)
        .map_err(|e| format!("xai: {e}"))?;
    let status = resp.status().as_u16();
    let reply: Value = resp
        .body_mut()
        .read_json()
        .map_err(|e| format!("xai: {status}: {e}"))?;
    if status >= 400 {
        let msg = reply["error"]["message"]
            .as_str()
            .or(reply["error"].as_str())
            .unwrap_or("failed");
        return Err(format!("xai: {status}: {msg}"));
    }
    let u = &reply["usage"];
    eprintln!(
        "yeoman-x: tokens model={MODEL} input={} cache_read={} output={} tools={}",
        u["input_tokens"],
        u["input_tokens_details"]["cached_tokens"],
        u["output_tokens"],
        u["server_side_tool_usage_details"]
    );
    answer(&reply)
}

/// The request as Grok reads it: the tool's filters bind the search, but
/// Grok sees only the text, so the text names them too.
fn request(ask: &Ask) -> String {
    let mut text = ask.query.trim().to_owned();
    let at = |hs: &[String]| {
        hs.iter()
            .map(|h| format!("@{}", h.trim().trim_start_matches('@')))
            .collect::<Vec<_>>()
            .join(", ")
    };
    if !ask.handles.is_empty() {
        text.push_str(&format!("\nOnly posts from {}.", at(&ask.handles)));
    }
    if !ask.exclude.is_empty() {
        text.push_str(&format!("\nNot posts from {}.", at(&ask.exclude)));
    }
    if let Some(from) = &ask.from {
        text.push_str(&format!("\nFrom {from}."));
    }
    if let Some(to) = &ask.to {
        text.push_str(&format!("\nUp to {to}."));
    }
    text
}

/// The x_search tool with the search's filters.
fn tool(ask: &Ask) -> Result<Value, String> {
    let clean = |hs: &[String]| -> Vec<String> {
        hs.iter()
            .map(|h| h.trim().trim_start_matches('@').to_owned())
            .filter(|h| !h.is_empty())
            .collect()
    };
    let (handles, exclude) = (clean(&ask.handles), clean(&ask.exclude));
    if !handles.is_empty() && !exclude.is_empty() {
        return Err("Give handles or exclude, not both.".into());
    }
    if handles.len() > 20 || exclude.len() > 20 {
        return Err("At most 20 handles.".into());
    }
    let mut tool = json!({"type": "x_search"});
    if !handles.is_empty() {
        tool["allowed_x_handles"] = json!(handles);
    }
    if !exclude.is_empty() {
        tool["excluded_x_handles"] = json!(exclude);
    }
    for (key, day) in [("from_date", &ask.from), ("to_date", &ask.to)] {
        if let Some(day) = day.as_deref().map(str::trim).filter(|d| !d.is_empty()) {
            chrono::NaiveDate::parse_from_str(day, "%Y-%m-%d")
                .map_err(|_| format!("{day}: a day is YYYY-MM-DD."))?;
            tool[key] = day.into();
        }
    }
    Ok(tool)
}

/// The answer's text, then the links it cites.
fn answer(reply: &Value) -> Result<String, String> {
    let mut text = Vec::new();
    let mut links: Vec<&str> = Vec::new();
    let parts = reply["output"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|o| o["type"] == "message")
        .flat_map(|o| o["content"].as_array().into_iter().flatten())
        .filter(|c| c["type"] == "output_text");
    for part in parts {
        text.extend(part["text"].as_str());
        for a in part["annotations"].as_array().into_iter().flatten() {
            if let Some(url) = a["url"].as_str()
                && !links.contains(&url)
            {
                links.push(url);
            }
        }
    }
    if text.is_empty() {
        return Err("xai: no answer".into());
    }
    let mut out = text.join("\n");
    if !links.is_empty() {
        out.push_str("\n\nSources:\n");
        out.push_str(&links.join("\n"));
    }
    Ok(out)
}

#[derive(Serialize, Deserialize)]
struct Login {
    access: String,
    refresh: String,
    /// Unix seconds.
    expires: u64,
}

fn home() -> Result<PathBuf, String> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or("HOME is not set".into())
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// A live access token, refreshed under a lock when near its end: the
/// refresh token may turn over, so two refreshes must not race.
fn token() -> Result<String, String> {
    let dir = home()?;
    let lock = File::create(dir.join("login.lock")).map_err(|e| e.to_string())?;
    lock.lock().map_err(|e| e.to_string())?;
    let path = dir.join("login.json");
    let text = fs::read_to_string(&path)
        .map_err(|_| "Not signed in to xAI: run `yeoman x login` as the service.".to_owned())?;
    let login: Login = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    if login.expires > now() + MARGIN {
        return Ok(login.access);
    }
    let fresh = grant(&[
        ("grant_type", "refresh_token"),
        ("refresh_token", &login.refresh),
    ])?;
    let fresh = granted(&fresh, Some(&login.refresh))?;
    save(&path, &fresh)?;
    Ok(fresh.access)
}

/// A post to the token endpoint, the client named.
fn grant(form: &[(&str, &str)]) -> Result<Value, String> {
    let mut form = form.to_vec();
    form.push(("client_id", CLIENT));
    let mut resp = agent()
        .post(&format!("{AUTH}/token"))
        .send_form(form)
        .map_err(|e| format!("xai auth: {e}"))?;
    resp.body_mut()
        .read_json()
        .map_err(|e| format!("xai auth: {e}"))
}

/// The login a token reply grants; a refresh that hands back no new
/// refresh token keeps the old one.
fn granted(reply: &Value, old: Option<&str>) -> Result<Login, String> {
    if let Some(err) = reply["error"].as_str() {
        return Err(format!("xai auth: {err}"));
    }
    let access = reply["access_token"].as_str().ok_or("xai auth: no token")?;
    let refresh = reply["refresh_token"]
        .as_str()
        .or(old)
        .ok_or("xai auth: no refresh token")?;
    Ok(Login {
        access: access.to_owned(),
        refresh: refresh.to_owned(),
        expires: now() + reply["expires_in"].as_u64().unwrap_or(3600),
    })
}

fn save(path: &Path, login: &Login) -> Result<(), String> {
    let tmp = path.with_extension("tmp");
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)
        .map_err(|e| e.to_string())?;
    f.write_all(&serde_json::to_vec(login).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    fs::rename(&tmp, path).map_err(|e| e.to_string())
}

/// Signs in once by device code: prints a link to approve on any device,
/// then waits for it.
pub fn login() -> Result<(), String> {
    let mut resp = agent()
        .post(&format!("{AUTH}/device/code"))
        .send_form([("client_id", CLIENT), ("scope", SCOPE)])
        .map_err(|e| format!("xai auth: {e}"))?;
    let start: Value = resp
        .body_mut()
        .read_json()
        .map_err(|e| format!("xai auth: {e}"))?;
    let device = start["device_code"]
        .as_str()
        .ok_or("xai auth: no device code")?;
    println!(
        "Open {} and approve code {}.",
        start["verification_uri_complete"].as_str().unwrap_or("?"),
        start["user_code"].as_str().unwrap_or("?")
    );
    let mut wait = start["interval"].as_u64().unwrap_or(5);
    let end = now() + start["expires_in"].as_u64().unwrap_or(900);
    while now() < end {
        std::thread::sleep(Duration::from_secs(wait));
        // A dropped connection is no answer yet: ask again.
        let Ok(reply) = grant(&[
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ("device_code", device),
        ]) else {
            continue;
        };
        match reply["error"].as_str() {
            Some("authorization_pending") => continue,
            Some("slow_down") => wait += 5,
            _ => {
                save(&home()?.join("login.json"), &granted(&reply, None)?)?;
                println!("Signed in.");
                return Ok(());
            }
        }
    }
    Err("The code expired.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ask(handles: &[&str], exclude: &[&str], from: Option<&str>) -> Ask {
        Ask {
            query: "q".into(),
            handles: handles.iter().map(|&h| h.into()).collect(),
            exclude: exclude.iter().map(|&h| h.into()).collect(),
            from: from.map(Into::into),
            to: None,
        }
    }

    #[test]
    fn the_tool_carries_clean_handles_and_checked_days() {
        let t = tool(&ask(&["@xai", " nasa "], &[], Some("2026-10-01"))).unwrap();
        assert_eq!(
            t,
            json!({"type": "x_search", "allowed_x_handles": ["xai", "nasa"], "from_date": "2026-10-01"})
        );
        assert!(tool(&ask(&["a"], &["b"], None)).is_err());
        assert!(tool(&ask(&[], &[], Some("Oct 1"))).is_err());
        assert_eq!(
            tool(&ask(&["@"], &[], Some(" "))).unwrap(),
            json!({"type": "x_search"})
        );
    }

    #[test]
    fn the_request_names_its_filters() {
        assert_eq!(
            request(&ask(&["xai"], &[], Some("2026-10-01"))),
            "q\nOnly posts from @xai.\nFrom 2026-10-01."
        );
    }

    #[test]
    fn an_answer_is_its_text_then_its_links_once_each() {
        let reply = json!({"output": [
            {"type": "reasoning"},
            {"type": "message", "content": [{"type": "output_text", "text": "Two posts.",
                "annotations": [
                    {"type": "url_citation", "url": "https://x.com/a/status/1"},
                    {"type": "url_citation", "url": "https://x.com/a/status/1"},
                    {"type": "url_citation", "url": "https://x.com/b/status/2"}]}]}]});
        assert_eq!(
            answer(&reply).unwrap(),
            "Two posts.\n\nSources:\nhttps://x.com/a/status/1\nhttps://x.com/b/status/2"
        );
        assert!(answer(&json!({"output": []})).is_err());
    }

    #[test]
    fn a_refresh_without_a_new_refresh_token_keeps_the_old() {
        let l = granted(&json!({"access_token": "a", "expires_in": 60}), Some("r")).unwrap();
        assert_eq!((l.access.as_str(), l.refresh.as_str()), ("a", "r"));
        assert!(granted(&json!({"error": "invalid_grant"}), Some("r")).is_err());
        assert!(granted(&json!({"access_token": "a"}), None).is_err());
    }
}
