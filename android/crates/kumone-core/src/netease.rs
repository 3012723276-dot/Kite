//! Platform-neutral NetEase request/session semantics.
//!
//! HTTP transport stays outside this module. Windows and Android can share the
//! exact cookie, header, URL and encrypted form construction while choosing the
//! most appropriate transport integration for each platform.

use std::collections::BTreeMap;

use percent_encoding::{AsciiSet, NON_ALPHANUMERIC, utf8_percent_encode};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use thiserror::Error;

use crate::crypto;

const USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36";
const REFERER: &str = "https://music.163.com";
const CONTENT_TYPE: &str = "application/x-www-form-urlencoded";
const FORM_ENCODE_SET: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionCookies {
    values: BTreeMap<String, String>,
}

impl SessionCookies {
    #[must_use]
    pub fn is_logged_in(&self) -> bool {
        self.cookie("MUSIC_U").is_some()
    }

    #[must_use]
    pub fn cookie(&self, name: &str) -> Option<&str> {
        self.values.get(name).map(String::as_str)
    }

    pub fn set(&mut self, name: impl Into<String>, value: impl Into<String>) {
        let name = name.into();
        let value = value.into();
        if !name.is_empty() && !value.is_empty() {
            self.values.insert(name, value);
        }
    }

    pub fn extend(&mut self, values: impl IntoIterator<Item = (String, String)>) {
        for (name, value) in values {
            self.set(name, value);
        }
    }

    /// Mirrors the QR-login cookie format used by upstream: cookies are joined
    /// by `;;`, with attributes after the first `;` ignored.
    pub fn ingest_cookie_string(&mut self, raw: &str) -> usize {
        let mut inserted = 0;
        for raw_cookie in raw.split(";;") {
            let pair = raw_cookie.split(';').next().unwrap_or_default();
            let Some((name, value)) = pair.split_once('=') else {
                continue;
            };
            let name = name.trim();
            let value = value.trim();
            if name.is_empty() || value.is_empty() {
                continue;
            }
            self.values.insert(name.to_owned(), value.to_owned());
            inserted += 1;
        }
        inserted
    }

    pub fn clear_auth(&mut self) {
        self.values.remove("MUSIC_U");
        self.values.remove("__csrf");
    }

    #[must_use]
    pub fn into_values(self) -> BTreeMap<String, String> {
        self.values
    }

