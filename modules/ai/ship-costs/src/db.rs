use crate::model::{QuotaSample, UsageEvent};
use rusqlite::{Connection, OptionalExtension, params};
use std::error::Error;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

// Increment when an adapter changes how an unchanged source file is read.
pub const PARSER_VERSION: i64 = 1;

pub struct Database {
    connection: Connection,
    pub path: PathBuf,
}

#[derive(Clone, Debug)]
pub struct SourceStamp {
    pub path: String,
    pub size: i64,
    pub modified_ns: i64,
}

impl SourceStamp {
    pub fn read(path: &Path) -> Result<Self, Box<dyn Error>> {
        let metadata = fs::metadata(path)?;
        let modified_ns = metadata
            .modified()?
            .duration_since(UNIX_EPOCH)?
            .as_nanos()
            .try_into()
            .unwrap_or(i64::MAX);
        Ok(Self {
            path: path.to_string_lossy().into_owned(),
            size: metadata.len().try_into().unwrap_or(i64::MAX),
            modified_ns,
        })
    }
}

impl Database {
    pub fn open(path: PathBuf) -> Result<Self, Box<dyn Error>> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let connection = Connection::open(&path)?;
        connection.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;
             PRAGMA foreign_keys = ON;
             CREATE TABLE IF NOT EXISTS usage_event (
               id TEXT PRIMARY KEY,
               timestamp INTEGER NOT NULL,
               provider TEXT NOT NULL,
               source TEXT NOT NULL,
               model TEXT NOT NULL,
               session TEXT NOT NULL,
               input_tokens INTEGER NOT NULL,
               output_tokens INTEGER NOT NULL,
               cache_read_tokens INTEGER NOT NULL,
               cache_write_5m_tokens INTEGER NOT NULL,
               cache_write_1h_tokens INTEGER NOT NULL,
               context_tokens INTEGER NOT NULL,
               web_searches INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS usage_event_time_provider
               ON usage_event(timestamp, provider);
             CREATE TABLE IF NOT EXISTS quota_sample (
               id TEXT PRIMARY KEY,
               timestamp INTEGER NOT NULL,
               provider TEXT NOT NULL,
               plan TEXT NOT NULL,
               window_minutes INTEGER NOT NULL,
               used_percent REAL NOT NULL,
               resets_at INTEGER,
               limit_reached INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS quota_sample_time_provider
               ON quota_sample(timestamp, provider);
             CREATE TABLE IF NOT EXISTS source_file (
               path TEXT PRIMARY KEY,
               size INTEGER NOT NULL,
               modified_ns INTEGER NOT NULL,
               parser_version INTEGER NOT NULL
             );",
        )?;
        let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        if version == 0 {
            connection.execute_batch("PRAGMA user_version = 1;")?;
        } else if version != 1 {
            return Err(format!("unsupported ledger schema {version}; expected 1").into());
        }
        Ok(Self { connection, path })
    }

