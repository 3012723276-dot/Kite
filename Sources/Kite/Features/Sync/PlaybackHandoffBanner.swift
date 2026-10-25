import SwiftUI

/// A non-intrusive floating capsule banner presented at the top of the screen
/// when there is no active playback, notifying the user of available playback
/// sessions on other devices and offering a one-tap handoff resume.
struct PlaybackHandoffBanner: View {
    @ObservedObject private var sync = SyncService.shared
    @ObservedObject private var account = AccountStore.shared
    @ObservedObject private var player = PlayerService.shared
    @State private var dismissedRecordID: UUID?

    private var activeSessionRecord: SyncRecord<PlaybackCheckpoint>? {
        guard !player.hasCurrentTrack,
              let accountID = account.authenticatedAccountID else { return nil }
        return sync.sessions.first { record in
            guard let session = record.payload, session.accountID == accountID else { return false }
            return record.id != dismissedRecordID
        }
    }

    var body: some View {
        if let record = activeSessionRecord, let session = record.payload {
            HStack(spacing: 10) {
                Image(systemName: record.deviceSymbolName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28, height: 28)
                    .background(Theme.accent.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text("来自 \(record.deviceName)")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(session.currentTrack.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button {
                    Task {
                        do { try await sync.resume(record) }
                        catch is CancellationError { }
                        catch { ToastCenter.shared.show(error.localizedDescription) }
                    }
                } label: {
                    Text("接续")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Theme.accent, in: Capsule())
                        .opacity(sync.resumingDeviceID == record.id ? 0 : 1)
                        .overlay {
                            if sync.resumingDeviceID == record.id { ProgressView().controlSize(.small) }
                        }
                }
                .buttonStyle(.plain)
                .disabled(sync.resumingDeviceID == record.id)

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        dismissedRecordID = record.id
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
