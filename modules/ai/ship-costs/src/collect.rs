use crate::db::{Database, SourceStamp};
use crate::model::{QuotaSample, UsageEvent, provider_of};
use chrono::DateTime;
use rusqlite::{Connection, OpenFlags};
use serde::Deserialize;
use serde_json::Value;
use std::error::Error;
use std::fs::{self, File};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

const FLEET_DIR: &str = match option_env!("SHIP_COSTS_FLEET_DIR") {
    Some(path) => path,
    None => "/var/lib/agents/tasks",
};

#[derive(Default)]
pub struct CollectStats {
    pub scanned_files: usize,
    pub unchanged_files: usize,
    pub events_seen: usize,
    pub quota_samples_seen: usize,
    pub warnings: Vec<String>,
}

pub fn collect(database: &mut Database, home: &Path, online: bool) -> CollectStats {
    let mut stats = CollectStats::default();
    collect_jsonl_tree(
        database,
        &home.join(".claude/projects"),
        parse_claude,
        &mut stats,
    );
    for root in [
        home.join(".codex/sessions"),
        home.join(".codex/archived_sessions"),
    ] {
        collect_jsonl_tree(database, &root, parse_codex, &mut stats);
    }
    collect_fleet(database, Path::new(FLEET_DIR), &mut stats);
    collect_opencode(database, &home.join(".local/share/opencode"), &mut stats);
    if online {
        collect_go_quota(database, home, &mut stats);
    }
    stats
}

#[derive(Deserialize)]
struct GoUsageResponse {
    usage: GoUsageWindows,
}

#[derive(Deserialize)]
struct GoUsageWindows {
    rolling: GoUsageWindow,
    weekly: GoUsageWindow,
    monthly: GoUsageWindow,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GoUsageWindow {
    status: String,
    percent: f64,
    resets_at: String,
}

fn collect_go_quota(database: &mut Database, home: &Path, stats: &mut CollectStats) {
    let result = || -> Result<Vec<QuotaSample>, Box<dyn Error>> {
        let auth_path = home.join(".local/share/opencode/auth.json");
        let auth: Value = serde_json::from_reader(File::open(&auth_path)?)?;
        let key = auth
            .get("opencode-go")
            .and_then(|entry| text(entry, "key"))
            .ok_or("OpenCode Go key is absent")?;
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(3))
            .timeout_read(Duration::from_secs(5))
            .build();
        let response: GoUsageResponse = agent
            .get("https://opencode.ai/zen/go/v1/usage")
            .set("Authorization", &format!("Bearer {key}"))
            .call()?
            .into_json()?;
        go_quota_samples(response, chrono::Utc::now().timestamp())
    }();

    match result {
        Ok(quotas) => {
            stats.quota_samples_seen += quotas.len();
            if let Err(error) = database.import(None, &[], &quotas) {
                stats.warnings.push(format!("OpenCode Go quota: {error}"));
            }
        }
        Err(error) => stats
            .warnings
            .push(format!("OpenCode Go quota unavailable: {error}")),
    }
}

fn go_quota_samples(
    response: GoUsageResponse,
    timestamp: i64,
) -> Result<Vec<QuotaSample>, Box<dyn Error>> {
    let windows = [
        ("rolling", 300, response.usage.rolling),
        ("weekly", 10_080, response.usage.weekly),
        ("monthly", 43_200, response.usage.monthly),
    ];
    windows
        .into_iter()
        .map(|(name, minutes, window)| {
            let resets_at = parse_timestamp(&window.resets_at)
                .ok_or_else(|| format!("invalid Go {name} reset timestamp"))?;
            Ok(QuotaSample {
                id: format!("opencode-go:{name}:{resets_at}:{}", window.percent),
                timestamp,
                provider: "opencode-go".into(),
                plan: "go".into(),
                window_minutes: minutes,
                used_percent: window.percent,
                resets_at: Some(resets_at),
                limit_reached: window.status == "rate-limited" || window.percent >= 100.0,
            })
        })
        .collect()
}

type Parser = fn(&Path) -> Result<(Vec<UsageEvent>, Vec<QuotaSample>), Box<dyn Error>>;

