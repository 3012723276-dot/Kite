#if os(macOS)
import Carbon
import AppKit
import OSLog

// MARK: - HotKeyModifier

/// 统一的修饰符定义，映射到 Carbon 的底层常量
public struct HotKeyModifier: OptionSet {
    public let rawValue: UInt32
    
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    
    public static let command = HotKeyModifier(rawValue: UInt32(cmdKey))
    public static let option  = HotKeyModifier(rawValue: UInt32(optionKey))
    public static let control = HotKeyModifier(rawValue: UInt32(controlKey))
    public static let shift   = HotKeyModifier(rawValue: UInt32(shiftKey))
    
    var carbonModifiers: UInt32 { rawValue }
}

// MARK: - Error Types

public enum GlobalHotKeyError: Error, LocalizedError {
    case invalidShortcut
    case registrationFailed(OSStatus)
    case handlerInstallFailed(OSStatus)
    
    public var errorDescription: String? {
        switch self {
        case .invalidShortcut:
            return "Invalid shortcut configuration"
        case .registrationFailed(let status):
            return "Failed to register global shortcut: \(describeOSStatus(status))"
        case .handlerInstallFailed(let status):
            return "Failed to install event handler: \(describeOSStatus(status))"
        }
    }
}

// MARK: - OSStatus Description

func describeOSStatus(_ status: OSStatus) -> String {
    switch status {
    case noErr:
        return "noErr (0)"
    default:
        if status >= 0 && status < 128 {
            let scalar = Unicode.Scalar(UInt8(status))
            let c = Character(scalar)
            if c.isASCII {
                return "OSStatus(\(status)) '\(c)'\(c)\(c)\(c)"
            }
        }
        return "OSStatus(\(status))"
    }
}

// MARK: - macOS Virtual Key Code Map

/// macOS Carbon virtual key codes (physical key positions), NOT ASCII values.
private let macosKeyCodeMap: [String: UInt32] = [
    // Letters (QWERTY physical positions)
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
    "z": 6, "x": 7, "c": 8, "v": 9,  "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
    "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
    "o": 31, "u": 32, "i": 34, "p": 35,
    "l": 37, "j": 38, "'": 39,
    "k": 40, ";": 41, "\\": 43, ",": 44,
    "n": 45, "m": 46, ".": 47,
    // Special keys
    " ": 49,          // Space
    "\t": 48,        // Tab
    "\r": 36,        // Return
    "\u{1B}": 53,    // Escape
    "\u{7F}": 51,    // Delete
    // Function keys
    "\u{F704}": 122, // F1
    "\u{F705}": 96,  // F2
    "\u{F706}": 97,  // F3
    "\u{F707}": 98,  // F4
    "\u{F708}": 100, // F5
    "\u{F709}": 101, // F6
    "\u{F70A}": 109, // F7
    "\u{F70B}": 103, // F8
    "\u{F70C}": 111, // F9
    "\u{F70D}": 105, // F10
    "\u{F70E}": 107, // F11
    "\u{F70F}": 113, // F12
    // Arrow keys
    "\u{F700}": 126, // Up
    "\u{F701}": 125, // Down
    "\u{F702}": 123, // Left
    "\u{F703}": 124, // Right
]

/// 将 UserShortcut 的 key 字符串转换为 Carbon 物理 keyCode
func resolveKeyCode(_ key: String) -> UInt32? {
    guard !key.isEmpty else { return nil }
    if let code = macosKeyCodeMap[key] { return code }
    guard let first = key.first else { return nil }
    let lower = String(first).lowercased()
    return macosKeyCodeMap[lower]
}

/// 将 UserShortcut 的 modifiers 转换为 Carbon modifier 常量
func resolveCarbonModifiers(_ modifiers: UserShortcut.ShortcutModifiers) -> UInt32 {
    var result = UInt32(0)
    if modifiers.contains(.command) { result |= UInt32(cmdKey) }
    if modifiers.contains(.option)  { result |= UInt32(optionKey) }
    if modifiers.contains(.control) { result |= UInt32(controlKey) }
    if modifiers.contains(.shift)   { result |= UInt32(shiftKey) }
    return result
}

// MARK: - GlobalHotKeyManager

/// 全局快捷键管理器：使用 Carbon RegisterEventHotKey 注册系统级热键。
/// 生命周期约束：
/// - 必须是 singleton（EventHandler refCon 使用 passUnretained，要求对象全程存活）
/// - 必须在 MainActor 上初始化（installEventHandler）
/// - shutdown() 必须在对象销毁前显式调用，释放 Carbon 资源
@MainActor
public final class GlobalHotKeyManager {
    public static let shared = GlobalHotKeyManager()
    
    private var hotKeyHandlers: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var hotKeyIDCounter: UInt32 = 0
    private let kHotKeySignature = OSType(0x4B4D4E31) // 'KMN1'
    private var actionHotKeyId: [ShortcutAction: UInt32] = [:]
    private let logger = Logger(subsystem: "Kite", category: "GlobalHotKey")
    
