//! Photos sized for the frame. Immich's previews run to 1440 pixels on
//! the short side, more than the frame's 1920×1080 screen can show in any
//! orientation, and decoding the excess stalls the slideshow. Each is
//! shrunk once to fit 1080×1920 either way round and kept on disk.

use std::io::Cursor;
use std::path::PathBuf;

use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::{DynamicImage, ImageDecoder, ImageEncoder, ImageFormat, ImageReader};

/// The screen's sides; a photo shown either way round never needs more.
const SHORT: u32 = 1080;
const LONG: u32 = 1920;
const QUALITY: u8 = 88;

/// The photo as JPEG no larger than the screen, its colour profile kept:
/// iPhone previews carry Display P3. Immich bakes orientation into
/// previews, so dropping the rest of the metadata turns nothing.
pub fn fit(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let reader = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .map_err(|e| format!("photo: {e}"))?;
    let jpeg = reader.format() == Some(ImageFormat::Jpeg);
    let mut decoder = reader.into_decoder().map_err(|e| format!("photo: {e}"))?;
    let (w, h) = decoder.dimensions();
    let (short, long) = (w.min(h), w.max(h));
    if jpeg && short <= SHORT && long <= LONG {
        return Ok(bytes.to_vec());
    }
    let icc = decoder.icc_profile().ok().flatten();
    let image = DynamicImage::from_decoder(decoder).map_err(|e| format!("photo: {e}"))?;
    let scale = (SHORT as f64 / short as f64)
        .min(LONG as f64 / long as f64)
        .min(1.0);
    let size = |n: u32| ((n as f64 * scale).round() as u32).max(1);
    let small = image
        .resize_exact(size(w), size(h), FilterType::Lanczos3)
        .into_rgb8();

    let mut out = Vec::new();
    let mut encoder = JpegEncoder::new_with_quality(&mut out, QUALITY);
    if let Some(icc) = icc {
        encoder
            .set_icc_profile(icc)
            .map_err(|e| format!("photo: {e}"))?;
    }
    small
        .write_with_encoder(encoder)
        .map_err(|e| format!("photo: {e}"))?;
    Ok(out)
}

/// Fitted photos on disk, one file per Immich id.
pub struct Cache {
    dir: PathBuf,
}

impl Cache {
    pub fn new(dir: &str) -> Self {
        Self { dir: dir.into() }
    }

    fn path(&self, id: &str) -> PathBuf {
        self.dir.join(format!("{id}.jpg"))
    }

    pub fn get(&self, id: &str) -> Option<Vec<u8>> {
        std::fs::read(self.path(id)).ok()
    }

    /// Written aside and renamed, so a reader never sees half a photo.
    pub fn put(&self, id: &str, bytes: &[u8]) {
        let part = self.dir.join(format!("{id}.part"));
        if let Err(e) =
            std::fs::write(&part, bytes).and_then(|()| std::fs::rename(&part, self.path(id)))
        {
            eprintln!("photo cache {id}: {e}");
        }
    }

    /// Drops photos no longer in the album.
    pub fn keep(&self, ids: &[String]) {
        let Ok(entries) = std::fs::read_dir(&self.dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let id = path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
            if !ids.iter().any(|k| k == id)
                && let Err(e) = std::fs::remove_file(&path)
            {
                eprintln!("photo cache {}: {e}", path.display());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn jpeg(w: u32, h: u32) -> Vec<u8> {
        let mut out = Vec::new();
        image::RgbImage::new(w, h)
            .write_with_encoder(JpegEncoder::new(&mut out))
            .unwrap();
        out
    }

    fn size(bytes: &[u8]) -> (u32, u32) {
        image::load_from_memory(bytes)
            .unwrap()
            .into_rgb8()
            .dimensions()
    }

    #[test]
    fn portrait_fits_the_short_side() {
        assert_eq!(size(&fit(&jpeg(1440, 1913)).unwrap()), (1080, 1435));
    }

    #[test]
    fn wide_panorama_fits_the_long_side() {
        assert_eq!(size(&fit(&jpeg(4000, 1000)).unwrap()), (1920, 480));
    }

    #[test]
    fn small_photo_passes_untouched() {
        let small = jpeg(800, 600);
        assert_eq!(fit(&small).unwrap(), small);
    }
}