fn collect_jsonl_tree(
    database: &mut Database,
    root: &Path,
    parser: Parser,
    stats: &mut CollectStats,
) {
    for path in discover(root, |path| {
        path.extension()
            .is_some_and(|extension| extension == "jsonl")
    }) {
        import_file(database, &path, parser, stats);
    }
}

fn import_file(database: &mut Database, path: &Path, parser: Parser, stats: &mut CollectStats) {
    let stamp = match SourceStamp::read(path) {
        Ok(stamp) => stamp,
        Err(error) => {
            stats.warnings.push(format!("{}: {error}", path.display()));
            return;
        }
    };
    match database.source_changed(&stamp) {
        Ok(false) => {
            stats.unchanged_files += 1;
            return;
        }
        Err(error) => {
            stats.warnings.push(format!("{}: {error}", path.display()));
            return;
        }
        Ok(true) => {}
    }
    match parser(path) {
        Ok((events, quotas)) => {
            stats.scanned_files += 1;
            stats.events_seen += events.len();
            stats.quota_samples_seen += quotas.len();
            if let Err(error) = database.import(Some(&stamp), &events, &quotas) {
                stats.warnings.push(format!("{}: {error}", path.display()));
            }
        }
        Err(error) => stats.warnings.push(format!("{}: {error}", path.display())),
    }
}

fn parse_claude(path: &Path) -> Result<(Vec<UsageEvent>, Vec<QuotaSample>), Box<dyn Error>> {
    let reader = BufReader::new(File::open(path)?);
    let mut events = Vec::new();
    for (line_number, line) in reader.lines().enumerate() {
        let line = line?;
        let Ok(entry) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if text(&entry, "type") != Some("assistant") {
            continue;
        }
        let Some(message) = entry.get("message") else {
            continue;
        };
        let Some(usage) = message.get("usage") else {
            continue;
        };
        let Some(timestamp) = text(&entry, "timestamp").and_then(parse_timestamp) else {
            continue;
        };
        let model = text(message, "model").unwrap_or("unknown");
        let session = text(&entry, "sessionId").unwrap_or("unknown");
        let request = text(&entry, "requestId");
        let message_id = text(message, "id");
        let uuid = text(&entry, "uuid");
        let identity = match (request, message_id, uuid) {
            (Some(request), Some(message), _) => format!("{request}:{message}"),
            (_, _, Some(uuid)) => uuid.to_string(),
            _ => format!("{session}:{line_number}"),
        };
        let creation = usage.get("cache_creation");
        let cache_write_5m = creation
            .map(|value| integer(value, "ephemeral_5m_input_tokens"))
            .unwrap_or_else(|| integer(usage, "cache_creation_input_tokens"));
        let cache_write_1h = creation
            .map(|value| integer(value, "ephemeral_1h_input_tokens"))
            .unwrap_or(0);
        let input = integer(usage, "input_tokens");
        let cache_read = integer(usage, "cache_read_input_tokens");
        let web_searches = usage
            .get("server_tool_use")
            .map(|value| integer(value, "web_search_requests"))
            .unwrap_or(0);
        events.push(UsageEvent {
            id: format!("claude:{identity}"),
            timestamp,
            provider: "claude".into(),
            source: "claude-code".into(),
            model: model.into(),
            session: session.into(),
            input_tokens: input,
            output_tokens: integer(usage, "output_tokens"),
            cache_read_tokens: cache_read,
            cache_write_5m_tokens: cache_write_5m,
            cache_write_1h_tokens: cache_write_1h,
            context_tokens: input
                .saturating_add(cache_read)
                .saturating_add(cache_write_5m)
                .saturating_add(cache_write_1h),
            web_searches,
        });
    }
    Ok((events, Vec::new()))
}

