//! `hippo door`: the memory as a remote MCP server, for apps that live
//! outside the ship (the Claude and Grok apps, Grok Bot). It is a client of
//! the service's socket like the CLI, so it reads what the CLI reads and
//! writes nothing to the store.
//!
//! MCP over Streamable HTTP at `/mcp`, answering each request with one JSON
//! body. Apps sign in by OAuth 2.1 as the MCP spec has it: protected
//! resource and authorization server metadata, dynamic client registration,
//! authorization code with PKCE (S256), refresh tokens. The authorization
//! page asks for the passphrase in `$CREDENTIALS_DIRECTORY/passphrase`;
//! registered clients and token hashes persist in `$STATE_DIRECTORY`.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tiny_http::{Header, Method, Request, Response, Server};

/// Protocol versions the door speaks, newest first.
const VERSIONS: [&str; 3] = ["2025-11-25", "2025-06-18", "2025-03-26"];
const ACCESS_TTL: i64 = 3600;
const REFRESH_TTL: i64 = 90 * 24 * 3600;
const CODE_TTL: i64 = 300;
/// Registered clients kept; the oldest go first.
const CLIENTS_MAX: usize = 32;
const BODY_MAX: u64 = 1 << 20;
/// A wrong passphrase holds the page this long, one guess at a time.
const WRONG: Duration = Duration::from_secs(3);

/// What the server tells apps it is, for one memory: `agent`'s chats with
/// `person`.
fn instructions(agent: &str, person: &str) -> String {
    format!(
        "hippo is the memory of {agent}, {person}'s AI assistant: every chat \
         between them, word for word. `view` gives the history as one-line \
         summaries, oldest first; each line `id+n|text` covers n messages \
         from id, tagged with kinds (user = {person}'s own words, talk = \
         {agent}'s replies, tool, echo = tool output, note). Recent lines \
         cover one message; older lines cover more. `zoom` opens a line into \
         its two halves, and n = 1 gives a message whole; `search` finds \
         words in every message. Zoom before you rely on what a line only \
         mentions."
    )
}

/// Asks the hippo service, as `main::ask` does; a parameter for tests.
pub type Ask = fn(&str, &[String]) -> Result<String, String>;

#[derive(Serialize, Deserialize, Clone)]
struct Client {
    id: String,
    name: String,
    redirect_uris: Vec<String>,
    issued: i64,
}

#[derive(Serialize, Deserialize, Clone, PartialEq)]
enum Grant {
    Access,
    Refresh,
}

#[derive(Serialize, Deserialize, Clone)]
struct Token {
    /// SHA-256 of the token, hex; the token itself is never stored.
    hash: String,
    grant: Grant,
    client: String,
    expires: i64,
}

#[derive(Serialize, Deserialize, Default)]
struct Saved {
    clients: Vec<Client>,
    tokens: Vec<Token>,
}

struct Code {
    code: String,
    client: String,
    redirect_uri: String,
    challenge: String,
    expires: i64,
}

pub struct Door {
    /// The public origin, as apps reach it: `https://host`.
    url: String,
    /// Whose memory this is: the agent and the person it serves.
    agent: String,
    person: String,
    passphrase: String,
    state: Option<PathBuf>,
    saved: Mutex<Saved>,
    codes: Mutex<Vec<Code>>,
    guess: Mutex<()>,
    ask: Ask,
}

