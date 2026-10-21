//! Files that stay: whatever the person sends is kept under the yeoman's
//! state by its name, so a later turn can find it, convert it and send it
//! back. The name is the only handle the model has, so no path it gives
//! can reach outside the library.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// The longest name kept, in characters; the extension survives a cut.
const NAME_MAX: usize = 120;

pub struct Library(PathBuf);

/// One kept file, as `files` lists it.
pub struct Kept {
    pub name: String,
    pub size: u64,
    pub when: SystemTime,
}

impl Library {
    pub fn new(state: &Path) -> Self {
        Self(state.join("files"))
    }

    /// Keeps `data` as `name` made plain; a name already taken by other
    /// bytes gets " 2", " 3" before its extension, while the same bytes
    /// again keep the name they have. Answers the name kept.
    pub fn keep(&self, name: &str, data: &[u8]) -> io::Result<String> {
        fs::create_dir_all(&self.0)?;
        let name = plain(name);
        let (stem, ext) = split(&name);
        for n in 1.. {
            let candidate = if n == 1 {
                name.clone()
            } else {
                format!("{stem} {n}{ext}")
            };
            let path = self.0.join(&candidate);
            match fs::read(&path) {
                Ok(old) if old == data => return Ok(candidate),
                Ok(_) => continue,
                Err(e) if e.kind() == io::ErrorKind::NotFound => {
                    // Written aside and renamed, so a reader never sees
                    // half a file.
                    let part = self.0.join(format!(".{candidate}.part"));
                    fs::write(&part, data)?;
                    fs::rename(&part, &path)?;
                    return Ok(candidate);
                }
                Err(e) => return Err(e),
            }
        }
        unreachable!()
    }

    /// The kept files whose names hold every word of `words`, any case,
    /// newest first; all of them when `words` is blank.
    pub fn find(&self, words: &str) -> io::Result<Vec<Kept>> {
        let words: Vec<String> = words.split_whitespace().map(str::to_lowercase).collect();
        let dir = match fs::read_dir(&self.0) {
            Ok(d) => d,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e),
        };
        let mut found = Vec::new();
        for entry in dir {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            let meta = entry.metadata()?;
            let lower = name.to_lowercase();
            if name.starts_with('.') || !meta.is_file() || !words.iter().all(|w| lower.contains(w))
            {
                continue;
            }
            found.push(Kept {
                name,
                size: meta.len(),
                when: meta.modified()?,
            });
        }
        found.sort_by(|a, b| b.when.cmp(&a.when).then_with(|| a.name.cmp(&b.name)));
        Ok(found)
    }

    /// Where the kept file `name` is, if there is one by exactly that name.
    pub fn path(&self, name: &str) -> Option<PathBuf> {
        if name != plain(name) {
            return None;
        }
        let path = self.0.join(name);
        path.is_file().then_some(path)
    }
}

/// Puts a file in the outbox, where the answer's sender picks it up: a
/// kept file by its name, else one on the computer's desk (a screenshot,
/// a download), which is kept first. Only the name counts, so no path
/// reaches past either folder. Answers the name it goes out as.
pub fn send(
    library: &Library,
    desk: Option<&Path>,
    outbox: &Path,
    name: &str,
) -> Result<String, String> {
    let kept = match library.path(name) {
        Some(_) => name.to_owned(),
        None => {
            let base = Path::new(name).file_name().ok_or("Which file?")?;
            let from = desk
                .map(|d| d.join(base))
                .filter(|p| p.is_file())
                .ok_or_else(|| format!("There is no file called {name}."))?;
            let data = fs::read(&from).map_err(|e| format!("{}: {e}", from.display()))?;
            library
                .keep(&base.to_string_lossy(), &data)
                .map_err(|e| e.to_string())?
        }
    };
    let from = library.path(&kept).ok_or("The file went missing.")?;
    fs::create_dir_all(outbox).map_err(|e| e.to_string())?;
    let stamp = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_millis();
    fs::copy(&from, outbox.join(format!("{stamp}-{kept}"))).map_err(|e| e.to_string())?;
    Ok(kept)
}

/// A name with no directory, no leading dot and nothing unprintable.
fn plain(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or_default();
    let clean: String = base
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let clean = clean.trim().trim_start_matches('.').trim();
    if clean.is_empty() {
        return "file".into();
    }
    if clean.chars().count() <= NAME_MAX {
        return clean.to_owned();
    }
    let (stem, ext) = split(clean);
    let keep = NAME_MAX.saturating_sub(ext.chars().count());
    format!("{}{ext}", stem.chars().take(keep).collect::<String>())
}

/// The name before its extension, and the extension with its dot.
fn split(name: &str) -> (&str, &str) {
    match name.rfind('.') {
        Some(i) if i > 0 && name.len() - i <= 8 => name.split_at(i),
        _ => (name, ""),
    }
}

