use std::collections::BTreeMap;

use bytes::Bytes;
use codexone_config::AdminWebBundle;
use http::header::{
    CONTENT_SECURITY_POLICY, REFERRER_POLICY, X_CONTENT_TYPE_OPTIONS, X_FRAME_OPTIONS,
};
use http::{HeaderValue, Response, StatusCode};
use percent_encoding::percent_decode_str;

use super::response;

const CSP: &str = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'";

pub(crate) struct Assets {
    index: Bytes,
    by_name: BTreeMap<String, Bytes>,
}

impl Assets {
    pub(crate) fn new(bundle: AdminWebBundle) -> Self {
        Self {
            index: bundle.index.into(),
            by_name: bundle
                .assets
                .into_iter()
                .map(|(name, data)| (name, data.into()))
                .collect(),
        }
    }

    pub(crate) fn index(&self) -> Response<Bytes> {
        asset_response("text/html; charset=utf-8", "no-store", self.index.clone())
    }

    pub(crate) fn asset(&self, raw_name: &str) -> Option<Response<Bytes>> {
        let name = percent_decode_str(raw_name).decode_utf8().ok()?;
        let (stem, extension) = name.rsplit_once('.')?;
        let content_type = match extension {
            "js" => "text/javascript; charset=utf-8",
            "css" => "text/css; charset=utf-8",
            _ => return None,
        };
        let body = self.by_name.get(name.as_ref())?;
        let cache_control = if versioned(stem) {
            "public, max-age=31536000, immutable"
        } else {
            "no-store"
        };
        Some(asset_response(content_type, cache_control, body.clone()))
    }
}

fn asset_response(
    content_type: &'static str,
    cache_control: &'static str,
    body: Bytes,
) -> Response<Bytes> {
    let mut response = response(StatusCode::OK, content_type, cache_control, body);
    let headers = response.headers_mut();
    headers.insert(CONTENT_SECURITY_POLICY, HeaderValue::from_static(CSP));
    headers.insert(X_CONTENT_TYPE_OPTIONS, HeaderValue::from_static("nosniff"));
    headers.insert(X_FRAME_OPTIONS, HeaderValue::from_static("DENY"));
    headers.insert(REFERRER_POLICY, HeaderValue::from_static("no-referrer"));
    response
}

fn versioned(stem: &str) -> bool {
    stem.rsplit_once("-h-").is_some_and(|(name, hash)| {
        !name.is_empty()
            && hash.len() == 8
            && hash
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    })
}