/// One HTTP answer, before it meets tiny_http.
#[derive(Debug)]
pub struct Answer {
    pub status: u16,
    pub kind: &'static str,
    pub body: String,
    pub headers: Vec<(&'static str, String)>,
}

impl Answer {
    fn json(status: u16, v: Value) -> Answer {
        Answer {
            status,
            kind: "application/json",
            body: v.to_string(),
            headers: Vec::new(),
        }
    }
    fn html(status: u16, body: String) -> Answer {
        Answer {
            status,
            kind: "text/html; charset=utf-8",
            body,
            headers: Vec::new(),
        }
    }
    fn empty(status: u16) -> Answer {
        Answer {
            status,
            kind: "text/plain",
            body: String::new(),
            headers: Vec::new(),
        }
    }
    fn oauth_error(status: u16, error: &str, about: &str) -> Answer {
        Answer::json(
            status,
            json!({ "error": error, "error_description": about }),
        )
    }
    fn redirect(to: String) -> Answer {
        let mut a = Answer::empty(302);
        a.headers.push(("Location", to));
        a
    }
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn random() -> String {
    let mut buf = [0u8; 32];
    let mut filled = 0;
    while filled < buf.len() {
        let n =
            unsafe { libc::getrandom(buf[filled..].as_mut_ptr().cast(), buf.len() - filled, 0) };
        assert!(n > 0, "getrandom failed");
        filled += n as usize;
    }
    URL_SAFE_NO_PAD.encode(buf)
}

fn sha256(s: &str) -> Vec<u8> {
    Sha256::digest(s.as_bytes()).to_vec()
}

fn hash(token: &str) -> String {
    sha256(token).iter().map(|b| format!("{b:02x}")).collect()
}

/// PKCE S256: the challenge is the verifier's SHA-256, base64url.
fn pkce(verifier: &str, challenge: &str) -> bool {
    URL_SAFE_NO_PAD.encode(sha256(verifier)) == challenge
}

/// Byte-wise comparison that takes the same time wherever they differ.
fn same(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |d, (x, y)| d | (x ^ y)) == 0
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

fn form(s: &str) -> HashMap<String, String> {
    form_urlencoded::parse(s.as_bytes()).into_owned().collect()
}

/// A redirect target a client may register: https anywhere, or http to
/// the client's own machine.
fn allowed_redirect(uri: &str) -> bool {
    uri.starts_with("https://")
        || uri.starts_with("http://localhost")
        || uri.starts_with("http://127.0.0.1")
}

/// The newest `lines` lines of a rendered view, still in `<chat>` tags,
/// with the note under it.
fn newest(view: &str, lines: usize) -> String {
    let (body, note) = match view.split_once("\n</chat>") {
        Some((b, n)) => (b.strip_prefix("<chat>\n").unwrap_or(b), n),
        None => return view.to_owned(),
    };
    let all: Vec<&str> = body.lines().collect();
    let keep = &all[all.len().saturating_sub(lines)..];
    format!("<chat>\n{}\n</chat>{note}", keep.join("\n"))
}

impl Door {
    pub fn new(
        url: &str,
        (agent, person): (&str, &str),
        passphrase: &str,
        state: Option<PathBuf>,
        ask: Ask,
    ) -> Door {
        let saved = state
            .as_ref()
            .and_then(|d| fs::read(d.join("door.json")).ok())
            .and_then(|raw| serde_json::from_slice(&raw).ok())
            .unwrap_or_default();
        Door {
            url: url.trim_end_matches('/').to_owned(),
            agent: agent.to_owned(),
            person: person.to_owned(),
            passphrase: passphrase.trim().to_owned(),
            state,
            saved: Mutex::new(saved),
            codes: Mutex::new(Vec::new()),
            guess: Mutex::new(()),
            ask,
        }
    }

    fn save(&self, s: &mut Saved) {
        let t = now();
        s.tokens.retain(|k| k.expires > t);
        let Some(dir) = &self.state else { return };
        let path = dir.join("door.json");
        let tmp = path.with_extension("tmp");
        let ok = serde_json::to_vec(&*s)
            .map_err(|e| e.to_string())
            .and_then(|raw| fs::write(&tmp, raw).map_err(|e| e.to_string()))
            .and_then(|()| fs::rename(&tmp, &path).map_err(|e| e.to_string()));
        if let Err(e) = ok {
            eprintln!("hippo door: saving {}: {e}", path.display());
        }
    }

    fn client(&self, id: &str) -> Option<Client> {
        let s = self.saved.lock().unwrap();
        s.clients.iter().find(|c| c.id == id).cloned()
    }

