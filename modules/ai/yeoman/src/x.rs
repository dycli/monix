//! X, read through Grok's `x_search` on xAI's Responses API, paid by the
//! household's X subscription. The service (`yeoman x`, one per
//! connection on the socket) alone holds the subscription's sign-in, a
//! Grok CLI login made once with `yeoman x login`; the tools reach only
//! its socket. Grok runs the searches and answers with the posts it found
//! and their links. It reads X and nothing else, so it acts on nothing.
//! The same sign-in reads replies aloud through xAI's text to speech, and
//! mints the short-lived passes a page holds to talk with Grok Voice, and
//! draws pictures with Grok Imagine for the image tool (yeoman-image.py).

use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
use rustls::{ClientConfig, ClientConnection, RootCertStore, StreamOwned};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::fs::{self, File};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tungstenite::client::IntoClientRequest;
use tungstenite::handshake::HandshakeError;
use tungstenite::{Message, WebSocket};
use ureq::Agent;

const AUTH: &str = "https://auth.x.ai/oauth2";
/// The Grok CLI's public client, whose sign-in the subscription covers.
const CLIENT: &str = "b1a00492-073a-47ea-816f-4c329264a828";
const SCOPE: &str = "openid profile email offline_access grok-cli:access api:access";
const API: &str = "https://api.x.ai/v1/responses";
const TTS_HOST: &str = "api.x.ai";
const SECRETS: &str = "https://api.x.ai/v1/realtime/client_secrets";
const IMAGES: &str = "https://api.x.ai/v1/images/generations";
const IMAGE_MODEL: &str = "grok-imagine-image-2.0";
/// The longest description the image tool sends.
const DRAW_MAX: usize = 4000;
/// xAI's limit on one text to speak, in characters.
pub const SPEAK_MAX: usize = 60_000;

/// xAI's built-in voices, each good for reading aloud and for calls, as
/// its text to speech docs list them; a page may pick any.
pub const VOICES: [&str; 9] = [
    "ara", "eve", "leo", "rex", "sal", "carina", "helix", "orion", "zagan",
];
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

/// What the socket carries: text to speak, a voice pass, a picture to
/// draw, or else a search.
#[derive(Serialize, Deserialize)]
#[serde(untagged)]
enum Request {
    Speak {
        speak: String,
        voice: String,
    },
    /// A pass to Grok Voice good for this many seconds.
    Secret {
        secret: u64,
    },
    /// A picture from this description; the reply carries it as base64.
    Draw {
        draw: String,
    },
    Search(Ask),
}

/// The tools' side: one search over the service's socket.
pub fn ask(sock: &Path, ask: &Ask) -> Result<String, String> {
    let reply = call(sock, &serde_json::to_vec(ask).map_err(|e| e.to_string())?)?;
    reply["ok"]
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| "x: no answer".into())
}

/// The site's side: `text` spoken in `voice`, as MP3 handed to `each` a
/// piece at a time while xAI makes it, so playing can start before the
/// end is made. Ok once the whole of it has come.
pub fn speak(
    sock: &Path,
    text: &str,
    voice: &str,
    mut each: impl FnMut(&[u8]),
) -> Result<(), String> {
    let ask = Request::Speak {
        speak: text.into(),
        voice: voice.into(),
    };
    let mut s = UnixStream::connect(sock).map_err(|e| format!("x: {e}"))?;
    s.set_read_timeout(Some(TIMEOUT))
        .map_err(|e| e.to_string())?;
    s.write_all(&serde_json::to_vec(&ask).map_err(|e| e.to_string())?)
        .and_then(|_| s.shutdown(std::net::Shutdown::Write))
        .map_err(|e| format!("x: {e}"))?;
    loop {
        let mut head = [0; 5];
        s.read_exact(&mut head)
            .map_err(|e| format!("x: speech cut off: {e}"))?;
        let mut body = vec![0; u32::from_be_bytes(head[1..].try_into().unwrap()) as usize];
        s.read_exact(&mut body)
            .map_err(|e| format!("x: speech cut off: {e}"))?;
        match head[0] {
            AUDIO => each(&body),
            DONE => return Ok(()),
            _ => return Err(format!("x: {}", String::from_utf8_lossy(&body))),
        }
    }
}

/// How speech comes over the socket: frames of a kind byte, a big-endian
/// u32 length and that many bytes, ending in DONE or a failure's words.
const AUDIO: u8 = b'a';
const DONE: u8 = b'd';
const FAILED: u8 = b'e';

fn frame(out: &mut impl Write, kind: u8, body: &[u8]) -> std::io::Result<()> {
    out.write_all(&[kind])?;
    out.write_all(&(body.len() as u32).to_be_bytes())?;
    out.write_all(body)?;
    out.flush()
}

