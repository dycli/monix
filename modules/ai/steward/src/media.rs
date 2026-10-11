//! Films and shows: the household's library, asked and added to through
//! Seerr's API on loopback. A request goes in under the Seerr user named
//! like the person when there is one, else under the key's own account.

use serde_json::{Value, json};
use std::time::Duration;
use ureq::Agent;

const TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Clone)]
pub struct Seerr {
    url: String,
    key: String,
    person: String,
    agent: Agent,
}

pub struct Service {
    pub id: u64,
    pub root: Option<String>,
    pub default_profile: Option<u64>,
    pub profiles: Vec<(u64, String)>,
}

impl Seerr {
    pub fn new(url: String, key: String, person: String) -> Self {
        let config = Agent::config_builder()
            .timeout_global(Some(TIMEOUT))
            .http_status_as_error(false)
            .build();
        Seerr {
            url,
            key: key.trim().to_owned(),
            person,
            agent: Agent::new_with_config(config),
        }
    }

    fn call(&self, path: &str, body: Option<Value>) -> Result<Value, String> {
        let url = format!("{}/api/v1{path}", self.url);
        let mut resp = match body {
            Some(b) => self
                .agent
                .post(&url)
                .header("X-Api-Key", &self.key)
                .send_json(&b),
            None => self.agent.get(&url).header("X-Api-Key", &self.key).call(),
        }
        .map_err(|e| format!("seerr: {e}"))?;
        let status = resp.status().as_u16();
        let v: Value = resp
            .body_mut()
            .read_json()
            .map_err(|e| format!("seerr: {e}"))?;
        if status >= 400 {
            let msg = v["message"].as_str().unwrap_or("").to_owned();
            return Err(format!("seerr: {status} {msg}"));
        }
        Ok(v)
    }

    pub fn search(&self, title: &str) -> Result<String, String> {
        let query: String = url_encode(title);
        let v = self.call(&format!("/search?query={query}&page=1"), None)?;
        Ok(search(&v))
    }

    pub fn seasons(&self, tmdb_id: u64) -> Result<String, String> {
        let v = self.call(&format!("/tv/{tmdb_id}"), None)?;
        Ok(seasons(&v))
    }

    /// The default Radarr or Sonarr behind Seerr, with its quality profiles.
    fn service(&self, kind: &str) -> Result<Service, String> {
        let name = if kind == "movie" { "radarr" } else { "sonarr" };
        let servers = self.call(&format!("/service/{name}"), None)?;
        let list = servers.as_array().cloned().unwrap_or_default();
        let server = list
            .iter()
            .find(|s| s["isDefault"].as_bool() == Some(true))
            .or(list.first())
            .ok_or(format!("No {name} behind Seerr."))?;
        let id = server["id"].as_u64().ok_or("seerr: server without id")?;
        let detail = self.call(&format!("/service/{name}/{id}"), None)?;
        Ok(Service {
            id,
            root: server["activeDirectory"].as_str().map(str::to_owned),
            default_profile: server["activeProfileId"].as_u64(),
            profiles: detail["profiles"]
                .as_array()
                .map(|p| {
                    p.iter()
                        .filter_map(|p| Some((p["id"].as_u64()?, p["name"].as_str()?.to_owned())))
                        .collect()
                })
                .unwrap_or_default(),
        })
    }

    pub fn profiles(&self, kind: &str) -> Result<String, String> {
        check_kind(kind)?;
        let s = self.service(kind)?;
        Ok(profiles(&s))
    }

    /// The Seerr user named like the person, if any.
    fn requester(&self) -> Result<Option<u64>, String> {
        if self.person.is_empty() {
            return Ok(None);
        }
        let v = self.call("/user?take=100", None)?;
        Ok(requester(&v, &self.person))
    }