    /// Issues an access and a refresh token to a client.
    fn issue(&self, client: &str) -> Answer {
        let (access, refresh) = (random(), random());
        let t = now();
        let mut s = self.saved.lock().unwrap();
        for (tok, grant, ttl) in [
            (&access, Grant::Access, ACCESS_TTL),
            (&refresh, Grant::Refresh, REFRESH_TTL),
        ] {
            s.tokens.push(Token {
                hash: hash(tok),
                grant,
                client: client.to_owned(),
                expires: t + ttl,
            });
        }
        self.save(&mut s);
        Answer::json(
            200,
            json!({
                "access_token": access,
                "token_type": "Bearer",
                "expires_in": ACCESS_TTL,
                "refresh_token": refresh,
            }),
        )
    }

    fn authorized(&self, header: Option<&str>) -> bool {
        let Some(token) = header.and_then(|h| h.strip_prefix("Bearer ")) else {
            return false;
        };
        let (h, t) = (hash(token.trim()), now());
        let s = self.saved.lock().unwrap();
        s.tokens
            .iter()
            .any(|k| k.grant == Grant::Access && k.expires > t && same(&k.hash, &h))
    }

    /// Routes one request. `path` may carry a query; `auth` is the
    /// Authorization header.
    pub fn route(&self, method: &str, path: &str, auth: Option<&str>, body: &str) -> Answer {
        let (path, query) = path.split_once('?').unwrap_or((path, ""));
        match (method, path) {
            ("GET", p) if p.starts_with("/.well-known/oauth-protected-resource") => Answer::json(
                200,
                json!({
                    "resource": format!("{}/mcp", self.url),
                    "authorization_servers": [self.url],
                    "bearer_methods_supported": ["header"],
                }),
            ),
            ("GET", p) if p.starts_with("/.well-known/oauth-authorization-server") => Answer::json(
                200,
                json!({
                    "issuer": self.url,
                    "authorization_endpoint": format!("{}/authorize", self.url),
                    "token_endpoint": format!("{}/token", self.url),
                    "registration_endpoint": format!("{}/register", self.url),
                    "response_types_supported": ["code"],
                    "grant_types_supported": ["authorization_code", "refresh_token"],
                    "code_challenge_methods_supported": ["S256"],
                    "token_endpoint_auth_methods_supported": ["none"],
                }),
            ),
            ("POST", "/register") => self.register(body),
            ("GET", "/authorize") => self.ask_passphrase(&form(query), ""),
            ("POST", "/authorize") => self.approve(&form(body)),
            ("POST", "/token") => self.token(&form(body)),
            ("POST", "/mcp") => {
                if !self.authorized(auth) {
                    let mut a = Answer::json(401, json!({ "error": "invalid_token" }));
                    a.headers.push((
                        "WWW-Authenticate",
                        format!(
                            "Bearer resource_metadata=\"{}/.well-known/oauth-protected-resource\"",
                            self.url
                        ),
                    ));
                    return a;
                }
                self.mcp(body)
            }
            (_, "/mcp") => {
                let mut a = Answer::empty(405);
                a.headers.push(("Allow", "POST".into()));
                a
            }
            _ => Answer::empty(404),
        }
    }