/// The site's side: a pass to Grok Voice for `seconds`, as xAI gives it,
/// `{value, expires_at}`. The page opens the call with it, so the
/// subscription's own sign-in never leaves this host.
pub fn secret(sock: &Path, seconds: u64) -> Result<Value, String> {
    let ask = Request::Secret { secret: seconds };
    call(sock, &serde_json::to_vec(&ask).map_err(|e| e.to_string())?)
}

/// One request over the socket; its reply, unless it is an error.
fn call(sock: &Path, body: &[u8]) -> Result<Value, String> {
    let mut s = UnixStream::connect(sock).map_err(|e| format!("x: {e}"))?;
    s.set_read_timeout(Some(TIMEOUT + Duration::from_secs(30)))
        .map_err(|e| e.to_string())?;
    s.write_all(body).map_err(|e| format!("x: {e}"))?;
    s.shutdown(std::net::Shutdown::Write)
        .map_err(|e| format!("x: {e}"))?;
    let mut reply = String::new();
    s.read_to_string(&mut reply)
        .map_err(|e| format!("x: {e}"))?;
    let reply: Value = serde_json::from_str(&reply).map_err(|e| format!("x: {e}"))?;
    match reply["err"].as_str() {
        Some(err) => Err(format!("x: {err}")),
        None => Ok(reply),
    }
}

