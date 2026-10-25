#if os(macOS)
import SwiftUI
import AppKit
import OSLog

public struct UserShortcut: Codable, Equatable {
    static let unassigned = UserShortcut(key: "", modifiers: [])
    public var key: String
    public var modifiers: ShortcutModifiers

    public struct ShortcutModifiers: OptionSet, Codable, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = ShortcutModifiers(rawValue: 1 << 0)
        public static let shift   = ShortcutModifiers(rawValue: 1 << 1)
        public static let option  = ShortcutModifiers(rawValue: 1 << 2)
        public static let control = ShortcutModifiers(rawValue: 1 << 3)

        public var eventModifiers: EventModifiers {
            var flags: EventModifiers = []
            if contains(.command) { flags.insert(.command) }
            if contains(.shift) { flags.insert(.shift) }
            if contains(.option) { flags.insert(.option) }
            if contains(.control) { flags.insert(.control) }
            return flags
        }

        public var nsModifierFlags: NSEvent.ModifierFlags {
            var flags: NSEvent.ModifierFlags = []
            if contains(.command) { flags.insert(.command) }
            if contains(.shift) { flags.insert(.shift) }
            if contains(.option) { flags.insert(.option) }
            if contains(.control) { flags.insert(.control) }
            return flags
        }

        public init(nsFlags: NSEvent.ModifierFlags) {
            var flags: ShortcutModifiers = []
            if nsFlags.contains(.command) { flags.insert(.command) }
            if nsFlags.contains(.shift) { flags.insert(.shift) }
            if nsFlags.contains(.option) { flags.insert(.option) }
            if nsFlags.contains(.control) { flags.insert(.control) }
            self = flags
        }
    }

    public var keyboardShortcut: KeyboardShortcut? {
        guard !key.isEmpty else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character(key)), modifiers: modifiers.eventModifiers)
    }

    public var displayString: String {
        if key.isEmpty { return String(localized: "无") }
        var str = ""
        if modifiers.contains(.control) { str += "⌃" }
        if modifiers.contains(.option) { str += "⌥" }
        if modifiers.contains(.shift) { str += "⇧" }
        if modifiers.contains(.command) { str += "⌘" }
        
        switch key {
        case " ": str += "Space"
        case "\u{F703}": str += "→"
        case "\u{F702}": str += "←"
        case "\u{F700}": str += "↑"
        case "\u{F701}": str += "↓"
        case "\u{1B}": str += "⎋"
        case "\u{F704}": str += "F1"
        case "\u{F705}": str += "F2"
        case "\u{F706}": str += "F3"
        case "\u{F707}": str += "F4"
        case "\u{F708}": str += "F5"
        case "\u{F709}": str += "F6"
        case "\u{F70A}": str += "F7"
        case "\u{F70B}": str += "F8"
        case "\u{F70C}": str += "F9"
        case "\u{F70D}": str += "F10"
        case "\u{F70E}": str += "F11"
        case "\u{F70F}": str += "F12"
        case "\r": str += "↩"
        case "\u{7F}": str += "⌫"
        default: str += key.uppercased()
        }
        return str
    }
}

public enum ShortcutAction: String, Codable, CaseIterable, Identifiable, Hashable {
    case togglePlayPause
    case nextTrack
    case previousTrack
    case cycleQueueOrder
    case cycleRepeatMode
    case toggleLike
    case toggleLyrics
    case toggleQueue
    case closeImmersive
    case volumeUp
    case volumeDown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .togglePlayPause: return String(localized: "播放 / 暂停")
        case .nextTrack: return String(localized: "下一首")
        case .previousTrack: return String(localized: "上一首")
        case .cycleQueueOrder: return String(localized: "播放顺序")
        case .cycleRepeatMode: return String(localized: "循环模式")
        case .toggleLike: return String(localized: "喜欢")
        case .toggleLyrics: return String(localized: "歌词")
        case .toggleQueue: return String(localized: "播放队列")
        case .closeImmersive: return String(localized: "关闭播放页")
        case .volumeUp: return String(localized: "增加音量")
        case .volumeDown: return String(localized: "减少音量")
        }
    }

    public var defaultShortcut: UserShortcut {
        switch self {
        case .togglePlayPause: return UserShortcut(key: " ", modifiers: [])
        case .nextTrack: return UserShortcut(key: "\u{F703}", modifiers: [.command])
        case .previousTrack: return UserShortcut(key: "\u{F702}", modifiers: [.command])
        case .cycleQueueOrder: return UserShortcut(key: "s", modifiers: [.command, .shift])
        case .cycleRepeatMode: return UserShortcut(key: "r", modifiers: [.command, .shift])
        case .toggleLike: return UserShortcut(key: "l", modifiers: [.command, .shift])
        case .toggleLyrics: return UserShortcut(key: "l", modifiers: [.command])
        case .toggleQueue: return UserShortcut(key: "u", modifiers: [.command])
        case .closeImmersive: return UserShortcut(key: "", modifiers: [])
        case .volumeUp: return UserShortcut(key: "\u{F700}", modifiers: [.command])
        case .volumeDown: return UserShortcut(key: "\u{F701}", modifiers: [.command])
        }
    }
}