    #[must_use]
    pub fn header_with_defaults(&self) -> String {
        let mut values = self.values.clone();
        values
            .entry("appver".to_owned())
            .or_insert_with(|| "3.1.17".to_owned());
        values
            .entry("os".to_owned())
            .or_insert_with(|| "pc".to_owned());
        values
            .into_iter()
            .map(|(name, value)| format!("{name}={value}"))
            .collect::<Vec<_>>()
            .join("; ")
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RequestSpec {
    pub method: String,
    pub url: String,
    pub headers: BTreeMap<String, String>,
    pub body: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EapiContext {
    pub request_id: String,
    pub build_version: String,
    pub os_version: String,
    pub resolution: String,
}

impl EapiContext {
    #[must_use]
    pub fn new(request_id: impl Into<String>, build_version: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            build_version: build_version.into(),
            os_version: "Version 14.0 (Build 23A344)".to_owned(),
            resolution: "1920x1080".to_owned(),
        }
    }
}

#[derive(Debug, Error)]
pub enum RequestBuildError {
    #[error("NetEase request payload must be a JSON object")]
    PayloadMustBeObject,
    #[error("failed to serialize NetEase request payload: {0}")]
    Serialize(#[from] serde_json::Error),
}

pub type RequestResult<T> = std::result::Result<T, RequestBuildError>;

/// Build a POST to `https://music.163.com/weapi<path>` using the same request
/// contract as upstream Swift `NeteaseClient.weapi`.
pub fn build_weapi_request(
    path: &str,
    payload: &Value,
    cookies: &SessionCookies,
) -> RequestResult<RequestSpec> {
    let mut body = payload
        .as_object()
        .cloned()
        .ok_or(RequestBuildError::PayloadMustBeObject)?;
    let csrf = cookies.cookie("__csrf").unwrap_or_default();
    body.insert("csrf_token".to_owned(), Value::String(csrf.to_owned()));

    let json = serde_json::to_string(&Value::Object(body))?;
    let form = crypto::weapi(&json);
    let encoded_body = format!(
        "params={}&encSecKey={}",
        form_value(&form.params),
        form_value(&form.enc_sec_key)
    );

    let mut full_path = path.to_owned();
    if !csrf.is_empty() {
        full_path.push(if full_path.contains('?') { '&' } else { '?' });
        full_path.push_str("csrf_token=");
        full_path.push_str(csrf);
    }

    Ok(RequestSpec {
        method: "POST".to_owned(),
        url: format!("https://music.163.com/weapi{full_path}"),
        headers: common_headers(cookies),
        body: encoded_body,
    })
}

/// Build a POST to `https://interface.music.163.com/eapi<path>` using the same
/// request contract as upstream Swift `NeteaseClient.eapi`.
pub fn build_eapi_request(
    path: &str,
    payload: &Value,
    cookies: &SessionCookies,
    context: &EapiContext,
) -> RequestResult<RequestSpec> {
    let mut body = payload
        .as_object()
        .cloned()
        .ok_or(RequestBuildError::PayloadMustBeObject)?;

    let mut header = Map::new();
    header.insert("os".to_owned(), Value::String("pc".to_owned()));
    header.insert("appver".to_owned(), Value::String("3.1.17".to_owned()));
    header.insert(
        "osver".to_owned(),
        Value::String(context.os_version.clone()),
    );
    header.insert("deviceId".to_owned(), Value::String("kumone".to_owned()));
    header.insert(
        "requestId".to_owned(),
        Value::String(context.request_id.clone()),
    );
    header.insert("clientSign".to_owned(), Value::String(String::new()));
    header.insert("versioncode".to_owned(), Value::String("140".to_owned()));
    header.insert(
        "buildver".to_owned(),
        Value::String(context.build_version.clone()),
    );
    header.insert(
        "resolution".to_owned(),
        Value::String(context.resolution.clone()),
    );
    header.insert("channel".to_owned(), Value::String(String::new()));
    if let Some(value) = cookies.cookie("MUSIC_U") {
        header.insert("MUSIC_U".to_owned(), Value::String(value.to_owned()));
    }
    if let Some(value) = cookies.cookie("__csrf") {
        header.insert("__csrf".to_owned(), Value::String(value.to_owned()));
    }
    body.insert("header".to_owned(), Value::Object(header));

    let json = serde_json::to_string(&Value::Object(body))?;
    let api_path = format!("/api{path}");
    let form = crypto::eapi(&api_path, &json);

    Ok(RequestSpec {
        method: "POST".to_owned(),
        url: format!("https://interface.music.163.com/eapi{path}"),
        headers: common_headers(cookies),
        body: format!("params={}", form_value(&form.params)),
    })
}

fn common_headers(cookies: &SessionCookies) -> BTreeMap<String, String> {
    BTreeMap::from([
        ("Content-Type".to_owned(), CONTENT_TYPE.to_owned()),
        ("Cookie".to_owned(), cookies.header_with_defaults()),
        ("Referer".to_owned(), REFERER.to_owned()),
        ("User-Agent".to_owned(), USER_AGENT.to_owned()),
    ])
}

fn form_value(value: &str) -> String {
    utf8_percent_encode(value, FORM_ENCODE_SET).to_string()
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn qr_cookie_ingestion_matches_upstream_semantics() {
        let mut cookies = SessionCookies::default();
        let count = cookies.ingest_cookie_string(
            "MUSIC_U=music-token; Path=/;; __csrf=csrf-token; Secure;; NMTID=device-cookie; HttpOnly;; empty=;; malformed",
        );

        assert_eq!(count, 3);
        assert!(cookies.is_logged_in());
        assert_eq!(cookies.cookie("MUSIC_U"), Some("music-token"));
        assert_eq!(cookies.cookie("__csrf"), Some("csrf-token"));
        assert_eq!(cookies.cookie("NMTID"), Some("device-cookie"));

        cookies.clear_auth();
        assert!(!cookies.is_logged_in());
        assert_eq!(cookies.cookie("__csrf"), None);
        assert_eq!(cookies.cookie("NMTID"), Some("device-cookie"));
    }

    #[test]
    fn cookie_defaults_do_not_override_stored_values() {
        let mut cookies = SessionCookies::default();
        cookies.set("os", "android");
        cookies.set("MUSIC_U", "token");
        let header = cookies.header_with_defaults();

        assert!(header.contains("os=android"));
        assert!(header.contains("appver=3.1.17"));
        assert!(header.contains("MUSIC_U=token"));
        assert!(!header.contains("os=pc"));
    }

    #[test]
    fn weapi_request_matches_upstream_url_and_headers() {
        let mut cookies = SessionCookies::default();
        cookies.set("__csrf", "csrf-token");
        cookies.set("MUSIC_U", "music-token");

        let request = build_weapi_request("/search/get", &json!({"s": "Kumone"}), &cookies)
            .expect("valid object payload");

        assert_eq!(request.method, "POST");
        assert_eq!(
            request.url,
            "https://music.163.com/weapi/search/get?csrf_token=csrf-token"
        );
        assert_eq!(
            request.headers.get("Referer").map(String::as_str),
            Some(REFERER)
        );
        assert!(request.body.starts_with("params="));
        assert!(request.body.contains("&encSecKey="));
        assert!(!request.body.contains('+'));
        assert!(request.body.contains("%2F") || request.body.contains("%3D"));
    }

    #[test]
    fn eapi_request_uses_api_path_for_digest_but_eapi_path_for_url() {
        let mut cookies = SessionCookies::default();
        cookies.set("MUSIC_U", "music-token");
        cookies.set("__csrf", "csrf-token");
        let context = EapiContext::new("23456789", "1777777777");

        let request = build_eapi_request(
            "/song/enhance/player/url/v1",
            &json!({"ids": "[347230]", "level": "standard"}),
            &cookies,
            &context,
        )
        .expect("valid object payload");

        assert_eq!(
            request.url,
            "https://interface.music.163.com/eapi/song/enhance/player/url/v1"
        );
        assert!(request.body.starts_with("params="));
        assert_eq!(
            request.headers.get("Content-Type").map(String::as_str),
            Some(CONTENT_TYPE)
        );
        assert!(request.headers["Cookie"].contains("MUSIC_U=music-token"));
    }

    #[test]
    fn request_builder_rejects_non_object_payloads() {
        let cookies = SessionCookies::default();
        let result = build_weapi_request("/x", &json!([1, 2, 3]), &cookies);
        assert!(matches!(
            result,
            Err(RequestBuildError::PayloadMustBeObject)
        ));
    }
}