    pub fn request(
        &self,
        kind: &str,
        tmdb_id: u64,
        seasons: Option<Vec<u64>>,
        quality: Option<&str>,
    ) -> Result<String, String> {
        check_kind(kind)?;
        let mut body = json!({"mediaType": kind, "mediaId": tmdb_id});
        if kind == "tv" {
            body["seasons"] = match seasons {
                Some(s) if !s.is_empty() => json!(s),
                _ => json!("all"),
            };
        }
        if let Some(q) = quality.filter(|q| !q.is_empty()) {
            let s = self.service(kind)?;
            let Some((id, _)) = s.profiles.iter().find(|(_, n)| n.eq_ignore_ascii_case(q)) else {
                return Err(format!("No quality {q}; the options are {}.", names(&s)));
            };
            body["serverId"] = json!(s.id);
            body["profileId"] = json!(id);
            if let Some(root) = s.root {
                body["rootFolder"] = json!(root);
            }
        }
        if let Some(user) = self.requester()? {
            body["userId"] = json!(user);
        }
        let made = self.call("/request", Some(body))?;
        Ok(format!(
            "Request {} is {}, by {}, at {} quality.",
            made["id"],
            request_status(&made),
            made["requestedBy"]["displayName"].as_str().unwrap_or("?"),
            quality.unwrap_or("default")
        ))
    }

    pub fn requests(&self, count: u64) -> Result<String, String> {
        let count = count.clamp(1, 50);
        let v = self.call(&format!("/request?take={count}&sort=added&skip=0"), None)?;
        Ok(requests(&v))
    }
}

fn check_kind(kind: &str) -> Result<(), String> {
    match kind {
        "movie" | "tv" => Ok(()),
        _ => Err("kind is movie or tv".into()),
    }
}

fn names(s: &Service) -> String {
    s.profiles
        .iter()
        .map(|(_, n)| n.as_str())
        .collect::<Vec<_>>()
        .join(", ")
}

/// Percent-encodes a query value: everything but unreserved characters.
fn url_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn media_status(info: &Value) -> &'static str {
    match info["status"].as_u64() {
        Some(2) => "pending",
        Some(3) => "downloading",
        Some(4) => "partly available",
        Some(5) => "available",
        _ => "not in the library",
    }
}

fn request_status(r: &Value) -> &'static str {
    match r["status"].as_u64() {
        Some(2) => "approved",
        Some(3) => "declined",
        _ => "pending",
    }
}

fn year(v: &Value) -> &str {
    v.as_str().map(|s| s.get(..4).unwrap_or("")).unwrap_or("")
}

fn search(v: &Value) -> String {
    let lines: Vec<String> = v["results"]
        .as_array()
        .map(|r| r.iter())
        .into_iter()
        .flatten()
        .filter(|r| matches!(r["mediaType"].as_str(), Some("movie" | "tv")))
        .take(10)
        .map(|r| {
            let kind = r["mediaType"].as_str().unwrap_or("");
            let title = r["title"].as_str().or(r["name"].as_str()).unwrap_or("?");
            let when = if kind == "movie" {
                year(&r["releaseDate"])
            } else {
                year(&r["firstAirDate"])
            };
            let overview: String = r["overview"]
                .as_str()
                .unwrap_or("")
                .chars()
                .take(300)
                .collect();
            format!(
                "{kind} {} {title} ({when}) [{}]: {overview}",
                r["id"],
                media_status(&r["mediaInfo"])
            )
        })
        .collect();
    if lines.is_empty() {
        "Nothing found.".into()
    } else {
        lines.join("\n")
    }
}

