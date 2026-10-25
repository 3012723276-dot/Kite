import Foundation

/// Owns preference merge state and its local recovery snapshot. The observed
/// values distinguish local edits from settings applied from another device.
@MainActor
final class PreferencesSync {
    private struct LocalPreferences: Codable, Equatable {
        var mergedPreferences: SyncedPreferences
        var lastObservedValues: [String: PreferenceValue]

        private enum CodingKeys: String, CodingKey {
            case mergedPreferences = "edits"
            case lastObservedValues = "observed"
        }
    }

    private let defaults: UserDefaults
    private let settingsManager: SettingsManager
    private var localPreferences: LocalPreferences
    private var persistedPreferences: LocalPreferences?
    private var lastPublishedPreferences: SyncedPreferences?
    private var needsInitialRead = true
    private static let preferencesDefaultsKey = "sync.preferences"

    init(defaults: UserDefaults, settings: SettingsManager) {
        self.defaults = defaults
        self.settingsManager = settings
        localPreferences = LocalPreferences(mergedPreferences: SyncedPreferences(), lastObservedValues: settings.syncPreferences)
    }

    func restore() throws {
        guard let data = defaults.data(forKey: Self.preferencesDefaultsKey) else { return }
        let restoredPreferences = try JSONDecoder().decode(LocalPreferences.self, from: data)
        localPreferences = restoredPreferences
        persistedPreferences = restoredPreferences
    }

    func resetConnection() {
        lastPublishedPreferences = nil
        needsInitialRead = true
    }

    func synchronize(reading shouldReadRemote: Bool, repository: SyncRepository, connectionID: UUID, clock: SyncRevisionClock) async throws
    {
        try Task.checkCancellation()
        for edit in localPreferences.mergedPreferences.fields.values { clock.observe(edit.revision.counter) }
        try captureLocalEdits(clock: clock)
        // Local intent must survive termination while a cloud read is suspended.
        try persistLocalEdits(clock: clock)
        if shouldReadRemote || needsInitialRead {
            let records = try await repository.read(.preferences, as: SyncedPreferences.self, connectionID: connectionID)
            try Task.checkCancellation()
            for record in records {
                clock.observe(record.revision.counter)
                if let incomingPreferences = record.payload {
                    for edit in incomingPreferences.fields.values { clock.observe(edit.revision.counter) }
                }
            }
            // Settings may have changed while awaiting the repository. Stamp
            // those edits after observing remote revisions, before merging.
            try captureLocalEdits(clock: clock)
            var mergedPreferences = localPreferences.mergedPreferences
            for record in records {
                if let incomingPreferences = record.payload { mergedPreferences.merge(incomingPreferences) }
            }
            try settingsManager.applySyncPreferences(mergedPreferences)
            localPreferences.mergedPreferences = mergedPreferences
            localPreferences.lastObservedValues = settingsManager.syncPreferences
            lastPublishedPreferences = records.lazy.filter { $0.id == clock.deviceID }.max { $0.revision < $1.revision }?.payload
            needsInitialRead = false
        }
        // A new installation fills only fields absent from the remote merge.
        for (key, value) in localPreferences.lastObservedValues where localPreferences.mergedPreferences.fields[key] == nil {
            localPreferences.mergedPreferences.fields[key] = PreferenceEdit(value: value, revision: try clock.nextRevision())
        }
        try persistLocalEdits(clock: clock)
        guard localPreferences.mergedPreferences != lastPublishedPreferences else { return }
        let record = try clock.makeRecord(localPreferences.mergedPreferences)
        try await repository.write(record, domain: .preferences, connectionID: connectionID)
        try Task.checkCancellation()
        lastPublishedPreferences = record.payload
    }

    private func captureLocalEdits(clock: SyncRevisionClock) throws {
        let currentPreferences = settingsManager.syncPreferences
        guard currentPreferences != localPreferences.lastObservedValues else { return }
        for (key, value) in currentPreferences where localPreferences.lastObservedValues[key] != value {
            localPreferences.mergedPreferences.fields[key] = PreferenceEdit(value: value, revision: try clock.nextRevision())
        }
        localPreferences.lastObservedValues = currentPreferences
    }

    private func persistLocalEdits(clock: SyncRevisionClock) throws {
        if localPreferences != persistedPreferences {
            defaults.set(try JSONEncoder().encode(localPreferences), forKey: Self.preferencesDefaultsKey)
            persistedPreferences = localPreferences
        }
        clock.persistCounter()
    }
}
