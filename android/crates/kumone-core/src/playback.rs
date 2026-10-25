//! Shared NetEase playback URL request/response behavior.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use thiserror::Error;

use crate::netease::{
    EapiContext, RequestBuildError, RequestSpec, SessionCookies, build_eapi_request,
};

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FreeTimeTrialPrivilege {
    #[serde(default)]
    pub remain_time: i64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FreeTrialPrivilege {
    #[serde(default)]
    pub cannot_listen_reason: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SongUrlData {
    pub id: i64,
    pub url: Option<String>,
    #[serde(default)]
    pub br: i64,
    #[serde(default)]
    pub size: i64,
    #[serde(rename = "type")]
    pub format: Option<String>,
    pub level: Option<String>,
    #[serde(default)]
    pub fee: i64,
    #[serde(default)]
    pub time: i64,
    #[serde(default)]
    pub code: i64,
    #[serde(default)]
    pub free_trial_info: Option<Value>,
    #[serde(default)]
    pub free_time_trial_privilege: Option<FreeTimeTrialPrivilege>,
    #[serde(default)]
    pub free_trial_privilege: Option<FreeTrialPrivilege>,
}

impl SongUrlData {
    #[must_use]
    pub fn is_trial_or_restricted(&self) -> bool {
        self.code == 404
            || self.free_trial_info.is_some()
            || self
                .free_time_trial_privilege
                .as_ref()
                .is_some_and(|privilege| privilege.remain_time > 0)
            || self
                .free_trial_privilege
                .as_ref()
                .is_some_and(|privilege| privilege.cannot_listen_reason == 1)
    }
}

#[derive(Debug, Deserialize)]
struct SongUrlResponse {
    #[serde(default = "ok_code")]
    code: i64,
    #[serde(default)]
    data: Vec<SongUrlData>,
    message: Option<String>,
}

const fn ok_code() -> i64 {
    200
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum PlaybackDecodeError {
    #[error("failed to decode song URL response: {0}")]
    Decode(String),
    #[error("NetEase song URL request failed with code {code}: {message}")]
    Business { code: i64, message: String },
    #[error("NetEase returned no full playback URL for track {0}")]
    NoPlayableUrl(i64),
}

pub fn build_song_url_request(
    ids: &[i64],
    level: &str,
    cookies: &SessionCookies,
    context: &EapiContext,
) -> Result<RequestSpec, RequestBuildError> {
    let ids = format!(
        "[{}]",
        ids.iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join(",")
    );
    let mut payload = json!({
        "ids": ids,
        "level": level,
        "encodeType": "flac"
    });
    if level == "sky" {
        payload["immerseType"] = json!("c51");
    }
    build_eapi_request("/song/enhance/player/url/v1", &payload, cookies, context)
}

/// Ordered quality fallback used by all clients.  A server may advertise a
/// trial/restricted URL at a requested quality; callers should retry lower
/// qualities before invoking an external unblock provider.
#[must_use]
pub fn quality_fallbacks(requested: &str) -> Vec<&str> {
    let mut levels = Vec::with_capacity(4);
    for level in [requested, "lossless", "exhigh", "standard"] {
        if !levels.contains(&level) {
            levels.push(level);
        }
    }
    levels
}

pub fn decode_song_url_response(body: &str) -> Result<Vec<SongUrlData>, PlaybackDecodeError> {
    let response: SongUrlResponse = serde_json::from_str(body)
        .map_err(|error| PlaybackDecodeError::Decode(error.to_string()))?;
    if response.code != 200 {
        return Err(PlaybackDecodeError::Business {
            code: response.code,
            message: response.message.unwrap_or_default(),
        });
    }
    Ok(response.data)
}

pub fn first_playable_url(body: &str, track_id: i64) -> Result<SongUrlData, PlaybackDecodeError> {
    decode_song_url_response(body)?
        .into_iter()
        .find(|item| {
            item.id == track_id
                && item.url.as_deref().is_some_and(|url| !url.is_empty())
                && !item.is_trial_or_restricted()
        })
        .ok_or(PlaybackDecodeError::NoPlayableUrl(track_id))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_matches_upstream_song_url_contract() {
        let request = build_song_url_request(
            &[42],
            "lossless",
            &SessionCookies::default(),
            &EapiContext::new("12345678", "1777777777"),
        )
        .expect("request");
        assert_eq!(
            request.url,
            "https://interface.music.163.com/eapi/song/enhance/player/url/v1"
        );
        assert!(request.body.starts_with("params="));
    }

    #[test]
    fn decoder_preserves_playback_fields() {
        let data = decode_song_url_response(
            r#"{"code":200,"data":[{"id":42,"url":"https://audio","br":999000,"size":1234,"type":"flac","level":"lossless","fee":0,"time":180000}]}"#,
        )
        .expect("response");
        assert_eq!(data[0].id, 42);
        assert_eq!(data[0].url.as_deref(), Some("https://audio"));
        assert_eq!(data[0].level.as_deref(), Some("lossless"));
        assert!(!data[0].is_trial_or_restricted());
    }

    #[test]
    fn missing_url_is_explicit_error() {
        let error = first_playable_url(r#"{"code":200,"data":[{"id":42,"url":null}]}"#, 42)
            .expect_err("unplayable");
        assert_eq!(error, PlaybackDecodeError::NoPlayableUrl(42));
    }

    #[test]
    fn trial_url_is_not_treated_as_full_playback() {
        let body = r#"{"code":200,"data":[{"id":42,"url":"https://trial","time":30000,"freeTrialInfo":{"start":0,"end":30}}]}"#;
        let error = first_playable_url(body, 42).expect_err("trial should fall through to unblock");
        assert_eq!(error, PlaybackDecodeError::NoPlayableUrl(42));
    }

    #[test]
    fn privilege_restrictions_trigger_unblock_fallback() {
        let body = r#"{"code":200,"data":[{"id":42,"url":"https://trial","freeTimeTrialPrivilege":{"remainTime":30}}]}"#;
        let error = first_playable_url(body, 42).expect_err("time trial should not be accepted");
        assert_eq!(error, PlaybackDecodeError::NoPlayableUrl(42));
    }

    #[test]
    fn quality_fallbacks_are_deterministic_and_deduplicated() {
        assert_eq!(
            quality_fallbacks("lossless"),
            vec!["lossless", "exhigh", "standard"]
        );
        assert_eq!(
            quality_fallbacks("standard"),
            vec!["standard", "lossless", "exhigh"]
        );
    }
}
