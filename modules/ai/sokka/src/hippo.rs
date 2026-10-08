//! Sokka's memory: its own hippo service, asked over `hippo.sock` as the
//! hippo CLI does. hippo stores every message and folds them into the view.

use serde::Deserialize;
use serde_json::json;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

pub struct Hippo {
    pub sock: PathBuf,
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

    /// Logs one message: `user` for the captain's words, `talk` for Sokka's.
    pub fn log(&self, kind: &str, text: &str) -> Result<(), String> {
        self.ask("log", &[kind, text]).map(|_| ())
    }
}