// MARK: - Global shortcut registration

@MainActor
protocol GlobalShortcutRegistry {
    func registerForAction(_ action: ShortcutAction, shortcut: UserShortcut) -> GlobalHotKeyRegistrationResult
    func unregister(action: ShortcutAction)
}

extension GlobalHotKeyManager: GlobalShortcutRegistry {}

private struct ShortcutBindings: Codable, Equatable {
    var app: [ShortcutAction: UserShortcut]
    var global: [ShortcutAction: UserShortcut]

    static var defaults: Self {
        // Global hotkeys are opt-in; resetting must not claim system-wide key combinations.
        Self(app: Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) }), global: [:])
    }
}

enum ShortcutSettingsError: LocalizedError, Equatable {
    case invalidShortcut, registrationFailed

    var errorDescription: String? {
        switch self {
        case .invalidShortcut: String(localized: "此组合无法用作全局快捷键")
        case .registrationFailed: String(localized: "快捷键不可用，原设置已保留")
        }
    }
}

@MainActor
final class ShortcutManager: ObservableObject {
    static let shared = ShortcutManager(userDefaults: .standard, hotKeys: GlobalHotKeyManager.shared)
    
    @Published private var bindings = ShortcutBindings.defaults
    var appShortcuts: [ShortcutAction: UserShortcut] { bindings.app }
    var globalShortcuts: [ShortcutAction: UserShortcut] { bindings.global }
    
    private let userDefaults: UserDefaults
    private let hotKeys: any GlobalShortcutRegistry
    private let logger = Logger(subsystem: "Kite", category: "Shortcuts")
    static let bindingsKey = "settings.shortcuts"
    private let appPrefix = "settings.shortcut."
    private let globalPrefix = "settings.globalShortcut."
    
    init(userDefaults: UserDefaults, hotKeys: any GlobalShortcutRegistry) {
        self.userDefaults = userDefaults
        self.hotKeys = hotKeys
        loadShortcuts()
    }
    
    private func loadShortcuts() {
        do {
            if let data = userDefaults.data(forKey: Self.bindingsKey) {
                bindings = try JSONDecoder().decode(ShortcutBindings.self, from: data)
            } else {
                var migrated = ShortcutBindings.defaults
                for action in ShortcutAction.allCases {
                    if let data = userDefaults.data(forKey: appPrefix + action.rawValue) {
                        migrated.app[action] = try JSONDecoder().decode(UserShortcut.self, from: data)
                    }
                    if let data = userDefaults.data(forKey: globalPrefix + action.rawValue) {
                        migrated.global[action] = try JSONDecoder().decode(UserShortcut.self, from: data)
                    }
                }
                let data = try JSONEncoder().encode(migrated)
                userDefaults.set(data, forKey: Self.bindingsKey)
                bindings = migrated
                for action in ShortcutAction.allCases {
                    userDefaults.removeObject(forKey: appPrefix + action.rawValue)
                    userDefaults.removeObject(forKey: globalPrefix + action.rawValue)
                }
            }
        } catch {
            // Retain unreadable stored data; defaults keep the app usable until the user replaces it.
            logger.error("Cannot load shortcuts: \(error.localizedDescription)")
            ToastCenter.shared.show(String(localized: "无法读取快捷键，暂用默认设置"))
        }
        for (action, shortcut) in globalShortcuts where !shortcut.key.isEmpty {
            switch hotKeys.registerForAction(action, shortcut: shortcut) {
            case .registered: break
            case .invalidShortcut, .registrationFailed:
                logger.error("Cannot restore global shortcut for \(action.rawValue)")
                ToastCenter.shared.show(String(localized: "全局快捷键未能启用"))
            }
        }
    }
    