fn parse_codex(path: &Path) -> Result<(Vec<UsageEvent>, Vec<QuotaSample>), Box<dyn Error>> {
    let reader = BufReader::new(File::open(path)?);
    let mut events = Vec::new();
    let mut quotas = Vec::new();
    let mut session = path
        .file_stem()
        .and_then(|name| name.to_str())
        .unwrap_or("unknown")
        .to_string();
    let mut model = "unknown".to_string();
    let mut previous = [0i64; 4];
    for (line_number, line) in reader.lines().enumerate() {
        let line = line?;
        let Ok(entry) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let Some(payload) = entry.get("payload") else {
            continue;
        };
        match text(&entry, "type") {
            Some("session_meta") => {
                if let Some(id) = text(payload, "id") {
                    session = id.to_string();
                }
            }
            Some("turn_context") => {
                if let Some(name) = text(payload, "model").filter(|name| !name.is_empty()) {
                    model = name.to_string();
                }
            }
            Some("event_msg") if text(payload, "type") == Some("token_count") => {
                let Some(timestamp) = text(&entry, "timestamp").and_then(parse_timestamp) else {
                    continue;
                };
                let Some(info) = payload.get("info") else {
                    collect_quotas(payload, timestamp, &session, line_number, &mut quotas);
                    continue;
                };
                let (usage, is_delta) = if let Some(last) = info.get("last_token_usage") {
                    (last, true)
                } else if let Some(total) = info.get("total_token_usage") {
                    (total, false)
                } else {
                    collect_quotas(payload, timestamp, &session, line_number, &mut quotas);
                    continue;
                };
                let current = [
                    integer(usage, "input_tokens"),
                    integer(usage, "cached_input_tokens"),
                    integer(usage, "cache_write_input_tokens"),
                    integer(usage, "output_tokens"),
                ];
                let values = if is_delta {
                    current
                } else {
                    if current
                        .iter()
                        .zip(previous)
                        .any(|(current, old)| current < &old)
                    {
                        previous = [0; 4];
                    }
                    let delta = [
                        current[0].saturating_sub(previous[0]),
                        current[1].saturating_sub(previous[1]),
                        current[2].saturating_sub(previous[2]),
                        current[3].saturating_sub(previous[3]),
                    ];
                    previous = current;
                    delta
                };
                if values.iter().any(|value| *value != 0) {
                    let uncached = values[0]
                        .saturating_sub(values[1])
                        .saturating_sub(values[2]);
                    let identity = format!("{session}:{timestamp}:{line_number}");
                    events.push(UsageEvent {
                        id: format!("codex:{identity}"),
                        timestamp,
                        provider: "chatgpt".into(),
                        source: "codex".into(),
                        model: model.clone(),
                        session: session.clone(),
                        input_tokens: uncached,
                        output_tokens: values[3],
                        cache_read_tokens: values[1],
                        cache_write_5m_tokens: values[2],
                        cache_write_1h_tokens: 0,
                        context_tokens: values[0],
                        web_searches: 0,
                    });
                }
                collect_quotas(payload, timestamp, &session, line_number, &mut quotas);
            }
            _ => {}
        }
    }
    Ok((events, quotas))
}

fn collect_quotas(
    payload: &Value,
    timestamp: i64,
    session: &str,
    line_number: usize,
    quotas: &mut Vec<QuotaSample>,
) {
    let Some(rate_limits) = payload.get("rate_limits") else {
        return;
    };
    let plan = text(rate_limits, "plan_type").unwrap_or("unknown");
    let reached = rate_limits
        .get("rate_limit_reached_type")
        .is_some_and(|value| !value.is_null());
    for name in ["primary", "secondary"] {
        let Some(window) = rate_limits.get(name).filter(|value| !value.is_null()) else {
            continue;
        };
        let Some(used_percent) = number(window, "used_percent") else {
            continue;
        };
        let window_minutes = integer(window, "window_minutes");
        quotas.push(QuotaSample {
            id: format!("codex-quota:{session}:{timestamp}:{line_number}:{name}"),
            timestamp,
            provider: "chatgpt".into(),
            plan: plan.into(),
            window_minutes,
            used_percent,
            resets_at: window.get("resets_at").and_then(Value::as_i64),
            limit_reached: reached || used_percent >= 100.0,
        });
    }
}

fn collect_fleet(database: &mut Database, root: &Path, stats: &mut CollectStats) {
    for path in discover(root, |path| {
        path.file_name().is_some_and(|name| name == "usage.json")
    }) {
        import_file(database, &path, parse_fleet, stats);
    }
}

