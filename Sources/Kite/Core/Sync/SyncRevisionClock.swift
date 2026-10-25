import Foundation

/// Shared by domain operations within one connection. Field edits reserve
/// revisions in memory; persistence occurs at the local commit boundary.
@MainActor
final class SyncRevisionClock {
    let deviceID: UUID
    private let deviceName: String
    private let defaults: UserDefaults
    private var counter: UInt64
    private var lastPersistedCounter: UInt64
    private static let counterDefaultsKey = "sync.counter"

    init(defaults: UserDefaults, deviceID: UUID, deviceName: String) {
        self.defaults = defaults
        self.deviceID = deviceID
        self.deviceName = deviceName
        counter = (defaults.object(forKey: Self.counterDefaultsKey) as? NSNumber)?.uint64Value ?? 0
        lastPersistedCounter = counter
    }

    func observe(_ incomingCounter: UInt64) {
        counter = max(counter, incomingCounter)
    }

    func nextRevision() throws -> SyncRevision {
        let (nextCounter, didOverflow) = counter.addingReportingOverflow(1)
        guard !didOverflow else { throw SyncError.invalidRecord }
        counter = nextCounter
        return SyncRevision(counter: counter, deviceID: deviceID)
    }

    func makeRecord<T: Codable>(_ payload: T?) throws -> SyncRecord<T> {
        let revision = try nextRevision()
        persistCounter()
        return SyncRecord(revision: revision, deviceName: deviceName, payload: payload)
    }

    func persistCounter() {
        guard counter != lastPersistedCounter else { return }
        defaults.set(NSNumber(value: counter), forKey: Self.counterDefaultsKey)
        lastPersistedCounter = counter
    }
}
