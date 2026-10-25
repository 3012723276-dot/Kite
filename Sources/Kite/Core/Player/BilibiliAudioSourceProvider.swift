import Foundation

/// Bilibili video audio, no login and no VIP required for public videos.
///
/// Flow (all plain HTTP, no cookie):
///   1. Search videos by "song artist", pages 1-2, 20 results each.
///   2. Pick candidates in tiers, strict first, so loosening never
///      displaces a good original match:
///      - Tier 0 (unchanged): title contains the song name, title or
///        uploader contains the artist, duration within 5 seconds of
///        the NetEase track, and no version conflict (live / remix /
///        cover /翻唱 /伴奏 /教学 / reaction) that is not in the
///        original track name.
///      - Tier 1: same title/artist check, duration within 20 seconds
///        (MV intros/outros and re-uploads often drift past 5s), and
///        singing versions (live / remix / cover /翻唱 / dj / reaction)
///        are allowed as a fallback. Non-singing versions (伴奏 /
///        instrumental / karaoke /教学) are still rejected unless the
///        original track itself is one.
///      - Tier 2: title contains the song name and duration within
///        30 seconds, artist check dropped. The search keyword already
///        included the artist, so this only fires when the uploader
///        did not put the artist in the title or author at all.
///   3. Try candidates in tier order, not just the first one: a
///      matching video can still fail pagelist/playurl (taken down,
///      region/copyright blocked, no DASH audio). Previously the
///      provider threw on the first such failure and UnblockService
///      moved on to the next source, discarding the other Bilibili
///      candidates. Now it tries up to 5 candidates before giving up.
///   4. For each candidate, resolve the first page's cid via pagelist,
///      then take the DASH audio track from playurl (fnval=16);
///      fall back to the progressive mp4 URL (fnval=0) when DASH
///      audio is unavailable.
/// Note: this is video audio, not the studio recording, and Bilibili
/// occasionally returns a WAF page instead of JSON; in that case the
/// provider throws and UnblockService moves on to the next source.
struct BilibiliAudioSourceProvider: AudioSourceProvider {
    let id: AudioSourceID = .bilibili
    let displayName: String = AudioSourceID.bilibili.displayName

    private let httpClient: AudioSourceClient

    init(httpClient: AudioSourceClient = .shared) {
        self.httpClient = httpClient
    }

    func resolve(track: Track) async throws -> ResolvedAudioSource? {
        let keyword: String = AudioSourceTrackMatcher.keyword(for: track)
        let query: String = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        // Collect raw search results from pages 1-2. A search failure
        // (code != 0, WAF page) still throws, as before.
        var allVideos: [Video] = []
        for page in 1...2 {
            let searchURL: String = "https://api.bilibili.com/x/web-interface/search/type"
                + "?keyword=\(query)&search_type=video&page=\(page)&page_size=20"
            let data: Data = try await httpClient.data(
                from: searchURL,
                source: id,
                operation: "search",
                headers: ["Referer": "https://www.bilibili.com"]
            )
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["code"] as? Int) == 0,
                  let dataObject = object["data"] as? [String: Any],
                  let results = dataObject["result"] as? [[String: Any]]
            else {
                // Page 1 failing is a real failure (WAF / bad response).
                // Page 2 failing must not discard page 1 results.
                if page == 1 {
                    throw AudioSourceProviderError.invalidResponse
                }
                break
            }
            for item in results {
                guard let bvid = item["bvid"] as? String,
                      let rawTitle = item["title"] as? String,
                      let durationString = item["duration"] as? String,
                      let durationMS = Self.durationMS(from: durationString)
                else {
                    continue
                }
                allVideos.append(Video(
                    bvid: bvid,
                    title: Self.stripHTML(rawTitle),
                    author: (item["author"] as? String) ?? "",
                    durationMS: durationMS
                ))
            }
            // No point paging further when a page comes back short.
            if results.count < 20 {
                break
            }
        }

        // Tier order, strict first. Deduplicate by bvid so a video
        // appearing in an earlier tier is not retried in a later one.
        var ordered: [Video] = []
        var seen: Set<String> = []
        let tiers: [(toleranceMS: Int, requireArtist: Bool, allowSingingVersions: Bool)] = [
            (5_000, true, false),
            (20_000, true, true),
            (30_000, false, true),
        ]
        for tier in tiers {
            for video in allVideos {
                guard !seen.contains(video.bvid) else {
                    continue
                }
                guard Self.matches(
                    track: track,
                    title: video.title,
                    author: video.author,
                    durationMS: video.durationMS,
                    toleranceMS: tier.toleranceMS,
                    requireArtist: tier.requireArtist,
                    allowSingingVersions: tier.allowSingingVersions
                ) else {
                    continue
                }
                seen.insert(video.bvid)
                ordered.append(video)
            }
        }
        guard !ordered.isEmpty else {
            return nil
        }

