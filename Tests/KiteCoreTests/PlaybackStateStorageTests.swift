import Foundation
import Synchronization
import Testing
@testable import KiteCore

private struct CheckpointWriteProbe: Encodable {
    let value: Int
    let onEncode: (Int) -> Void

    func encode(to encoder: Encoder) throws {
        onEncode(value)
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

@Suite("Local playback checkpoints")
struct PlaybackStateStorageTests {
    @Test(arguments: [false, true])
    func currentStateRoundTripsWithoutLegacyQueue(hasSession: Bool) throws {
        let track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1}".utf8))
        let session = PlaybackSession(accountID: 42, queue: [track, track], orderedQueue: [track, track],
                                      currentIndex: 1, currentTrack: track, playNext: [track], source: .playlist(7),
                                      repeatMode: "all", shuffled: true, automaticOrder: false,
                                      isFM: false, progress: 95.5)
        let contexts = [PlayContext.playlist(id: 7, name: "Recent playlist")]
        let state = PlaybackState(session: hasSession ? session : nil, recentContexts: contexts)
        let data = try JSONEncoder().encode(state)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["queue"] == nil)
        #expect(object["currentID"] == nil)
        #expect(object["repeatMode"] == nil)
        #expect(object["shuffle"] == nil)
        #expect(object["queueOrder"] == nil)
        let restored = try JSONDecoder().decode(PlaybackState.self, from: data)
        #expect(restored.session == state.session)
        #expect(restored.recentContexts == contexts)
        #expect(restored.legacy == nil)

        if hasSession {
            // Older development files carried both forms. Only the session is
            // authoritative, even if its obsolete queue cannot be decoded.
            var combined = object
            combined["queue"] = "obsolete"
            let combinedData = try JSONSerialization.data(withJSONObject: combined)
            let combinedState = try JSONDecoder().decode(PlaybackState.self, from: combinedData)
            #expect(combinedState.session == session)
            #expect(combinedState.legacy == nil)
        }
    }

    @Test func preSessionStateStillRestoresQueueAndRecents() throws {
        let data = Data(#"{"queue":[{"id":1},{"id":2}],"currentID":2,"repeatMode":"all","shuffle":true,"recentContexts":[{"kind":"playlist","id":7,"name":"Recent playlist"}]}"#.utf8)
        let restored = try JSONDecoder().decode(PlaybackState.self, from: data)
        #expect(restored.session == nil)
        let legacy = try #require(restored.legacy)
        #expect(legacy.queue.map(\.id) == [1, 2])
        #expect(legacy.currentID == 2)
        #expect(legacy.shuffle)
        #expect(legacy.queueOrder == nil)
        #expect(restored.recentContexts == [.playlist(id: 7, name: "Recent playlist")])
    }

    @Test func terminationFlushRetainsTheLastEnqueuedPlaybackPosition() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Kite-checkpoint-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("player-state.json")
        let track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1}".utf8))
        // Track start, periodic saves, then a final pause/seek checkpoint.
        for progress in [0.0, 20, 40, 60, 95.5] {
            let session = PlaybackSession(accountID: nil, queue: [track], orderedQueue: [track],
                                          currentIndex: 0, currentTrack: track, playNext: [], source: .none,
                                          repeatMode: "off", shuffled: false, automaticOrder: false,
                                          isFM: false, progress: progress)
            PlaybackStateStorage.save(session, to: file)
        }
        PlaybackStateStorage.flush()
        let restored = try JSONDecoder().decode(PlaybackSession.self, from: Data(contentsOf: file))
        #expect(restored.progress == 95.5)
        #expect(restored.accountID == nil)
        #expect(restored.currentTrack == track)
    }

    @Test func pendingSnapshotsCoalesceWhileAnOlderWriteIsInFlight() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Kite-checkpoint-coalesce-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("player-state.json")
        let other = root.appendingPathComponent("other-state.json")
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let encoded = Mutex<[Int]>([])
        PlaybackStateStorage.save(CheckpointWriteProbe(value: 0, onEncode: { value in
            encoded.withLock { $0.append(value) }
            started.signal()
            release.wait()
        }), to: file)
        try #require(started.wait(timeout: .now() + 5) == .success)
        for value in 1...1000 {
            PlaybackStateStorage.save(CheckpointWriteProbe(value: value, onEncode: { value in
                encoded.withLock { $0.append(value) }
            }), to: file)
        }
        PlaybackStateStorage.save(7, to: other)
        release.signal()
        PlaybackStateStorage.flush()
        #expect(encoded.withLock { $0 } == [0, 1000])
        #expect(try JSONDecoder().decode(Int.self, from: Data(contentsOf: file)) == 1000)
        #expect(try JSONDecoder().decode(Int.self, from: Data(contentsOf: other)) == 7)
    }
}
