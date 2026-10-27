#if os(iOS)
import ActivityKit
import Combine
import Foundation

/// Drives the lock-screen lyrics Live Activity from the player.
///
/// Attached alongside `NowPlayingManager`: it watches the current track, the
/// parsed lyrics and the shared lyrics cursor, and mirrors them into one
/// Live Activity per track. Updates happen only when the sung line changes
/// (the cursor publishes on a change), plus play/pause and track changes —
/// never on a timer — so the activity costs no background wake-ups of its
/// own. The whole feature is gated by the 锁屏歌词 setting (default on) and
/// by the system's Live Activities authorization.
@available(iOS 16.1, *)
@MainActor
final class LockScreenLyricsController {
    static let shared = LockScreenLyricsController()

    private weak var player: PlayerService?
    private var cancellables: Set<AnyCancellable> = []
    private var activity: Activity<LockScreenLyricsAttributes>?
    private var activityTrackID: Int?

    private init() {}

    func attach(to player: PlayerService) {
        self.player = player
        cancellables.removeAll()

        // Any of these changing can change what the card should show; they
        // all funnel into `sync`, which diffs before touching ActivityKit.
        player.$currentTrack
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        player.$lyrics
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        player.$isPlaying
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        player.lyricsCursor.$activeIndex
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        SettingsManager.shared.$lockScreenLyrics
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)

        sync()
    }

    // MARK: - Sync

    private func sync() {
        guard let player else { return }

        guard SettingsManager.shared.lockScreenLyrics,
              ActivityAuthorizationInfo().areActivitiesEnabled,
              let track = player.currentTrack
        else {
            endActivity()
            return
        }

        let state = contentState(for: player, track: track)

        if let activity, activityTrackID == track.id {
            // Same song: push the new line / play state into the live card.
            let stale = staleDate(for: player)
            Task { await activity.update(ActivityContent(state: state, staleDate: stale)) }
        } else {
            endActivity()
            do {
                activity = try Activity.request(
                    attributes: LockScreenLyricsAttributes(startedAt: Date()),
                    content: ActivityContent(state: state, staleDate: staleDate(for: player)),
                    pushType: nil
                )
                activityTrackID = track.id
            } catch {
                activity = nil
                activityTrackID = nil
            }
        }
    }

    private func contentState(for player: PlayerService, track: Track) -> LockScreenLyricsAttributes.ContentState {
        var line = ""
        var nextLine = ""
        if let lyrics = player.lyrics, let index = player.lyricsCursor.activeIndex,
           lyrics.lines.indices.contains(index) {
            line = lyrics.lines[index].text
            if lyrics.lines.indices.contains(index + 1) {
                nextLine = lyrics.lines[index + 1].text
            }
        }
        return LockScreenLyricsAttributes.ContentState(
            trackTitle: track.name,
            artist: track.artistNames,
            line: line,
            nextLine: nextLine,
            isPlaying: player.isPlaying
        )
    }

    /// The card goes stale when the current line ends, so the system can
    /// dim it if the app is suspended and the next update never arrives.
    private func staleDate(for player: PlayerService) -> Date? {
        guard player.isPlaying,
              let lyrics = player.lyrics,
              let index = player.lyricsCursor.activeIndex,
              lyrics.lines.indices.contains(index)
        else { return nil }
        let lineEnd = lyrics.lines.indices.contains(index + 1)
            ? lyrics.lines[index + 1].start
            : player.duration
        let remaining = lineEnd - player.clock.progress
        guard remaining > 0 else { return nil }
        return Date().addingTimeInterval(remaining)
    }

    private func endActivity() {
        guard let activity else { return }
        self.activity = nil
        activityTrackID = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif
