//! The little of HTTP the dashboard needs, over tiny_http.

pub struct Response {
    status: u16,
    headers: Vec<(&'static str, String)>,
    body: Vec<u8>,
}

impl Response {
    pub fn bytes(status: u16, kind: &str, body: impl Into<Vec<u8>>) -> Self {
        Response {
            status,
            headers: vec![("Content-Type", kind.to_owned())],
            body: body.into(),
        }
    }

    pub fn json(value: &impl serde::Serialize) -> Self {
        Self::bytes(
            200,
            "application/json",
            serde_json::to_vec(value).unwrap_or_default(),
        )
        .cache("no-cache")
    }

    pub fn empty(status: u16) -> Self {
        Self::bytes(status, "text/plain", Vec::new())
    }

    pub fn cache(mut self, policy: &str) -> Self {
        self.headers.push(("Cache-Control", policy.to_owned()));
        self
    }

    pub fn send(self, r: tiny_http::Request) {
        let headers: Vec<tiny_http::Header> = self
            .headers
            .iter()
            .filter_map(|(k, v)| tiny_http::Header::from_bytes(k.as_bytes(), v.as_bytes()).ok())
            .collect();
        let n = self.body.len();
        let response = tiny_http::Response::new(
            tiny_http::StatusCode(self.status),
            headers,
            std::io::Cursor::new(self.body),
            Some(n),
            None,
        );
        if let Err(e) = r.respond(response) {
            eprintln!("respond: {e}");
        }
    }
}
