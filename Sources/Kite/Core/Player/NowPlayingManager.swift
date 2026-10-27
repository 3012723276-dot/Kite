import Combine
import Foundation
import MediaPlayer

/// System Now Playing integration: media keys, Control Center, lock-screen metadata.
@MainActor
final class NowPlayingManager {
    static let shared = NowPlayingManager()

    private weak var player: PlayerService?
    private var artworkTask: Task<Void, Never>?
    private var playbackStateCancellables: Set<AnyCancellable> = []
    private var info: [String: Any] = [:]
    /// The track `info` currently describes, kept so the lock-screen
    /// lyric line can rewrite title / artist without a service round-trip.
    private var metadataTrack: Track?

    // Lock-screen lyric line timing (iOS): the freshest position handed to
    // updateElapsed, its wall-clock stamp and rate. Between position
    // updates the current position is interpolated from these, so a line
    // change is never computed from a position up to half a second old.
    private var lastElapsedValue: TimeInterval = 0
    private var lastElapsedStamp = Date()
    private var lastRate: Double = 0
    /// Signature of the last title/artist/lyrics combination pushed to
    /// the system, so the refresh timer only writes on a real change.
    private var lastPushedSignature = ""
    private var lineTimer: Timer?

    private init() {}

    func attach(to player: PlayerService) {
        self.player = player
        playbackStateCancellables.removeAll()
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak player] _ in
            guard let player, player.hasCurrentTrack else { return .noActionableNowPlayingItem }
            if !player.isPlaying { player.togglePlayPause() }
            return .success
        }
        center.pauseCommand.addTarget { [weak player] _ in
            guard let player, player.hasCurrentTrack else { return .noActionableNowPlayingItem }
            if player.isPlaying { player.togglePlayPause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak player] _ in
            guard let player, player.hasCurrentTrack else { return .noActionableNowPlayingItem }
            player.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak player] _ in
            player?.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak player] _ in
            player?.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak player] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            player?.seek(to: event.positionTime)
            return .success
        }

        // Like feedback (Control Center long-press / CarPlay; isActive = hearted)
        center.likeCommand.isEnabled = true
        center.likeCommand.localizedTitle = String(localized: "喜欢")
        center.likeCommand.localizedShortTitle = String(localized: "喜欢")
        center.likeCommand.addTarget { [weak player] _ in
            guard let track = player?.currentTrack else { return .noActionableNowPlayingItem }
            Task { @MainActor in
                await AccountStore.shared.toggleLike(trackID: track.id)
                NowPlayingManager.shared.refreshLikeState()
            }
            return .success
        }

        // NB: we deliberately do NOT register skipForward/skipBackward (±15s).
        // Enabling those commands makes iOS show "back 15s / forward 15s" on the
        // lock screen and Dynamic Island *instead of* previous/next track — a
        // podcast-style layout that's wrong for a music player and hid the
        // skip-track buttons (#83, #87). Previous/next above stay the system
        // media buttons everywhere, including CarPlay.

        // Shuffle / Repeat — backs the shuffle and repeat buttons on the CarPlay Now Playing screen.
        center.changeShuffleModeCommand.addTarget { [weak player] event in
            guard let player,
                  let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let wantOn = event.shuffleType != .off
            if player.shuffleEnabled != wantOn { player.toggleShuffle() }
            return .success
        }
        center.changeRepeatModeCommand.addTarget { [weak player] event in
            guard let player,
                  let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            // MPRepeatType: .off / .one / .all → RepeatMode: .off / .one / .all
            let target: RepeatMode? = switch event.repeatType {
                case .off:  .off
                case .one:  .one
                case .all:  .all
                default:    nil
            }
            if let target, player.repeatMode != target { player.repeatMode = target }
            return .success
        }

        #if os(macOS)
        // Shuffle is one of the queue orders on macOS (`shuffleEnabled` is
        // derived), so observe the order and map it back to on/off.
        player.$queueOrder
            .map { $0 == .shuffled }
            .removeDuplicates()
            .sink { enabled in
                center.changeShuffleModeCommand.currentShuffleType = enabled ? .items : .off
            }
            .store(in: &playbackStateCancellables)
        #else
        player.$shuffleEnabled
            .removeDuplicates()
            .sink { enabled in
                center.changeShuffleModeCommand.currentShuffleType = enabled ? .items : .off
            }
            .store(in: &playbackStateCancellables)
        #endif

        player.$repeatMode
            .removeDuplicates()
            .sink { mode in
                center.changeRepeatModeCommand.currentRepeatType = switch mode {
                case .off: .off
                case .one: .one
                case .all: .all
                }
            }
            .store(in: &playbackStateCancellables)

        // Lock-screen lyrics (0.1.7): hand the parsed lyrics to the system
        // player through the standard lyrics metadata key, so they appear
        // in the system player's lyrics page (the expanded player on the
        // lock screen and in Control Center). Lyrics load after the track
        // metadata is set, hence a subscription rather than doing this in
        // updateMetadata alone.
        player.$lyrics
            .sink { [weak self] _ in self?.refreshSystemLyrics() }
            .store(in: &playbackStateCancellables)
        player.lyricsCursor.$activeIndex
            .sink { [weak self] _ in self?.refreshSystemLyrics() }
            .store(in: &playbackStateCancellables)
        SettingsManager.shared.$lockScreenLyrics
            .sink { [weak self] _ in self?.refreshSystemLyrics() }
            .store(in: &playbackStateCancellables)

        #if os(iOS)
        // Re-derive the lock-screen lyric line five times a second from
        // the interpolated position; the write itself is signature-gated,
        // so this costs nothing while the line is unchanged.
        lineTimer?.invalidate()
        lineTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSystemLyrics() }
        }
        #endif
    }

    /// Publishes (or withdraws) the lyrics in the now-playing info,
    /// according to the 锁屏歌词 setting. Also called at the end of
    /// updateMetadata, which rebuilds `info` from scratch.
    ///
    /// On iOS this also drives the lock-screen lyric line, QQ Music style:
    /// the system card renders exactly two text lines (title / artist) and
    /// cannot be customized, so while the setting is on the title carries
    /// "Song — Artist" and the artist slot carries the current lyric line,
    /// updated as the cursor moves. Songs without lyrics keep the standard
    /// title / artist display.
    func refreshSystemLyrics() {
        refreshSystemLyrics(push: true)
    }

    private func refreshSystemLyrics(push: Bool) {
        guard !info.isEmpty else { return }
        let enabled = SettingsManager.shared.lockScreenLyrics
        if enabled, let lyrics = player?.lyrics, !lyrics.isEmpty {
            info[MPMediaItemPropertyLyrics] =
                lyrics.lines.map(\.text).joined(separator: "\n")
        } else {
            info[MPMediaItemPropertyLyrics] = nil
        }
        #if os(iOS)
        if let track = metadataTrack {
            var lyricLine: String? = nil
            if enabled, let lyrics = player?.lyrics, !lyrics.isEmpty {
                // Derive the line from the playback position, the same
                // source the immersive lyrics view uses, so the lock
                // screen cannot drift from what the app shows. (The shared
                // lyrics cursor is fed by the engine's raw timeline, which
                // lags the heard position and does not recover cleanly
                // after a seek.) The position is interpolated between the
                // service's position updates and given a slightly larger
                // lead than the in-app view's 0.2, to absorb the time the
                // system needs to render the change on the lock screen.
                let interpolated = lastElapsedValue
                    + (lastRate > 0 ? Date().timeIntervalSince(lastElapsedStamp) * lastRate : 0)
                let position = max(interpolated, player?.clock.progress ?? 0) + 0.35
                let index = lyrics.activeIndex(at: position)
                    ?? player?.lyricsCursor.activeIndex
                if let index, lyrics.lines.indices.contains(index) {
                    let text = lyrics.lines[index].text
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    lyricLine = text.isEmpty ? nil : text
                }
            }
            if let lyricLine {
                info[MPMediaItemPropertyTitle] = "\(track.name) — \(track.artistNames)"
                info[MPMediaItemPropertyArtist] = lyricLine
            } else {
                info[MPMediaItemPropertyTitle] = track.name
                info[MPMediaItemPropertyArtist] = track.artistNames
            }
        }
        #endif
        if push {
            let signature = [
                info[MPMediaItemPropertyTitle] as? String ?? "",
                info[MPMediaItemPropertyArtist] as? String ?? "",
                info[MPMediaItemPropertyLyrics] != nil ? "L" : "",
            ].joined(separator: "|")
            if signature != lastPushedSignature {
                lastPushedSignature = signature
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    /// Reflects the current track's hearted state on the like command.
    func refreshLikeState() {
        guard let track = player?.currentTrack else {
            MPRemoteCommandCenter.shared().likeCommand.isActive = false
            return
        }
        MPRemoteCommandCenter.shared().likeCommand.isActive =
            AccountStore.shared.isLiked(track.id)
    }

    func updateMetadata(for track: Track, duration: TimeInterval) {
        metadataTrack = track
        lastElapsedValue = 0
        lastElapsedStamp = Date()
        lastRate = 0
        lastPushedSignature = ""
        info = [
            MPMediaItemPropertyTitle: track.name,
            MPMediaItemPropertyArtist: track.artistNames,
            MPMediaItemPropertyAlbumTitle: track.album.name,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            // Declare the session as audio so system surfaces treat it as a
            // complete now-playing app (best-effort hardening for #36/#40).
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = .playing
        refreshLikeState()
        refreshSystemLyrics()

        artworkTask?.cancel()
        // 1024px: the lock screen's tap-to-fullscreen artwork presentation
        // needs high-resolution art to engage.
        guard let url = track.album.picUrl?.resizedImageURL(1024) else { return }
        artworkTask = Task { [weak self] in
            let apply: ImageCache.CachedImageHandler = { [weak self] image in
                guard let self, !Task.isCancelled else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = self.info
            }
            if let image = await ImageCache.shared.image(for: url, onCachedImage: apply) {
                apply(image)
            }
        }
    }

    func updateElapsed(_ elapsed: TimeInterval, rate: Double) {
        lastElapsedValue = elapsed
        lastElapsedStamp = Date()
        lastRate = rate
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        #if os(iOS)
        // Re-derive the lock-screen lyric line on every position update
        // (about twice a second while playing, and on every seek), so it
        // stays glued to the app's lyrics even if a cursor event was
        // missed. The write below publishes it together with the new
        // elapsed time.
        refreshSystemLyrics(push: false)
        #endif
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
    }

    func clear() {
        artworkTask?.cancel()
        artworkTask = nil
        info = [:]
        metadataTrack = nil
        lastPushedSignature = ""
        lastRate = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPRemoteCommandCenter.shared().likeCommand.isActive = false
    }
}
