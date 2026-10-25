//! Shared NetEase song-search request and response semantics.
//!
//! The authoritative behavior comes from upstream `NeteaseAPI.search` and the
//! tolerant Swift `Track` decoder. Platform apps only own transport and UI.

use serde::{Deserialize, Serialize};
use serde_json::json;
use thiserror::Error;

use crate::netease::{EapiContext, RequestResult, RequestSpec, SessionCookies, build_eapi_request};

const SEARCH_PATH: &str = "/cloudsearch/pc";
const SEARCH_TYPE_SONGS: i64 = 1;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchArtist {
    #[serde(default)]
    pub id: i64,
    #[serde(default)]
    pub name: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchAlbum {
    #[serde(default)]
    pub id: i64,
    #[serde(default)]
    pub name: String,
    #[serde(default, rename = "picUrl")]
    pub pic_url: Option<String>,
}

/// A search result track that tolerates both modern (`ar`/`al`/`dt`) and
/// legacy (`artists`/`album`/`duration`) NetEase shapes, matching upstream.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchTrack {
    pub id: i64,
    #[serde(default)]
    pub name: String,
    #[serde(default, rename = "ar", alias = "artists")]
    pub artists: Vec<SearchArtist>,
    #[serde(default, rename = "al", alias = "album")]
    pub album: SearchAlbum,
    #[serde(default, rename = "dt", alias = "duration")]
    pub duration_ms: i64,
    #[serde(default, rename = "alia", alias = "alias")]
    pub aliases: Vec<String>,
    #[serde(default, rename = "tns")]
    pub trans_names: Vec<String>,
}

impl SearchTrack {
    #[must_use]
    pub fn artist_names(&self) -> String {
        self.artists
            .iter()
            .map(|artist| artist.name.as_str())
            .filter(|name| !name.is_empty())
            .collect::<Vec<_>>()
            .join(" / ")
    }

    #[must_use]
    pub fn subtitle(&self) -> Option<&str> {
        self.trans_names
            .first()
            .or_else(|| self.aliases.first())
            .map(String::as_str)
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SongSearchResult {
    pub songs: Vec<SearchTrack>,
    pub total: i64,
}

#[derive(Debug, Deserialize)]
struct SearchEnvelope {
    #[serde(default)]
    code: i64,
    #[serde(default)]
    message: Option<String>,
    #[serde(default)]
    msg: Option<String>,
    #[serde(default)]
    result: Option<SearchPayload>,
}

#[derive(Debug, Default, Deserialize)]
struct SearchPayload {
    #[serde(default)]
    songs: Vec<SearchTrack>,
    #[serde(default, rename = "songCount")]
    song_count: i64,
}

#[derive(Debug, Error)]
pub enum SearchDecodeError {
    #[error("failed to decode NetEase search response: {0}")]
    Json(#[from] serde_json::Error),
    #[error("NetEase search failed ({code}): {message}")]
    Business { code: i64, message: String },
}

/// Builds the exact song-search request used by upstream:
/// `eapi("/cloudsearch/pc", { s, type: 1, limit, offset, total: true })`.
pub fn build_song_search_request(
    keywords: &str,
    limit: i64,
    offset: i64,
    cookies: &SessionCookies,
    context: &EapiContext,
) -> RequestResult<RequestSpec> {
    let payload = json!({
        "s": keywords,
        "type": SEARCH_TYPE_SONGS,
        "limit": limit.max(1),
        "offset": offset.max(0),
        "total": true,
    });
    build_eapi_request(SEARCH_PATH, &payload, cookies, context)
}

pub fn decode_song_search_response(body: &str) -> Result<SongSearchResult, SearchDecodeError> {
    let envelope: SearchEnvelope = serde_json::from_str(body)?;
    if envelope.code != 0 && envelope.code != 200 {
        return Err(SearchDecodeError::Business {
            code: envelope.code,
            message: envelope
                .message
                .or(envelope.msg)
                .unwrap_or_else(|| "unknown error".to_owned()),
        });
    }

    let result = envelope.result.unwrap_or_default();
    Ok(SongSearchResult {
        songs: result.songs,
        total: result.song_count,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_modern_and_legacy_track_shapes() {
        let result = decode_song_search_response(
            r#"{
                "code": 200,
                "result": {
                    "songCount": 2,
                    "songs": [
                        {
                            "id": 1,
                            "name": "Modern",
                            "ar": [{"id": 11, "name": "Artist A"}],
                            "al": {"id": 21, "name": "Album A", "picUrl": "https://img/a.jpg"},
                            "dt": 180000,
                            "alia": ["Alias A"],
                            "tns": ["Translation A"]
                        },
                        {
                            "id": 2,
                            "name": "Legacy",
                            "artists": [{"id": 12, "name": "Artist B"}],
                            "album": {"id": 22, "name": "Album B"},
                            "duration": 200000,
                            "alias": ["Alias B"]
                        }
                    ]
                }
            }"#,
        )
        .expect("search fixture should decode");

        assert_eq!(result.total, 2);
        assert_eq!(result.songs.len(), 2);
        assert_eq!(result.songs[0].artist_names(), "Artist A");
        assert_eq!(result.songs[0].subtitle(), Some("Translation A"));
        assert_eq!(result.songs[0].album.name, "Album A");
        assert_eq!(result.songs[1].duration_ms, 200_000);
        assert_eq!(result.songs[1].subtitle(), Some("Alias B"));
    }

    #[test]
    fn missing_result_becomes_empty_search_result() {
        let result = decode_song_search_response(r#"{"code":200}"#)
            .expect("missing result is a valid empty result");
        assert!(result.songs.is_empty());
        assert_eq!(result.total, 0);
    }

    #[test]
    fn business_error_is_not_silently_treated_as_empty() {
        let error = decode_song_search_response(r#"{"code":401,"message":"unauthorized"}"#)
            .expect_err("business error must surface");
        assert!(matches!(
            error,
            SearchDecodeError::Business { code: 401, .. }
        ));
    }

    #[test]
    fn request_uses_cloudsearch_eapi_endpoint() {
        let cookies = SessionCookies::default();
        let context = EapiContext::new("23456789", "1777777777");
        let request = build_song_search_request("Kumone", 30, 0, &cookies, &context)
            .expect("search request should build");

        assert_eq!(
            request.url,
            "https://interface.music.163.com/eapi/cloudsearch/pc"
        );
        assert_eq!(request.method, "POST");
        assert!(request.body.starts_with("params="));
    }
}
