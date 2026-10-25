//! Shared NetEase authentication, account and playlist request/response behavior.

use serde::{Deserialize, Serialize};
use serde_json::json;
use thiserror::Error;

use crate::{
    netease::{RequestBuildError, RequestSpec, SessionCookies, build_weapi_request},
    search::SearchTrack,
};

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ApiDecodeError {
    #[error("failed to decode NetEase response: {0}")]
    Decode(String),
    #[error("NetEase request failed with code {code}: {message}")]
    Business { code: i64, message: String },
    #[error("NetEase response is missing {0}")]
    Missing(&'static str),
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserProfile {
    #[serde(default)]
    pub user_id: i64,
    #[serde(default)]
    pub nickname: String,
    pub avatar_url: Option<String>,
    pub background_url: Option<String>,
    pub signature: Option<String>,
    #[serde(default)]
    pub vip_type: i64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaylistSummary {
    #[serde(default)]
    pub id: i64,
    #[serde(default)]
    pub name: String,
    pub cover_img_url: Option<String>,
    #[serde(default)]
    pub track_count: i64,
    #[serde(default)]
    pub play_count: i64,
    #[serde(default)]
    pub subscribed: bool,
    pub creator: Option<UserProfile>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QrLoginState {
    Expired,
    Waiting,
    Scanned,
    Success,
    Other(i64),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QrCheckResult {
    pub code: i64,
    pub state: QrLoginState,
    pub message: Option<String>,
    pub nickname: Option<String>,
    pub avatar_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CodeEnvelope {
    #[serde(default)]
    code: i64,
    message: Option<String>,
    msg: Option<String>,
}

impl CodeEnvelope {
    fn ensure_success(&self) -> Result<(), ApiDecodeError> {
        if self.code == 0 || self.code == 200 {
            Ok(())
        } else {
            Err(ApiDecodeError::Business {
                code: self.code,
                message: self
                    .message
                    .clone()
                    .or_else(|| self.msg.clone())
                    .unwrap_or_default(),
            })
        }
    }
}

#[derive(Debug, Deserialize)]
struct QrKeyEnvelope {
    #[serde(flatten)]
    base: CodeEnvelope,
    unikey: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct QrCheckEnvelope {
    #[serde(default)]
    code: i64,
    message: Option<String>,
    nickname: Option<String>,
    avatar_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct AccountEnvelope {
    #[serde(default)]
    code: i64,
    message: Option<String>,
    profile: Option<UserProfile>,
}

#[derive(Debug, Deserialize)]
struct UserPlaylistsEnvelope {
    #[serde(default = "ok_code")]
    code: i64,
    message: Option<String>,
    #[serde(default)]
    playlist: Vec<PlaylistSummary>,
}

#[derive(Debug, Deserialize)]
struct PersonalizedEnvelope {
    #[serde(default = "ok_code")]
    code: i64,
    message: Option<String>,
    #[serde(default)]
    result: Vec<PlaylistSummary>,
}

#[derive(Debug, Deserialize)]
struct RecommendResourceEnvelope {
    #[serde(default = "ok_code")]
    code: i64,
    message: Option<String>,
    #[serde(default)]
    recommend: Vec<PlaylistSummary>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DailySongsBody {
    #[serde(default)]
    daily_songs: Vec<SearchTrack>,
}

#[derive(Debug, Deserialize)]
struct DailySongsEnvelope {
    #[serde(default = "ok_code")]
    code: i64,
    message: Option<String>,
    data: Option<DailySongsBody>,
}

#[derive(Debug, Deserialize)]
struct PlaylistDetailBody {
    #[serde(flatten)]
    summary: PlaylistSummary,
    #[serde(default)]
    tracks: Vec<SearchTrack>,
}

#[derive(Debug, Deserialize)]
struct PlaylistDetailEnvelope {
    #[serde(default = "ok_code")]
    code: i64,
    message: Option<String>,
    playlist: Option<PlaylistDetailBody>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PlaylistDetail {
    pub summary: PlaylistSummary,
    pub tracks: Vec<SearchTrack>,
}

const fn ok_code() -> i64 {
    200
}

fn ensure_code(code: i64, message: Option<String>) -> Result<(), ApiDecodeError> {
    if code == 0 || code == 200 {
        Ok(())
    } else {
        Err(ApiDecodeError::Business {
            code,
            message: message.unwrap_or_default(),
        })
    }
}

pub fn build_qr_key_request(cookies: &SessionCookies) -> Result<RequestSpec, RequestBuildError> {
    build_weapi_request("/login/qrcode/unikey", &json!({"type": 1}), cookies)
}

pub fn decode_qr_key_response(body: &str) -> Result<String, ApiDecodeError> {
    let envelope: QrKeyEnvelope =
        serde_json::from_str(body).map_err(|error| ApiDecodeError::Decode(error.to_string()))?;
    envelope.base.ensure_success()?;
    envelope.unikey.ok_or(ApiDecodeError::Missing("unikey"))
}

#[must_use]
pub fn qr_login_url(unikey: &str) -> String {
    format!("https://music.163.com/login?codekey={unikey}")
}

pub fn build_qr_check_request(
    unikey: &str,
    cookies: &SessionCookies,
) -> Result<RequestSpec, RequestBuildError> {
    build_weapi_request(
        "/login/qrcode/client/login",
        &json!({"key": unikey, "type": 1}),
        cookies,
    )
}

pub fn decode_qr_check_response(body: &str) -> Result<QrCheckResult, ApiDecodeError> {
    let envelope: QrCheckEnvelope =
        serde_json::from_str(body).map_err(|error| ApiDecodeError::Decode(error.to_string()))?;
    let state = match envelope.code {
        800 => QrLoginState::Expired,
        801 => QrLoginState::Waiting,
        802 => QrLoginState::Scanned,
        803 => QrLoginState::Success,
        code => QrLoginState::Other(code),
    };
    Ok(QrCheckResult {
        code: envelope.code,
        state,
        message: envelope.message,
        nickname: envelope.nickname,
        avatar_url: envelope.avatar_url,
    })
}

pub fn build_user_account_request(
    cookies: &SessionCookies,
) -> Result<RequestSpec, RequestBuildError> {
    build_weapi_request("/w/nuser/account/get", &json!({}), cookies)
}

pub fn decode_user_account_response(body: &str) -> Result<Option<UserProfile>, ApiDecodeError> {
    let envelope: AccountEnvelope =
        serde_json::from_str(body).map_err(|error| ApiDecodeError::Decode(error.to_string()))?;
    ensure_code(envelope.code, envelope.message)?;
    Ok(envelope.profile)
}

pub fn build_user_playlists_request(
    uid: i64,
    limit: i64,
    offset: i64,
    cookies: &SessionCookies,
) -> Result<RequestSpec, RequestBuildError> {
    build_weapi_request(
        "/user/playlist",
        &json!({
            "uid": uid,
            "limit": limit.max(1),
            "offset": offset.max(0),
            "includeVideo": true
        }),
        cookies,
    )
}

pub fn decode_user_playlists_response(body: &str) -> Result<Vec<PlaylistSummary>, ApiDecodeError> {
    let envelope: UserPlaylistsEnvelope =
        serde_json::from_str(body).map_err(|error| ApiDecodeError::Decode(error.to_string()))?;
    ensure_code(envelope.code, envelope.message)?;
    Ok(envelope.playlist)
}

pub fn build_personalized_playlists_request(
    limit: i64,
    cookies: &SessionCookies,
) -> Result<RequestSpec, RequestBuildError> {
    build_weapi_request(
        "/personalized/playlist",
        &json!({"limit": limit.max(1), "total": true, "n": 1000}),
        cookies,
    )
}

pub fn decode_personalized_playlists_response(
    body: &str,
) -> Result<Vec<PlaylistSummary>, ApiDecodeError> {
    let envelope: PersonalizedEnvelope =
        serde_json::from_str(body).map_err(|error| ApiDecodeError::Decode(error.to_string()))?;
    ensure_code(envelope.code, envelope.message)?;
    Ok(envelope.result)
}

pub fn build_recommend_resource_request(
    cookies: &SessionCookies,
) -> Result<RequestSpec, RequestBuildError> {
    build_weapi_request("/v1/discovery/recommend/resource", &json!({}), cookies)
}

pub fn decode_recommend_resource_response(
    body: &str,
) -> Result<Vec<PlaylistSummary>, ApiDecodeError> {
    let envelope: RecommendResourceEnvelope =
        serde_json::from_str(body).map_err(|error| ApiDecodeError::Decode(error.to_string()))?;
    ensure_code(envelope.code, envelope.message)?;
    Ok(envelope.recommend)
}

pub fn build_daily_songs_request(
    cookies: &SessionCookies,
) -> Result<RequestSpec, RequestBuildError> {
    build_weapi_request("/v3/discovery/recommend/songs", &json!({}), cookies)
}

pub fn decode_daily_songs_response(body: &str) -> Result<Vec<SearchTrack>, ApiDecodeError> {
    let envelope: DailySongsEnvelope =
        serde_json::from_str(body).map_err(|error| ApiDecodeError::Decode(error.to_string()))?;
    ensure_code(envelope.code, envelope.message)?;
    Ok(envelope.data.unwrap_or_default().daily_songs)
}

pub fn build_playlist_detail_request(
    id: i64,
    cookies: &SessionCookies,
) -> Result<RequestSpec, RequestBuildError> {
    build_weapi_request(
        "/v6/playlist/detail",
        &json!({"id": id, "n": 100000, "s": 8}),
        cookies,
    )
}

pub fn decode_playlist_detail_response(body: &str) -> Result<PlaylistDetail, ApiDecodeError> {
    let envelope: PlaylistDetailEnvelope =
        serde_json::from_str(body).map_err(|error| ApiDecodeError::Decode(error.to_string()))?;
    ensure_code(envelope.code, envelope.message)?;
    let playlist = envelope
        .playlist
        .ok_or(ApiDecodeError::Missing("playlist"))?;
    Ok(PlaylistDetail {
        summary: playlist.summary,
        tracks: playlist.tracks,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn qr_contract_matches_upstream_codes() {
        let key = decode_qr_key_response(r#"{"code":200,"unikey":"abc"}"#).expect("key");
        assert_eq!(key, "abc");
        assert_eq!(
            qr_login_url(&key),
            "https://music.163.com/login?codekey=abc"
        );

        let scanned =
            decode_qr_check_response(r#"{"code":802,"message":"scanned"}"#).expect("check");
        assert_eq!(scanned.state, QrLoginState::Scanned);
    }

    #[test]
    fn account_and_playlist_models_decode_tolerantly() {
        let profile = decode_user_account_response(
            r#"{"code":200,"profile":{"userId":42,"nickname":"Kumone","avatarUrl":"https://avatar"}}"#,
        )
        .expect("account")
        .expect("profile");
        assert_eq!(profile.user_id, 42);

        let playlists = decode_user_playlists_response(
            r#"{"code":200,"playlist":[{"id":7,"name":"Liked","trackCount":12,"coverImgUrl":"https://cover"}]}"#,
        )
        .expect("playlists");
        assert_eq!(playlists[0].track_count, 12);
    }

    #[test]
    fn daily_songs_reuse_tolerant_shared_track_shape() {
        let songs = decode_daily_songs_response(
            r#"{"code":200,"data":{"dailySongs":[{"id":1,"name":"Song","ar":[{"id":2,"name":"Artist"}],"al":{"id":3,"name":"Album"},"dt":1234}]}}"#,
        )
        .expect("daily songs");
        assert_eq!(songs[0].artist_names(), "Artist");
    }

    #[test]
    fn playlist_detail_decodes_embedded_tracks() {
        let playlist = decode_playlist_detail_response(
            r#"{"code":200,"playlist":{"id":7,"name":"Mix","trackCount":1,"tracks":[{"id":1,"name":"Song","ar":[],"al":{"id":0,"name":""},"dt":1000}]}}"#,
        )
        .expect("playlist");
        assert_eq!(playlist.summary.name, "Mix");
        assert_eq!(playlist.tracks.len(), 1);
    }
}
