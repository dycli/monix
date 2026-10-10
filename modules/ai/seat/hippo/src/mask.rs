//! Secrets kept out of the log, best effort: every message is masked
//! before it is written, against the known shapes below; a secret of any
//! other shape gets through. The raw transcript archive (root-owned) keeps
//! the originals.

use regex::Regex;
use std::sync::LazyLock;

pub const MASK: &str = "[secret masked]";

/// The whole pattern list. A capture group named `keep` survives the mask
/// (a header name, say), the rest of the match is replaced.
const PATTERNS: &[&str] = &[
    // PEM private keys, whole block.
    r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
    // Anthropic, then OpenAI (sk-, sk-proj-, sk-svcacct-...).
    r"\bsk-ant-[A-Za-z0-9_\-]{20,}",
    r"\bsk-[A-Za-z0-9_\-]{20,}",
    // GitHub tokens: classic and fine-grained.
    r"\bgh[pousr]_[A-Za-z0-9]{30,}",
    r"\bgithub_pat_[A-Za-z0-9_]{20,}",
    // Tailscale auth and API keys.
    r"\btskey-[A-Za-z0-9]+-[A-Za-z0-9\-]{8,}",
    // age secret keys.
    r"\bAGE-SECRET-KEY-1[0-9A-Z]{50,}",
    // AWS access key ids and secret keys given by name.
    r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b",
    r"(?i)(?P<keep>aws_secret_access_key\s*[=:]\s*)[A-Za-z0-9/+=]{30,}",
    // Bearer tokens in headers.
    r"(?i)(?P<keep>\bbearer\s+)[A-Za-z0-9._~+/=\-]{16,}",
    // JSON web tokens, wherever they appear.
    r"\beyJ[\w-]{10,}\.eyJ[\w-]{10,}(?:\.[\w-]*)?",
    // Any long value given as a password, secret or token.
    r#"(?i)(?P<keep>(?:password|passwd|secret|token)["']?\s*[=:]\s*)\S{8,}"#,
];

static RES: LazyLock<Vec<Regex>> =
    LazyLock::new(|| PATTERNS.iter().map(|p| Regex::new(p).unwrap()).collect());

pub fn mask(text: &str) -> String {
    let mut out = text.to_owned();
    for re in RES.iter() {
        if re.is_match(&out) {
            out = re
                .replace_all(&out, |c: &regex::Captures| {
                    let keep = c.name("keep").map_or("", |m| m.as_str());
                    format!("{keep}{MASK}")
                })
                .into_owned();
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn masked(s: &str) -> bool {
        mask(s).contains(MASK)
    }

    #[test]
    fn masks_each_kind() {
        // Assembled at runtime: whole key-shaped literals in the source
        // set off secret scanners.
        let cases = [
            concat!("key sk-", "ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"),
            concat!("OPENAI_API_KEY=sk-", "proj-AbCdEfGhIjKlMnOpQrStUvWx"),
            concat!("token gh", "p_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"),
            concat!(
                "github",
                "_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz"
            ),
            concat!("tskey", "-auth-kAbCdEf1CNTRL-AbCdEfGhIjKlMnOpQrStUv"),
            concat!(
                "AGE-SECRET",
                "-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"
            ),
            concat!("AKIA", "IOSFODNN7EXAMPLE"),
            concat!(
                "aws_secret_access_key = wJalrXUtnFEMI/K7MDENG",
                "/bPxRfiCYEXAMPLEKEY"
            ),
            concat!(
                "Authorization: Bearer ",
                "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc"
            ),
            concat!(
                "cookie eyJhbGciOiJIUzI1NiJ9",
                ".eyJzdWIiOiIxMjM0NTY3ODkwIn0.sig"
            ),
            concat!("DB_PASSWORD=", "hunter2hunter2"),
            concat!(r#"{"refresh_token": ""#, "AbCdEfGh12345678\"}"),
            concat!(
                "-----BEGIN OPENSSH PRIVATE",
                " KEY-----\nb3BlbnNzaC1rZXktdjEA\n-----END OPENSSH PRIVATE",
                " KEY-----"
            ),
        ];
        for case in cases {
            assert!(masked(case), "not masked: {case}");
        }
    }

    #[test]
    fn keeps_context_and_ordinary_text() {
        assert_eq!(
            mask("Authorization: Bearer abcdefghijklmnopqrstuvwxyz"),
            format!("Authorization: Bearer {MASK}")
        );
        let pem = concat!(
            "a\n-----BEGIN PRIVATE",
            " KEY-----\nMIIE\n-----END PRIVATE",
            " KEY-----\nb"
        );
        assert_eq!(mask(pem), format!("a\n{MASK}\nb"));
        for plain in [
            "sk-short",
            "the task-runner ran",
            "git commit -m 'Add ghp support'",
            "-----BEGIN PUBLIC KEY-----",
            "bearer of bad news",
            "hippo: tokens model=claude-sonnet-5-5 input=2",
            "token: String,",
        ] {
            assert_eq!(mask(plain), plain);
        }
    }
}
