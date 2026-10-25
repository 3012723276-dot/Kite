import SwiftUI

struct PlaybackLifecycle: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task { await SyncService.shared.start() }
            #if os(macOS)
            .onChange(of: scenePhase) { _, phase in
                PlayerService.shared.checkpointPlayback()
                Task { await SyncService.shared.setForeground(phase == .active) }
            }
            #else
            .onChange(of: scenePhase) { phase in
                PlayerService.shared.checkpointPlayback()
                Task { await SyncService.shared.setForeground(phase == .active) }
            }
            #endif
    }
}
