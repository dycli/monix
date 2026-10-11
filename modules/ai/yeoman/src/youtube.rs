//! The yeoman's YouTube, through yt-dlp: a search, and a video's captions
//! as plain text, the uploader's own before YouTube's automatic ones. It
//! reaches YouTube only: a link to any other site is refused, so nothing
//! read elsewhere can be carried out through it.

use serde_json::{Value, json};
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;
use ureq::Agent;

const HOSTS: [&str; 5] = [
    "youtube.com",
    "www.youtube.com",
    "m.youtube.com",
    "music.youtube.com",
    "youtu.be",
];
/// How much of a transcript a read shows.
const TEXT: usize = 200_000;
const TIMEOUT: Duration = Duration::from_secs(60);

pub struct Youtube {
    bin: PathBuf,
    agent: Agent,
}

impl Youtube {
    pub fn new(bin: PathBuf) -> Self {
        let config = Agent::config_builder()
            .timeout_global(Some(TIMEOUT))
            .http_status_as_error(false)
            .build();
        Youtube {
            bin,
            agent: Agent::new_with_config(config),
        }
    }

    /// yt-dlp's JSON for a target, nothing downloaded.
    fn info(&self, args: &[&str]) -> Result<Value, String> {
        let out = Command::new(&self.bin)
            .args(["-J", "--no-warnings", "--socket-timeout", "30"])
            .args(args)
            .output()
            .map_err(|e| format!("yt-dlp: {e}"))?;
        if !out.status.success() {
            let err = String::from_utf8_lossy(&out.stderr);
            return Err(format!(
                "yt-dlp: {}",
                err.lines().last().unwrap_or("failed").trim()
            ));
        }
        serde_json::from_slice(&out.stdout).map_err(|e| format!("yt-dlp: {e}"))
    }

    pub fn search(&self, query: &str, count: u64) -> Result<String, String> {
        let target = format!("ytsearch{}:{query}", count.clamp(1, 25));
        let info = self.info(&["--flat-playlist", &target])?;
        Ok(serde_json::to_string_pretty(&videos(&info)).unwrap_or_default())
    }

    pub fn transcript(&self, url: &str, language: &str) -> Result<String, String> {
        if !is_youtube(url) {
            return Err("only youtube.com and youtu.be links".into());
        }
        let info = self.info(&[url.trim()])?;
        let (track, kind, key) = pick(&info, language).ok_or("this video has no captions")?;
        let (ext, track_url) = ["json3", "vtt"]
            .into_iter()
            .find_map(|ext| {
                track
                    .as_array()?
                    .iter()
                    .find(|f| f["ext"] == ext)
                    .and_then(|f| f["url"].as_str())
                    .map(|u| (ext, u))
            })
            .ok_or("no readable caption format")?;
        let mut resp = self
            .agent
            .get(track_url)
            .call()
            .map_err(|e| format!("captions: {e}"))?;
        let body = resp
            .body_mut()
            .read_to_string()
            .map_err(|e| format!("captions: {e}"))?;
        let text = if ext == "json3" {
            let events: Value =
                serde_json::from_str(&body).map_err(|e| format!("captions: {e}"))?;
            json3_text(&events)
        } else {
            vtt_text(&body)
        };
        let cut = text.char_indices().nth(TEXT).map(|(i, _)| i);
        Ok(json!({
            "title": info["title"],
            "channel": channel(&info),
            "length": info["duration"].as_u64().map(minutes),
            "captions": format!("{kind} ({key})"),
            "cut": cut.is_some(),
            "text": cut.map_or(text.as_str(), |i| &text[..i]),
        })
        .to_string())
    }
}

fn is_youtube(url: &str) -> bool {
    let rest = url.trim().split_once("://").map_or("", |(_, r)| r);
    let host = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host = host.rsplit('@').next().unwrap_or(host);
    let host = host.split(':').next().unwrap_or(host).to_ascii_lowercase();
    HOSTS.contains(&host.as_str())
}

fn channel(v: &Value) -> Value {
    v["channel"]
        .as_str()
        .or(v["uploader"].as_str())
        .map_or(Value::Null, Value::from)
}

/// Seconds as h:mm:ss or m:ss.
fn minutes(seconds: u64) -> String {
    let (m, s) = (seconds / 60, seconds % 60);
    if m >= 60 {
        format!("{}:{:02}:{s:02}", m / 60, m % 60)
    } else {
        format!("{m}:{s:02}")
    }
}

/// A search's videos: title, channel, length, views and link.
fn videos(info: &Value) -> Vec<Value> {
    info["entries"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|e| {
            let id = e["id"].as_str()?;
            Some(json!({
                "title": e["title"],
                "channel": channel(e),
                "length": e["duration"].as_u64().map(minutes),
                "views": e["view_count"],
                "url": format!("https://www.youtube.com/watch?v={id}"),
            }))
        })
        .collect()
}

