#if os(macOS)
import AppKit
import Combine
import Foundation
import Testing
@testable import KiteCore

@MainActor
private final class ShortcutRegistryFixture: GlobalShortcutRegistry {
    var result = GlobalHotKeyRegistrationResult.registered
    var registered: [ShortcutAction] = []
    var cleared: [ShortcutAction] = []

    func registerForAction(_ action: ShortcutAction, shortcut: UserShortcut) -> GlobalHotKeyRegistrationResult {
        registered.append(action)
        return result
    }

    func unregister(action: ShortcutAction) { cleared.append(action) }
}

@Suite @MainActor
struct ShortcutSettingsTests {
    @Test func migratesLegacyBindingsIncludingExplicitlyDisabledDefaults() throws {
        let suite = "Kite-shortcuts-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let global = UserShortcut(key: "k", modifiers: [.command, .option])
        defaults.set(try JSONEncoder().encode(UserShortcut.unassigned), forKey: "settings.shortcut.nextTrack")
        defaults.set(try JSONEncoder().encode(global), forKey: "settings.globalShortcut.toggleLike")

        let registry = ShortcutRegistryFixture()
        let manager = ShortcutManager(userDefaults: defaults, hotKeys: registry)
        #expect(manager.shortcut(for: .nextTrack, isGlobal: false) == .unassigned)
        #expect(manager.shortcut(for: .toggleLike, isGlobal: true) == global)
        #expect(registry.registered == [.toggleLike])
        #expect(defaults.data(forKey: ShortcutManager.bindingsKey) != nil)
        #expect(defaults.object(forKey: "settings.shortcut.nextTrack") == nil)
        #expect(defaults.object(forKey: "settings.globalShortcut.toggleLike") == nil)
        let restored = ShortcutManager(userDefaults: defaults, hotKeys: ShortcutRegistryFixture())
        #expect(restored.appShortcuts == manager.appShortcuts)
        #expect(restored.globalShortcuts == manager.globalShortcuts)
    }

    @Test func resetPublishesOnceAndRestoresBothScopesPersistently() throws {
        let suite = "Kite-shortcuts-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ShortcutRegistryFixture()
        let manager = ShortcutManager(userDefaults: defaults, hotKeys: registry)
        try manager.clearShortcut(for: .nextTrack, isGlobal: false)
        try manager.setShortcut(UserShortcut(key: "j", modifiers: [.control]), for: .toggleLike, isGlobal: true)
        var publications = 0
        let observation = manager.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }

