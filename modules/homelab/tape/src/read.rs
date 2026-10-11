//! Reading the tape back. `show` prints the file's header and a count of
//! each record kind; `dump` streams every record as JSON lines with
//! prices and times made readable.

use std::{collections::BTreeMap, io};

use databento::dbn::{
    RType,
    decode::{DbnMetadata, DecodeRecordRef, dbn::Decoder},
    encode::{EncodeRecordRef, json::Encoder},
};

pub fn show(file: &str) -> Result<(), String> {
    let mut decoder = Decoder::from_zstd_file(file).map_err(|e| format!("{file}: {e}"))?;
    let meta = decoder.metadata();
    println!("dataset   {}", meta.dataset);
    println!("version   {}", meta.version);
    println!(
        "schema    {}",
        meta.schema.map_or("mixed".to_owned(), |s| s.to_string())
    );
    println!("symbols   {}", meta.symbols.join(" "));
    println!("mappings  {}", meta.mappings.len());

    let mut counts: BTreeMap<String, u64> = BTreeMap::new();
    let (mut first, mut last) = (u64::MAX, 0u64);
    while let Some(record) = decoder.decode_record_ref().map_err(|e| e.to_string())? {
        let kind = RType::try_from(record.header().rtype).map_or_else(
            |_| format!("rtype {}", record.header().rtype),
            |r| r.to_string(),
        );
        *counts.entry(kind).or_default() += 1;
        if let Some(ts) = record.header().ts_event() {
            let ns = ts.unix_timestamp_nanos() as u64;
            first = first.min(ns);
            last = last.max(ns);
        }
    }
    if first <= last {
        println!("from      {}", when(first));
        println!("to        {}", when(last));
    }
    for (kind, n) in counts {
        println!("{kind:<9} {n}");
    }
    Ok(())
}

pub fn dump(file: &str) -> Result<(), String> {
    let mut decoder = Decoder::from_zstd_file(file).map_err(|e| format!("{file}: {e}"))?;
    let out = io::stdout().lock();
    let mut json = Encoder::new(io::BufWriter::new(out), false, true, true);
    while let Some(record) = decoder.decode_record_ref().map_err(|e| e.to_string())? {
        json.encode_record_ref(record).map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn when(ns: u64) -> String {
    chrono::DateTime::from_timestamp_nanos(ns as i64)
        .format("%Y-%m-%d %H:%M:%S%.9f UTC")
        .to_string()
}
