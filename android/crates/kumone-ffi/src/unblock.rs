use kumone_core::unblock::{
    KugouMatch, KuwoMatch, UnblockHttpRequest, UnblockTrack,
    decode_kugou_search_response as core_decode_kugou_search_response,
    decode_kugou_track_response as core_decode_kugou_track_response,
    decode_kuwo_convert_response as core_decode_kuwo_convert_response,
    decode_kuwo_search_response as core_decode_kuwo_search_response,
    decode_pyncmd_response as core_decode_pyncmd_response,
    kugou_search_request as core_kugou_search_request,
    kugou_track_request as core_kugou_track_request,
    kuwo_convert_request as core_kuwo_convert_request,
    kuwo_search_request as core_kuwo_search_request, pyncmd_request as core_pyncmd_request,
};

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiUnblockTrack {
    pub id: i64,
    pub name: String,
    pub artist_name: String,
    pub duration_ms: i64,
}

impl From<FfiUnblockTrack> for UnblockTrack {
    fn from(value: FfiUnblockTrack) -> Self {
        Self {
            id: value.id,
            name: value.name,
            artist_name: value.artist_name,
            duration_ms: value.duration_ms,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiUnblockRequest {
    pub url: String,
    pub user_agent: String,
}

impl From<UnblockHttpRequest> for FfiUnblockRequest {
    fn from(value: UnblockHttpRequest) -> Self {
        Self {
            url: value.url,
            user_agent: value.user_agent,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiKuwoMatch {
    pub rid: String,
    pub duration_ms: i64,
}

impl From<KuwoMatch> for FfiKuwoMatch {
    fn from(value: KuwoMatch) -> Self {
        Self {
            rid: value.rid,
            duration_ms: value.duration_ms,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiKugouMatch {
    pub hash: String,
    pub album_id: String,
    pub duration_ms: i64,
}

impl From<KugouMatch> for FfiKugouMatch {
    fn from(value: KugouMatch) -> Self {
        Self {
            hash: value.hash,
            album_id: value.album_id,
            duration_ms: value.duration_ms,
        }
    }
}

impl From<FfiKugouMatch> for KugouMatch {
    fn from(value: FfiKugouMatch) -> Self {
        Self {
            hash: value.hash,
            album_id: value.album_id,
            duration_ms: value.duration_ms,
        }
    }
}

#[uniffi::export]
pub fn unblock_pyncmd_request(track: FfiUnblockTrack) -> FfiUnblockRequest {
    core_pyncmd_request(&track.into()).into()
}

#[uniffi::export]
pub fn unblock_decode_pyncmd_response(body: String) -> Option<String> {
    core_decode_pyncmd_response(&body)
}

#[uniffi::export]
pub fn unblock_kuwo_search_request(track: FfiUnblockTrack) -> FfiUnblockRequest {
    core_kuwo_search_request(&track.into()).into()
}

#[uniffi::export]
pub fn unblock_decode_kuwo_search_response(body: String, duration_ms: i64) -> Option<FfiKuwoMatch> {
    core_decode_kuwo_search_response(&body, duration_ms).map(Into::into)
}

#[uniffi::export]
pub fn unblock_kuwo_convert_request(rid: String) -> FfiUnblockRequest {
    core_kuwo_convert_request(&rid).into()
}

#[uniffi::export]
pub fn unblock_decode_kuwo_convert_response(body: String) -> Option<String> {
    core_decode_kuwo_convert_response(&body)
}

#[uniffi::export]
pub fn unblock_kugou_search_request(track: FfiUnblockTrack) -> FfiUnblockRequest {
    core_kugou_search_request(&track.into()).into()
}

#[uniffi::export]
pub fn unblock_decode_kugou_search_response(
    body: String,
    duration_ms: i64,
) -> Option<FfiKugouMatch> {
    core_decode_kugou_search_response(&body, duration_ms).map(Into::into)
}

#[uniffi::export]
pub fn unblock_kugou_track_request(song: FfiKugouMatch) -> FfiUnblockRequest {
    core_kugou_track_request(&song.into()).into()
}

#[uniffi::export]
pub fn unblock_decode_kugou_track_response(body: String) -> Option<String> {
    core_decode_kugou_track_response(&body)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track() -> FfiUnblockTrack {
        FfiUnblockTrack {
            id: 185809,
            name: "夜曲".to_owned(),
            artist_name: "周杰伦".to_owned(),
            duration_ms: 226_000,
        }
    }

    #[test]
    fn ffi_keeps_provider_request_shapes_platform_neutral() {
        assert!(unblock_pyncmd_request(track()).url.contains("id=185809"));
        assert!(
            unblock_kuwo_search_request(track())
                .url
                .contains("search.kuwo.cn")
        );
        assert!(
            unblock_kugou_search_request(track())
                .url
                .contains("mobilecdn.kugou.com")
        );
    }

    #[test]
    fn ffi_parsers_preserve_provider_results() {
        assert_eq!(
            unblock_decode_pyncmd_response(
                r#"{"br":320,"url":"http://audio.example/song.mp3"}"#.to_owned()
            )
            .as_deref(),
            Some("https://audio.example/song.mp3")
        );
    }
}