        // Try candidates in order, up to 5, instead of failing on the
        // first pagelist/playurl error.
        for video in ordered.prefix(5) {
            if let resolved = try? await resolveVideo(video) {
                return resolved
            }
        }
        return nil
    }

    private func resolveVideo(_ video: Video) async throws -> ResolvedAudioSource {
        let pagelistURL: String = "https://api.bilibili.com/x/player/pagelist?bvid=\(video.bvid)"
        let pagelistData: Data = try await httpClient.data(
            from: pagelistURL,
            source: id,
            operation: "pagelist",
            headers: ["Referer": "https://www.bilibili.com"]
        )
        guard let pagelistObject = try JSONSerialization.jsonObject(with: pagelistData) as? [String: Any],
              (pagelistObject["code"] as? Int) == 0,
              let pages = pagelistObject["data"] as? [[String: Any]],
              let cid = pages.first?["cid"] as? Int
        else {
            throw AudioSourceProviderError.invalidResponse
        }

        let playURL: String = "https://api.bilibili.com/x/player/playurl"
            + "?bvid=\(video.bvid)&cid=\(cid)&qn=64&fnval=16&fourk=1"
        let playData: Data = try await httpClient.data(
            from: playURL,
            source: id,
            operation: "resolve-stream",
            headers: ["Referer": "https://www.bilibili.com"]
        )
        guard let playObject = try JSONSerialization.jsonObject(with: playData) as? [String: Any],
              (playObject["code"] as? Int) == 0,
              let playDataObject = playObject["data"] as? [String: Any]
        else {
            throw AudioSourceProviderError.invalidResponse
        }

        if let dash = playDataObject["dash"] as? [String: Any],
           let audio = dash["audio"] as? [[String: Any]],
           let baseURL = audio.first?["baseUrl"] as? String,
           let url = URL(string: baseURL) {
            return ResolvedAudioSource(id: id, displayName: displayName, url: url)
        }
        if let durl = playDataObject["durl"] as? [[String: Any]],
           let urlString = durl.first?["url"] as? String,
           let url = URL(string: urlString) {
            return ResolvedAudioSource(id: id, displayName: displayName, url: url)
        }
        throw AudioSourceProviderError.invalidResponse
    }

    private struct Video {
        let bvid: String
        let title: String
        let author: String
        let durationMS: Int
    }

    private static func stripHTML(_ value: String) -> String {
        return value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func durationMS(from value: String) -> Int? {
        let parts: [Int] = value.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else {
            return nil
        }
        var seconds: Int = 0
        for part in parts {
            seconds = seconds * 60 + part
        }
        return seconds * 1_000
    }

    private static func normalized(_ value: String) -> String {
        return value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map { String($0) }
            .joined()
    }

    private static let versionMarkers: [String] = [
        "live", "remix", "伴奏", "dj", "cover", "翻唱", "instrumental", "karaoke", "教学", "reaction",
    ]

    /// Singing versions that Tier 1/2 may fall back to. Non-singing
    /// versions (伴奏 / instrumental / karaoke /教学) are never allowed
    /// as a fallback unless the original track itself is one.
    private static let singingVersionMarkers: Set<String> = [
        "live", "remix", "dj", "cover", "翻唱", "reaction",
    ]

    private static let nonSingingVersionMarkers: Set<String> = [
        "伴奏", "instrumental", "karaoke", "教学",
    ]

    private static func matches(
        track: Track,
        title: String,
        author: String,
        durationMS: Int,
        toleranceMS: Int,
        requireArtist: Bool,
        allowSingingVersions: Bool
    ) -> Bool {
        if track.durationMS > 0, durationMS > 0,
           abs(durationMS - track.durationMS) > toleranceMS {
            return false
        }
        let normalizedTitle: String = normalized(title)
        let normalizedName: String = normalized(track.name)
        guard !normalizedName.isEmpty, normalizedTitle.contains(normalizedName) else {
            return false
        }
        if requireArtist {
            let firstArtistName: String = track.artists.first?.name ?? ""
            let expectedArtist: String = normalized(firstArtistName)
            guard !expectedArtist.isEmpty,
                  normalizedTitle.contains(expectedArtist) || normalized(author).contains(expectedArtist)
            else {
                return false
            }
        }
        let originalMarkers: Set<String> = Set(versionMarkers.filter { normalized(track.name).contains($0) })
        let candidateMarkers: Set<String> = Set(versionMarkers.filter {
            normalizedTitle.contains($0) || normalized(author).contains($0)
        })
        if allowSingingVersions {
            // Allow singing versions, but never a non-singing version
            // the original is not.
            let forbidden = candidateMarkers.intersection(nonSingingVersionMarkers)
                .subtracting(originalMarkers)
            guard forbidden.isEmpty else {
                return false
            }
            let allowed = originalMarkers.union(singingVersionMarkers)
            return candidateMarkers.isSubset(of: allowed)
        }
        return candidateMarkers.isSubset(of: originalMarkers)
    }
}
