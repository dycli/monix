// ship-alert — the one mouth for every alarm on the ship. Sensors are
// borrowed specialists (systemd OnFailure, the sweep timer, smartd, upsmon);
// each one composes a message and hands it here. This binary owns delivery
// and nothing else: optional local-LLM enrichment, repeat throttling, then a
// Matrix post to the alert room over the loopback homeserver.
//
// Credential model (unchanged from the bash predecessor): the bot's password
// arrives via environment (MATRIX_USER / MATRIX_PASSWORD / ALERT_ROOM_ID from
// the agenix env file); every alert logs in, sends, and logs out so devices
// don't accumulate. First ever send also joins the room and sets the
// display name, stamped in the state directory. If the homeserver is down,
// alerts can't send — accepted; meta-monitoring needs an off-host watcher,
// which this deliberately is not.
//
// usage: ship-alert [--summarize] [--throttle-minutes N] [message...]
//        (message on stdin when no positional arguments are given)

use serde_json::{Value, json};
use std::env;
use std::fs;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

type Result<T> = std::result::Result<T, String>;

const fn build_default(value: Option<&'static str>, default: &'static str) -> &'static str {
    match value {
        Some(value) => value,
        None => default,
    }
}

const HOMESERVER: &str = build_default(option_env!("SHIP_ALERT_HOMESERVER"), "http://127.0.0.1:6167");
const STATE_DIR: &str = build_default(option_env!("SHIP_ALERT_STATE_DIR"), "/var/lib/alerts");
const SUMMARY_URL: &str = build_default(option_env!("SHIP_ALERT_SUMMARY_URL"), "");
const SUMMARY_MODEL: &str = build_default(option_env!("SHIP_ALERT_SUMMARY_MODEL"), "");
const CURL: &str = build_default(option_env!("SHIP_ALERT_CURL"), "curl");

const SUMMARY_PROMPT: &str = "You summarize alerts from a home server for its alert \
channel. Reply with 1-2 short plain sentences: what happened and the likely cause \
based on the details. No preamble, no markdown.";

struct Options {
    summarize: bool,
    throttle_minutes: u64,
    body: String,
}

fn parse_arguments(arguments: &[String], stdin_body: impl FnOnce() -> String) -> Result<Options> {
    let mut summarize = false;
    let mut throttle_minutes = 0;
    let mut positional = Vec::new();
    let mut cursor = arguments.iter();
    while let Some(argument) = cursor.next() {
        match argument.as_str() {
            "--summarize" => summarize = true,
            "--throttle-minutes" => {
                throttle_minutes = cursor
                    .next()
                    .and_then(|value| value.parse().ok())
                    .ok_or("usage: --throttle-minutes <positive integer>")?;
            }
            _ => positional.push(argument.clone()),
        }
    }
    let body = if positional.is_empty() {
        stdin_body()
    } else {
        positional.join(" ")
    };
    let body = body.trim_end().to_string();
    if body.is_empty() {
        return Err("empty alert message".into());
    }
    Ok(Options {
        summarize,
        throttle_minutes,
        body,
    })
}

// ---- helpers ---------------------------------------------------------------

fn percent_encode(value: &str) -> String {
    value
        .bytes()
        .map(|byte| {
            if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~') {
                (byte as char).to_string()
            } else {
                format!("%{byte:02X}")
            }
        })
        .collect()
}

fn unix_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}

fn env_required(name: &str) -> Result<String> {
    env::var(name).map_err(|_| format!("required environment variable {name} is missing"))
}

/// Insert the enrichment line after the first line of the alert, preserving
/// the established format: header, 💡 summary, a rule, then the details.
fn insert_summary(body: &str, summary: &str) -> String {
    match body.split_once('\n') {
        Some((header, rest)) => format!("{header}\n💡 {summary}\n———\n{rest}"),
        None => format!("{body}\n💡 {summary}"),
    }
}

/// The Qwen template wraps reasoning in <think> blocks even when asked not
/// to; strip them and blank lines, exactly like the sed pipeline before.
fn clean_summary(raw: &str) -> String {
    let mut kept = Vec::new();
    let mut thinking = false;
    for line in raw.lines() {
        if line.contains("<think>") {
            thinking = true;
        }
        if !thinking && !line.trim().is_empty() {
            kept.push(line);
        }
        if line.contains("</think>") {
            thinking = false;
        }
    }
    kept.join("\n").trim().to_string()
}

