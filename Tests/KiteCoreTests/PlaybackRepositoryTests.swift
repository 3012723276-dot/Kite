import Foundation
import Synchronization
import Testing
@testable import KiteCore

private struct DecodeProbe: Codable {
    @TaskLocal static var onDecode: (@Sendable () -> Void)?
    let value: String
    init(_ value: String) { self.value = value }
    init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(String.self)
        Self.onDecode?()
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}

@Suite("Playback repository snapshots")
struct PlaybackRepositoryTests {
    private func restoredSession(from repository: SyncRepository, connection: UUID) async throws -> PlaybackSession {
        let received = try await repository.readPlayback(connectionID: connection)
        let record = try #require(received.records.first)
        return try await repository.loadPlayback(record, connectionID: connection)
    }

    private func session(progress: Double = 0, count: Int = 4, accountID: Int? = 42,
                         repeatMode: String = "all") throws -> PlaybackSession {
        let tracks = try (0..<count).map {
            try JSONDecoder().decode(Track.self, from: Data("{\"id\":\($0 % 2),\"name\":\"Track \($0)\"}".utf8))
        }
        let outside = try JSONDecoder().decode(Track.self, from: Data("{\"id\":99,\"name\":\"Outside\"}".utf8))
        return PlaybackSession(accountID: accountID, queue: tracks, orderedQueue: tracks.reversed(),
                               currentIndex: count - 1, currentTrack: outside, playNext: [outside, outside],
                               source: .playlist(7), repeatMode: repeatMode, shuffled: true,
                               automaticOrder: false, isFM: false, progress: progress)
    }

    @Test func decodedCacheDetectsReplacementInPlaceEditsDeletionAndReconnect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Kite-decoded-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let connection = UUID()
        let bookmark = try await repository.connect(to: root, connectionID: connection)
        let device = UUID()
        let first = SyncRecord(revision: .init(counter: 1, deviceID: device), deviceName: "Fixture", payload: DecodeProbe("AAAA"))
        try await repository.write(first, domain: .preferences, connectionID: connection)
        let file = root.appendingPathComponent("Kite/Devices/\(device.uuidString)/preferences.json")
        let originalDate = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let counter = Mutex(0)
        try await DecodeProbe.$onDecode.withValue({ counter.withLock { $0 += 1 } }) {
            for _ in 0..<2 {
                let records = try await repository.read(.preferences, as: DecodeProbe.self, connectionID: connection)
                #expect(records.first?.payload?.value == "AAAA")
            }
            // A successful write seeds the decoded cache before presenter echoes.
            #expect(counter.withLock { $0 } == 0)
            let replacement = SyncRecord(revision: first.revision, deviceName: first.deviceName,
                                         updatedAt: first.updatedAt, payload: DecodeProbe("BBBB"))
            let bytes = try JSONEncoder().encode(replacement)
            try bytes.write(to: file, options: .atomic)
            if let originalDate { try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: file.path) }
            let replaced = try await repository.read(.preferences, as: DecodeProbe.self, connectionID: connection)
            #expect(replaced.first?.payload?.value == "BBBB")
            #expect(counter.withLock { $0 } == 1)