fn parse_fleet(path: &Path) -> Result<(Vec<UsageEvent>, Vec<QuotaSample>), Box<dyn Error>> {
    let usage: Value = serde_json::from_reader(File::open(path)?)?;
    let metadata = fs::metadata(path)?;
    let timestamp = metadata.modified()?.duration_since(UNIX_EPOCH)?.as_secs() as i64;
    let model = text(&usage, "model").unwrap_or("unknown");
    let provider = provider_of("", model);
    let input = integer(&usage, "input_tokens");
    let cache_read = integer(&usage, "cache_read_tokens");
    let cache_write = integer(&usage, "cache_creation_tokens");
    let session = path
        .parent()
        .and_then(Path::file_name)
        .and_then(|name| name.to_str())
        .unwrap_or("unknown");
    Ok((
        vec![UsageEvent {
            id: format!("fleet:{session}"),
            timestamp,
            provider: provider.into(),
            source: format!("fleet/{}", text(&usage, "executor").unwrap_or("unknown")),
            model: model.into(),
            session: session.into(),
            input_tokens: input,
            output_tokens: integer(&usage, "output_tokens"),
            cache_read_tokens: cache_read,
            cache_write_5m_tokens: cache_write,
            cache_write_1h_tokens: 0,
            context_tokens: 0,
            web_searches: 0,
        }],
        Vec::new(),
    ))
}

fn collect_opencode(database: &mut Database, root: &Path, stats: &mut CollectStats) {
    for path in discover(root, |path| {
        path.extension().is_some_and(|extension| extension == "db")
    }) {
        match parse_opencode(&path) {
            Ok(events) => {
                stats.scanned_files += 1;
                stats.events_seen += events.len();
                if let Err(error) = database.import(None, &events, &[]) {
                    stats.warnings.push(format!("{}: {error}", path.display()));
                }
            }
            Err(error) => stats.warnings.push(format!("{}: {error}", path.display())),
        }
    }
}

fn parse_opencode(path: &Path) -> Result<Vec<UsageEvent>, Box<dyn Error>> {
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    let mut statement = connection.prepare(
        "SELECT id, session_id, time_created, data FROM message ORDER BY time_created, id",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, i64>(2)?,
            row.get::<_, String>(3)?,
        ))
    })?;
    let mut events = Vec::new();
    for row in rows {
        let (id, session, created, data) = row?;
        let Ok(message) = serde_json::from_str::<Value>(&data) else {
            continue;
        };
        if text(&message, "role") != Some("assistant") {
            continue;
        }
        let Some(tokens) = message.get("tokens") else {
            continue;
        };
        let provider_hint = text(&message, "providerID").unwrap_or("unknown");
        let model_id = text(&message, "modelID").unwrap_or("unknown");
        let model = format!("{provider_hint}/{model_id}");
        let cache = tokens.get("cache").unwrap_or(&Value::Null);
        let input = integer(tokens, "input");
        let cache_read = integer(cache, "read");
        let cache_write = integer(cache, "write");
        events.push(UsageEvent {
            id: format!("opencode:{id}"),
            timestamp: if created > 10_000_000_000 {
                created / 1000
            } else {
                created
            },
            provider: provider_of(provider_hint, model_id).into(),
            source: "opencode".into(),
            model,
            session,
            input_tokens: input,
            output_tokens: integer(tokens, "output").saturating_add(integer(tokens, "reasoning")),
            cache_read_tokens: cache_read,
            cache_write_5m_tokens: cache_write,
            cache_write_1h_tokens: 0,
            context_tokens: input.saturating_add(cache_read).saturating_add(cache_write),
            web_searches: 0,
        });
    }
    Ok(events)
}

fn discover(root: &Path, predicate: impl Fn(&Path) -> bool + Copy) -> Vec<PathBuf> {
    fn visit(
        root: &Path,
        depth: u8,
        predicate: impl Fn(&Path) -> bool + Copy,
        paths: &mut Vec<PathBuf>,
    ) {
        if depth == 0 {
            return;
        }
        let Ok(entries) = fs::read_dir(root) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if file_type.is_dir() && !file_type.is_symlink() {
                visit(&path, depth - 1, predicate, paths);
            } else if file_type.is_file() && predicate(&path) {
                paths.push(path);
            }
        }
    }
    let mut paths = Vec::new();
    visit(root, 14, predicate, &mut paths);
    paths.sort();
    paths
}

