import Foundation

/// A queue cursor identifies an occurrence, including duplicate songs. A separate
/// current track covers play-next entries and personal FM, outside the main queue.
struct PlaybackSession: Codable, Equatable {
    let accountID: Int?
    let queue: [Track]
    let orderedQueue: [Track]
    let currentIndex: Int
    let currentTrack: Track
    let playNext: [Track]
    let source: PlaySource
    let repeatMode: String
    let shuffled: Bool
    let automaticOrder: Bool
    let isFM: Bool
    let progress: TimeInterval

    func validate() throws {
        guard RepeatMode(rawValue: repeatMode) != nil else { throw SyncError.invalidRecord }
        try PlaybackQueueSnapshot(self).validate()
        try Self.validatePosition(currentIndex, progress: progress, count: orderedQueue.count)
    }

    static func validatePosition(_ index: Int, progress: TimeInterval, count: Int) throws {
        guard progress.isFinite, progress >= 0, index == -1 || (0..<count).contains(index)
        else { throw SyncError.invalidRecord }
    }

    func validateAccess(accountID: Int?) throws {
        try validate()
        guard let accountID, accountID > 0, self.accountID == accountID else { throw SyncError.accountMismatch }
    }
}

extension PlaybackSession {
    /// One song table serves all queue occurrences. Full Track equality keeps
    /// distinct metadata for the same song ID instead of silently replacing it.
    private struct Snapshot: Codable {
        let tracks: [Track]
        let queue: [Int]
        let orderedQueue: [Int]
        let currentTrack: Int
        let playNext: [Int]
        let accountID: Int?
        let currentIndex: Int
        let source: PlaySource
        let repeatMode: String
        let shuffled: Bool
        let automaticOrder: Bool
        let isFM: Bool
        let progress: TimeInterval
    }

    init(from decoder: Decoder) throws {
        let snapshot = try Snapshot(from: decoder)
        self.init(accountID: snapshot.accountID,
                  queue: try snapshot.queue.map { try snapshot.tracks.referencedTrack(at: $0) },
                  orderedQueue: try snapshot.orderedQueue.map { try snapshot.tracks.referencedTrack(at: $0) },
                  currentIndex: snapshot.currentIndex,
                  currentTrack: try snapshot.tracks.referencedTrack(at: snapshot.currentTrack),
                  playNext: try snapshot.playNext.map { try snapshot.tracks.referencedTrack(at: $0) },
                  source: snapshot.source, repeatMode: snapshot.repeatMode,
                  shuffled: snapshot.shuffled, automaticOrder: snapshot.automaticOrder,
                  isFM: snapshot.isFM, progress: snapshot.progress)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var table = PlaybackTrackTable()
        let queue = queue.map { table.reference(for: $0) }
        let orderedQueue = orderedQueue.map { table.reference(for: $0) }
        let currentTrack = table.reference(for: currentTrack)
        let playNext = playNext.map { table.reference(for: $0) }
        try Snapshot(tracks: table.tracks, queue: queue, orderedQueue: orderedQueue,
                     currentTrack: currentTrack, playNext: playNext, accountID: accountID,
                     currentIndex: currentIndex, source: source, repeatMode: repeatMode,
                     shuffled: shuffled, automaticOrder: automaticOrder, isFM: isFM,
                     progress: progress).encode(to: encoder)
    }
}
