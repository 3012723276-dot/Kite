import Combine
import Foundation

enum PreferenceValue: Codable, Equatable {
    case string(String), boolean(Bool), number(Double), strings([String])
}

struct PreferenceEdit: Codable, Equatable {
    let value: PreferenceValue
    let revision: SyncRevision
}

struct SyncedPreferences: Codable, Equatable {
    var fields: [String: PreferenceEdit] = [:]

    mutating func merge(_ other: Self) {
        fields.merge(other.fields) { local, remote in
            local.revision < remote.revision ? remote : local
        }
    }
}

extension SettingsManager {
    /// Keep the portable preference contract beside its projection and validation.
    var syncPreferenceChanges: AnyPublisher<Void, Never> {
        Publishers.MergeMany([
            $audioQuality.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $appearance.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $showLyricsTranslation.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $lyricsAnnotation.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $verbatimLyrics.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $enableUnblock.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $enabledAudioSourceIDs.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $showMainWindowAmbientBackground.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $mainWindowAmbientBackgroundIntensity.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        ]).eraseToAnyPublisher()
    }

    /// Explicit portable preferences; cache policy, output routing and platform
    /// layouts stay local. Unknown fields remain in SyncedPreferences for newer apps.
    var syncPreferences: [String: PreferenceValue] {
        [Keys.quality: .string(audioQuality.rawValue),
         Keys.appearance: .string(appearance.rawValue),
         Keys.showTranslation: .boolean(showLyricsTranslation),
         Keys.annotation: .string(lyricsAnnotation.rawValue),
         Keys.verbatimLyrics: .boolean(verbatimLyrics),
         Keys.unblock: .boolean(enableUnblock),
         Keys.unblockSources: .strings(enabledAudioSourceIDs.map(\.rawValue).sorted()),
         Keys.mainWindowAmbientBackground: .boolean(showMainWindowAmbientBackground),
         Keys.mainWindowAmbientBackgroundIntensity: .number(mainWindowAmbientBackgroundIntensity)]
    }

    func applySyncPreferences(_ preferences: SyncedPreferences) throws {
        // Validate the entire known projection before any setter runs its side effects.
        for (key, edit) in preferences.fields {
            switch (key, edit.value) {
            case (Keys.quality, .string(let value)):
                guard AudioQuality(rawValue: value) != nil else { throw SyncError.invalidRecord }
            case (Keys.appearance, .string(let value)):
                guard AppAppearance(rawValue: value) != nil else { throw SyncError.invalidRecord }
            case (Keys.annotation, .string(let value)):
                guard LyricsAnnotation(rawValue: value) != nil else { throw SyncError.invalidRecord }
            case (Keys.mainWindowAmbientBackgroundIntensity, .number(let value)):
                guard value.isFinite, Self.mainWindowAmbientBackgroundIntensityRange.contains(value) else {
                    throw SyncError.invalidRecord
                }
            case (Keys.showTranslation, .boolean), (Keys.verbatimLyrics, .boolean),
                 (Keys.unblock, .boolean), (Keys.mainWindowAmbientBackground, .boolean),
                 (Keys.unblockSources, .strings): break
            case (Keys.quality, _), (Keys.appearance, _), (Keys.annotation, _),
                 (Keys.mainWindowAmbientBackgroundIntensity, _), (Keys.showTranslation, _),
                 (Keys.verbatimLyrics, _), (Keys.unblock, _),
                 (Keys.mainWindowAmbientBackground, _), (Keys.unblockSources, _):
                throw SyncError.invalidRecord
            default: break
            }
        }
        let current = syncPreferences
        for (key, edit) in preferences.fields where current[key] != edit.value {
            switch (key, edit.value) {
            case (Keys.quality, .string(let value)):
                if let quality = AudioQuality(rawValue: value) { audioQuality = quality }
            case (Keys.appearance, .string(let value)):
                if let theme = AppAppearance(rawValue: value) { appearance = theme }
            case (Keys.annotation, .string(let value)):
                if let annotation = LyricsAnnotation(rawValue: value) { lyricsAnnotation = annotation }
            case (Keys.showTranslation, .boolean(let value)): showLyricsTranslation = value
            case (Keys.verbatimLyrics, .boolean(let value)): verbatimLyrics = value
            case (Keys.unblock, .boolean(let value)): enableUnblock = value
            case (Keys.mainWindowAmbientBackground, .boolean(let value)): showMainWindowAmbientBackground = value
            case (Keys.mainWindowAmbientBackgroundIntensity, .number(let value)): mainWindowAmbientBackgroundIntensity = value
            case (Keys.unblockSources, .strings(let value)):
                enabledAudioSourceIDs = Set(value.compactMap(AudioSourceID.init(rawValue:)))
            default: break
            }
        }
    }
}