    /// RFC 7591 dynamic registration. Anyone may register; the passphrase
    /// is the gate.
    fn register(&self, body: &str) -> Answer {
        let Ok(req) = serde_json::from_str::<Value>(body) else {
            return Answer::oauth_error(400, "invalid_client_metadata", "Not JSON.");
        };
        let uris: Vec<String> = req["redirect_uris"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|u| u.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default();
        if uris.is_empty() || !uris.iter().all(|u| allowed_redirect(u)) {
            return Answer::oauth_error(
                400,
                "invalid_redirect_uri",
                "Redirect URIs must be https, or http to localhost.",
            );
        }
        let client = Client {
            id: random(),
            name: req["client_name"]
                .as_str()
                .unwrap_or("An app")
                .chars()
                .take(80)
                .collect(),
            redirect_uris: uris,
            issued: now(),
        };
        let mut s = self.saved.lock().unwrap();
        s.clients.push(client.clone());
        if s.clients.len() > CLIENTS_MAX {
            let gone = s.clients.remove(0);
            s.tokens.retain(|k| k.client != gone.id);
        }
        self.save(&mut s);
        Answer::json(
            201,
            json!({
                "client_id": client.id,
                "client_id_issued_at": client.issued,
                "client_name": client.name,
                "redirect_uris": client.redirect_uris,
                "grant_types": ["authorization_code", "refresh_token"],
                "response_types": ["code"],
                "token_endpoint_auth_method": "none",
            }),
        )
    }

    /// Checks an authorization request; the client and where its code goes.
    fn check(&self, q: &HashMap<String, String>) -> Result<(Client, String), String> {
        let get = |k: &str| q.get(k).map(String::as_str).unwrap_or("");
        let client = self
            .client(get("client_id"))
            .ok_or("This app is not registered here; add the connector again.")?;
        let uri = get("redirect_uri");
        if !client.redirect_uris.iter().any(|u| u == uri) {
            return Err("The app asked to send you somewhere it did not register.".into());
        }
        if get("response_type") != "code" {
            return Err("Only response_type=code is supported.".into());
        }
        if get("code_challenge_method") != "S256" || get("code_challenge").is_empty() {
            return Err("The app must use PKCE with S256.".into());
        }
        Ok((client, uri.to_owned()))
    }

    fn ask_passphrase(&self, q: &HashMap<String, String>, wrong: &str) -> Answer {
        let (client, uri) = match self.check(q) {
            Ok(c) => c,
            Err(e) => return Answer::html(400, page(&format!("<p>{}</p>", esc(&e)))),
        };
        let host = uri.split('/').nth(2).unwrap_or(&uri);
        let hidden: String = [
            "client_id",
            "redirect_uri",
            "response_type",
            "code_challenge",
            "code_challenge_method",
            "state",
        ]
        .iter()
        .filter_map(|k| q.get(*k).map(|v| (k, v)))
        .map(|(k, v)| format!("<input type=hidden name={k} value=\"{}\">", esc(v)))
        .collect();
        Answer::html(
            200,
            page(&format!(
                "<p><b>{}</b> asks to read {}'s memory. \
                 It will send you back to <b>{}</b>.</p>{wrong}\
                 <form method=post action=/authorize>{hidden}\
                 <input type=password name=passphrase autofocus \
                 autocomplete=current-password placeholder=Passphrase>\
                 <button>Allow</button></form>",
                esc(&client.name),
                esc(&self.agent),
                esc(host),
            )),
        )
    }

    fn approve(&self, f: &HashMap<String, String>) -> Answer {
        let (client, uri) = match self.check(f) {
            Ok(c) => c,
            Err(e) => return Answer::html(400, page(&format!("<p>{}</p>", esc(&e)))),
        };
        let given = f.get("passphrase").map(String::as_str).unwrap_or("");
        {
            let _one = self.guess.lock().unwrap();
            if self.passphrase.is_empty() || !same(given, &self.passphrase) {
                thread::sleep(WRONG);
                return self.ask_passphrase(f, "<p class=wrong>Wrong passphrase.</p>");
            }
        }
        let code = random();
        let t = now();
        let mut codes = self.codes.lock().unwrap();
        codes.retain(|c| c.expires > t);
        codes.push(Code {
            code: code.clone(),
            client: client.id,
            redirect_uri: uri.clone(),
            challenge: f["code_challenge"].clone(),
            expires: t + CODE_TTL,
        });
        let mut to = format!(
            "{uri}{}code={code}",
            if uri.contains('?') { '&' } else { '?' }
        );
        if let Some(state) = f.get("state") {
            to.push_str("&state=");
            to.extend(form_urlencoded::byte_serialize(state.as_bytes()));
        }
        Answer::redirect(to)
    }

    fn token(&self, f: &HashMap<String, String>) -> Answer {
        let get = |k: &str| f.get(k).map(String::as_str).unwrap_or("");
        match get("grant_type") {
            "authorization_code" => {
                let code = {
                    let mut codes = self.codes.lock().unwrap();
                    let at = codes.iter().position(|c| same(&c.code, get("code")));
                    at.map(|i| codes.remove(i))
                };
                let Some(code) = code.filter(|c| c.expires > now()) else {
                    return Answer::oauth_error(400, "invalid_grant", "Unknown or expired code.");
                };
                if code.client != get("client_id") || code.redirect_uri != get("redirect_uri") {
                    return Answer::oauth_error(400, "invalid_grant", "Code issued elsewhere.");
                }
                if !pkce(get("code_verifier"), &code.challenge) {
                    return Answer::oauth_error(400, "invalid_grant", "PKCE check failed.");
                }
                self.issue(&code.client)
            }
            // Refresh tokens rotate: the old one is spent.
            "refresh_token" => {
                let h = hash(get("refresh_token"));
                let client = {
                    let mut s = self.saved.lock().unwrap();
                    let t = now();
                    let at = s.tokens.iter().position(|k| {
                        k.grant == Grant::Refresh && k.expires > t && same(&k.hash, &h)
                    });
                    at.map(|i| s.tokens.remove(i).client)
                };
                match client {
                    Some(c) if self.client(&c).is_some() => self.issue(&c),
                    _ => Answer::oauth_error(400, "invalid_grant", "Unknown refresh token."),
                }
            }
            _ => Answer::oauth_error(400, "unsupported_grant_type", "Unsupported grant."),
        }
    }

    /// One JSON-RPC message; notifications and responses get 202.
    fn mcp(&self, body: &str) -> Answer {
        let msg: Value = match serde_json::from_str(body) {
            Ok(v) => v,
            Err(e) => return rpc_error(Value::Null, -32700, &format!("Parse error: {e}")),
        };
        let Some(id) = msg.get("id").cloned() else {
            return Answer::empty(202);
        };
        let Some(method) = msg["method"].as_str() else {
            return Answer::empty(202);
        };
        let params = &msg["params"];
        let result = match method {
            "initialize" => {
                let asked = params["protocolVersion"].as_str().unwrap_or("");
                let version = VERSIONS
                    .iter()
                    .find(|v| **v == asked)
                    .unwrap_or(&VERSIONS[0]);
                json!({
                    "protocolVersion": version,
                    "capabilities": { "tools": {} },
                    "serverInfo": { "name": "hippo", "version": env!("CARGO_PKG_VERSION") },
                    "instructions": instructions(&self.agent, &self.person),
                })
            }
            "ping" => json!({}),
            "tools/list" => json!({ "tools": tools() }),
            "tools/call" => {
                let args = &params["arguments"];
                let (text, failed) = match self.call(params["name"].as_str().unwrap_or(""), args) {
                    Ok(t) => (t, false),
                    Err(e) => (e, true),
                };
                json!({ "content": [{ "type": "text", "text": text }], "isError": failed })
            }
            other => return rpc_error(id, -32601, &format!("Unknown method {other}.")),
        };
        Answer::json(200, json!({ "jsonrpc": "2.0", "id": id, "result": result }))
    }

    fn call(&self, name: &str, a: &Value) -> Result<String, String> {
        let int = |k: &str| -> Result<String, String> {
            a[k].as_u64()
                .map(|n| n.to_string())
                .ok_or_else(|| format!("{k} must be a whole number."))
        };
        match name {
            "view" => {
                let whole = (self.ask)("view", &["whole".into()])?;
                Ok(match a["lines"].as_u64() {
                    Some(n) if n > 0 => newest(&whole, n as usize),
                    _ => whole,
                })
            }
            "zoom" => (self.ask)("zoom", &[int("id")?, int("n")?]),
            "date" => (self.ask)("date", &[int("id")?]),
            "search" => {
                let p = a["pattern"].as_str().ok_or("pattern must be text.")?;
                (self.ask)("search", &[p.to_owned()])
            }
            other => Err(format!("No tool {other}.")),
        }
    }
}

fn rpc_error(id: Value, code: i64, message: &str) -> Answer {
    Answer::json(
        200,
        json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } }),
    )
}