/// The best caption track: own captions before automatic ones, the asked
/// language before the video's original one. The track's formats, its
/// kind and its language key.
fn pick<'a>(info: &'a Value, language: &str) -> Option<(&'a Value, &'static str, &'a str)> {
    let own = info["subtitles"].as_object();
    let auto = info["automatic_captions"].as_object();
    let find = |tracks: Option<&'a serde_json::Map<String, Value>>, want: &str| {
        tracks?
            .iter()
            .find(|(k, _)| *k == want || k.starts_with(&format!("{want}-")))
            .map(|(k, v)| (v, k.as_str()))
    };
    if let Some((v, k)) = find(own, language) {
        return Some((v, "own", k));
    }
    if let Some((v, k)) = find(auto, &format!("{language}-orig")).or_else(|| find(auto, language)) {
        return Some((v, "automatic", k));
    }
    if let Some((k, v)) = own.into_iter().flatten().find(|(k, _)| *k != "live_chat") {
        return Some((v, "own", k));
    }
    auto.into_iter()
        .flatten()
        .find(|(k, _)| k.ends_with("-orig"))
        .map(|(k, v)| (v, "automatic", k.as_str()))
}

/// The words of a json3 caption file, one space between them.
fn json3_text(events: &Value) -> String {
    let lines: Vec<String> = events["events"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|e| {
            e["segs"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|s| s["utf8"].as_str())
                .collect()
        })
        .collect();
    lines
        .join(" ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// The words of a WebVTT file: cue text only, with the repeats automatic
/// captions roll over dropped.
fn vtt_text(vtt: &str) -> String {
    let mut lines: Vec<String> = Vec::new();
    for raw in vtt.lines() {
        let line = raw.trim();
        if line.is_empty()
            || line.starts_with("WEBVTT")
            || line.starts_with("Kind:")
            || line.starts_with("Language:")
            || line.starts_with("NOTE")
            || line.contains("-->")
        {
            continue;
        }
        let clean = strip_tags(line);
        if clean.is_empty() || lines.last().is_some_and(|l| *l == clean) {
            continue;
        }
        lines.push(clean);
    }
    lines
        .join(" ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn strip_tags(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut depth = 0;
    for c in line.chars() {
        match c {
            '<' => depth += 1,
            '>' if depth > 0 => depth -= 1,
            _ if depth == 0 => out.push(c),
            _ => {}
        }
    }
    out.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
        .trim()
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_youtube_links_pass() {
        assert!(is_youtube("https://www.youtube.com/watch?v=abc"));
        assert!(is_youtube(" https://YOUTU.BE/abc "));
        assert!(is_youtube("https://music.youtube.com:443/watch?v=abc"));
        assert!(!is_youtube("https://youtube.com.evil.net/watch?v=abc"));
        assert!(!is_youtube("https://evil.net/?u=https://youtube.com"));
        assert!(!is_youtube("https://user@evil.net/youtube.com"));
        assert!(!is_youtube("watch?v=abc"));
    }

    #[test]
    fn lengths_and_search_entries_read_well() {
        assert_eq!(minutes(19), "0:19");
        assert_eq!(minutes(241), "4:01");
        assert_eq!(minutes(3725), "1:02:05");
        let info = json!({"entries": [
            {"id": "a1", "title": "T", "uploader": "U", "duration": 61, "view_count": 5},
            {"title": "no id"},
        ]});
        let v = videos(&info);
        assert_eq!(v.len(), 1);
        assert_eq!(v[0]["channel"], "U");
        assert_eq!(v[0]["length"], "1:01");
        assert_eq!(v[0]["url"], "https://www.youtube.com/watch?v=a1");
    }

    #[test]
    fn own_captions_come_before_automatic_and_the_language_before_original() {
        let info = json!({
            "subtitles": {"de": [{"ext": "vtt"}], "live_chat": [{"ext": "json"}]},
            "automatic_captions": {"en": [{"ext": "vtt"}], "en-orig": [{"ext": "json3"}]},
        });
        let (_, kind, key) = pick(&info, "en").unwrap();
        assert_eq!((kind, key), ("automatic", "en-orig"));
        let (_, kind, key) = pick(&info, "de").unwrap();
        assert_eq!((kind, key), ("own", "de"));
        let (_, kind, key) = pick(&info, "fr").unwrap();
        assert_eq!((kind, key), ("own", "de"));
        let auto_only = json!({"automatic_captions": {"ja-orig": [], "en": []}});
        assert_eq!(pick(&auto_only, "fr").unwrap().2, "ja-orig");
        assert!(pick(&json!({}), "en").is_none());
        assert!(pick(&json!({"subtitles": {"live_chat": []}}), "en").is_none());
    }

    #[test]
    fn caption_files_become_words() {
        let events = json!({"events": [
            {"segs": [{"utf8": "Hello "}, {"utf8": "there"}]},
            {"tStartMs": 1},
            {"segs": [{"utf8": "friend"}]},
        ]});
        assert_eq!(json3_text(&events), "Hello there friend");
        let vtt = "WEBVTT\nKind: captions\nLanguage: en\n\n00:00:00.000 --> 00:00:01.000\nHello <c>there</c>\n\n00:00:01.000 --> 00:00:02.000\nHello there\n\n00:00:02.000 --> 00:00:03.000 align:start\nfriend &amp; co\n";
        assert_eq!(vtt_text(vtt), "Hello there friend & co");
    }
}
