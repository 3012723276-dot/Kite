import CryptoKit
import Foundation

/// Bodian Music (波点音乐), Kuwo's free-tier app, no login required.
///
/// Search reuses the public Kuwo search, then resolves playback through
/// Bodian's own bd-api endpoint, which signs the request with MD5
/// ("kuwotest" + sorted alphanumeric query chars + path, same scheme as
/// the public UnblockNeteaseMusic bodian provider).
///
/// Honest limitation, verified 2026-10-25: for a VIP track such as
/// Jay Chou's 稻香, bd-api returns code 20018 ("没有授权付费歌曲")
/// without a paid token, so this provider only helps free tracks that
/// Kuwo's convert endpoint happens to miss. It deliberately does NOT
/// fake an ad-watch request; when bd-api refuses, the provider throws
/// and UnblockService moves on to the next source.
struct BodianAudioSourceProvider: AudioSourceProvider {
    let id: AudioSourceID = .bodian
    let displayName = AudioSourceID.bodian.displayName

    private let httpClient: AudioSourceClient
    private let deviceID: String

    init(httpClient: AudioSourceClient = .shared) {
        self.httpClient = httpClient
        self.deviceID = String(Int.random(in: 0...100_000_000_000))
    }

    func resolve(track: Track) async throws -> ResolvedAudioSource? {
        let query = AudioSourceTrackMatcher.keyword(for: track)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let searchURL = "https://search.kuwo.cn/r.s?&correct=1&vipver=1&stype=comprehensive&encoding=utf8"
            + "&rformat=json&mobi=1&show_copyright_off=1&searchapi=6&all=\(query)"
        let data = try await httpClient.data(
            from: searchURL,
            source: id,
            operation: "search"
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? [[String: Any]],
              content.count >= 2,
              let musicPage = content[1]["musicpage"] as? [String: Any],
              let songs = musicPage["abslist"] as? [[String: Any]]
        else { throw AudioSourceProviderError.invalidResponse }

        let matches = songs.prefix(5).compactMap { item -> String? in
            guard let musicRID = item["MUSICRID"] as? String,
                  let rid = musicRID.components(separatedBy: "_").last,
                  let title = item["SONGNAME"] as? String,
                  let artist = item["ARTIST"] as? String
            else { return nil }
            let durationSeconds = Int((item["DURATION"] as? String) ?? "") ?? (item["DURATION"] as? Int ?? 0)
            guard AudioSourceTrackMatcher.matches(
                track: track,
                title: title,
                artist: artist,
                durationMS: durationSeconds * 1_000
            ) else { return nil }
            return rid
        }
        guard let musicID = matches.first else { return nil }

        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let unsigned = "http://bd-api.kuwo.cn/api/play/music/v2/audioUrl?&br=320kmp3&musicId=\(musicID)&timestamp=\(timestamp)"
        guard let urlComponents = URLComponents(string: unsigned),
              let queryString = urlComponents.query
        else { throw AudioSourceProviderError.invalidURL }
        let filtered = queryString.unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map { String($0) }
            .sorted()
            .joined()
        let signInput = "kuwotest\(filtered)\(urlComponents.path)"
        let sign = Insecure.MD5.hash(data: Data(signInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let audioURL = "\(unsigned)&sign=\(sign)"
        let audioData = try await httpClient.data(
            from: audioURL,
            source: id,
            operation: "resolve-stream",
            userAgent: "Dart/2.19 (dart:io)",
            headers: [
                "plat": "ar",
                "channel": "aliopen",
                "devid": deviceID,
                "ver": "3.9.0",
                "host": "bd-api.kuwo.cn",
                "X-Forwarded-For": "1.0.1.114",
            ]
        )
        guard let audioObject = try JSONSerialization.jsonObject(with: audioData) as? [String: Any],
              (audioObject["code"] as? Int) == 200,
              let audioDataObject = audioObject["data"] as? [String: Any],
              let urlString = audioDataObject["audioUrl"] as? String,
              let url = URL(string: urlString)
        else { throw AudioSourceProviderError.invalidResponse }

        return ResolvedAudioSource(id: id, displayName: displayName, url: url)
    }
}
