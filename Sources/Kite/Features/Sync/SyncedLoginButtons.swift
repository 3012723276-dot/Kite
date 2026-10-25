import SwiftUI

struct SyncedLoginButtons: View {
    @ObservedObject private var sync = SyncService.shared
    @ObservedObject private var account = AccountStore.shared
    var onStart: () -> Void = {}
    var onFinished: (Bool) -> Void = { _ in }
    @State private var passphraseMode: LoginPassphraseMode?
    @State private var pendingRecord: SyncRecord<SyncedLogin>?

    var body: some View {
        if sync.enabled, sync.connected, account.isBootstrapped, account.authenticatedAccountID == nil {
            ForEach(sync.logins) { record in
                if let login = record.payload {
                    Button {
                        // The offer is sealed; this device needs the passphrase once.
                        if sync.loginKeyState == .unlocked {
                            signIn(with: record)
                        } else {
                            pendingRecord = record
                            passphraseMode = .unlock
                        }
                    } label: {
                        HStack {
                            Image(systemName: "icloud")
                            Text("以\(login.nickname)登录").lineLimit(1)
                            if sync.importingLogin { ProgressView().controlSize(.small) }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(sync.importingLogin)
                }
            }
            if !sync.logins.isEmpty {
                Text("在已连接的设备间同步登录状态")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // One alert for all offers: on the `ForEach` it would be
                    // copied onto every row.
                    .loginPassphraseAlert(mode: $passphraseMode) { _, passphrase, _ in
                        guard let record = pendingRecord else { return }
                        pendingRecord = nil
                        Task {
                            do {
                                try await sync.unlockLogin(passphrase: passphrase)
                                signIn(with: record)
                            } catch is CancellationError {
                            } catch { ToastCenter.shared.show(error.localizedDescription) }
                        }
                    }
            }
        }
    }

    private func signIn(with record: SyncRecord<SyncedLogin>) {
        onStart()
        Task {
            do {
                let signedIn = try await sync.importLogin(record)
                onFinished(signedIn)
                if let error = sync.errorMessage { ToastCenter.shared.show(error) }
            } catch is CancellationError {
                onFinished(false)
            } catch {
                onFinished(false)
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }
}