fn seasons(show: &Value) -> String {
    let have: Vec<(u64, &'static str)> = show["mediaInfo"]["seasons"]
        .as_array()
        .map(|s| s.iter())
        .into_iter()
        .flatten()
        .filter_map(|s| Some((s["seasonNumber"].as_u64()?, media_status(s))))
        .collect();
    let mut out = format!("{}\n", show["name"].as_str().unwrap_or("?"));
    for s in show["seasons"].as_array().into_iter().flatten() {
        let n = s["seasonNumber"].as_u64().unwrap_or(0);
        if n == 0 {
            continue;
        }
        let status = have
            .iter()
            .find(|(k, _)| *k == n)
            .map_or("not in the library", |(_, st)| st);
        out.push_str(&format!(
            "season {n}: {} episodes [{status}]\n",
            s["episodeCount"]
        ));
    }
    out
}

fn profiles(s: &Service) -> String {
    s.profiles
        .iter()
        .map(|(id, n)| {
            if Some(*id) == s.default_profile {
                format!("{n} (default)")
            } else {
                n.clone()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn requester(users: &Value, person: &str) -> Option<u64> {
    users["results"].as_array()?.iter().find_map(|u| {
        ["displayName", "jellyfinUsername", "plexUsername"]
            .iter()
            .any(|k| {
                u[k].as_str()
                    .is_some_and(|n| n.eq_ignore_ascii_case(person))
            })
            .then(|| u["id"].as_u64())
            .flatten()
    })
}

fn requests(v: &Value) -> String {
    let lines: Vec<String> = v["results"]
        .as_array()
        .map(|r| r.iter())
        .into_iter()
        .flatten()
        .map(|r| {
            let seasons: Vec<String> = r["seasons"]
                .as_array()
                .map(|s| s.iter())
                .into_iter()
                .flatten()
                .map(|s| s["seasonNumber"].to_string())
                .collect();
            let seasons = if seasons.is_empty() {
                String::new()
            } else {
                format!(" seasons {}", seasons.join(","))
            };
            format!(
                "request {}: {} {}{seasons}, by {}, {} [{}]",
                r["id"],
                r["media"]["mediaType"].as_str().unwrap_or("?"),
                r["media"]["tmdbId"],
                r["requestedBy"]["displayName"].as_str().unwrap_or("?"),
                request_status(r),
                media_status(&r["media"])
            )
        })
        .collect();
    if lines.is_empty() {
        "No requests.".into()
    } else {
        lines.join("\n")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_search_keeps_films_and_shows_with_their_library_state() {
        let v = json!({"results": [
            {"mediaType": "tv", "id": 95396, "name": "Severance", "firstAirDate": "2022-02-18",
             "overview": "Mark leads a team.", "mediaInfo": {"status": 5}},
            {"mediaType": "person", "id": 1, "name": "Someone"},
            {"mediaType": "movie", "id": 27205, "title": "Inception", "releaseDate": "2010-07-15"},
        ]});
        assert_eq!(
            search(&v),
            "tv 95396 Severance (2022) [available]: Mark leads a team.\n\
             movie 27205 Inception (2010) [not in the library]: "
        );
        assert_eq!(search(&json!({"results": []})), "Nothing found.");
    }

    #[test]
    fn seasons_skip_specials_and_show_what_the_library_holds() {
        let v = json!({"name": "Severance",
            "seasons": [{"seasonNumber": 0, "episodeCount": 3}, {"seasonNumber": 1, "episodeCount": 9},
                        {"seasonNumber": 2, "episodeCount": 10}],
            "mediaInfo": {"seasons": [{"seasonNumber": 1, "status": 5}]}});
        assert_eq!(
            seasons(&v),
            "Severance\nseason 1: 9 episodes [available]\nseason 2: 10 episodes [not in the library]\n"
        );
    }

    #[test]
    fn the_requester_is_the_person_by_any_of_their_names() {
        let users = json!({"results": [
            {"id": 1, "displayName": "clyd", "jellyfinUsername": "clyd"},
            {"id": 2, "displayName": "Gab", "jellyfinUsername": null},
        ]});
        assert_eq!(requester(&users, "gab"), Some(2));
        assert_eq!(requester(&users, "Clyd"), Some(1));
        assert_eq!(requester(&users, "nobody"), None);
    }

    #[test]
    fn profiles_mark_the_default_and_queries_are_encoded() {
        let s = Service {
            id: 1,
            root: None,
            default_profile: Some(4),
            profiles: vec![(4, "HD-1080p".into()), (5, "Ultra-HD".into())],
        };
        assert_eq!(profiles(&s), "HD-1080p (default)\nUltra-HD");
        assert_eq!(url_encode("the office & co"), "the%20office%20%26%20co");
        assert!(check_kind("book").is_err());
    }
}
