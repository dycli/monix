//! `hippo browse`: the whole memory as one HTML page: the view, every
//! message, and each level of the tree, each entry with its range, time
//! span and size.

use crate::server::Core;
use crate::store::fmt_date;
use crate::tree::addr;
use std::fmt::Write as _;

fn esc(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn span(c: &Core, s: u64, n: u64) -> String {
    let date = |i| c.store.date(i).map(|d| fmt_date(&d)).unwrap_or_default();
    if n == 1 {
        date(s)
    } else {
        format!("{} – {}", date(s), date(s + n - 1))
    }
}

pub fn render(c: &Core) -> Result<String, String> {
    let mut h = String::from(
        "<!doctype html><meta charset=utf-8><title>hippo</title><style>\
         body{font:14px/1.4 system-ui;margin:2em;max-width:70em}\
         details{margin:.3em 0}summary{cursor:pointer;font-weight:600}\
         .e{border-top:1px solid #ddd;padding:.3em 0;white-space:pre-wrap}\
         .m{color:#777;font-size:12px}</style><h1>hippo</h1>",
    );
    let e = |r: std::fmt::Result| r.map_err(|e| e.to_string());
    e(write!(
        h,
        "<details open><summary>View: {} lines, {} bytes</summary>",
        c.view.parts.len(),
        c.view.size()
    ))?;
    for &(l, i) in &c.view.parts {
        let (s, n) = addr(l, i);
        let text = c.tree.text(l, i)?.unwrap_or_default();
        e(write!(
            h,
            "<div class=e><span class=m>{s}+{n} · {}</span>\n{}</div>",
            span(c, s, n),
            esc(&text)
        ))?;
    }
    h.push_str("</details>");
    e(write!(
        h,
        "<details><summary>Every message: {}</summary>",
        c.store.len()
    ))?;
    c.store.scan(|m| {
        let _ = write!(
            h,
            "<div class=e><span class=m>{} · {} · {} bytes</span>\n{}</div>",
            m.i,
            m.date,
            m.size,
            esc(&m.labelled())
        );
        true
    })?;
    h.push_str("</details>");
    for (l, count) in c.tree.counts().iter().enumerate() {
        let l = l as u8;
        e(write!(
            h,
            "<details><summary>Level {l}: {count} lines of {} messages</summary>",
            1u64 << l
        ))?;
        let mut i = 0;
        while let Some(node) = c.tree.get(l, i)? {
            let (s, n) = addr(l, i);
            e(write!(
                h,
                "<div class=e><span class=m>{s}+{n} · {} · {} bytes{}</span>\n{}</div>",
                span(c, s, n),
                node.size,
                if node.model.is_empty() {
                    String::new()
                } else {
                    format!(" · {}", node.model)
                },
                esc(&node.text)
            ))?;
            i += 1;
        }
        h.push_str("</details>");
    }
    Ok(h)
}