// ---- throttle --------------------------------------------------------------

/// Identical bodies within the window are dropped: sensors like smartd can
/// re-fire the same condition on every poll. Keyed by body hash in the state
/// directory; failures never block the alert.
fn throttled(state: &Path, body: &str, minutes: u64) -> bool {
    if minutes == 0 {
        return false;
    }
    let mut hasher = DefaultHasher::new();
    body.hash(&mut hasher);
    let marker = state.join(format!("throttle-{:016x}", hasher.finish()));
    let recent = fs::metadata(&marker)
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| SystemTime::now().duration_since(modified).ok())
        .is_some_and(|age| age.as_secs() < minutes * 60);
    if recent {
        return true;
    }
    let _ = fs::write(&marker, b"");
    false
}

// ---- HTTP via curl ---------------------------------------------------------

fn curl_json(method: &str, url: &str, token: Option<&str>, payload: &Value) -> Result<Value> {
    let mut command = Command::new(CURL);
    command
        .args(["-sf", "--connect-timeout", "5", "--max-time", "30"])
        .args(["-H", "Content-Type: application/json"])
        .args(["-X", method, url, "-d", &payload.to_string()])
        .stdin(Stdio::null())
        .stderr(Stdio::null());
    if let Some(token) = token {
        command.args(["-H", &format!("Authorization: Bearer {token}")]);
    }
    let output = command
        .output()
        .map_err(|error| format!("run curl: {error}"))?;
    if !output.status.success() {
        return Err(format!("{method} {url} failed"));
    }
    if output.stdout.is_empty() {
        return Ok(Value::Null);
    }
    serde_json::from_slice(&output.stdout).map_err(|error| format!("parse response: {error}"))
}

// ---- enrichment ------------------------------------------------------------

/// Best-effort local-LLM summary; None on any failure — a cold model or a
/// downed llama-swap degrades the summary but never drops the alert. The
/// generous timeout covers llama-swap's on-demand model load; local tokens
/// are free, so max_tokens is a guard, not a budget.
fn summarize(body: &str) -> Option<String> {
    if SUMMARY_URL.is_empty() {
        return None;
    }
    let payload = json!({
        "model": SUMMARY_MODEL,
        "max_tokens": 2000,
        "chat_template_kwargs": {"enable_thinking": false},
        "messages": [
            {"role": "system", "content": SUMMARY_PROMPT},
            {"role": "user", "content": body},
        ],
    });
    let mut command = Command::new(CURL);
    command
        .args(["-sf", "--max-time", "150"])
        .args(["-H", "Content-Type: application/json"])
        .args([&format!("{SUMMARY_URL}/v1/chat/completions"), "-d", &payload.to_string()])
        .stdin(Stdio::null())
        .stderr(Stdio::null());
    let output = command.output().ok()?;
    if !output.status.success() {
        return None;
    }
    let response: Value = serde_json::from_slice(&output.stdout).ok()?;
    let content = response
        .get("choices")?
        .get(0)?
        .get("message")?
        .get("content")?
        .as_str()?;
    let cleaned = clean_summary(content);
    (!cleaned.is_empty()).then_some(cleaned)
}

// ---- Matrix delivery -------------------------------------------------------

