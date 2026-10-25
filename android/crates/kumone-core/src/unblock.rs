//! Deterministic unblock/source-matching and provider protocol shared by platform clients.
//!
//! Network I/O remains platform-owned, but request construction and response
//! parsing mirror upstream `UnblockService.swift` so Android and Windows use
//! the same provider order and matching behavior.

use md5::{Digest, Md5};
use percent_encoding::{NON_ALPHANUMERIC, utf8_percent_encode};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UnblockProvider {
    Pyncmd,
    Kuwo,
    Kugou,
}

impl UnblockProvider {
    #[must_use]
    pub const fn priority(self) -> u8 {
        match self {
            Self::Pyncmd => 0,
            Self::Kuwo => 1,
            Self::Kugou => 2,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MatchTarget {
    pub title: String,
    pub artists: Vec<String>,
    pub duration_ms: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnblockCandidate {
    pub provider: UnblockProvider,
    pub id: String,
    pub title: String,
    pub artists: Vec<String>,
    pub duration_ms: Option<u64>,
    pub url: Option<String>,
    pub bitrate: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct MatchScore(pub i32);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UnblockTrack {
    pub id: i64,
    pub name: String,
    pub artist_name: String,
    pub duration_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UnblockHttpRequest {
    pub url: String,
    pub user_agent: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KuwoMatch {
    pub rid: String,
    pub duration_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KugouMatch {
    pub hash: String,
    pub album_id: String,
    pub duration_ms: i64,
}

#[must_use]
pub fn score_candidate(target: &MatchTarget, candidate: &UnblockCandidate) -> MatchScore {
    let target_title = normalize(&target.title);
    let candidate_title = normalize(&candidate.title);
    if target_title.is_empty() || candidate_title.is_empty() {
        return MatchScore(i32::MIN / 2);
    }

    let mut score = if target_title == candidate_title {
        100
    } else if target_title.contains(&candidate_title) || candidate_title.contains(&target_title) {
        72
    } else {
        token_overlap(&target_title, &candidate_title) * 50
    };

    let target_artists: Vec<String> = target
        .artists
        .iter()
        .map(|value| normalize(value))
        .collect();
    let candidate_artists: Vec<String> = candidate
        .artists
        .iter()
        .map(|value| normalize(value))
        .collect();
    if target_artists.iter().any(|artist| {
        !artist.is_empty()
            && candidate_artists
                .iter()
                .any(|other| artist == other || artist.contains(other) || other.contains(artist))
    }) {
        score += 35;
    }

    if let (Some(expected), Some(actual)) = (target.duration_ms, candidate.duration_ms) {
        let delta = expected.abs_diff(actual);
        score += match delta {
            0..=1_500 => 20,
            1_501..=4_000 => 12,
            4_001..=8_000 => 4,
            _ => -20,
        };
    }

    if candidate.url.as_deref().is_some_and(|url| !url.is_empty()) {
        score += 5;
    }
    score -= i32::from(candidate.provider.priority());
    MatchScore(score)
}

#[must_use]
pub fn best_candidate<'a>(
    target: &MatchTarget,
    candidates: &'a [UnblockCandidate],
) -> Option<&'a UnblockCandidate> {
    candidates
        .iter()
        .filter(|candidate| candidate.url.as_deref().is_some_and(|url| !url.is_empty()))
        .max_by_key(|candidate| score_candidate(target, candidate))
        .filter(|candidate| score_candidate(target, candidate).0 >= 90)
}

#[must_use]
pub fn normalize(value: &str) -> String {
    value
        .chars()
        .flat_map(char::to_lowercase)
        .filter(|ch| ch.is_alphanumeric())
        .collect()
}

#[must_use]
pub fn pyncmd_request(track: &UnblockTrack) -> UnblockHttpRequest {
    UnblockHttpRequest {
        url: format!(
            "https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id={}&br=320",
            track.id
        ),
        user_agent: "Mozilla/5.0".to_owned(),
    }
}

#[must_use]
pub fn decode_pyncmd_response(body: &str) -> Option<String> {
    let value: Value = serde_json::from_str(body).ok()?;
    let bitrate = value.get("br")?.as_i64()?;
    if bitrate <= 0 {
        return None;
    }
    let url = value.get("url")?.as_str()?;
    if url.is_empty() {
        return None;
    }
    Some(if let Some(rest) = url.strip_prefix("http://") {
        format!("https://{rest}")
    } else {
        url.to_owned()
    })
}

#[must_use]
pub fn kuwo_search_request(track: &UnblockTrack) -> UnblockHttpRequest {
    let query = encoded_keyword(track);
    UnblockHttpRequest {
        url: format!(
            "https://search.kuwo.cn/r.s?&correct=1&vipver=1&stype=comprehensive&encoding=utf8&rformat=json&mobi=1&show_copyright_off=1&searchapi=6&all={query}"
        ),
        user_agent: "Mozilla/5.0".to_owned(),
    }
}

#[must_use]
pub fn decode_kuwo_search_response(body: &str, target_duration_ms: i64) -> Option<KuwoMatch> {
    let value: Value = serde_json::from_str(body).ok()?;
    let abslist = value
        .get("content")?
        .as_array()?
        .get(1)?
        .get("musicpage")?
        .get("abslist")?
        .as_array()?;
    let songs = abslist
        .iter()
        .filter_map(|item| {
            let music_rid = item.get("MUSICRID")?.as_str()?;
            let rid = music_rid.rsplit('_').next()?.to_owned();
            let duration_seconds = item
                .get("DURATION")
                .and_then(|value| {
                    value
                        .as_i64()
                        .or_else(|| value.as_str().and_then(|text| text.parse::<i64>().ok()))
                })
                .unwrap_or(0);
            Some(KuwoMatch {
                rid,
                duration_ms: duration_seconds.saturating_mul(1000),
            })
        })
        .collect::<Vec<_>>();
    select_duration_match(&songs, target_duration_ms, |song| song.duration_ms).cloned()
}

#[must_use]
pub fn kuwo_convert_request(rid: &str) -> UnblockHttpRequest {
    UnblockHttpRequest {
        url: format!(
            "https://antiserver.kuwo.cn/anti.s?type=convert_url&format=mp3&response=url&rid=MUSIC_{rid}"
        ),
        user_agent: "okhttp/3.10.0".to_owned(),
    }
}

#[must_use]
pub fn decode_kuwo_convert_response(body: &str) -> Option<String> {
    let start = body.find("http")?;
    let candidate = &body[start..];
    let end = candidate
        .find(|ch: char| ch.is_whitespace() || ch == '$' || ch == '"')
        .unwrap_or(candidate.len());
    let url = &candidate[..end];
    (!url.is_empty()).then(|| url.to_owned())
}

#[must_use]
pub fn kugou_search_request(track: &UnblockTrack) -> UnblockHttpRequest {
    let query = encoded_keyword(track);
    UnblockHttpRequest {
        url: format!(
            "https://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword={query}&page=1&pagesize=10"
        ),
        user_agent: "Mozilla/5.0".to_owned(),
    }
}

#[must_use]
pub fn decode_kugou_search_response(body: &str, target_duration_ms: i64) -> Option<KugouMatch> {
    let value: Value = serde_json::from_str(body).ok()?;
    let info = value.get("data")?.get("info")?.as_array()?;
    let songs = info
        .iter()
        .filter_map(|item| {
            let hash = item.get("hash")?.as_str()?.to_owned();
            let album_id = item
                .get("album_id")
                .and_then(|value| {
                    value
                        .as_str()
                        .map(str::to_owned)
                        .or_else(|| value.as_i64().map(|id| id.to_string()))
                })
                .unwrap_or_else(|| "0".to_owned());
            let duration_ms = item
                .get("duration")
                .and_then(Value::as_i64)
                .unwrap_or(0)
                .saturating_mul(1000);
            Some(KugouMatch {
                hash,
                album_id,
                duration_ms,
            })
        })
        .collect::<Vec<_>>();
    select_duration_match(&songs, target_duration_ms, |song| song.duration_ms).cloned()
}

#[must_use]
pub fn kugou_track_request(song: &KugouMatch) -> UnblockHttpRequest {
    let mut hasher = Md5::new();
    hasher.update(format!("{}kgcloudv2", song.hash).as_bytes());
    let key = hex::encode(hasher.finalize());
    UnblockHttpRequest {
        url: format!(
            "https://trackercdn.kugou.com/i/v2/?key={key}&hash={}&appid=1005&pid=2&cmd=25&behavior=play&album_id={}",
            song.hash, song.album_id
        ),
        user_agent: "Mozilla/5.0".to_owned(),
    }
}

#[must_use]
pub fn decode_kugou_track_response(body: &str) -> Option<String> {
    let value: Value = serde_json::from_str(body).ok()?;
    value
        .get("url")?
        .as_array()?
        .first()?
        .as_str()
        .filter(|url| !url.is_empty())
        .map(str::to_owned)
}

fn encoded_keyword(track: &UnblockTrack) -> String {
    let keyword = format!("{} {}", track.name, track.artist_name)
        .trim()
        .to_owned();
    utf8_percent_encode(&keyword, NON_ALPHANUMERIC).to_string()
}

fn select_duration_match<T>(
    values: &[T],
    target_duration_ms: i64,
    duration: impl Fn(&T) -> i64,
) -> Option<&T> {
    values
        .iter()
        .take(5)
        .find(|value| {
            let candidate_duration = duration(value);
            candidate_duration > 0 && candidate_duration.abs_diff(target_duration_ms) < 5_000_u64
        })
        .or_else(|| values.first())
}

fn token_overlap(left: &str, right: &str) -> i32 {
    if left.is_empty() || right.is_empty() {
        return 0;
    }
    let shorter = if left.len() <= right.len() {
        left
    } else {
        right
    };
    let longer = if left.len() <= right.len() {
        right
    } else {
        left
    };
    let common = shorter.chars().filter(|ch| longer.contains(*ch)).count();
    ((common * 100) / shorter.chars().count().max(1)) as i32 / 100
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target() -> MatchTarget {
        MatchTarget {
            title: "夜曲".to_owned(),
            artists: vec!["周杰伦".to_owned()],
            duration_ms: Some(226_000),
        }
    }

    fn unblock_track() -> UnblockTrack {
        UnblockTrack {
            id: 185809,
            name: "夜曲".to_owned(),
            artist_name: "周杰伦".to_owned(),
            duration_ms: 226_000,
        }
    }

    #[test]
    fn provider_order_matches_authoritative_swift() {
        assert!(UnblockProvider::Pyncmd.priority() < UnblockProvider::Kuwo.priority());
        assert!(UnblockProvider::Kuwo.priority() < UnblockProvider::Kugou.priority());
    }

    #[test]
    fn exact_title_artist_duration_wins() {
        let candidates = vec![
            UnblockCandidate {
                provider: UnblockProvider::Kugou,
                id: "bad".to_owned(),
                title: "夜曲 (Live)".to_owned(),
                artists: vec!["Other".to_owned()],
                duration_ms: Some(260_000),
                url: Some("https://bad".to_owned()),
                bitrate: None,
            },
            UnblockCandidate {
                provider: UnblockProvider::Kuwo,
                id: "good".to_owned(),
                title: "夜曲".to_owned(),
                artists: vec!["周杰伦".to_owned()],
                duration_ms: Some(226_500),
                url: Some("https://good".to_owned()),
                bitrate: Some(320_000),
            },
        ];
        assert_eq!(
            best_candidate(&target(), &candidates).map(|item| item.id.as_str()),
            Some("good")
        );
    }

    #[test]
    fn candidate_without_url_is_never_selected() {
        let candidates = vec![UnblockCandidate {
            provider: UnblockProvider::Kuwo,
            id: "missing".to_owned(),
            title: "夜曲".to_owned(),
            artists: vec!["周杰伦".to_owned()],
            duration_ms: Some(226_000),
            url: None,
            bitrate: None,
        }];
        assert!(best_candidate(&target(), &candidates).is_none());
    }

    #[test]
    fn normalization_ignores_spaces_punctuation_and_case() {
        assert_eq!(normalize("Hello, World!"), "helloworld");
    }

    #[test]
    fn pyncmd_request_and_response_match_upstream_contract() {
        let request = pyncmd_request(&unblock_track());
        assert!(request.url.contains("source=netease&id=185809&br=320"));
        assert_eq!(
            decode_pyncmd_response(r#"{"br":320,"url":"http://audio.example/song.mp3"}"#)
                .as_deref(),
            Some("https://audio.example/song.mp3")
        );
    }

    #[test]
    fn kuwo_search_uses_top_five_duration_match() {
        let body = r#"{"content":[{}, {"musicpage":{"abslist":[{"MUSICRID":"MUSIC_1","DURATION":"260"},{"MUSICRID":"MUSIC_2","DURATION":"225"}]}}]}"#;
        let selected = decode_kuwo_search_response(body, 226_000).expect("match");
        assert_eq!(selected.rid, "2");
        assert_eq!(
            decode_kuwo_convert_response("http://audio.example/a.mp3\r\n").as_deref(),
            Some("http://audio.example/a.mp3")
        );
    }

    #[test]
    fn kugou_request_uses_md5_key_and_parser_returns_first_url() {
        let body = r#"{"data":{"info":[{"hash":"ABC","album_id":7,"duration":225}]}}"#;
        let selected = decode_kugou_search_response(body, 226_000).expect("match");
        let request = kugou_track_request(&selected);
        assert!(request.url.contains("hash=ABC"));
        assert!(request.url.contains("album_id=7"));
        assert_eq!(
            decode_kugou_track_response(r#"{"url":["https://audio.example/k.mp3"]}"#).as_deref(),
            Some("https://audio.example/k.mp3")
        );
    }
}