fn tools() -> Value {
    let read = json!({ "readOnlyHint": true, "openWorldHint": false });
    json!([
        {
            "name": "view",
            "description": "The memory's whole history as one-line summaries, oldest \
                first, about 128 KB; or only its newest lines. Start here.",
            "inputSchema": { "type": "object", "properties": {
                "lines": { "type": "integer", "minimum": 1,
                    "description": "Only this many of the newest lines (100 covers about the last day)." }
            }},
            "annotations": read,
        },
        {
            "name": "zoom",
            "description": "Open line id+n into its two halves; n = 1 gives message id whole.",
            "inputSchema": { "type": "object", "required": ["id", "n"], "properties": {
                "id": { "type": "integer", "minimum": 0 },
                "n": { "type": "integer", "minimum": 1, "description": "A power of two, as in the line." }
            }},
            "annotations": read,
        },
        {
            "name": "search",
            "description": "Search every message word for word, case-insensitive; up to 100 hits.",
            "inputSchema": { "type": "object", "required": ["pattern"], "properties": {
                "pattern": { "type": "string", "description": "A regular expression (Rust syntax)." }
            }},
            "annotations": read,
        },
        {
            "name": "date",
            "description": "Date and time of message id.",
            "inputSchema": { "type": "object", "required": ["id"], "properties": {
                "id": { "type": "integer", "minimum": 0 }
            }},
            "annotations": read,
        },
    ])
}

