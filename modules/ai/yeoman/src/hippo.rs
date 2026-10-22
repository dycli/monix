//! The yeoman's memory: its own hippo service, asked over `hippo.sock` as the
//! hippo CLI does. hippo stores every message and folds them into the view.

use serde::Deserialize;
use serde_json::json;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

#[derive(Clone)]
pub struct Hippo {
    pub sock: PathBuf,
    /// In seat mode, the title the seat's sessions go by: hippo reads the
    /// chat from Claude Code's session files on its own (logging would keep
    /// it twice), among every other chat it follows.
    pub seat: Option<String>,
}

#[derive(Deserialize)]
struct Reply {
    ok: bool,
    out: String,
}

impl Hippo {
    fn ask(&self, cmd: &str, args: &[&str]) -> Result<String, String> {
        let mut conn = UnixStream::connect(&self.sock)
            .map_err(|e| format!("hippo at {}: {e}", self.sock.display()))?;
        let mut raw = json!({"cmd": cmd, "args": args}).to_string();
        raw.push('\n');
        conn.write_all(raw.as_bytes()).map_err(|e| e.to_string())?;
        let mut line = String::new();
        BufReader::new(&conn)
            .read_line(&mut line)
            .map_err(|e| e.to_string())?;
        let reply: Reply = serde_json::from_str(&line).map_err(|e| format!("hippo: {e}"))?;
        if reply.ok {
            Ok(reply.out)
        } else {
            Err(format!("hippo: {}", reply.out))
        }
    }

    /// The whole view, `<chat>` to `</chat>`, once the compactor settles.
    pub fn view(&self) -> Result<String, String> {
        self.ask("view", &["whole"])
    }

    /// Logs one message: `user` for the captain's words, `talk` for the yeoman's.
    pub fn log(&self, kind: &str, text: &str) -> Result<(), String> {
        if self.seat.is_some() {
            return Ok(());
        }
        self.ask("log", &[kind, text]).map(|_| ())
    }

    /// Opens line `id+n` into its two halves; `n = 1` gives the message whole.
    pub fn zoom(&self, id: u64, n: u64) -> Result<String, String> {
        self.ask("zoom", &[&id.to_string(), &n.to_string()])
    }

    /// Every message matching a case-insensitive regex, newest last.
    pub fn search(&self, regex: &str) -> Result<String, String> {
        self.ask("search", &[regex])
    }

    /// When message `id` was sent.
    pub fn date(&self, id: u64) -> Result<String, String> {
        self.ask("date", &[&id.to_string()])
    }

    /// The last `n` messages whole, oldest first: the seat's own, when
    /// hippo keeps other chats too.
    pub fn tail(&self, n: u64) -> Result<Vec<Said>, String> {
        let n = n.to_string();
        let out = match &self.seat {
            Some(title) => self.ask("tail", &[&n, title])?,
            None => self.ask("tail", &[&n])?,
        };
        out.lines()
            .map(|l| serde_json::from_str(l).map_err(|e| format!("hippo tail: {e}")))
            .collect()
    }
}

/// One message as hippo keeps it, for showing a conversation.
#[derive(Clone, Debug, Deserialize, serde::Serialize)]
pub struct Said {
    pub i: u64,
    pub kind: String,
    pub text: String,
    pub date: String,
}