    private init() {
        let status = installEventHandler()
        if status != noErr {
            logger.error("Failed to install hot key event handler: \(describeOSStatus(status))")
        }
    }
    
    /// 必须由 App lifecycle 在退出时调用，同步释放所有 Carbon 资源。
    public func shutdown() {
        unregisterAll()
        if let handler = eventHandler {
            let status = RemoveEventHandler(handler)
            if status != noErr {
                logger.warning("RemoveEventHandler failed: \(describeOSStatus(status))")
            }
            eventHandler = nil
        }
    }
    
    @discardableResult
    private func registerHotKey(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> UInt32? {
        guard hotKeyIDCounter < UInt32.max else {
            logger.error("hotKeyIDCounter overflow")
            return nil
        }
        hotKeyIDCounter &+= 1
        let id = hotKeyIDCounter
        let hotKeyID = EventHotKeyID(signature: kHotKeySignature, id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr, let ref = hotKeyRef {
            hotKeyHandlers[id] = handler
            hotKeyRefs[id] = ref
            logger.debug("Registered hotkey id=\(id) keyCode=\(keyCode) modifiers=\(modifiers)")
            return id
        } else {
            logger.error("RegisterEventHotKey failed id=\(id) keyCode=\(keyCode) modifiers=\(modifiers) status=\(describeOSStatus(status))")
            return nil
        }
    }
    
    private func _unregisterByID(_ id: UInt32) {
        if let ref = hotKeyRefs[id] { UnregisterEventHotKey(ref) }
        hotKeyHandlers.removeValue(forKey: id)
        hotKeyRefs.removeValue(forKey: id)
    }
    
    public func unregisterAll() {
        for id in hotKeyRefs.keys { _unregisterByID(id) }
    }
    
    private func installEventHandler() -> OSStatus {
        guard eventHandler == nil else {
            logger.warning("Event handler already installed, skipping")
            return noErr
        }
        let eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, refCon in
            guard let refCon else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(refCon).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, OSType(kEventParamDirectObject), OSType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if status == noErr {
                Task { @MainActor in manager.handleHotKey(id: hotKeyID.id) }
            } else {
                manager.logger.error("GetEventParameter failed: \(describeOSStatus(status))")
            }
            return noErr
        }
        let status = InstallEventHandler(GetApplicationEventTarget(), callback, 1, [eventType], Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        if status != noErr {
            logger.error("InstallEventHandler failed: \(describeOSStatus(status))")
            eventHandler = nil
        }
        return status
    }
    
    private func handleHotKey(id: UInt32) { hotKeyHandlers[id]?() }
    
    @discardableResult
    public func register(keyCode: UInt32, modifiers: HotKeyModifier, action: @escaping () -> Void) -> Result<UInt32, GlobalHotKeyError> {
        guard let id = registerHotKey(keyCode: keyCode, modifiers: modifiers.carbonModifiers, handler: action) else {
            return .failure(.registrationFailed(noErr))
        }
        return .success(id)
    }
    
    @discardableResult
    public func unregister(id: UInt32) -> Bool {
        guard hotKeyRefs[id] != nil else { return false }
        defer { _unregisterByID(id) }
        return true
    }
    
    @discardableResult
    public func registerForAction(_ action: ShortcutAction, shortcut: UserShortcut) -> GlobalHotKeyRegistrationResult {
        guard let keyCode = resolveKeyCode(shortcut.key) else { return .invalidShortcut }
        let carbonMods = resolveCarbonModifiers(shortcut.modifiers)
        guard let newId = registerHotKey(keyCode: keyCode, modifiers: carbonMods, handler: { [weak self] in self?.executeAction(action) }) else {
            return .registrationFailed
        }
        if let oldId = actionHotKeyId[action] { _unregisterByID(oldId) }
        actionHotKeyId[action] = newId
        logger.info("Registered \(action.rawValue): keyCode=\(keyCode) mods=\(carbonMods)")
        return .registered
    }
    
    public func unregister(action: ShortcutAction) {
        if let id = actionHotKeyId[action] {
            _unregisterByID(id)
            actionHotKeyId.removeValue(forKey: action)
        }
    }
    
    func refreshAll(from manager: ShortcutManager) {
        unregisterAll()
        actionHotKeyId.removeAll()
        for (action, shortcut) in manager.globalShortcuts {
            guard !shortcut.key.isEmpty else { continue }
            _ = registerForAction(action, shortcut: shortcut)
        }
        logger.info("refreshAll complete, registered \(self.actionHotKeyId.count) hotkeys")
    }
    
    private func executeAction(_ action: ShortcutAction) {
        ShortcutManager.shared.executeAction(action)
    }
}

// MARK: - Registration Result

public enum GlobalHotKeyRegistrationResult {
    case registered
    case invalidShortcut
    case registrationFailed
}
#endif