fn page(body: &str) -> String {
    format!(
        "<!doctype html><meta charset=utf-8>\
         <meta name=viewport content=\"width=device-width,initial-scale=1\">\
         <title>hippo</title><style>body{{font:16px system-ui;max-width:30em;\
         margin:3em auto;padding:0 1em}}input,button{{font:inherit;padding:.5em;\
         margin:.3em 0;width:100%;box-sizing:border-box}}.wrong{{color:#b00}}</style>\
         <h1>hippo</h1>{body}"
    )
}

fn respond(req: Request, a: Answer) {
    let mut r = Response::from_string(a.body).with_status_code(a.status);
    let mut headers = vec![
        ("Content-Type", a.kind.to_owned()),
        ("Cache-Control", "no-store".into()),
    ];
    headers.extend(a.headers);
    for (k, v) in headers {
        if let Ok(h) = Header::from_bytes(k.as_bytes(), v.as_bytes()) {
            r.add_header(h);
        }
    }
    let _ = req.respond(r);
}

fn serve_one(door: &Door, mut req: Request) {
    let method = match req.method() {
        Method::Get => "GET",
        Method::Post => "POST",
        Method::Delete => "DELETE",
        _ => "OTHER",
    };
    let path = req.url().to_owned();
    let auth = req
        .headers()
        .iter()
        .find(|h| h.field.equiv("Authorization"))
        .map(|h| h.value.as_str().to_owned());
    let mut body = String::new();
    if (&mut req.as_reader())
        .take(BODY_MAX)
        .read_to_string(&mut body)
        .is_err()
    {
        return respond(req, Answer::empty(400));
    }
    let a = door.route(method, &path, auth.as_deref(), &body);
    respond(req, a);
}