fn deliver(state: &Path, body: &str) -> Result<()> {
    let user = env_required("MATRIX_USER")?;
    let password = env_required("MATRIX_PASSWORD")?;
    let room = percent_encode(&env_required("ALERT_ROOM_ID")?);

    let login = curl_json(
        "POST",
        &format!("{HOMESERVER}/_matrix/client/v3/login"),
        None,
        &json!({
            "type": "m.login.password",
            "identifier": {"type": "m.id.user", "user": user},
            "password": password,
        }),
    )?;
    let token = login
        .get("access_token")
        .and_then(Value::as_str)
        .ok_or("login returned no access token")?
        .to_string();

    // One-time setup, stamped: accept the room invite and set the display
    // name. Both best-effort — joining is idempotent but concurrent alerts
    // can race here, and the send below must still happen.
    let stamp = state.join("initialized");
    if !stamp.exists() {
        let _ = curl_json(
            "POST",
            &format!("{HOMESERVER}/_matrix/client/v3/join/{room}"),
            Some(&token),
            &json!({}),
        );
        let _ = curl_json(
            "PUT",
            &format!(
                "{HOMESERVER}/_matrix/client/v3/profile/{}/displayname",
                percent_encode(&env_required("MATRIX_USER")?)
            ),
            Some(&token),
            &json!({"displayname": "alertbot"}),
        );
        let _ = fs::write(&stamp, b"");
    }

    // txn id: nanoseconds + PID, so two concurrent alerts in the same
    // instant can't be deduplicated into one by the server.
    let result = curl_json(
        "PUT",
        &format!(
            "{HOMESERVER}/_matrix/client/v3/rooms/{room}/send/m.room.message/{}-{}",
            unix_nanos(),
            std::process::id()
        ),
        Some(&token),
        &json!({"msgtype": "m.text", "body": body}),
    );

    let _ = curl_json(
        "POST",
        &format!("{HOMESERVER}/_matrix/client/v3/logout"),
        Some(&token),
        &json!({}),
    );
    result.map(|_| ())
}

fn run() -> Result<()> {
    let arguments: Vec<String> = env::args().skip(1).collect();
    let options = parse_arguments(&arguments, || {
        let mut text = String::new();
        let _ = std::io::stdin().take(1_048_576).read_to_string(&mut text);
        text
    })?;

    let state = PathBuf::from(STATE_DIR);
    let _ = fs::create_dir_all(&state);
    if throttled(&state, &options.body, options.throttle_minutes) {
        return Ok(());
    }
    let body = match options.summarize {
        true => match summarize(&options.body) {
            Some(summary) => insert_summary(&options.body, &summary),
            None => options.body,
        },
        false => options.body,
    };
    deliver(&state, &body)
}

fn main() {
    if let Err(error) = run() {
        eprintln!("ship-alert: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arguments_and_stdin() {
        let options =
            parse_arguments(&["hello".into(), "world".into()], || unreachable!()).unwrap();
        assert_eq!(options.body, "hello world");
        assert!(!options.summarize);
        assert_eq!(options.throttle_minutes, 0);

        let options = parse_arguments(
            &["--summarize".into(), "--throttle-minutes".into(), "30".into()],
            || "from stdin\n".into(),
        )
        .unwrap();
        assert!(options.summarize);
        assert_eq!(options.throttle_minutes, 30);
        assert_eq!(options.body, "from stdin");

        assert!(parse_arguments(&[], || "".into()).is_err());
        assert!(parse_arguments(&["--throttle-minutes".into()], || "x".into()).is_err());
    }

    #[test]
    fn summary_insertion_preserves_the_format() {
        assert_eq!(
            insert_summary("🔴 fw0: x.service failed\nlog line", "disk was full"),
            "🔴 fw0: x.service failed\n💡 disk was full\n———\nlog line"
        );
        assert_eq!(
            insert_summary("one-liner", "context"),
            "one-liner\n💡 context"
        );
    }

    #[test]
    fn think_blocks_are_stripped() {
        assert_eq!(
            clean_summary("<think>\nreasoning\n</think>\n\nThe disk failed.\n"),
            "The disk failed."
        );
        assert_eq!(clean_summary("plain answer"), "plain answer");
        assert_eq!(clean_summary("<think>only thoughts</think>"), "");
    }

    #[test]
    fn matrix_ids_are_percent_encoded() {
        assert_eq!(percent_encode("!room:sux.is"), "%21room%3Asux.is");
        assert_eq!(percent_encode("@alertbot:sux.is"), "%40alertbot%3Asux.is");
        assert_eq!(percent_encode("safe-chars_1.2~"), "safe-chars_1.2~");
    }

    #[test]
    fn throttle_drops_repeats_within_the_window() {
        let state = env::temp_dir().join(format!("ship-alert-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&state);
        fs::create_dir_all(&state).unwrap();
        assert!(!throttled(&state, "same body", 30));
        assert!(throttled(&state, "same body", 30));
        assert!(!throttled(&state, "different body", 30));
        // Window zero disables throttling entirely.
        assert!(!throttled(&state, "same body", 0));
        let _ = fs::remove_dir_all(&state);
    }
}
