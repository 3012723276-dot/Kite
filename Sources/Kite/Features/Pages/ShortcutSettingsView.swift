#if os(macOS)
import SwiftUI
import AppKit

private enum ShortcutScope: Hashable {
    case inApp, global
}

struct ShortcutSettingsView: View {
    @ObservedObject private var manager = ShortcutManager.shared
    @State private var scope = ShortcutScope.inApp
    @State private var recordingAction: ShortcutAction?
    
    var body: some View {
        VStack(spacing: 0) {
            Picker("作用范围", selection: Binding(
                get: { scope },
                set: { newScope in
                    recordingAction = nil
                    scope = newScope
                }
            )) {
                Text("应用内").tag(ShortcutScope.inApp)
                Text("全局").tag(ShortcutScope.global)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding()
            
            Form {
                Section {
                    ForEach(ShortcutAction.allCases) { action in
                        let rowScope = scope
                        ShortcutRow(action: action, isGlobal: rowScope == .global,
                                    shortcut: manager.shortcut(for: action, isGlobal: rowScope == .global),
                                    isRecording: Binding(
                                        get: { recordingAction == action && scope == rowScope },
                                        set: { recording in
                                            // Ignore callbacks from a row removed by a scope or recording change.
                                            guard scope == rowScope else { return }
                                            if recording { recordingAction = action }
                                            else if recordingAction == action { recordingAction = nil }
                                        }
                                    ))
                    }
                }
                
                Section {
                    Button("恢复默认") {
                        do {
                            try manager.resetToDefaults()
                        } catch { ToastCenter.shared.show(error.localizedDescription) }
                    }
                    .foregroundColor(.red)
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle("快捷键")
        .onDisappear { recordingAction = nil }
    }
}

struct ShortcutRow: View {
    let action: ShortcutAction
    let isGlobal: Bool
    let shortcut: UserShortcut
    @Binding var isRecording: Bool
    @FocusState private var isFocused: Bool
    
    var body: some View {
        HStack {
            Label(action.displayName, systemImage: action.systemImage)
            Spacer()
            Button {
                isRecording = true
                isFocused = true
            } label: {
                Text(isRecording ? String(localized: "录制中…") : shortcut.displayString)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(minWidth: 80)
                    .background(isRecording ? Color.accentColor : Color.secondary.opacity(0.15))
                    .cornerRadius(6)
                    .foregroundColor(isRecording ? .white : .primary)
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .help("Delete 清除 · Esc 取消")
            .accessibilityLabel(Text(action.displayName))
            .accessibilityValue(Text(isRecording ? String(localized: "录制中…") : shortcut.displayString))
            .accessibilityHint(Text("Delete 清除 · Esc 取消"))
            .accessibilityAction(named: Text("清除快捷键"), clearShortcut)
            .contextMenu {
                if !isRecording, !shortcut.key.isEmpty {
                    Button("清除快捷键", action: clearShortcut)
                }
            }

            if isRecording {
                ShortcutRecorderView(isRecording: $isRecording, onClear: clearShortcut) { key, modifiers in
                    do {
                        try ShortcutManager.shared.setShortcut(
                            UserShortcut(key: key, modifiers: modifiers), for: action, isGlobal: isGlobal)
                    } catch { ToastCenter.shared.show(error.localizedDescription) }
                }
                .frame(width: 0, height: 0)
            }
        }
        .padding(.vertical, 2)
    }

    private func clearShortcut() {
        do {
            try ShortcutManager.shared.clearShortcut(for: action, isGlobal: isGlobal)
            isRecording = false
        } catch { ToastCenter.shared.show(error.localizedDescription) }
    }
}

extension ShortcutAction {
    var systemImage: String {
        switch self {
        case .togglePlayPause: return "playpause"
        case .nextTrack: return "forward.end"
        case .previousTrack: return "backward.end"
        case .cycleQueueOrder: return "shuffle"
        case .cycleRepeatMode: return "repeat"
        case .toggleLike: return "heart"
        case .toggleLyrics: return "quote.bubble"
        case .toggleQueue: return "list.bullet"
        case .closeImmersive: return "xmark.circle"
        case .volumeUp: return "speaker.wave.2"
        case .volumeDown: return "speaker.wave.1"
        }
    }
}

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onClear: () -> Void
    let onRecord: (String, UserShortcut.ShortcutModifiers) -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = RecorderNSView()
        view.onRecord = { key, modifiers in
            guard isRecording else { return }
            onRecord(key, modifiers)
            isRecording = false
        }
        view.onCancel = {
            isRecording = false
        }
        view.onClear = {
            guard isRecording else { return }
            onClear()
            isRecording = false
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if isRecording {
            DispatchQueue.main.async {
                guard isRecording, let window = nsView.window, window.firstResponder !== nsView else { return }
                window.makeFirstResponder(nsView)
            }
        }
    }
    
    class RecorderNSView: NSView {
        var onRecord: ((String, UserShortcut.ShortcutModifiers) -> Void)?
        var onCancel: (() -> Void)?
        var onClear: (() -> Void)?
        
        override var acceptsFirstResponder: Bool { true }
        
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                onCancel?()
                return
            }
            
            let modifiers = UserShortcut.ShortcutModifiers(nsFlags: event.modifierFlags)
            if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
                onClear?()
                return
            }
            
            // Try to get the key, handling special characters/function keys
            let key = event.charactersIgnoringModifiers ?? ""
            
            // If the key is empty, check keyCode for special keys
            if key.isEmpty {
                // Map function keys/arrows
                let specialKey: String
                switch event.keyCode {
                case 123: specialKey = "\u{F702}" // Left
                case 124: specialKey = "\u{F703}" // Right
                case 125: specialKey = "\u{F701}" // Down
                case 126: specialKey = "\u{F700}" // Up
                case 122: specialKey = "\u{F704}" // F1
                // ... add more if needed
                default: specialKey = ""
                }
                
                if !specialKey.isEmpty {
                    onRecord?(specialKey, modifiers)
                    return
                }
            } else {
                onRecord?(key, modifiers)
                return
            }
            
            super.keyDown(with: event)
        }
        
        override func resignFirstResponder() -> Bool {
            onCancel?()
            return super.resignFirstResponder()
        }
    }
}
#endif