    /// 设置快捷键，采用"先注册新快捷键，成功后再替换旧快捷键"策略。
    /// 若系统注册失败，UserDefaults 不会被修改，原有快捷键保持不变。
    func setShortcut(_ shortcut: UserShortcut, for action: ShortcutAction, isGlobal: Bool) throws {
        guard shortcut != self.shortcut(for: action, isGlobal: isGlobal) else { return }
        var updated = bindings
        if isGlobal { updated.global[action] = shortcut }
        else { updated.app[action] = shortcut }
        let data = try JSONEncoder().encode(updated)

        if isGlobal {
            if shortcut.key.isEmpty {
                hotKeys.unregister(action: action)
            } else {
                switch hotKeys.registerForAction(action, shortcut: shortcut) {
                case .registered: break
                case .invalidShortcut: throw ShortcutSettingsError.invalidShortcut
                case .registrationFailed: throw ShortcutSettingsError.registrationFailed
                }
            }
        }
        userDefaults.set(data, forKey: Self.bindingsKey)
        bindings = updated
    }

    func clearShortcut(for action: ShortcutAction, isGlobal: Bool) throws {
        try setShortcut(.unassigned, for: action, isGlobal: isGlobal)
    }

    func resetToDefaults() throws {
        let defaults = ShortcutBindings.defaults
        let data = try JSONEncoder().encode(defaults)
        for (action, shortcut) in globalShortcuts where !shortcut.key.isEmpty {
            hotKeys.unregister(action: action)
        }
        userDefaults.set(data, forKey: Self.bindingsKey)
        if bindings != defaults { bindings = defaults }
    }
    
    func shortcut(for action: ShortcutAction, isGlobal: Bool) -> UserShortcut {
        if isGlobal {
            return globalShortcuts[action] ?? .unassigned
        } else {
            return appShortcuts[action] ?? action.defaultShortcut
        }
    }
    
    // MARK: - App-internal Key Event Matching (local monitor only)
    // Global hotkeys are handled by GlobalHotKeyManager via Carbon Event Hot Key API.
    
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        let currentModifiers = UserShortcut.ShortcutModifiers(nsFlags: event.modifierFlags)
        
        // We handle some keys only if not editing text
        let editingText = NSApp.keyWindow?.firstResponder is NSText
            || NSApp.keyWindow?.firstResponder is NSTextView
        
        // Match against registered app shortcuts only
        for (action, shortcut) in appShortcuts where !shortcut.key.isEmpty {
            if editingText {
                if shortcut.modifiers.isEmpty || (!shortcut.modifiers.contains(.command) && !shortcut.modifiers.contains(.control)) {
                    continue
                }
            }
            
            if event.charactersIgnoringModifiers == shortcut.key && currentModifiers == shortcut.modifiers {
                executeAction(action)
                return true
            }
        }
        
        return false
    }
    
    func executeAction(_ action: ShortcutAction) {
        Task { @MainActor in
            let player = PlayerService.shared
            switch action {
            case .togglePlayPause:
                player.togglePlayPause()
            case .nextTrack:
                player.next()
            case .previousTrack:
                player.previous()
            case .cycleQueueOrder:
                player.cycleQueueOrder()
            case .cycleRepeatMode:
                player.cycleRepeatMode()
            case .toggleLike:
                if let track = player.currentTrack {
                    await AccountStore.shared.toggleLike(trackID: track.id)
                }
            case .toggleLyrics:
                player.activePanel = player.activePanel == .lyrics ? nil : .lyrics
            case .toggleQueue:
                player.activePanel = player.activePanel == .queue ? nil : .queue
            case .closeImmersive:
                if player.showNowPlaying {
                    player.showNowPlaying = false
                }
            case .volumeUp:
                player.volume = min(player.volume + 0.1, 1.0)
            case .volumeDown:
                player.volume = max(player.volume - 0.1, 0.0)
            }
        }
    }
}
#endif