/// Runs the door on `listen` (loopback; a tunnel carries it out) for apps
/// that reach it at `url`.
pub fn run(listen: &str, url: &str, ask: Ask) -> Result<(), String> {
    let creds = std::env::var_os("CREDENTIALS_DIRECTORY")
        .ok_or("No CREDENTIALS_DIRECTORY: the passphrase comes as a systemd credential.")?;
    let passphrase = fs::read_to_string(PathBuf::from(creds).join("passphrase"))
        .map_err(|e| format!("passphrase: {e}"))?;
    if passphrase.trim().len() < 12 {
        return Err("The passphrase is shorter than 12 characters.".into());
    }
    let state = std::env::var_os("STATE_DIRECTORY").map(PathBuf::from);
    let name = |k: &str, or: &str| {
        std::env::var(k)
            .ok()
            .filter(|v| !v.is_empty())
            .unwrap_or_else(|| or.to_owned())
    };
    let (agent, person) = (name("HIPPO_AGENT", "Bridge"), name("HIPPO_PERSON", "Dylan"));
    let door = Arc::new(Door::new(url, (&agent, &person), &passphrase, state, ask));
    let server = Server::http(listen).map_err(|e| format!("{listen}: {e}"))?;
    eprintln!("hippo door: serving {url} on {listen}");
    for req in server.incoming_requests() {
        let door = door.clone();
        thread::spawn(move || serve_one(&door, req));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const VIEW: &str = "<chat>\n0+2|old\n2+1|user: a\n3+1|talk: b\n</chat>\n1 recent lines are not summarized yet: zoom them.\n";

    fn fake(cmd: &str, args: &[String]) -> Result<String, String> {
        match cmd {
            "view" => Ok(VIEW.into()),
            _ => Ok(format!("{cmd} {}", args.join(" "))),
        }
    }

    fn door() -> Door {
        Door::new(
            "https://hippo.example/",
            ("Sokka", "Dylan"),
            "correct horse battery",
            None,
            fake,
        )
    }

    fn body(a: &Answer) -> Value {
        serde_json::from_str(&a.body).unwrap()
    }

    /// Registers, authorizes and trades the code; the token response.
    fn sign_in(d: &Door) -> Value {
        let reg = d.route(
            "POST",
            "/register",
            None,
            r#"{"client_name":"Claude","redirect_uris":["https://claude.ai/api/mcp/auth_callback"]}"#,
        );
        assert_eq!(reg.status, 201);
        let id = body(&reg)["client_id"].as_str().unwrap().to_owned();
        let verifier = "a-verifier-of-enough-length-for-pkce-0123456789";
        let challenge = URL_SAFE_NO_PAD.encode(sha256(verifier));
        let q: String = form_urlencoded::Serializer::new(String::new())
            .append_pair("client_id", &id)
            .append_pair("redirect_uri", "https://claude.ai/api/mcp/auth_callback")
            .append_pair("response_type", "code")
            .append_pair("code_challenge", &challenge)
            .append_pair("code_challenge_method", "S256")
            .append_pair("state", "s t")
            .finish();
        let page = d.route("GET", &format!("/authorize?{q}"), None, "");
        assert_eq!(page.status, 200);
        assert!(page.body.contains("<b>Claude</b>") && page.body.contains("claude.ai"));
        assert!(page.body.contains("Sokka's memory"));
        let ok = d.route(
            "POST",
            "/authorize",
            None,
            &format!("{q}&passphrase=correct+horse+battery"),
        );
        assert_eq!(ok.status, 302);
        let to = &ok.headers[0].1;
        assert!(to.ends_with("&state=s+t"), "{to}");
        let code = to.split("code=").nth(1).unwrap().split('&').next().unwrap();
        let tok = d.route(
            "POST",
            "/token",
            None,
            &form_urlencoded::Serializer::new(String::new())
                .append_pair("grant_type", "authorization_code")
                .append_pair("code", code)
                .append_pair("client_id", &id)
                .append_pair("redirect_uri", "https://claude.ai/api/mcp/auth_callback")
                .append_pair("code_verifier", verifier)
                .finish(),
        );
        assert_eq!(tok.status, 200, "{}", tok.body);
        let t = body(&tok);
        // A code is spent once.
        let again = d.route(
            "POST",
            "/token",
            None,
            &format!("grant_type=authorization_code&code={code}"),
        );
        assert_eq!(again.status, 400);
        t
    }

    #[test]
    fn mcp_needs_a_token() {
        let a = door().route("POST", "/mcp", None, "{}");
        assert_eq!(a.status, 401);
        assert!(
            a.headers[0]
                .1
                .contains("https://hippo.example/.well-known/oauth-protected-resource")
        );
        let a = door().route("POST", "/mcp", Some("Bearer nope"), "{}");
        assert_eq!(a.status, 401);
    }

    #[test]
    fn metadata_names_the_origin() {
        let d = door();
        let r = body(&d.route("GET", "/.well-known/oauth-protected-resource/mcp", None, ""));
        assert_eq!(r["resource"], "https://hippo.example/mcp");
        let s = body(&d.route("GET", "/.well-known/oauth-authorization-server", None, ""));
        assert_eq!(s["token_endpoint"], "https://hippo.example/token");
    }

    #[test]
    fn sign_in_then_call_tools() {
        let d = door();
        let t = sign_in(&d);
        let bearer = format!("Bearer {}", t["access_token"].as_str().unwrap());
        let rpc = |b: &str| d.route("POST", "/mcp", Some(&bearer), b);
        let init = body(&rpc(
            r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
        ));
        assert_eq!(init["result"]["protocolVersion"], "2025-06-18");
        let says = init["result"]["instructions"].as_str().unwrap();
        assert!(says.contains("memory of Sokka, Dylan's") && !says.contains("Bridge"));
        assert_eq!(
            rpc(r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).status,
            202
        );
        let list = body(&rpc(r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#));
        assert_eq!(list["result"]["tools"].as_array().unwrap().len(), 4);
        let z = body(&rpc(
            r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"zoom","arguments":{"id":2,"n":1}}}"#,
        ));
        assert_eq!(z["result"]["content"][0]["text"], "zoom 2 1");
        let v = body(&rpc(
            r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"view","arguments":{"lines":2}}}"#,
        ));
        assert_eq!(
            v["result"]["content"][0]["text"],
            "<chat>\n2+1|user: a\n3+1|talk: b\n</chat>\n1 recent lines are not summarized yet: zoom them.\n"
        );
        let bad = body(&rpc(
            r#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"zoom","arguments":{"id":"x"}}}"#,
        ));
        assert_eq!(bad["result"]["isError"], true);
    }

    #[test]
    fn refresh_rotates() {
        let d = door();
        let t = sign_in(&d);
        let r = t["refresh_token"].as_str().unwrap();
        let body1 = format!("grant_type=refresh_token&refresh_token={r}");
        assert_eq!(d.route("POST", "/token", None, &body1).status, 200);
        assert_eq!(d.route("POST", "/token", None, &body1).status, 400);
    }

    #[test]
    fn authorize_refuses_strangers() {
        let d = door();
        let reg = body(&d.route(
            "POST",
            "/register",
            None,
            r#"{"redirect_uris":["https://good.example/cb"]}"#,
        ));
        let id = reg["client_id"].as_str().unwrap();
        let q = format!(
            "client_id={id}&redirect_uri=https%3A%2F%2Fevil.example%2Fcb&response_type=code&code_challenge=x&code_challenge_method=S256"
        );
        assert_eq!(
            d.route("GET", &format!("/authorize?{q}"), None, "").status,
            400
        );
        let plain = d.route(
            "POST",
            "/register",
            None,
            r#"{"redirect_uris":["http://evil.example/cb"]}"#,
        );
        assert_eq!(plain.status, 400);
    }

    #[test]
    fn wrong_passphrase_gets_no_code() {
        let d = door();
        let reg = body(&d.route(
            "POST",
            "/register",
            None,
            r#"{"redirect_uris":["https://a.example/cb"]}"#,
        ));
        let id = reg["client_id"].as_str().unwrap();
        let q = format!(
            "client_id={id}&redirect_uri=https%3A%2F%2Fa.example%2Fcb&response_type=code&code_challenge=x&code_challenge_method=S256&passphrase=guess"
        );
        let a = d.route("POST", "/authorize", None, &q);
        assert_eq!(a.status, 200);
        assert!(a.body.contains("Wrong passphrase"));
    }

    #[test]
    fn escapes_and_pkce() {
        assert_eq!(esc("<a href=\"x\">'"), "&lt;a href=&quot;x&quot;&gt;&#39;");
        // RFC 7636 appendix B.
        assert!(pkce(
            "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        ));
        assert_eq!(newest(VIEW, 9), VIEW);
    }
}