/// The service's side: one request from stdin, its answer to stdout.
pub fn serve() -> Result<(), String> {
    let mut body = Vec::new();
    // A text at SPEAK_MAX characters may take four bytes each.
    std::io::stdin()
        .take((SPEAK_MAX * 4 + 4096) as u64)
        .read_to_end(&mut body)
        .map_err(|e| e.to_string())?;
    let reply = match serde_json::from_slice::<Request>(&body).map_err(|e| e.to_string()) {
        Ok(Request::Search(a)) => search(&a).map(|text| json!({ "ok": text })),
        Ok(Request::Speak { speak, voice }) => {
            let out = &mut std::io::stdout().lock();
            let (kind, body) = match tts(&speak, &voice, out) {
                Ok(()) => (DONE, String::new()),
                Err(e) => {
                    eprintln!("yeoman-x: {e}");
                    (FAILED, e)
                }
            };
            return frame(out, kind, body.as_bytes()).map_err(|e| e.to_string());
        }
        Ok(Request::Secret { secret }) => client_secret(secret),
        Ok(Request::Draw { draw }) => imagine(&draw).map(|image| json!({ "image": image })),
        Err(e) => Err(e),
    };
    let reply = reply.unwrap_or_else(|e| {
        eprintln!("yeoman-x: {e}");
        json!({ "err": e })
    });
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

/// `text` spoken by xAI in `voice`, its MP3 framed onto `out` as it comes.
/// The streaming endpoint is a WebSocket; the plain POST answers only once
/// the whole is made, which for a long reply is a minute of silence.
fn tts(text: &str, voice: &str, out: &mut impl Write) -> Result<(), String> {
    if text.chars().count() > SPEAK_MAX {
        return Err(format!("Too long to speak: over {SPEAK_MAX} characters."));
    }
    if voice.is_empty() || !voice.bytes().all(|b| b.is_ascii_alphanumeric()) {
        return Err(format!("xai tts: bad voice {voice:?}"));
    }
    let token = token()?;
    let mut ws = tts_socket(voice, &token)?;
    let say = |ws: &mut Socket, m: Value| {
        ws.send(Message::text(m.to_string()))
            .map_err(|e| format!("xai tts: {e}"))
    };
    say(&mut ws, json!({"type": "text.delta", "delta": text}))?;
    say(&mut ws, json!({"type": "text.done"}))?;
    let mut bytes = 0;
    loop {
        let event = match ws.read().map_err(|e| format!("xai tts: {e}"))? {
            Message::Text(t) => {
                serde_json::from_str::<Value>(&t).map_err(|e| format!("xai tts: {e}"))?
            }
            Message::Close(why) => return Err(format!("xai tts: closed early: {why:?}")),
            _ => continue,
        };
        match event["type"].as_str() {
            Some("audio.delta") => {
                let mp3 = BASE64
                    .decode(event["delta"].as_str().unwrap_or_default())
                    .map_err(|e| format!("xai tts: {e}"))?;
                bytes += mp3.len();
                frame(out, AUDIO, &mp3).map_err(|e| format!("yeoman-x: {e}"))?;
            }
            Some("audio.done") => break,
            Some("error") => {
                let msg = event["message"].as_str().unwrap_or("unknown error");
                return Err(format!("xai tts: {msg}"));
            }
            _ => {}
        }
    }
    let _ = ws.close(None);
    eprintln!(
        "yeoman-x: spoke chars={} voice={voice} bytes={bytes}",
        text.chars().count()
    );
    Ok(())
}

type Socket = WebSocket<StreamOwned<ClientConnection, TcpStream>>;

/// The streaming text to speech socket, MP3 in `voice`, tuned for the
/// first sound soonest.
fn tts_socket(voice: &str, token: &str) -> Result<Socket, String> {
    let roots = RootCertStore {
        roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
    };
    let config = ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    let conn = ClientConnection::new(Arc::new(config), TTS_HOST.try_into().unwrap())
        .map_err(|e| format!("xai tts: {e}"))?;
    let tcp = TcpStream::connect((TTS_HOST, 443)).map_err(|e| format!("xai tts: {e}"))?;
    tcp.set_read_timeout(Some(TIMEOUT))
        .and(tcp.set_write_timeout(Some(TIMEOUT)))
        .map_err(|e| format!("xai tts: {e}"))?;
    let mut ask = format!(
        "wss://{TTS_HOST}/v1/tts?voice={voice}&language=en&codec=mp3&optimize_streaming_latency=1"
    )
    .into_client_request()
    .map_err(|e| format!("xai tts: {e}"))?;
    ask.headers_mut().insert(
        "Authorization",
        format!("Bearer {token}")
            .parse()
            .map_err(|_| "xai tts: bad token")?,
    );
    let (ws, _) = tungstenite::client(ask, StreamOwned::new(conn, tcp)).map_err(|e| match e {
        HandshakeError::Failure(tungstenite::Error::Http(r)) => {
            let body = r
                .body()
                .as_deref()
                .map(String::from_utf8_lossy)
                .unwrap_or_default();
            format!("xai tts: {}: {body}", r.status())
        }
        e => format!("xai tts: {e}"),
    })?;
    Ok(ws)
}

/// A Grok Voice pass from xAI, at most an hour long.
fn client_secret(seconds: u64) -> Result<Value, String> {
    let token = token()?;
    let mut resp = agent()
        .post(SECRETS)
        .header("Authorization", &format!("Bearer {token}"))
        .send_json(json!({"expires_after": {"seconds": seconds.clamp(10, 3600)}}))
        .map_err(|e| format!("xai secret: {e}"))?;
    let status = resp.status().as_u16();
    let reply: Value = resp
        .body_mut()
        .read_json()
        .map_err(|e| format!("xai secret: {status}: {e}"))?;
    if status >= 400 || !reply["value"].is_string() {
        let msg = reply["error"]["message"]
            .as_str()
            .or(reply["error"].as_str())
            .unwrap_or("no pass");
        return Err(format!("xai secret: {status}: {msg}"));
    }
    eprintln!("yeoman-x: voice pass for {seconds}s");
    Ok(json!({"value": reply["value"], "expires_at": reply["expires_at"]}))
}

/// One picture from Grok Imagine, base64 as xAI sends it (a JPEG).
fn imagine(description: &str) -> Result<String, String> {
    let prompt: String = description.chars().take(DRAW_MAX).collect();
    let token = token()?;
    let mut resp = agent()
        .post(IMAGES)
        .header("Authorization", &format!("Bearer {token}"))
        .send_json(json!({"model": IMAGE_MODEL, "prompt": prompt, "n": 1,
            "response_format": "b64_json"}))
        .map_err(|e| format!("xai image: {e}"))?;
    let status = resp.status().as_u16();
    let reply: Value = resp
        .body_mut()
        .with_config()
        .limit(64 * 1024 * 1024)
        .read_json()
        .map_err(|e| format!("xai image: {status}: {e}"))?;
    let Some(image) = reply["data"][0]["b64_json"].as_str() else {
        let msg = reply["error"]["message"]
            .as_str()
            .or(reply["error"].as_str())
            .unwrap_or("no picture");
        return Err(format!("xai image: {status}: {msg}"));
    };
    eprintln!(
        "yeoman-x: drew model={IMAGE_MODEL} bytes={}",
        image.len() / 4 * 3
    );
    Ok(image.to_owned())
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

    #[test]
    fn speech_comes_a_piece_at_a_time_and_says_how_it_ended() {
        let dir = std::env::temp_dir().join(format!("yeoman-x-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let sock = dir.join("x.sock");
        let listener = std::os::unix::net::UnixListener::bind(&sock).unwrap();
        let ends: [(u8, &[u8]); 2] = [(DONE, b""), (FAILED, b"xai tts: no")];
        let serve = std::thread::spawn(move || {
            for (kind, body) in ends {
                let (mut s, _) = listener.accept().unwrap();
                let mut ask = String::new();
                s.read_to_string(&mut ask).unwrap();
                assert!(ask.contains(r#""speak":"hi""#), "{ask}");
                frame(&mut s, AUDIO, b"ID3").unwrap();
                frame(&mut s, AUDIO, b"mp3").unwrap();
                frame(&mut s, kind, body).unwrap();
            }
        });
        let mut got = Vec::new();
        assert_eq!(speak(&sock, "hi", "leo", |b| got.push(b.to_vec())), Ok(()));
        assert_eq!(got, [b"ID3".to_vec(), b"mp3".to_vec()]);
        assert_eq!(
            speak(&sock, "hi", "leo", |_| {}),
            Err("x: xai tts: no".into())
        );
        serve.join().unwrap();
        fs::remove_dir_all(&dir).unwrap();
    }
}
