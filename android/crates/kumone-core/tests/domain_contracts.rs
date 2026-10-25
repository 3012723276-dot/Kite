use kumone_core::{
    lyrics::decode_lyrics_response,
    netease::{SessionCookies, build_weapi_request},
    search::decode_song_search_response,
};
use serde_json::Value;

fn fixture() -> Value {
    serde_json::from_str(include_str!("../../../contracts/domain-vectors.json"))
        .expect("valid domain contract fixture")
}

#[test]
fn session_and_weapi_request_contracts_match() {
    let fixture = fixture();
    assert_eq!(fixture["schema_version"].as_u64(), Some(1));

    let session = &fixture["session"];
    let mut cookies = SessionCookies::default();
    let inserted = cookies.ingest_cookie_string(
        session["raw_cookie_string"]
            .as_str()
            .expect("raw cookie string"),
    );
    assert_eq!(
        inserted as u64,
        session["expected_inserted"]
            .as_u64()
            .expect("expected inserted")
    );
    assert_eq!(
        cookies.is_logged_in(),
        session["expected_logged_in"]
            .as_bool()
            .expect("expected login state")
    );

    let cookie_header = cookies.header_with_defaults();
    for required in session["expected_cookie_header_contains"]
        .as_array()
        .expect("cookie header expectations")
    {
        let required = required.as_str().expect("cookie substring");
        assert!(
            cookie_header.contains(required),
            "missing cookie contract: {required}"
        );
    }

    let request_fixture = &fixture["weapi_request"];
    let request = build_weapi_request(
        request_fixture["path"].as_str().expect("request path"),
        &request_fixture["payload"],
        &cookies,
    )
    .expect("contract request builds");

    assert_eq!(
        request.method,
        request_fixture["expected_method"]
            .as_str()
            .expect("expected method")
    );
    assert_eq!(
        request.url,
        request_fixture["expected_url"]
            .as_str()
            .expect("expected URL")
    );
    for header in request_fixture["required_headers"]
        .as_array()
        .expect("required headers")
    {
        let header = header.as_str().expect("header name");
        assert!(
            request.headers.contains_key(header),
            "missing header: {header}"
        );
    }
    assert!(
        request.body.starts_with(
            request_fixture["body_prefix"]
                .as_str()
                .expect("body prefix")
        )
    );
    assert!(
        request.body.contains(
            request_fixture["body_contains"]
                .as_str()
                .expect("body substring")
        )
    );
}

#[test]
fn search_decode_contract_matches() {
    let fixture = fixture();
    let search = &fixture["search"];
    let body = serde_json::to_string(&search["response"]).expect("serialize search fixture");
    let result = decode_song_search_response(&body).expect("search fixture decodes");

    assert_eq!(
        result.total,
        search["expected_total"].as_i64().expect("expected total")
    );
    assert_eq!(result.songs.len(), 2);
    assert_eq!(
        result.songs[0].artist_names(),
        search["expected_first_artist_names"]
            .as_str()
            .expect("first artist names")
    );
    assert_eq!(
        result.songs[0].subtitle(),
        search["expected_first_subtitle"].as_str()
    );
    assert_eq!(
        result.songs[1].duration_ms,
        search["expected_second_duration_ms"]
            .as_i64()
            .expect("second duration")
    );
    assert_eq!(
        result.songs[1].subtitle(),
        search["expected_second_subtitle"].as_str()
    );
}

#[test]
fn lyrics_decode_contract_matches() {
    let fixture = fixture();
    let lyrics = &fixture["lyrics"];
    let body = serde_json::to_string(&lyrics["response"]).expect("serialize lyrics fixture");
    let result = decode_lyrics_response(&body).expect("lyrics fixture decodes");

    assert_eq!(
        result.lines.len() as u64,
        lyrics["expected_line_count"]
            .as_u64()
            .expect("expected line count")
    );
    assert_eq!(
        result.lines[0].time_ms,
        lyrics["expected_first_time_ms"]
            .as_u64()
            .expect("expected first timestamp")
    );
    assert_eq!(
        result.lines[0].text,
        lyrics["expected_first_text"].as_str().expect("first text")
    );
    assert_eq!(
        result.lines[0].translation.as_deref(),
        lyrics["expected_first_translation"].as_str()
    );
    assert_eq!(
        result.lines[0].romaji.as_deref(),
        lyrics["expected_first_romaji"].as_str()
    );
    assert_eq!(
        result.contributor.as_deref(),
        lyrics["expected_contributor"].as_str()
    );
    assert_eq!(
        result.translation_contributor.as_deref(),
        lyrics["expected_translation_contributor"].as_str()
    );
}