fn text<'a>(value: &'a Value, field: &str) -> Option<&'a str> {
    value.get(field).and_then(Value::as_str)
}

fn integer(value: &Value, field: &str) -> i64 {
    value
        .get(field)
        .and_then(|value| value.as_i64().or_else(|| value.as_u64()?.try_into().ok()))
        .unwrap_or(0)
}

fn number(value: &Value, field: &str) -> Option<f64> {
    value.get(field).and_then(Value::as_f64)
}

fn parse_timestamp(timestamp: &str) -> Option<i64> {
    DateTime::parse_from_rfc3339(&timestamp.replace('Z', "+00:00"))
        .ok()
        .map(|timestamp| timestamp.timestamp())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn fixture(name: &str, contents: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "ship-costs-{name}-{}-{}.jsonl",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let mut file = File::create(&path).unwrap();
        file.write_all(contents.as_bytes()).unwrap();
        path
    }

    #[test]
    fn parses_claude_cache_classes() {
        let path = fixture(
            "claude",
            r#"{"type":"assistant","timestamp":"2026-08-19T12:00:00Z","requestId":"r","sessionId":"s","message":{"id":"m","model":"claude-fable-5","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":11,"cache_creation":{"ephemeral_5m_input_tokens":40,"ephemeral_1h_input_tokens":50},"server_tool_use":{"web_search_requests":2}}}}
"#,
        );
        let (events, _) = parse_claude(&path).unwrap();
        fs::remove_file(path).unwrap();
        let event = &events[0];
        assert_eq!(event.id, "claude:r:m");
        assert_eq!(event.cache_write_5m_tokens, 40);
        assert_eq!(event.cache_write_1h_tokens, 50);
        assert_eq!(event.web_searches, 2);
        assert_eq!(event.context_tokens, 130);
    }

    #[test]
    fn prefers_codex_last_usage_and_reads_quota() {
        let path = fixture(
            "codex",
            concat!(
                "{\"type\":\"session_meta\",\"payload\":{\"id\":\"session\"}}\n",
                "{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.6-sol\"}}\n",
                "{\"type\":\"event_msg\",\"timestamp\":\"2026-08-19T12:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":60,\"cache_write_input_tokens\":10,\"output_tokens\":20}},\"rate_limits\":{\"plan_type\":\"plus\",\"primary\":{\"used_percent\":41.0,\"window_minutes\":10080,\"resets_at\":123},\"secondary\":null,\"rate_limit_reached_type\":null}}}\n"
            ),
        );
        let (events, quotas) = parse_codex(&path).unwrap();
        fs::remove_file(path).unwrap();
        assert_eq!(events[0].input_tokens, 30);
        assert_eq!(events[0].cache_read_tokens, 60);
        assert_eq!(events[0].cache_write_5m_tokens, 10);
        assert_eq!(events[0].output_tokens, 20);
        assert_eq!(quotas[0].window_minutes, 10080);
        assert_eq!(quotas[0].used_percent, 41.0);
        assert_eq!(quotas[0].plan, "plus");
    }

    #[test]
    fn parses_direct_go_quota_windows() {
        let response: GoUsageResponse = serde_json::from_str(
            r#"{"usage":{"rolling":{"status":"ok","percent":0,"resetsAt":"2026-08-19T18:48:11Z"},"weekly":{"status":"ok","percent":14,"resetsAt":"2026-08-24T00:00:00Z"},"monthly":{"status":"rate-limited","percent":100,"resetsAt":"2026-09-17T02:32:11Z"}}}"#,
        )
        .unwrap();
        let quotas = go_quota_samples(response, 42).unwrap();
        assert_eq!(quotas.len(), 3);
        assert_eq!(quotas[1].window_minutes, 10_080);
        assert_eq!(quotas[1].used_percent, 14.0);
        assert!(quotas[2].limit_reached);
    }
}
