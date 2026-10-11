//! Where the tape lives: `<root>/glbx-mdp3/<UTC date>/<name>.dbn.zst`.
//! Files are written under a dot-name and renamed in once complete, so a
//! reader never sees a half-written file.

use std::{
    fs::{self, File},
    io::{self, BufWriter},
    path::{Path, PathBuf},
};

use chrono::{DateTime, NaiveDate, Utc};

pub struct Archive {
    root: PathBuf,
}

/// A file being written: the final path and the temporary one it grows at.
pub struct Fresh {
    pub path: PathBuf,
    tmp: PathBuf,
}

impl Archive {
    pub fn new(root: &Path, dataset: &str) -> Self {
        Self {
            root: root.join(dataset.to_ascii_lowercase().replace('.', "-")),
        }
    }

    /// A new file for `day` named after `stamp`; the directory is created.
    pub fn open(&self, day: NaiveDate, stamp: &str) -> io::Result<(BufWriter<File>, Fresh)> {
        let dir = self.root.join(day.format("%Y-%m-%d").to_string());
        fs::create_dir_all(&dir)?;
        let path = dir.join(format!("{stamp}.dbn.zst"));
        let tmp = dir.join(format!(".{stamp}.dbn.zst"));
        let writer = BufWriter::new(File::create(&tmp)?);
        Ok((writer, Fresh { path, tmp }))
    }
}

impl Fresh {
    /// Moves the finished file to its final name.
    pub fn commit(self) -> io::Result<PathBuf> {
        fs::rename(&self.tmp, &self.path)?;
        Ok(self.path)
    }
}

/// The UTC day of a wall-clock instant.
pub fn day_of(t: DateTime<Utc>) -> NaiveDate {
    t.date_naive()
}

/// A file-name stamp for an instant: `20261011T143000Z`.
pub fn stamp_of(t: DateTime<Utc>) -> String {
    t.format("%Y%m%dT%H%M%SZ").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn files_land_under_the_dataset_and_day_once_committed() {
        let tmp = std::env::temp_dir().join(format!("tape-test-{}", std::process::id()));
        let archive = Archive::new(&tmp, "GLBX.MDP3");
        let t = Utc.with_ymd_and_hms(2026, 10, 11, 14, 30, 0).unwrap();
        let (_writer, fresh) = archive.open(day_of(t), &stamp_of(t)).unwrap();
        let hidden = tmp.join("glbx-mdp3/2026-10-11/.20261011T143000Z.dbn.zst");
        assert!(hidden.exists());
        let path = fresh.commit().unwrap();
        assert_eq!(
            path,
            tmp.join("glbx-mdp3/2026-10-11/20261011T143000Z.dbn.zst")
        );
        assert!(path.exists() && !hidden.exists());
        fs::remove_dir_all(tmp).unwrap();
    }
}
