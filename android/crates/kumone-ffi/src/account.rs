use std::collections::HashMap;

use kumone_core::{
    account::{
        PlaylistDetail, PlaylistSummary, QrLoginState, UserProfile,
        build_daily_songs_request as core_build_daily_songs_request,
        build_personalized_playlists_request as core_build_personalized_playlists_request,
        build_playlist_detail_request as core_build_playlist_detail_request,
        build_qr_check_request as core_build_qr_check_request,
        build_qr_key_request as core_build_qr_key_request,
        build_recommend_resource_request as core_build_recommend_resource_request,
        build_user_account_request as core_build_user_account_request,
        build_user_playlists_request as core_build_user_playlists_request,
        decode_daily_songs_response as core_decode_daily_songs_response,
        decode_personalized_playlists_response as core_decode_personalized_playlists_response,
        decode_playlist_detail_response as core_decode_playlist_detail_response,
        decode_qr_check_response as core_decode_qr_check_response,
        decode_qr_key_response as core_decode_qr_key_response,
        decode_recommend_resource_response as core_decode_recommend_resource_response,
        decode_user_account_response as core_decode_user_account_response,
        decode_user_playlists_response as core_decode_user_playlists_response,
        qr_login_url as core_qr_login_url,
    },
    search::SearchTrack,
};

use crate::{FfiRequestResult, FfiSearchTrack, session_cookies};

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiUserProfile {
    pub user_id: i64,
    pub nickname: String,
    pub avatar_url: Option<String>,
    pub background_url: Option<String>,
    pub signature: Option<String>,
    pub vip_type: i64,
}