        try manager.resetToDefaults()
        #expect(publications == 1)
        #expect(registry.cleared == [.toggleLike])
        let restored = ShortcutManager(userDefaults: defaults, hotKeys: ShortcutRegistryFixture())
        for action in ShortcutAction.allCases {
            #expect(restored.shortcut(for: action, isGlobal: false) == action.defaultShortcut)
            #expect(restored.shortcut(for: action, isGlobal: true) == .unassigned)
        }
        try manager.resetToDefaults()
        #expect(publications == 1)
    }

    @Test func registrationFailurePreservesBindingPersistenceAndNotifications() throws {
        let suite = "Kite-shortcuts-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ShortcutRegistryFixture()
        let manager = ShortcutManager(userDefaults: defaults, hotKeys: registry)
        let original = UserShortcut(key: "k", modifiers: [.option])
        try manager.setShortcut(original, for: .toggleLike, isGlobal: true)
        let stored = defaults.data(forKey: ShortcutManager.bindingsKey)
        var publications = 0
        let observation = manager.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        registry.result = .registrationFailed

        #expect(throws: ShortcutSettingsError.registrationFailed) {
            try manager.setShortcut(UserShortcut(key: "j", modifiers: [.option]), for: .toggleLike, isGlobal: true)
        }
        #expect(manager.shortcut(for: .toggleLike, isGlobal: true) == original)
        #expect(defaults.data(forKey: ShortcutManager.bindingsKey) == stored)
        #expect(publications == 0)
        try manager.clearShortcut(for: .toggleLike, isGlobal: true)
        #expect(registry.cleared == [.toggleLike])
        #expect(manager.shortcut(for: .toggleLike, isGlobal: true) == .unassigned)
        #expect(publications == 1)
    }

    @Test func resetReplacesUnreadableStoredBindingsWhileAlreadyUsingDefaults() throws {
        let suite = "Kite-shortcuts-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let unreadable = Data("invalid shortcut data".utf8)
        defaults.set(unreadable, forKey: ShortcutManager.bindingsKey)
        let manager = ShortcutManager(userDefaults: defaults, hotKeys: ShortcutRegistryFixture())
        #expect(defaults.data(forKey: ShortcutManager.bindingsKey) == unreadable)
        var publications = 0
        let observation = manager.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }

        try manager.resetToDefaults()

        #expect(defaults.data(forKey: ShortcutManager.bindingsKey) != unreadable)
        #expect(publications == 0)
        let restored = ShortcutManager(userDefaults: defaults, hotKeys: ShortcutRegistryFixture())
        #expect(restored.appShortcuts == manager.appShortcuts)
        #expect(restored.globalShortcuts.isEmpty)
    }

    @Test func emptyKeyEventsDoNotMatchUnassignedActions() throws {
        let suite = "Kite-shortcuts-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ShortcutManager(userDefaults: defaults, hotKeys: ShortcutRegistryFixture())
        try manager.clearShortcut(for: .togglePlayPause, isGlobal: false)
        try manager.clearShortcut(for: .nextTrack, isGlobal: false)

        #expect(!manager.handleKeyEvent(try keyEvent(code: 0, key: "")))
    }

    @Test(arguments: [UInt16(51), UInt16(117)])
    func unmodifiedDeleteClearsInsteadOfRecording(code: UInt16) throws {
        let recorder = ShortcutRecorderView.RecorderNSView()
        var clears = 0
        var recorded: [String] = []
        recorder.onClear = { clears += 1 }
        recorder.onRecord = { key, _ in recorded.append(key) }

        recorder.keyDown(with: try keyEvent(code: code, key: "\u{7F}"))

        #expect(clears == 1)
        #expect(recorded.isEmpty)
    }

    @Test(arguments: [NSEvent.ModifierFlags.command, .control, .option, .shift])
    func modifiedDeleteRemainsRecordable(flags: NSEvent.ModifierFlags) throws {
        let recorder = ShortcutRecorderView.RecorderNSView()
        var clears = 0
        var recorded: [UserShortcut] = []
        recorder.onClear = { clears += 1 }
        recorder.onRecord = { key, modifiers in recorded.append(UserShortcut(key: key, modifiers: modifiers)) }

        recorder.keyDown(with: try keyEvent(code: 51, key: "\u{7F}", flags: flags))
        recorder.keyDown(with: try keyEvent(code: 117, key: "\u{F728}", flags: flags))

        #expect(clears == 0)
        #expect(recorded == [
            UserShortcut(key: "\u{7F}", modifiers: .init(nsFlags: flags)),
            UserShortcut(key: "\u{F728}", modifiers: .init(nsFlags: flags))
        ])
    }

    @Test func recordingReceivesPlaybackBindingsDeleteAndEscapeBeforeAppShortcuts() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let recorder = ShortcutRecorderView.RecorderNSView()
        window.contentView = recorder
        try #require(window.makeFirstResponder(recorder))
        var recorded: [UserShortcut] = []
        var clears = 0
        var cancellations = 0
        recorder.onRecord = { key, modifiers in recorded.append(UserShortcut(key: key, modifiers: modifiers)) }
        recorder.onClear = { clears += 1 }
        recorder.onCancel = { cancellations += 1 }

        let previousTrack = try keyEvent(code: 123, key: "\u{F702}", flags: .command,
                                         windowNumber: window.windowNumber)
        try #require(previousTrack.window === window)
        #expect(AppDelegate.interceptKeyEvent(previousTrack) == nil)
        #expect(recorded == [UserShortcut(key: "\u{F702}", modifiers: .command)])
        #expect(AppDelegate.interceptKeyEvent(try keyEvent(code: 51, key: "\u{7F}",
                                                        windowNumber: window.windowNumber)) == nil)
        #expect(clears == 1)
        #expect(AppDelegate.interceptKeyEvent(try keyEvent(code: 53, key: "\u{1B}",
                                                        windowNumber: window.windowNumber)) == nil)
        #expect(cancellations == 1)
        #expect(recorded.count == 1)
    }

    private func keyEvent(code: UInt16, key: String, flags: NSEvent.ModifierFlags = [],
                          windowNumber: Int = 0) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                            timestamp: 0, windowNumber: windowNumber, context: nil,
                                            characters: key, charactersIgnoringModifiers: key,
                                            isARepeat: false, keyCode: code))
    }
}
#endif