/// A file's type: by its bytes for pictures and PDFs, else by its
/// extension, else plain bytes.
pub fn mime_of(name: &str, data: &[u8]) -> String {
    if let Some(m) = crate::image_type(data) {
        return m.into();
    }
    if data.starts_with(b"%PDF") {
        return "application/pdf".into();
    }
    let ext = split(name).1.trim_start_matches('.').to_lowercase();
    match ext.as_str() {
        "txt" | "log" => "text/plain",
        "md" => "text/markdown",
        "csv" => "text/csv",
        "html" | "htm" => "text/html",
        "json" => "application/json",
        "xml" => "application/xml",
        "svg" => "image/svg+xml",
        "heic" => "image/heic",
        "tif" | "tiff" => "image/tiff",
        "bmp" => "image/bmp",
        "ico" => "image/x-icon",
        "avif" => "image/avif",
        "zip" => "application/zip",
        "gz" | "tgz" => "application/gzip",
        "tar" => "application/x-tar",
        "7z" => "application/x-7z-compressed",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "odt" => "application/vnd.oasis.opendocument.text",
        "epub" => "application/epub+zip",
        "mp3" => "audio/mpeg",
        "m4a" => "audio/mp4",
        "wav" => "audio/wav",
        "ogg" | "opus" => "audio/ogg",
        "flac" => "audio/flac",
        "mp4" => "video/mp4",
        "mov" => "video/quicktime",
        "webm" => "video/webm",
        "mkv" => "video/x-matroska",
        _ => "application/octet-stream",
    }
    .into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_by_plain_name_and_finds_by_words() {
        let dir = std::env::temp_dir().join(format!("yeoman-files-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let lib = Library::new(&dir);
        assert_eq!(
            lib.keep("../../etc/Lease Scan.pdf", b"a").unwrap(),
            "Lease Scan.pdf"
        );
        assert_eq!(lib.keep("Lease Scan.pdf", b"a").unwrap(), "Lease Scan.pdf");
        assert_eq!(
            lib.keep("Lease Scan.pdf", b"b").unwrap(),
            "Lease Scan 2.pdf"
        );
        assert_eq!(lib.keep(".bashrc", b"c").unwrap(), "bashrc");
        assert_eq!(lib.keep("", b"d").unwrap(), "file");
        let names =
            |w| -> Vec<String> { lib.find(w).unwrap().into_iter().map(|k| k.name).collect() };
        assert_eq!(names("lease").len(), 2);
        assert_eq!(names("SCAN 2"), ["Lease Scan 2.pdf"]);
        assert_eq!(names("").len(), 4);
        assert!(lib.path("Lease Scan.pdf").is_some());
        assert!(lib.path("../files/Lease Scan.pdf").is_none());
        assert!(lib.path(".Lease Scan.pdf.part").is_none());
        assert!(lib.path("missing.pdf").is_none());
        let long = format!("{}.jpeg", "x".repeat(300));
        assert_eq!(plain(&long).chars().count(), NAME_MAX);
        assert!(plain(&long).ends_with(".jpeg"));
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn sends_kept_files_and_desk_files_by_name_only() {
        let dir = std::env::temp_dir().join(format!("yeoman-send-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let (desk, outbox) = (dir.join("desk"), dir.join("outbox"));
        fs::create_dir_all(&desk).unwrap();
        fs::write(desk.join("page.png"), b"png").unwrap();
        fs::write(dir.join("secret"), b"no").unwrap();
        let lib = Library::new(&dir);
        lib.keep("notes.txt", b"text").unwrap();
        assert_eq!(
            send(&lib, Some(&desk), &outbox, "notes.txt").unwrap(),
            "notes.txt"
        );
        assert_eq!(
            send(&lib, Some(&desk), &outbox, "/desk/page.png").unwrap(),
            "page.png"
        );
        assert!(lib.path("page.png").is_some());
        assert!(send(&lib, Some(&desk), &outbox, "../secret").is_err());
        assert!(send(&lib, None, &outbox, "missing.png").is_err());
        let mut out: Vec<String> = fs::read_dir(&outbox)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .map(|n| n.split_once('-').unwrap().1.to_owned())
            .collect();
        out.sort();
        assert_eq!(out, ["notes.txt", "page.png"]);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn types_by_bytes_then_extension() {
        assert_eq!(mime_of("x.txt", b"\x89PNG\r\n"), "image/png");
        assert_eq!(mime_of("IMG_1.HEIC", b"...."), "image/heic");
        assert_eq!(mime_of("a.zip", b"PK"), "application/zip");
        assert_eq!(mime_of("noext", b"?"), "application/octet-stream");
    }
}