            let original = try JSONEncoder().encode(first)
            #expect(bytes.count == original.count)
            let handle = try FileHandle(forWritingTo: file)
            try handle.write(contentsOf: original)
            try handle.close()
            if let originalDate { try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: file.path) }
            let edited = try await repository.read(.preferences, as: DecodeProbe.self, connectionID: connection)
            #expect(edited.first?.payload?.value == "AAAA")
            #expect(counter.withLock { $0 } == 2)

            try Data("broken".utf8).write(to: file, options: .atomic)
            await #expect(throws: SyncError.self) {
                try await repository.read(.preferences, as: DecodeProbe.self, connectionID: connection)
            }
            try FileManager.default.removeItem(at: file)
            #expect(try await repository.read(.preferences, as: DecodeProbe.self, connectionID: connection).isEmpty)
            try bytes.write(to: file, options: .atomic)
            _ = try await repository.read(.preferences, as: DecodeProbe.self, connectionID: connection)
            #expect(counter.withLock { $0 } == 3)
            _ = try await repository.restore(bookmark: bookmark, connectionID: connection)
            _ = try await repository.read(.preferences, as: DecodeProbe.self, connectionID: connection)
            #expect(counter.withLock { $0 } == 4)
        }
        await repository.disconnect(connectionID: connection)
    }

    @Test(arguments: [1000, 10000])
    func progressUpdatesReuseQueueAndRestoreAllMetadata(queueSize: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Kite-progress-write-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let device = UUID()
        let first = SyncRecord(revision: .init(counter: 1, deviceID: device), deviceName: "Fixture", payload: try session(count: queueSize))
        try await repository.writePlayback(first, connectionID: connection)
        let folder = root.appendingPathComponent("Kite/Devices/\(device.uuidString)/Queues")
        let queue = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        let queueBytes = try Data(contentsOf: queue)
        let modified = try queue.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let next = try session(progress: 95, count: queueSize)
        for revision in 2...4 {
            try await repository.writePlayback(SyncRecord(revision: .init(counter: UInt64(revision), deviceID: device),
                                                           deviceName: "Fixture", payload: next), connectionID: connection)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
        #expect(try Data(contentsOf: queue) == queueBytes)
        #expect(try queue.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
        let cursor = root.appendingPathComponent("Kite/Devices/\(device.uuidString)/playback.json")
        let cursorBytes = try Data(contentsOf: cursor)
        print("Playback repository fixture: \(queueSize) tracks, queue \(queueBytes.count) bytes, checkpoint \(cursorBytes.count) bytes")
        #expect(cursorBytes.count < 2048)
        #expect(queueBytes.count > cursorBytes.count * 50)
        let object = try #require(JSONSerialization.jsonObject(with: cursorBytes) as? [String: Any])
        let payload = try #require(object["payload"] as? [String: Any])
        #expect(payload["tracks"] == nil && payload["queue"] == nil)
        #expect(try await restoredSession(from: repository, connection: connection) == next)
        await repository.disconnect(connectionID: connection)
    }

    @Test func writtenCacheKeepsPayloadTypesSeparate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Kite-cache-types-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let record = SyncRecord(revision: .init(counter: 1, deviceID: UUID()), deviceName: "Fixture", payload: DecodeProbe("AAAA"))
        try await repository.write(record, domain: .preferences, connectionID: connection)
        let counter = Mutex(0)
        try await DecodeProbe.$onDecode.withValue({ counter.withLock { $0 += 1 } }) {
            let strings = try await repository.read(.preferences, as: String.self, connectionID: connection)
            #expect(strings.first?.payload == "AAAA")
            let probes = try await repository.read(.preferences, as: DecodeProbe.self, connectionID: connection)
            #expect(probes.first?.payload?.value == "AAAA")
            #expect(counter.withLock { $0 } == 1)
        }
        await repository.disconnect(connectionID: connection)
    }

    @Test func discoveryDoesNotLoadQueuesAndSelectedSessionConvergesAfterDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Kite-pointer-order-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = SyncRepository()
        let reader = SyncRepository()
        let freshReader = SyncRepository()
        let connection = UUID()
        for repository in [writer, reader, freshReader] { _ = try await repository.connect(to: root, connectionID: connection) }
        let device = UUID()
        let old = try session(progress: 10, count: 2)
        try await writer.writePlayback(SyncRecord(revision: .init(counter: 1, deviceID: device), deviceName: "Fixture", payload: old),
                                       connectionID: connection)
        let pointer = root.appendingPathComponent("Kite/Devices/\(device.uuidString)/playback.json")
        let oldPointer = try Data(contentsOf: pointer)
        #expect(try await restoredSession(from: reader, connection: connection) == old)
        let next = try session(progress: 90, count: 8, accountID: 99)
        try await writer.writePlayback(SyncRecord(revision: .init(counter: 2, deviceID: device), deviceName: "Fixture", payload: next),
                                       connectionID: connection)
        let newPointer = try Data(contentsOf: pointer)
        let record = try JSONDecoder().decode(SyncRecord<PlaybackCheckpoint>.self, from: newPointer)
        // Queue arrives first: it cannot change the session before its pointer.
        try oldPointer.write(to: pointer, options: .atomic)
        #expect(try await restoredSession(from: reader, connection: connection) == old)
        try newPointer.write(to: pointer, options: .atomic)
        let revision = try #require(record.payload?.queueRevision)
        let queue = root.appendingPathComponent("Kite/Devices/\(device.uuidString)/Queues/\(revision.uuidString).json")
        let delayed = root.appendingPathComponent("delayed.json")
        try FileManager.default.moveItem(at: queue, to: delayed)
        let pending = try await reader.readPlayback(connectionID: connection)
        #expect(pending.records.first?.payload?.accountID == 99)
        #expect(pending.records.first?.payload?.progress == 90)
        #expect(pending.counter == 2)
        let fresh = try await freshReader.readPlayback(connectionID: connection)
        #expect(fresh.records.count == 1 && fresh.counter == 2)
        await #expect(throws: SyncError.downloading) {
            try await reader.loadPlayback(record, connectionID: connection)
        }
        try FileManager.default.moveItem(at: delayed, to: queue)
        for repository in [reader, freshReader] {
            #expect(try await restoredSession(from: repository, connection: connection) == next)
        }
        let tombstone = SyncRecord<PlaybackCheckpoint>(revision: .init(counter: 3, deviceID: device),
                                                        deviceName: "Fixture", payload: nil)
        try await writer.write(tombstone, domain: .playback, connectionID: connection)
        let withdrawn = try await reader.readPlayback(connectionID: connection)
        #expect(withdrawn.records.first?.payload == nil)
        for repository in [writer, reader, freshReader] { await repository.disconnect(connectionID: connection) }
    }

    @Test func repeatChangesOnlyRewriteCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Kite-repeat-write-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let device = UUID()
        let first = try session(count: 426)
        try await repository.writePlayback(SyncRecord(revision: .init(counter: 1, deviceID: device),
                                                       deviceName: "Fixture", payload: first), connectionID: connection)
        let folder = root.appendingPathComponent("Kite/Devices/\(device.uuidString)/Queues")
        let file = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        let bytes = try Data(contentsOf: file)
        let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect((object["payload"] as? [String: Any])?["repeatMode"] == nil)
        for revision in 2...11 {
            let mode = RepeatMode.allCases[(revision - 2) % RepeatMode.allCases.count].rawValue
            let next = try session(count: 426, repeatMode: mode)
            try await repository.writePlayback(SyncRecord(revision: .init(counter: UInt64(revision), deviceID: device),
                                                           deviceName: "Fixture", payload: next), connectionID: connection)
            #expect(try await restoredSession(from: repository, connection: connection) == next)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
        await repository.disconnect(connectionID: connection)
    }

    @Test(arguments: [false, true])
    func reconnectAndRestartReuseExistingQueue(readBeforePublishing: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Kite-reconnect-write-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let connection = UUID()
        let bookmark = try await repository.connect(to: root, connectionID: connection)
        let device = UUID()
        let original = try session(count: 426)
        try await repository.writePlayback(SyncRecord(revision: .init(counter: 1, deviceID: device),
                                                       deviceName: "Fixture", payload: original), connectionID: connection)
        let folder = root.appendingPathComponent("Kite/Devices/\(device.uuidString)/Queues")
        let file = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        let bytes = try Data(contentsOf: file)
        let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        await repository.disconnect(connectionID: connection)
        let restarted = SyncRepository()
        for (offset, writer) in [repository, restarted].enumerated() {
            _ = try await writer.restore(bookmark: bookmark, connectionID: connection)
            if readBeforePublishing { _ = try await writer.readPlayback(connectionID: connection) }
            let next = try session(progress: Double(offset + 1) * 20, count: 426, repeatMode: "one")
            try await writer.writePlayback(SyncRecord(revision: .init(counter: UInt64(offset + 2), deviceID: device),
                                                       deviceName: "Fixture", payload: next), connectionID: connection)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
            #expect(try Data(contentsOf: file) == bytes)
            #expect(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
            #expect(try await restoredSession(from: writer, connection: connection) == next)
            await writer.disconnect(connectionID: connection)
        }
        // A genuine content change still publishes a new immutable snapshot.
        _ = try await restarted.restore(bookmark: bookmark, connectionID: connection)
        try await restarted.writePlayback(SyncRecord(revision: .init(counter: 4, deviceID: device), deviceName: "Fixture",
                                                      payload: try session(count: 427)), connectionID: connection)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
        await restarted.disconnect(connectionID: connection)
    }

    @Test(arguments: [false, true])
    func missingPublishedQueueCanBeReplacedWithoutDuplicatingSubsequentWrites(changedQueue: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Kite-replace-missing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let restarted = SyncRepository()
        let connection = UUID()
        let bookmark = try await repository.connect(to: root, connectionID: connection)
        let device = UUID()
        try await repository.writePlayback(SyncRecord(revision: .init(counter: 1, deviceID: device), deviceName: "Fixture",
                                                       payload: try session()), connectionID: connection)
        let folder = root.appendingPathComponent("Kite/Devices/\(device.uuidString)/Queues")
        let pointer = folder.deletingLastPathComponent().appendingPathComponent("playback.json")
        // Cover a warm publication cache, reconnect, and a new repository instance.
        for (offset, writer) in [repository, repository, restarted].enumerated() {
            let file = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
            try FileManager.default.removeItem(at: file)
            if offset > 0 { _ = try await writer.restore(bookmark: bookmark, connectionID: connection) }
            let incomplete = try await writer.readPlayback(connectionID: connection)
            let offer = try #require(incomplete.records.first)
            await #expect(throws: SyncError.downloading) {
                try await writer.loadPlayback(offer, connectionID: connection)
            }
            let next = try session(progress: 25, count: changedQueue ? 5 + offset : 4)
            let revision = UInt64(offset * 2 + 2)
            try await writer.writePlayback(SyncRecord(revision: .init(counter: revision, deviceID: device),
                                                       deviceName: "Fixture", payload: next), connectionID: connection)
            #expect(try await restoredSession(from: writer, connection: connection) == next)
            let checkpoint = try JSONDecoder().decode(SyncRecord<PlaybackCheckpoint>.self, from: Data(contentsOf: pointer))
            let queueID = try #require(checkpoint.payload?.queueRevision)
            #expect(checkpoint.revision.counter == revision)
            #expect(queueID.uuidString != file.deletingPathExtension().lastPathComponent)
            let replacement = folder.appendingPathComponent(queueID.uuidString).appendingPathExtension("json")
            #expect(FileManager.default.fileExists(atPath: replacement.path))
            let bytes = try Data(contentsOf: replacement)
            try await writer.writePlayback(SyncRecord(revision: .init(counter: revision + 1, deviceID: device),
                                                       deviceName: "Fixture", payload: next), connectionID: connection)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
            #expect(try Data(contentsOf: replacement) == bytes)
            await writer.disconnect(connectionID: connection)
        }
    }

    @Test func missingPublishedQueueDoesNotAllowInvalidLocalSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Kite-missing-invalid-local-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let connection = UUID()
        let bookmark = try await repository.connect(to: root, connectionID: connection)
        let device = UUID()
        let value = try session()
        try await repository.writePlayback(SyncRecord(revision: .init(counter: 1, deviceID: device),
                                                       deviceName: "Fixture", payload: value), connectionID: connection)
        let folder = root.appendingPathComponent("Kite/Devices/\(device.uuidString)/Queues")
        let file = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        let pointer = folder.deletingLastPathComponent().appendingPathComponent("playback.json")
        let bytes = try Data(contentsOf: pointer)
        try FileManager.default.removeItem(at: file)
        _ = try await repository.restore(bookmark: bookmark, connectionID: connection)
        let invalid = PlaybackSession(accountID: value.accountID, queue: value.queue, orderedQueue: [], currentIndex: -1,
                                       currentTrack: value.currentTrack, playNext: [], source: value.source,
                                       repeatMode: value.repeatMode, shuffled: false, automaticOrder: false,
                                       isFM: false, progress: 0)
        await #expect(throws: SyncError.invalidRecord) {
            try await repository.writePlayback(SyncRecord(revision: .init(counter: 2, deviceID: device),
                                                           deviceName: "Fixture", payload: invalid), connectionID: connection)
        }
        #expect(try Data(contentsOf: pointer) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        await repository.disconnect(connectionID: connection)
    }

    @Test(arguments: ["queue", "pointer"])
    func reconnectDoesNotHideUnavailableOrInvalidPublishedFiles(damage: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Kite-reconnect-invalid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let connection = UUID()
        let bookmark = try await repository.connect(to: root, connectionID: connection)
        let device = UUID()
        let value = try session()
        try await repository.writePlayback(SyncRecord(revision: .init(counter: 1, deviceID: device),
                                                       deviceName: "Fixture", payload: value), connectionID: connection)
        let folder = root.appendingPathComponent("Kite/Devices/\(device.uuidString)/Queues")
        let file = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        let pointer = folder.deletingLastPathComponent().appendingPathComponent("playback.json")
        try Data("broken".utf8).write(to: damage == "queue" ? file : pointer, options: .atomic)
        let pointerBytes = try Data(contentsOf: pointer)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        _ = try await repository.restore(bookmark: bookmark, connectionID: connection)
        await #expect(throws: SyncError.invalidRecord) {
            try await repository.writePlayback(SyncRecord(revision: .init(counter: 2, deviceID: device),
                                                           deviceName: "Fixture", payload: value), connectionID: connection)
        }
        #expect(try Data(contentsOf: pointer) == pointerBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == files)
        await repository.disconnect(connectionID: connection)
    }

    @Test(arguments: ["owner", "index", "progress", "queue-reference", "repeatMode", "account"])
    func splitFilesRejectInvalidOwnershipCursorAndQueueReferences(field: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Kite-invalid-split-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let device = UUID()
        try await repository.writePlayback(SyncRecord(revision: .init(counter: 1, deviceID: device),
                                                       deviceName: "Fixture", payload: try session()), connectionID: connection)
        let pointer = root.appendingPathComponent("Kite/Devices/\(device.uuidString)/playback.json")
        let checkpoint = try JSONDecoder().decode(SyncRecord<PlaybackCheckpoint>.self, from: Data(contentsOf: pointer))
        let id = try #require(checkpoint.payload?.queueRevision)
        let file = ["owner", "queue-reference", "account"].contains(field)
            ? root.appendingPathComponent("Kite/Devices/\(device.uuidString)/Queues/\(id.uuidString).json") : pointer
        // Warm the cache before modifying a file outside the repository API.
        _ = try await restoredSession(from: repository, connection: connection)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        if field == "owner" {
            var revision = try #require(object["revision"] as? [String: Any])
            revision["deviceID"] = UUID().uuidString
            object["revision"] = revision
        } else {
            var payload = try #require(object["payload"] as? [String: Any])
            switch field {
            case "index": payload["currentIndex"] = 100
            case "progress": payload["progress"] = -1
            case "repeatMode": payload["repeatMode"] = "invalid"
            case "account": payload["accountID"] = 99
            default: payload["queue"] = [-1]
            }
            object["payload"] = payload
        }
        try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
        await #expect(throws: SyncError.self) { try await restoredSession(from: repository, connection: connection) }
        await repository.disconnect(connectionID: connection)
    }

    @Test func unrelatedBrokenQueueDoesNotBlockDiscoveryOrSelectedDevice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Kite-lazy-queues-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let devices = [UUID(), UUID()]
        let value = try session(count: 1000)
        for device in devices {
            try await repository.writePlayback(SyncRecord(revision: .init(counter: 1, deviceID: device),
                                                          deviceName: "Fixture", payload: value), connectionID: connection)
        }
        let folder = root.appendingPathComponent("Kite/Devices/\(devices[1].uuidString)/Queues")
        let file = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        try Data("broken".utf8).write(to: file, options: .atomic)
        // A fresh repository cannot satisfy discovery from a warmed queue cache.
        let reader = SyncRepository()
        _ = try await reader.connect(to: root, connectionID: connection)
        let offers = try await reader.readPlayback(connectionID: connection)
        #expect(offers.records.count == 2)
        let selected = try #require(offers.records.first { $0.id == devices[0] })
        #expect(try await reader.loadPlayback(selected, connectionID: connection) == value)
        let broken = try #require(offers.records.first { $0.id == devices[1] })
        await #expect(throws: SyncError.invalidRecord) {
            try await reader.loadPlayback(broken, connectionID: connection)
        }
        await repository.disconnect(connectionID: connection)
        await reader.disconnect(connectionID: connection)
    }

    @Test func cleanupRetainsCurrentPreviousRecentAndOtherDevicesQueues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Kite-queue-cleanup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Mutex(ContinuousClock.now)
        let repository = SyncRepository(now: { clock.withLock { $0 } })
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let device = UUID()
        let otherDevice = UUID()
        let folder = root.appendingPathComponent("Kite/Devices/\(device.uuidString)/Queues")
        for (revision, owner) in [(1, device), (2, device), (3, otherDevice)] {
            try await repository.writePlayback(SyncRecord(revision: .init(counter: UInt64(revision), deviceID: owner),
                                                           deviceName: "Fixture", payload: try session(count: revision)), connectionID: connection)
        }
        let oldFiles = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let otherFolder = root.appendingPathComponent("Kite/Devices/\(otherDevice.uuidString)/Queues")
        let other = try #require(FileManager.default.contentsOfDirectory(at: otherFolder, includingPropertiesForKeys: nil).first)
        for file in oldFiles + [other] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 24 * 60 * 60)], ofItemAtPath: file.path)
        }
        let recent = folder.appendingPathComponent("\(UUID()).json")
        try Data().write(to: recent)
        let unrelated = folder.appendingPathComponent("notes.json")
        try Data().write(to: unrelated)
        clock.withLock { $0 = $0.advanced(by: .seconds(24 * 60 * 60)) }
        try await repository.writePlayback(SyncRecord(revision: .init(counter: 4, deviceID: device), deviceName: "Fixture",
                                                       payload: try session(count: 4)), connectionID: connection)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 4)
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(try await repository.readPlayback(connectionID: connection).records.count == 2)
        await repository.disconnect(connectionID: connection)
    }

    @Test func failedQueueRemovalDoesNotBlockPublicationOrOtherFilesAndRetriesNextWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Kite-cleanup-removal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Mutex(ContinuousClock.now)
        let repository = SyncRepository(now: { clock.withLock { $0 } })
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let device = UUID()
        try await repository.writePlayback(SyncRecord(revision: .init(counter: 1, deviceID: device), deviceName: "Fixture",
                                                       payload: try session()), connectionID: connection)
        let folder = root.appendingPathComponent("Kite/Devices/\(device.uuidString)/Queues")
        let locked = folder.appendingPathComponent("\(UUID()).json")
        let removable = folder.appendingPathComponent("\(UUID()).json")
        let oldDate = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        for file in [locked, removable] {
            try Data().write(to: file)
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
        }
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
        clock.withLock { $0 = $0.advanced(by: .seconds(24 * 60 * 60)) }
        try await repository.writePlayback(SyncRecord(revision: .init(counter: 2, deviceID: device), deviceName: "Fixture",
                                                       payload: try session(progress: 10)), connectionID: connection)
        #expect(FileManager.default.fileExists(atPath: locked.path))
        #expect(!FileManager.default.fileExists(atPath: removable.path))
        #expect(try await repository.readPlayback(connectionID: connection).records.first?.payload?.progress == 10)

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path)
        // The failed pass must not advance the maintenance clock.
        try await repository.writePlayback(SyncRecord(revision: .init(counter: 3, deviceID: device), deviceName: "Fixture",
                                                       payload: try session(progress: 20)), connectionID: connection)
        #expect(!FileManager.default.fileExists(atPath: locked.path))
        // A successful retry restores the normal daily cadence.
        try Data().write(to: removable)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: removable.path)
        try await repository.writePlayback(SyncRecord(revision: .init(counter: 4, deviceID: device), deviceName: "Fixture",
                                                       payload: try session(progress: 30)), connectionID: connection)
        #expect(FileManager.default.fileExists(atPath: removable.path))
        #expect(try await repository.readPlayback(connectionID: connection).records.first?.payload?.progress == 30)
        await repository.disconnect(connectionID: connection)
    }

    @Test func unreadableMaintenanceDirectoryDoesNotFailCommittedCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Kite-cleanup-enumeration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Mutex(ContinuousClock.now)
        let repository = SyncRepository(now: { clock.withLock { $0 } })
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let device = UUID()
        try await repository.writePlayback(SyncRecord(revision: .init(counter: 1, deviceID: device), deviceName: "Fixture",
                                                       payload: try session()), connectionID: connection)
        let folder = root.appendingPathComponent("Kite/Devices/\(device.uuidString)/Queues")
        let orphan = folder.appendingPathComponent("\(UUID()).json")
        try Data().write(to: orphan)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 24 * 60 * 60)],
                                              ofItemAtPath: orphan.path)
        // Keep known file paths accessible but deny directory enumeration.
        try FileManager.default.setAttributes([.posixPermissions: 0o333], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        #expect(throws: (any Error).self) {
            try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        }
        clock.withLock { $0 = $0.advanced(by: .seconds(24 * 60 * 60)) }
        try await repository.writePlayback(SyncRecord(revision: .init(counter: 2, deviceID: device), deviceName: "Fixture",
                                                       payload: try session(progress: 10)), connectionID: connection)
        #expect(try await repository.readPlayback(connectionID: connection).records.first?.payload?.progress == 10)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try await repository.writePlayback(SyncRecord(revision: .init(counter: 3, deviceID: device), deviceName: "Fixture",
                                                       payload: try session(progress: 20)), connectionID: connection)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        await repository.disconnect(connectionID: connection)
    }

    @Test func cleanupWaitsForMaintenanceIntervalAndRunsWithoutQueueChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Kite-cleanup-cadence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Mutex(ContinuousClock.now)
        let repository = SyncRepository(now: { clock.withLock { $0 } })
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let device = UUID()
        try await repository.writePlayback(SyncRecord(revision: .init(counter: 1, deviceID: device), deviceName: "Fixture",
                                                       payload: try session()), connectionID: connection)
        let folder = root.appendingPathComponent("Kite/Devices/\(device.uuidString)/Queues")
        let orphan = folder.appendingPathComponent("\(UUID()).json")
        try Data().write(to: orphan)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 24 * 60 * 60)],
                                              ofItemAtPath: orphan.path)
        let changed = try session(count: 5)
        try await repository.writePlayback(SyncRecord(revision: .init(counter: 2, deviceID: device), deviceName: "Fixture",
                                                       payload: changed), connectionID: connection)
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        clock.withLock { $0 = $0.advanced(by: .seconds(24 * 60 * 60 - 1)) }
        try await repository.writePlayback(SyncRecord(revision: .init(counter: 3, deviceID: device), deviceName: "Fixture",
                                                       payload: changed), connectionID: connection)
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        clock.withLock { $0 = $0.advanced(by: .seconds(1)) }
        try await repository.writePlayback(SyncRecord(revision: .init(counter: 4, deviceID: device), deviceName: "Fixture",
                                                       payload: changed), connectionID: connection)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
        await repository.disconnect(connectionID: connection)
    }
}
