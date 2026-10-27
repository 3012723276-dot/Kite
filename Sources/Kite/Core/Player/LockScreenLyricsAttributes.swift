#if os(iOS)
import ActivityKit
import Foundation

/// Live Activity attributes for the lock-screen lyrics card.
///
/// This file is compiled into BOTH the app (via the Kite package) and the
/// KiteLyricsWidget extension (which lists this file in its own sources):
/// ActivityKit pairs an activity with its UI by the attributes type, so the
/// two targets must share one definition. Keep it free of app dependencies —
/// ActivityKit + Foundation only — or the extension stops compiling.
///
/// The dynamic payload stays tiny on purpose: ActivityKit caps a content
/// state at roughly 4 KB, so there is no artwork here, just text.
@available(iOS 16.1, *)
struct LockScreenLyricsAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var trackTitle: String
        var artist: String
        /// The lyric line being sung right now ("" when the song has none).
        var line: String
        /// The following line, shown dimmed as a preview.
        var nextLine: String
        var isPlaying: Bool
    }

    /// One activity per playback session; a new track replaces the activity
    /// rather than reusing it, so the system never shows stale song info.
    var startedAt: Date
}
#endif
