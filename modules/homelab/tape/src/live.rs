//! One live session, written to the tape as it arrives.
//!
//! Each connection asks for a book snapshot first, so a file always opens
//! with a full book and can be replayed on its own. The file rolls at the
//! UTC day boundary. A dropped connection ends the file and a new session
//! begins after a pause, which again starts with a snapshot; nothing is
//! replayed, so a gap in the tape is a gap in the connection.

use std::{fs::File, io::BufWriter, path::Path, time::Duration};

use chrono::Utc;
use databento::{
    LiveClient,
    dbn::{
        Compression, ErrorMsg, Metadata, RecordRef, SType, Schema, SystemMsg,
        encode::{DynWriter, EncodeRecordRef, dbn::Encoder},
    },
    live::Subscription,
};

use crate::{
    DATASET,
    archive::{Archive, Fresh, day_of, stamp_of},
};

const RETRY: Duration = Duration::from_secs(10);

pub fn record(root: &Path, key: &str, symbols: &[String]) -> Result<(), String> {
    let archive = Archive::new(root, DATASET);
    let runtime = tokio::runtime::Runtime::new().map_err(|e| e.to_string())?;
    runtime.block_on(async {
        loop {
            match session(&archive, key, symbols).await {
                Ok(()) => eprintln!("tape: gateway closed the session"),
                Err(e) => eprintln!("tape: session ended: {e}"),
            }
            tokio::time::sleep(RETRY).await;
        }
    })
}

/// Connects, subscribes, and writes until the gateway hangs up.
async fn session(archive: &Archive, key: &str, symbols: &[String]) -> Result<(), String> {
    let mut client = LiveClient::builder()
        .key(key)
        .map_err(|e| e.to_string())?
        .dataset(DATASET)
        .build()
        .await
        .map_err(|e| e.to_string())?;
    for schema in [Schema::Definition, Schema::Mbo] {
        client
            .subscribe(
                Subscription::builder()
                    .symbols(symbols.to_vec())
                    .schema(schema)
                    .stype_in(SType::Continuous)
                    .use_snapshot(schema == Schema::Mbo)
                    .build(),
            )
            .await
            .map_err(|e| e.to_string())?;
    }
    let metadata = client.start().await.map_err(|e| e.to_string())?;
    eprintln!("tape: recording {} symbols", symbols.len());

    let mut tape = Tape::open(archive, &metadata)?;
    let result = loop {
        match client.next_record().await {
            Ok(Some(record)) => {
                if let Some(msg) = record.get::<ErrorMsg>() {
                    eprintln!("tape: gateway error: {}", msg.err().unwrap_or("?"));
                } else if let Some(msg) = record.get::<SystemMsg>()
                    && !msg.is_heartbeat()
                {
                    eprintln!("tape: gateway: {}", msg.msg().unwrap_or("?"));
                }
                tape.roll_if_new_day(archive, &metadata)?;
                tape.write(record)?;
            }
            Ok(None) => break Ok(()),
            Err(e) => break Err(e.to_string()),
        }
    };
    tape.finish()?;
    result
}

/// The file currently being written and the day it belongs to.
struct Tape {
    day: chrono::NaiveDate,
    encoder: Encoder<DynWriter<'static, BufWriter<File>>>,
    fresh: Fresh,
}

impl Tape {
    fn open(archive: &Archive, metadata: &Metadata) -> Result<Self, String> {
        let now = Utc::now();
        let (writer, fresh) = archive
            .open(day_of(now), &stamp_of(now))
            .map_err(|e| e.to_string())?;
        let zstd = DynWriter::new(writer, Compression::Zstd).map_err(|e| e.to_string())?;
        let encoder = Encoder::new(zstd, metadata).map_err(|e| e.to_string())?;
        eprintln!("tape: writing {}", fresh.path.display());
        Ok(Self {
            day: day_of(now),
            encoder,
            fresh,
        })
    }

    fn write(&mut self, record: RecordRef<'_>) -> Result<(), String> {
        self.encoder
            .encode_record_ref(record)
            .map_err(|e| e.to_string())
    }

    fn roll_if_new_day(&mut self, archive: &Archive, metadata: &Metadata) -> Result<(), String> {
        if day_of(Utc::now()) == self.day {
            return Ok(());
        }
        let next = Self::open(archive, metadata)?;
        std::mem::replace(self, next).finish()
    }

    /// Writes the Zstandard end of frame and renames the file into place.
    fn finish(mut self) -> Result<(), String> {
        self.encoder.get_mut().finish().map_err(|e| e.to_string())?;
        self.fresh.commit().map(drop).map_err(|e| e.to_string())
    }
}
