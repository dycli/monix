//! How much of each AI subscription is used, and by whom, from the host's
//! usage service (a Unix socket that answers with a report for people).

use std::time::Duration;

use serde_json::Value;

use crate::core::Cached;

/// Each report asks every provider afresh, so it is kept a while.
const FRESH: Duration = Duration::from_secs(300);
/// The usage service reads three providers in turn.
const USAGE_PATIENCE: Duration = Duration::from_secs(60);

pub struct Usage {
    socket: String,
    held: Cached<Value>,
}

impl Usage {
    pub fn new(socket: String) -> Self {
        Usage {
            socket,
            held: Cached::new(FRESH),
        }
    }

    pub fn report(&self) -> Result<Value, String> {
        self.held.get(|| {
            let text = report::read(&self.socket).map_err(|e| format!("usage: {e}"))?;
            Ok(serde_json::to_value(report::parse(&text)).unwrap_or_default())
        })
    }
}

/// The usage service's report, which is written for people: a line per
/// window, then who used it.
///
/// ```text
/// claude  5h      3%  resets Mon Oct 19 00:09
///         bridge 75% (memory 17%) · libri 24% (memory 2%) · $10 at API prices
/// codex   unknown (RuntimeError: ...)
/// ```
mod report {
    use std::io::Read;
    use std::os::unix::net::UnixStream;

    use serde::Serialize;

    use super::USAGE_PATIENCE;

    #[derive(Serialize, Debug, PartialEq)]
    pub struct Report {
        pub windows: Vec<Window>,
        /// Accounts that couldn't be read, and the kind of error.
        pub unknown: Vec<(String, String)>,
    }

    #[derive(Serialize, Debug, PartialEq)]
    pub struct Window {
        pub account: String,
        pub window: String,
        pub pct: u32,
        pub resets: String,
        /// Who used it, as shares of the whole, most first.
        pub shares: Vec<(String, u32)>,
        pub cost: Option<String>,
    }

    pub fn read(sock: &str) -> std::io::Result<String> {
        let mut s = UnixStream::connect(sock)?;
        s.set_read_timeout(Some(USAGE_PATIENCE))?;
        s.shutdown(std::net::Shutdown::Write)?;
        let mut text = String::new();
        s.read_to_string(&mut text)?;
        Ok(text)
    }

    pub fn parse(text: &str) -> Report {
        let mut r = Report {
            windows: Vec::new(),
            unknown: Vec::new(),
        };
        for line in text.lines() {
            if let Some(rest) = line.strip_prefix("        ") {
                let Some(w) = r.windows.last_mut() else {
                    continue;
                };
                for part in rest.split(" · ") {
                    if part.ends_with("at API prices") {
                        w.cost = part.split_whitespace().next().map(str::to_owned);
                    } else if let Some((who, pct)) = part.split_once(' ')
                        && let Some(Ok(pct)) = pct.split('%').next().map(str::parse)
                    {
                        w.shares.push((who.to_owned(), pct));
                    }
                }
                continue;
            }
            let mut words = line.split_whitespace();
            let (Some(account), Some(second)) = (words.next(), words.next()) else {
                continue;
            };
            if second == "unknown" {
                let why = line.split_once('(').map_or("", |(_, w)| w);
                let kind = why.split_once(':').map_or(why, |(kind, _)| kind);
                r.unknown
                    .push((account.to_owned(), kind.trim_end_matches(')').to_owned()));
            } else if let (Some(pct), Some("resets")) = (words.next(), words.next())
                && let Ok(pct) = pct.trim_end_matches('%').parse()
            {
                r.windows.push(Window {
                    account: account.to_owned(),
                    window: second.to_owned(),
                    pct,
                    resets: words.collect::<Vec<_>>().join(" "),
                    shares: Vec::new(),
                    cost: None,
                });
            }
        }
        r
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn reads_windows_shares_and_failures() {
            let r = parse(concat!(
                "claude  5h      3%  resets Mon Oct 19 00:09\n",
                "        bridge 75% (memory 17%) · libri 24% (memory 2%) · suki 1% (memory 0%) · $10 at API prices\n",
                "claude  week    0%  resets Sun Oct 25 17:59\n",
                "        no use logged here\n",
                "codex   unknown (RuntimeError: failed to fetch: 401\n",
                "  \"error\": {\n",
                "})\n",
                "go      unknown (HTTPError: HTTP Error 401: Unauthorized)\n",
                "Shares count use logged on Water.\n",
            ));
            assert_eq!(r.windows.len(), 2);
            assert_eq!(r.windows[0].pct, 3);
            assert_eq!(r.windows[0].resets, "Mon Oct 19 00:09");
            assert_eq!(
                r.windows[0].shares,
                [
                    ("bridge".into(), 75),
                    ("libri".into(), 24),
                    ("suki".into(), 1)
                ]
            );
            assert_eq!(r.windows[0].cost.as_deref(), Some("$10"));
            assert!(r.windows[1].shares.is_empty());
            assert_eq!(
                r.unknown,
                [
                    ("codex".into(), "RuntimeError".into()),
                    ("go".into(), "HTTPError".into())
                ]
            );
        }
    }
}