    pub fn source_changed(&self, stamp: &SourceStamp) -> Result<bool, Box<dyn Error>> {
        let saved: Option<(i64, i64, i64)> = self
            .connection
            .query_row(
                "SELECT size, modified_ns, parser_version FROM source_file WHERE path = ?1",
                [&stamp.path],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()?;
        Ok(saved != Some((stamp.size, stamp.modified_ns, PARSER_VERSION)))
    }

    pub fn import(
        &mut self,
        stamp: Option<&SourceStamp>,
        events: &[UsageEvent],
        quotas: &[QuotaSample],
    ) -> Result<(), Box<dyn Error>> {
        let transaction = self.connection.transaction()?;
        {
            let mut statement = transaction.prepare(
                "INSERT INTO usage_event (
                   id, timestamp, provider, source, model, session,
                   input_tokens, output_tokens, cache_read_tokens,
                   cache_write_5m_tokens, cache_write_1h_tokens,
                   context_tokens, web_searches
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
                 ON CONFLICT(id) DO UPDATE SET
                   timestamp = excluded.timestamp,
                   provider = excluded.provider,
                   source = excluded.source,
                   model = excluded.model,
                   session = excluded.session,
                   input_tokens = excluded.input_tokens,
                   output_tokens = excluded.output_tokens,
                   cache_read_tokens = excluded.cache_read_tokens,
                   cache_write_5m_tokens = excluded.cache_write_5m_tokens,
                   cache_write_1h_tokens = excluded.cache_write_1h_tokens,
                   context_tokens = excluded.context_tokens,
                   web_searches = excluded.web_searches",
            )?;
            for event in events {
                statement.execute(params![
                    event.id,
                    event.timestamp,
                    event.provider,
                    event.source,
                    event.model,
                    event.session,
                    event.input_tokens,
                    event.output_tokens,
                    event.cache_read_tokens,
                    event.cache_write_5m_tokens,
                    event.cache_write_1h_tokens,
                    event.context_tokens,
                    event.web_searches,
                ])?;
            }
        }
        {
            let mut statement = transaction.prepare(
                "INSERT INTO quota_sample (
                   id, timestamp, provider, plan, window_minutes,
                   used_percent, resets_at, limit_reached
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                 ON CONFLICT(id) DO UPDATE SET
                   timestamp = excluded.timestamp,
                   provider = excluded.provider,
                   plan = excluded.plan,
                   window_minutes = excluded.window_minutes,
                   used_percent = excluded.used_percent,
                   resets_at = excluded.resets_at,
                   limit_reached = excluded.limit_reached",
            )?;
            for quota in quotas {
                statement.execute(params![
                    quota.id,
                    quota.timestamp,
                    quota.provider,
                    quota.plan,
                    quota.window_minutes,
                    quota.used_percent,
                    quota.resets_at,
                    quota.limit_reached,
                ])?;
            }
        }
        if let Some(stamp) = stamp {
            transaction.execute(
                "INSERT INTO source_file(path, size, modified_ns, parser_version)
                 VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(path) DO UPDATE SET
                   size = excluded.size,
                   modified_ns = excluded.modified_ns,
                   parser_version = excluded.parser_version",
                params![stamp.path, stamp.size, stamp.modified_ns, PARSER_VERSION],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn events_since(&self, timestamp: i64) -> Result<Vec<UsageEvent>, Box<dyn Error>> {
        let mut statement = self.connection.prepare(
            "SELECT id, timestamp, provider, source, model, session,
                    input_tokens, output_tokens, cache_read_tokens,
                    cache_write_5m_tokens, cache_write_1h_tokens,
                    context_tokens, web_searches
             FROM usage_event WHERE timestamp >= ?1 ORDER BY timestamp",
        )?;
        let rows = statement.query_map([timestamp], |row| {
            Ok(UsageEvent {
                id: row.get(0)?,
                timestamp: row.get(1)?,
                provider: row.get(2)?,
                source: row.get(3)?,
                model: row.get(4)?,
                session: row.get(5)?,
                input_tokens: row.get(6)?,
                output_tokens: row.get(7)?,
                cache_read_tokens: row.get(8)?,
                cache_write_5m_tokens: row.get(9)?,
                cache_write_1h_tokens: row.get(10)?,
                context_tokens: row.get(11)?,
                web_searches: row.get(12)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn quotas_since(&self, timestamp: i64) -> Result<Vec<QuotaSample>, Box<dyn Error>> {
        let mut statement = self.connection.prepare(
            "SELECT id, timestamp, provider, plan, window_minutes,
                    used_percent, resets_at, limit_reached
             FROM quota_sample WHERE timestamp >= ?1 ORDER BY timestamp",
        )?;
        let rows = statement.query_map([timestamp], |row| {
            Ok(QuotaSample {
                id: row.get(0)?,
                timestamp: row.get(1)?,
                provider: row.get(2)?,
                plan: row.get(3)?,
                window_minutes: row.get(4)?,
                used_percent: row.get(5)?,
                resets_at: row.get(6)?,
                limit_reached: row.get::<_, i64>(7)? != 0,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn counts(&self) -> Result<(i64, i64, i64), Box<dyn Error>> {
        Ok((
            self.connection
                .query_row("SELECT count(*) FROM usage_event", [], |row| row.get(0))?,
            self.connection
                .query_row("SELECT count(*) FROM quota_sample", [], |row| row.get(0))?,
            self.connection
                .query_row("SELECT count(*) FROM source_file", [], |row| row.get(0))?,
        ))
    }
}