impl From<UserProfile> for FfiUserProfile {
    fn from(value: UserProfile) -> Self {
        Self {
            user_id: value.user_id,
            nickname: value.nickname,
            avatar_url: value.avatar_url,
            background_url: value.background_url,
            signature: value.signature,
            vip_type: value.vip_type,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiPlaylistSummary {
    pub id: i64,
    pub name: String,
    pub cover_img_url: Option<String>,
    pub track_count: i64,
    pub play_count: i64,
    pub subscribed: bool,
}

impl From<PlaylistSummary> for FfiPlaylistSummary {
    fn from(value: PlaylistSummary) -> Self {
        Self {
            id: value.id,
            name: value.name,
            cover_img_url: value.cover_img_url,
            track_count: value.track_count,
            play_count: value.play_count,
            subscribed: value.subscribed,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiQrKeyResult {
    pub key: Option<String>,
    pub url: Option<String>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiQrCheckResult {
    pub code: i64,
    pub state: String,
    pub message: Option<String>,
    pub nickname: Option<String>,
    pub avatar_url: Option<String>,
    pub error: Option<String>,
}

impl FfiQrCheckResult {
    fn failure(error: impl ToString) -> Self {
        Self {
            code: 0,
            state: "error".to_owned(),
            message: None,
            nickname: None,
            avatar_url: None,
            error: Some(error.to_string()),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiProfileResult {
    pub profile: Option<FfiUserProfile>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiPlaylistsResult {
    pub playlists: Vec<FfiPlaylistSummary>,
    pub error: Option<String>,
}

impl FfiPlaylistsResult {
    fn failure(error: impl ToString) -> Self {
        Self {
            playlists: Vec::new(),
            error: Some(error.to_string()),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiTracksResult {
    pub tracks: Vec<FfiSearchTrack>,
    pub error: Option<String>,
}

impl FfiTracksResult {
    fn failure(error: impl ToString) -> Self {
        Self {
            tracks: Vec::new(),
            error: Some(error.to_string()),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiPlaylistDetail {
    pub summary: FfiPlaylistSummary,
    pub tracks: Vec<FfiSearchTrack>,
}

impl From<PlaylistDetail> for FfiPlaylistDetail {
    fn from(value: PlaylistDetail) -> Self {
        Self {
            summary: value.summary.into(),
            tracks: value.tracks.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiPlaylistDetailResult {
    pub detail: Option<FfiPlaylistDetail>,
    pub error: Option<String>,
}

fn playlist_result(result: Result<Vec<PlaylistSummary>, impl ToString>) -> FfiPlaylistsResult {
    match result {
        Ok(playlists) => FfiPlaylistsResult {
            playlists: playlists.into_iter().map(Into::into).collect(),
            error: None,
        },
        Err(error) => FfiPlaylistsResult::failure(error),
    }
}

fn tracks_result(result: Result<Vec<SearchTrack>, impl ToString>) -> FfiTracksResult {
    match result {
        Ok(tracks) => FfiTracksResult {
            tracks: tracks.into_iter().map(Into::into).collect(),
            error: None,
        },
        Err(error) => FfiTracksResult::failure(error),
    }
}

#[uniffi::export]
pub fn build_qr_key_request(cookies: HashMap<String, String>) -> FfiRequestResult {
    match core_build_qr_key_request(&session_cookies(cookies)) {
        Ok(request) => FfiRequestResult::success(request),
        Err(error) => FfiRequestResult::failure(error),
    }
}

#[uniffi::export]
pub fn decode_qr_key_response(body: String) -> FfiQrKeyResult {
    match core_decode_qr_key_response(&body) {
        Ok(key) => FfiQrKeyResult {
            url: Some(core_qr_login_url(&key)),
            key: Some(key),
            error: None,
        },
        Err(error) => FfiQrKeyResult {
            key: None,
            url: None,
            error: Some(error.to_string()),
        },
    }
}

#[uniffi::export]
pub fn build_qr_check_request(key: String, cookies: HashMap<String, String>) -> FfiRequestResult {
    match core_build_qr_check_request(&key, &session_cookies(cookies)) {
        Ok(request) => FfiRequestResult::success(request),
        Err(error) => FfiRequestResult::failure(error),
    }
}

#[uniffi::export]
pub fn decode_qr_check_response(body: String) -> FfiQrCheckResult {
    match core_decode_qr_check_response(&body) {
        Ok(result) => {
            let state = match result.state {
                QrLoginState::Expired => "expired".to_owned(),
                QrLoginState::Waiting => "waiting".to_owned(),
                QrLoginState::Scanned => "scanned".to_owned(),
                QrLoginState::Success => "success".to_owned(),
                QrLoginState::Other(code) => format!("other:{code}"),
            };
            FfiQrCheckResult {
                code: result.code,
                state,
                message: result.message,
                nickname: result.nickname,
                avatar_url: result.avatar_url,
                error: None,
            }
        }
        Err(error) => FfiQrCheckResult::failure(error),
    }
}

#[uniffi::export]
pub fn build_user_account_request(cookies: HashMap<String, String>) -> FfiRequestResult {
    match core_build_user_account_request(&session_cookies(cookies)) {
        Ok(request) => FfiRequestResult::success(request),
        Err(error) => FfiRequestResult::failure(error),
    }
}

#[uniffi::export]
pub fn decode_user_account_response(body: String) -> FfiProfileResult {
    match core_decode_user_account_response(&body) {
        Ok(profile) => FfiProfileResult {
            profile: profile.map(Into::into),
            error: None,
        },
        Err(error) => FfiProfileResult {
            profile: None,
            error: Some(error.to_string()),
        },
    }
}

#[uniffi::export]
pub fn build_user_playlists_request(
    uid: i64,
    limit: i64,
    offset: i64,
    cookies: HashMap<String, String>,
) -> FfiRequestResult {
    match core_build_user_playlists_request(uid, limit, offset, &session_cookies(cookies)) {
        Ok(request) => FfiRequestResult::success(request),
        Err(error) => FfiRequestResult::failure(error),
    }
}

#[uniffi::export]
pub fn decode_user_playlists_response(body: String) -> FfiPlaylistsResult {
    playlist_result(core_decode_user_playlists_response(&body))
}

#[uniffi::export]
pub fn build_personalized_playlists_request(
    limit: i64,
    cookies: HashMap<String, String>,
) -> FfiRequestResult {
    match core_build_personalized_playlists_request(limit, &session_cookies(cookies)) {
        Ok(request) => FfiRequestResult::success(request),
        Err(error) => FfiRequestResult::failure(error),
    }
}

#[uniffi::export]
pub fn decode_personalized_playlists_response(body: String) -> FfiPlaylistsResult {
    playlist_result(core_decode_personalized_playlists_response(&body))
}

#[uniffi::export]
pub fn build_recommend_resource_request(cookies: HashMap<String, String>) -> FfiRequestResult {
    match core_build_recommend_resource_request(&session_cookies(cookies)) {
        Ok(request) => FfiRequestResult::success(request),
        Err(error) => FfiRequestResult::failure(error),
    }
}

#[uniffi::export]
pub fn decode_recommend_resource_response(body: String) -> FfiPlaylistsResult {
    playlist_result(core_decode_recommend_resource_response(&body))
}

#[uniffi::export]
pub fn build_daily_songs_request(cookies: HashMap<String, String>) -> FfiRequestResult {
    match core_build_daily_songs_request(&session_cookies(cookies)) {
        Ok(request) => FfiRequestResult::success(request),
        Err(error) => FfiRequestResult::failure(error),
    }
}

#[uniffi::export]
pub fn decode_daily_songs_response(body: String) -> FfiTracksResult {
    tracks_result(core_decode_daily_songs_response(&body))
}

#[uniffi::export]
pub fn build_playlist_detail_request(
    id: i64,
    cookies: HashMap<String, String>,
) -> FfiRequestResult {
    match core_build_playlist_detail_request(id, &session_cookies(cookies)) {
        Ok(request) => FfiRequestResult::success(request),
        Err(error) => FfiRequestResult::failure(error),
    }
}

#[uniffi::export]
pub fn decode_playlist_detail_response(body: String) -> FfiPlaylistDetailResult {
    match core_decode_playlist_detail_response(&body) {
        Ok(detail) => FfiPlaylistDetailResult {
            detail: Some(detail.into()),
            error: None,
        },
        Err(error) => FfiPlaylistDetailResult {
            detail: None,
            error: Some(error.to_string()),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn qr_state_is_stable_for_platform_clients() {
        let result = decode_qr_check_response(r#"{"code":802,"message":"scanned"}"#.to_owned());
        assert_eq!(result.state, "scanned");
        assert!(result.error.is_none());
    }

    #[test]
    fn account_result_exposes_profile() {
        let result = decode_user_account_response(
            r#"{"code":200,"profile":{"userId":42,"nickname":"Kumone"}}"#.to_owned(),
        );
        assert_eq!(result.profile.expect("profile").user_id, 42);
        assert!(result.error.is_none());
    }

    #[test]
    fn playlists_and_tracks_reuse_shared_shapes() {
        let playlists = decode_user_playlists_response(
            r#"{"code":200,"playlist":[{"id":7,"name":"Liked","trackCount":12}]}"#.to_owned(),
        );
        assert_eq!(playlists.playlists[0].track_count, 12);

        let tracks = decode_daily_songs_response(
            r#"{"code":200,"data":{"dailySongs":[{"id":1,"name":"Song","ar":[],"al":{"id":0,"name":""},"dt":1000}]}}"#.to_owned(),
        );
        assert_eq!(tracks.tracks[0].id, 1);
    }
}
