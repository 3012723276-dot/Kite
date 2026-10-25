import Foundation

/// Queue metadata changes independently of the playhead. Each published snapshot
/// is immutable and is named by the checkpoint's queue revision.
struct PlaybackQueueSnapshot: Codable, Equatable {
    let accountID: Int?
    let queue: [Track]
    let orderedQueue: [Track]
    let playNext: [Track]
    let source: PlaySource
    let shuffled: Bool
    let automaticOrder: Bool
    let isFM: Bool

    init(_ session: PlaybackSession) {
        accountID = session.accountID
        queue = session.queue
        orderedQueue = session.orderedQueue
        playNext = session.playNext
        source = session.source
        shuffled = session.shuffled
        automaticOrder = session.automaticOrder
        isFM = session.isFM
    }

    func validate() throws {
        guard !(shuffled && automaticOrder), queue.count == orderedQueue.count else { throw SyncError.invalidRecord }
        var occurrences: [Int: Int] = [:]
        for track in queue { occurrences[track.id, default: 0] += 1 }
        for track in orderedQueue {
            guard let count = occurrences[track.id], count > 0 else { throw SyncError.invalidRecord }
            occurrences[track.id] = count - 1
        }
    }

    private enum CodingKeys: String, CodingKey {
        case tracks, queue, orderedQueue, playNext, accountID, source, shuffled, automaticOrder, isFM
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tracks = try c.decode([Track].self, forKey: .tracks)
        func referencedTracks(_ key: CodingKeys) throws -> [Track] {
            try c.decode([Int].self, forKey: key).map { try tracks.referencedTrack(at: $0) }
        }
        queue = try referencedTracks(.queue)
        orderedQueue = try referencedTracks(.orderedQueue)
        playNext = try referencedTracks(.playNext)
        accountID = try c.decodeIfPresent(Int.self, forKey: .accountID)
        source = try c.decode(PlaySource.self, forKey: .source)
        shuffled = try c.decode(Bool.self, forKey: .shuffled)
        automaticOrder = try c.decode(Bool.self, forKey: .automaticOrder)
        isFM = try c.decode(Bool.self, forKey: .isFM)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var table = PlaybackTrackTable()
        let queue = queue.map { table.reference(for: $0) }
        let order = orderedQueue.map { table.reference(for: $0) }
        let next = playNext.map { table.reference(for: $0) }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(table.tracks, forKey: .tracks)
        try c.encode(queue, forKey: .queue)
        try c.encode(order, forKey: .orderedQueue)
        try c.encode(next, forKey: .playNext)
        try c.encodeIfPresent(accountID, forKey: .accountID)
        try c.encode(source, forKey: .source)
        try c.encode(shuffled, forKey: .shuffled)
        try c.encode(automaticOrder, forKey: .automaticOrder)
        try c.encode(isFM, forKey: .isFM)
    }
}

struct PlaybackCheckpoint: Codable {
    let accountID: Int?
    let queueRevision: UUID
    let currentIndex: Int
    // A play-next or FM song need not be present in the published queue.
    let currentTrack: Track
    let progress: TimeInterval
    let repeatMode: String

    init(_ session: PlaybackSession, queueRevision: UUID) {
        accountID = session.accountID
        self.queueRevision = queueRevision
        currentIndex = session.currentIndex
        currentTrack = session.currentTrack
        progress = session.progress
        repeatMode = session.repeatMode
    }

    func validate() throws {
        guard progress.isFinite, progress >= 0, currentIndex >= -1,
              RepeatMode(rawValue: repeatMode) != nil,
              accountID.map({ $0 > 0 }) ?? true else { throw SyncError.invalidRecord }
    }

    /// The queue was validated at its serialization boundary. Only the cursor
    /// depends on both files; do not revalidate a large queue on each heartbeat.
    func session(using queue: PlaybackQueueSnapshot) throws -> PlaybackSession {
        try validate()
        guard accountID == queue.accountID else { throw SyncError.invalidRecord }
        try PlaybackSession.validatePosition(currentIndex, progress: progress, count: queue.orderedQueue.count)
        return PlaybackSession(accountID: queue.accountID, queue: queue.queue, orderedQueue: queue.orderedQueue,
                               currentIndex: currentIndex, currentTrack: currentTrack, playNext: queue.playNext,
                               source: queue.source, repeatMode: repeatMode, shuffled: queue.shuffled,
                               automaticOrder: queue.automaticOrder, isFM: queue.isFM, progress: progress)
    }
}

struct PlaybackTrackTable {
    private(set) var tracks: [Track] = []
    private var references: [Track: Int] = [:]

    mutating func reference(for track: Track) -> Int {
        if let index = references[track] { return index }
        let index = tracks.count
        references[track] = index
        tracks.append(track)
        return index
    }
}

extension Array where Element == Track {
    func referencedTrack(at index: Int) throws -> Track {
        guard indices.contains(index) else { throw SyncError.invalidRecord }
        return self[index]
    }
}
