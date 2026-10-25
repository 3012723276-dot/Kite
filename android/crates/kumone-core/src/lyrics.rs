//! Shared lyric request, decoding and LRC parsing behavior.

use std::collections::HashMap;

use serde::Deserialize;
use serde_json::json;
use thiserror::Error;

use crate::netease::{RequestBuildError, RequestSpec, SessionCookies, build_weapi_request};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LyricLine {
    pub time_ms: u64,
    pub text: String,
    pub translation: Option<String>,
    pub romaji: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ParsedLyrics {
    pub lines: Vec<LyricLine>,
    pub is_instrumental: bool,
    pub contributor: Option<String>,
    pub translation_contributor: Option<String>,
}

impl ParsedLyrics {
    #[must_use]
    pub fn active_index(&self, time_ms: u64) -> Option<usize> {
        self.lines
            .partition_point(|line| line.time_ms <= time_ms)
            .checked_sub(1)
    }
}

#[derive(Debug, Deserialize)]
struct LyricBody {
    lyric: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Contributor {
    nickname: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LyricResponse {
    #[serde(default = "ok_code")]
    code: i64,
    lrc: Option<LyricBody>,
    tlyric: Option<LyricBody>,
    romalrc: Option<LyricBody>,
    lyric_user: Option<Contributor>,
    trans_user: Option<Contributor>,
    message: Option<String>,
}

const fn ok_code() -> i64 {
    200
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum LyricsDecodeError {
    #[error("failed to decode lyric response: {0}")]
    Decode(String),
    #[error("NetEase lyric request failed with code {code}: {message}")]
    Business { code: i64, message: String },
}

pub fn build_lyric_request(
    id: i64,
    cookies: &SessionCookies,
) -> Result<RequestSpec, RequestBuildError> {
    build_weapi_request(
        "/song/lyric",
        &json!({"id": id, "lv": -1, "kv": -1, "tv": -1, "rv": -1}),
        cookies,
    )
}

pub fn decode_lyrics_response(body: &str) -> Result<ParsedLyrics, LyricsDecodeError> {
    let response: LyricResponse =
        serde_json::from_str(body).map_err(|error| LyricsDecodeError::Decode(error.to_string()))?;
    if response.code != 200 {
        return Err(LyricsDecodeError::Business {
            code: response.code,
            message: response.message.unwrap_or_default(),
        });
    }

    let mut output = ParsedLyrics {
        contributor: response.lyric_user.and_then(|value| value.nickname),
        translation_contributor: response.trans_user.and_then(|value| value.nickname),
        ..ParsedLyrics::default()
    };

    let raw = response
        .lrc
        .and_then(|value| value.lyric)
        .unwrap_or_default();
    if raw.is_empty() {
        return Ok(output);
    }

    let mut main = parse_lrc(&raw);
    const INSTRUMENTAL_MARKER: &str = "纯音乐，请欣赏";
    if main.len() <= 10
        && main
            .iter()
            .any(|(_, text)| text.contains(INSTRUMENTAL_MARKER))
    {
        output.is_instrumental = true;
        main.retain(|(_, text)| !text.contains(INSTRUMENTAL_MARKER) && !is_writer_credit(text));
        if main.is_empty() {
            return Ok(output);
        }
    }
    main.retain(|(_, text)| !is_empty_writer_credit(text));

    output.lines = main
        .into_iter()
        .map(|(time_ms, text)| LyricLine {
            time_ms,
            text,
            translation: None,
            romaji: None,
        })
        .collect();

    merge_secondary(
        &mut output.lines,
        response.tlyric.and_then(|value| value.lyric).as_deref(),
        |line, text| line.translation = Some(text),
    );
    merge_secondary(
        &mut output.lines,
        response.romalrc.and_then(|value| value.lyric).as_deref(),
        |line, text| line.romaji = Some(text),
    );

    Ok(output)
}

#[must_use]
pub fn parse_lrc(body: &str) -> Vec<(u64, String)> {
    let mut result = Vec::new();
    for raw_line in body.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }
        let mut tags = Vec::new();
        let mut cursor = 0usize;
        let bytes = line.as_bytes();
        while cursor < bytes.len() && bytes[cursor] == b'[' {
            let Some(relative_end) = line[cursor + 1..].find(']') else {
                break;
            };
            let end = cursor + 1 + relative_end;
            if let Some(time_ms) = parse_timestamp(&line[cursor + 1..end]) {
                tags.push((time_ms, end + 1));
                cursor = end + 1;
            } else {
                break;
            }
        }
        let Some((_, content_start)) = tags.last().copied() else {
            continue;
        };
        let content = line[content_start..].trim().to_owned();
        for (time_ms, _) in tags {
            result.push((time_ms, content.clone()));
        }
    }
    result.sort_by_key(|(time_ms, _)| *time_ms);
    result
}

fn parse_timestamp(tag: &str) -> Option<u64> {
    let (minutes, remainder) = tag.split_once(':')?;
    let minutes = minutes.parse::<u64>().ok()?;
    let (seconds, fraction) = remainder
        .split_once('.')
        .or_else(|| remainder.split_once(':'))
        .map_or((remainder, None), |(seconds, fraction)| {
            (seconds, Some(fraction))
        });
    let seconds = seconds.parse::<u64>().ok()?;
    let fraction_ms = fraction.map_or(Some(0), |digits| {
        // LRC fractions are milliseconds at most. Read only the first three
        // ASCII digits so hostile input cannot make `u64::pow` overflow or
        // cause a panic before the decoder can reject it.
        let mut value = 0u64;
        let mut width = 0usize;
        for byte in digits.bytes() {
            if !byte.is_ascii_digit() {
                return None;
            }
            if width < 3 {
                value = value * 10 + u64::from(byte - b'0');
                width += 1;
            }
        }
        Some(match width {
            0 => 0,
            1 => value * 100,
            2 => value * 10,
            _ => value,
        })
    })?;
    minutes
        .checked_mul(60)
        .and_then(|value| value.checked_add(seconds))
        .and_then(|value| value.checked_mul(1000))
        .and_then(|value| value.checked_add(fraction_ms))
}

fn merge_secondary(
    lines: &mut [LyricLine],
    body: Option<&str>,
    mut assign: impl FnMut(&mut LyricLine, String),
) {
    let Some(body) = body.filter(|body| !body.is_empty()) else {
        return;
    };
    let by_centisecond: HashMap<u64, String> = parse_lrc(body)
        .into_iter()
        .filter(|(_, text)| !text.is_empty())
        .map(|(time_ms, text)| (time_ms / 10, text))
        .collect();
    for line in lines {
        if let Some(text) = by_centisecond.get(&(line.time_ms / 10)) {
            assign(line, text.clone());
        }
    }
}

fn is_writer_credit(text: &str) -> bool {
    let compact = text.trim_start();
    compact.starts_with("作词:")
        || compact.starts_with("作词：")
        || compact.starts_with("作曲:")
        || compact.starts_with("作曲：")
}

fn is_empty_writer_credit(text: &str) -> bool {
    let compact = text.trim().replace(' ', "");
    matches!(
        compact.as_str(),
        "作词:无" | "作词：无" | "作曲:无" | "作曲：无"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lrc_supports_multiple_timestamps_and_fraction_styles() {
        let lines = parse_lrc("[00:01.50][00:02:750]Hello\n[01:03]World");
        assert_eq!(
            lines,
            vec![
                (1500, "Hello".to_owned()),
                (2750, "Hello".to_owned()),
                (63_000, "World".to_owned()),
            ]
        );
    }

    #[test]
    fn lrc_rejects_overflowing_timestamps_without_panicking() {
        let fraction = "9".repeat(128);
        assert_eq!(
            parse_lrc(&format!("[00:00.{fraction}]ignored")),
            vec![(999, "ignored".to_owned())]
        );
        assert!(parse_lrc("[18446744073709551615:59]ignored").is_empty());
    }

    #[test]
    fn translation_and_romaji_merge_by_centisecond() {
        let parsed = decode_lyrics_response(
            r#"{"code":200,"lrc":{"lyric":"[00:01.00]主歌词"},"tlyric":{"lyric":"[00:01.00]Translation"},"romalrc":{"lyric":"[00:01.00]Romaji"}}"#,
        )
        .expect("lyrics");
        assert_eq!(parsed.lines.len(), 1);
        assert_eq!(parsed.lines[0].translation.as_deref(), Some("Translation"));
        assert_eq!(parsed.lines[0].romaji.as_deref(), Some("Romaji"));
        assert_eq!(parsed.active_index(1000), Some(0));
    }

    #[test]
    fn instrumental_marker_is_preserved_as_state_not_visible_line() {
        let parsed =
            decode_lyrics_response(r#"{"code":200,"lrc":{"lyric":"[00:00.00]纯音乐，请欣赏"}}"#)
                .expect("lyrics");
        assert!(parsed.is_instrumental);
        assert!(parsed.lines.is_empty());
    }

    #[test]
    fn lyric_request_matches_upstream_contract() {
        let request = build_lyric_request(42, &SessionCookies::default()).expect("request");
        assert!(
            request
                .url
                .starts_with("https://music.163.com/weapi/song/lyric")
        );
        assert!(request.body.starts_with("params="));
    }
}
