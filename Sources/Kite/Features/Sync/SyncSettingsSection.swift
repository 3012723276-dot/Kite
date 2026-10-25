import SwiftUI
import UniformTypeIdentifiers

struct SyncSettingsSection: View {
    @ObservedObject private var sync = SyncService.shared
    @State private var showDirectoryPicker = false
    @State private var connectionError: String?
    @State private var passphraseMode: LoginPassphraseMode?

    private var errorMessage: String? { connectionError ?? sync.errorMessage }

    var body: some View {
        Section("iCloud") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("同步", isOn: Binding(
                    get: { sync.enabled },
                    set: { enabled in
                        Task {
                            connectionError = nil
                            if enabled {
                                do { showDirectoryPicker = try await !sync.enable() }
                                catch is CancellationError { return }
                                catch { connectionError = error.localizedDescription }
                            } else { await sync.disable() }
                        }
                    }
                ))
                Text("在设备间接续播放，同步设置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if sync.enabled {
                Toggle("登录同步", isOn: Binding(
                    get: { sync.loginEnabled },
                    set: { enabled in
                        // Nothing is shared until this device holds the folder's key.
                        if enabled, sync.loginKeyState != .unlocked {
                            passphraseMode = sync.loginKeyState == .unset ? .create : .unlock
                        } else {
                            Task { await sync.setLoginEnabled(enabled) }
                        }
                    }
                ))

                Text("允许已连接的设备登录此账号，登录信息以同步密码加密")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if sync.loginEnabled, sync.connected { passphraseButtons }
            }
            if !sync.connected, sync.enabled || errorMessage != nil {
                Button("重新连接") {
                    showDirectoryPicker = true
                }
                #if os(macOS)
                .controlSize(.small)
                #endif
            }
            if let error = errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .loginPassphraseAlert(mode: $passphraseMode) { mode, passphrase, confirmation in
            Task {
                connectionError = nil
                do {
                    switch mode {
                    case .create: try await sync.createLoginKey(passphrase: passphrase, confirmation: confirmation)
                    case .unlock: try await sync.unlockLogin(passphrase: passphrase)
                    }
                    if !sync.loginEnabled { await sync.setLoginEnabled(true) }
                } catch is CancellationError {
                } catch { connectionError = error.localizedDescription }
            }
        }
        .fileImporter(isPresented: $showDirectoryPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let directory):
                connectionError = nil
                Task { await sync.connect(to: directory) }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    connectionError = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder
    private var passphraseButtons: some View {
        HStack {
            switch sync.loginKeyState {
            case .unset:
                Button("设置同步密码") { passphraseMode = .create }
            case .locked:
                Button("输入同步密码") { passphraseMode = .unlock }
                // A forgotten passphrase is replaced, not recovered.
                Button("重设同步密码") { passphraseMode = .create }
            case .unlocked:
                Button("更改同步密码") { passphraseMode = .create }
            }
        }
        #if os(macOS)
        .controlSize(.small)
        #endif
    }
}
