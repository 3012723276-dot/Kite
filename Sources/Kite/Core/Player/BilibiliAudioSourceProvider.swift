import Foundation

/// Bilibili video audio, no login and no VIP required for public videos.
///
/// Flow (all plain HTTP, no cookie):
/// 1. Search videos by "song artist".
/// 2. Take the first result whose title contains the song name, whose
/// title or uploader contains the artist, and whose duration is within
/// 5 seconds of the NetEase track. Titles on Bilibili often carry
/// prefixes ("", "歌手 - 歌名"), so exact-title matching
/// (AudioSourceTrackMatcher) would reject almost everything; this
/// provider therefore uses its own contains-based match, while still
/// rejecting version conflicts (live / remix / cover / 翻唱 / 伴奏
/// / 教学 / reaction) that are not in the original track name.
/// 3. Resolve the first page's cid via pagelist.
/// 4. Take the DASH audio track from playurl (fnval=16); fall back to the
/// progressive mp4 URL (fnval=0) when DASH audio is unavailable.
/// Note: this is video audio, not the studio recording, and Bilibili
/// occasionally returns a WAF page instead of JSON; in that case the
/// provider throws and UnblockService moves on to the next source.
struct BilibiliAudioSourceProvider: AudioSourceProvider {
let id: AudioSourceID =.bilibili
let displayName = AudioSourceID.bilibili.displayName

private let httpClient: AudioSourceClient

init(httpClient: AudioSourceClient =.shared) {
self.httpClient = httpClient
}

func resolve(track: Track) async throws -> ResolvedAudioSource? {
let query = AudioSourceTrackMatcher.keyword(for: track)
.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
let searchURL = "https://api.bilibili.com/x/web-interface/search/type"
+ "?keyword=\(query)&search_type=video&page=1&page_size=10"
let data = try await httpClient.data(
from: searchURL,
source: id,
operation: "search",
headers: ["Referer": "https://www.bilibili.com"]
)
guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
(object["code"] as? Int) == 0,
let dataObject = object["data"] as? [String: Any],
let results = dataObject["result"] as? [[String: Any]]
else { throw AudioSourceProviderError.invalidResponse}

let candidates = results.prefix(10).compactMap { item -> Video? in
guard let bvid = item["bvid"] as? String,
let rawTitle = item["title"] as? String,
let durationString = item["duration"] as? String,
let durationMS = Self.durationMS(from: durationString)
else { return nil}
let title = Self.stripHTML(rawTitle)
let author = (item["author"] as? String) ?? ""
guard Self.matches(track: track, title: title, author: author, durationMS: durationMS)
else { return nil}
return Video(bvid: bvid, title: title)
}
guard let video = candidates.first else { return nil}

let pagelistURL = "https://api.bilibili.com/x/player/pagelist?bvid=\(video.bvid)"
let pagelistData = try await httpClient.data(
from: pagelistURL,
source: id,
operation: "pagelist",
headers: ["Referer": "https://www.bilibili.com"]
)
guard let pagelistObject = try JSONSerialization.jsonObject(with: pagelistData) as? [String: Any],
(pagelistObject["code"] as? Int) == 0,
let pages = pagelistObject["data"] as? [[String: Any]],
let cid = pages.first?["cid"] as? Int
else { throw AudioSourceProviderError.invalidResponse}

let playURL = "https://api.bilibili.com/x/player/playurl"
+ "?bvid=\(video.bvid)&cid=\(cid)&qn=64&fnval=16&fourk=1"
let playData = try await httpClient.data(
from: playURL,
source: id,
operation: "resolve-stream",
headers: ["Referer": "https://www.bilibili.com"]
)
guard let playObject = try JSONSerialization.jsonObject(with: playData) as? [String: Any],
(playObject["code"] as? Int) == 0,
let playDataObject = playObject["data"] as? [String: Any]
else { throw AudioSourceProviderError.invalidResponse}

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
}

private static func stripHTML(_ value: String) -> String {
value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
}

private static func durationMS(from value: String) -> Int? {
let parts = value.split(separator: ":").compactMap { Int($0)}
guard !parts.isEmpty else { return nil}
var seconds = 0
for part in parts { seconds = seconds * 60 + part}
return seconds * 1_000
}

private static func normalized(_ value: String) -> String {
value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
.unicodeScalars
.filter(CharacterSet.alphanumerics.contains)
.map { String($0)}
.joined()
}

private static let versionMarkers = [
"live", "remix", "伴奏", "dj", "cover", "翻唱", "instrumental", "karaoke", "教学", "reaction",
]

private static func matches(track: Track, title: String, author: String, durationMS: Int) -> Bool {
guard track.durationMS > 0, durationMS > 0,
abs(durationMS - track.durationMS) <= 5_000
else { return false}
let normalizedTitle = normalized(title)
let normalizedName = normalized(track.name)
guard !normalizedName.isEmpty, normalizedTitle.contains(normalizedName) else { return false}
let expectedArtist = normalized(track.artists.first?.name ?? "")
guard !expectedArtist.isEmpty,
normalizedTitle.contains(expectedArtist) || normalized(author).contains(expectedArtist)
else { return false}
let originalMarkers = Set(versionMarkers.filter { normalized(track.name).contains($0)})
let candidateMarkers = Set(versionMarkers.filter {
normalizedTitle.contains($0) || normalized(author).contains($0)
})
return candidateMarkers.isSubset(of: originalMarkers)
}
}
