import SwiftUI
#if os(macOS)
import Combine
#endif

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openDestination) private var openDestination
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @State private var navigationPath: [SettingsPage] = []
    #endif

    private enum SettingsPage: Hashable {
        case storage
        #if os(macOS)
        case shortcuts
        #endif
    }

    var body: some View {
        #if os(macOS)
        NavigationStack(path: $navigationPath) { settingsForm }
            .toolbar {
                if !navigationPath.isEmpty {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            _ = navigationPath.popLast()
                        } label: {
                            Label("返回", systemImage: "chevron.backward")
                        }
                        .labelStyle(.iconOnly)
                    }
                }
            }
            .background(SettingsWindowToolbar(onClose: { navigationPath.removeAll() }))
            .frame(width: 520, height: 620)
            .overlay(alignment: .top) { SettingsToastOverlay() }
        #else
        settingsForm
        #endif
    }

    private var settingsForm: some View {
        Form {
            Section("播放") {
                Picker("音质", selection: $settings.audioQuality) {
                    ForEach(AudioQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                            .foregroundStyle(quality == settings.audioQuality ? .primary : .secondary)
                    }
                }
                .tint(.secondary)
                Text("无损与 Hi-Res 需要黑胶 VIP，未开通时自动回落到可用音质")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("灰色歌曲解锁", isOn: $settings.enableUnblock)
                    .tint(.green)
                Text("无版权或下架歌曲将从已启用音源中匹配播放")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #if os(macOS)

            AutoMixSettingsSection()
            #endif

            if settings.enableUnblock {
                Section {
                    ForEach(AudioSourceID.allCases, id: \.self) { source in
                        Toggle(source.displayName, isOn: Binding(
                            get: { settings.enabledAudioSourceIDs.contains(source) },
                            set: { isEnabled in
                                if isEnabled {
                                    settings.enabledAudioSourceIDs.insert(source)
                                } else {
                                    settings.enabledAudioSourceIDs.remove(source)
                                }
                            }
                        ))
                        .tint(.green)
                    }
                    // Kuwo is the last source in AudioSourceID.allCases,
                    // so this footnote sits directly under the Kuwo row,
                    // in the same caption style as the gray-song-unlock
                    // footnote above. It is not a footnote for that row.
                    Text("因版权问题，部分歌曲目前暂不支持播放，建议从云端导入")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("音源")
                }
            }

            Section("外观") {
                Picker("主题", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance)
                            .foregroundStyle(appearance == settings.appearance ? .primary : .secondary)
                    }
                }
                .tint(.secondary)
                #if os(macOS)
                // macOS only renders two now-playing layouts — 黑胶 and the
                // regular page; the iOS 沉浸/简洁 options all fall back to the
                // regular page here, so offering four was misleading (#105).
                // Map any non-vinyl value onto 经典模式 so a stored default (e.g.
                // 沉浸模式) still shows a valid selection.
                Picker("播放页模式", selection: Binding(
                    get: { settings.nowPlayingMode == .vinyl ? .vinyl : .classic },
                    set: { settings.nowPlayingMode = $0 }
                )) {
                    Text(NowPlayingMode.vinyl.displayName).tag(NowPlayingMode.vinyl)
                        .foregroundStyle(settings.nowPlayingMode == .vinyl ? .primary : .secondary)
                    Text(NowPlayingMode.classic.displayName).tag(NowPlayingMode.classic)
                        .foregroundStyle(settings.nowPlayingMode == .vinyl ? .secondary : .primary)
                }
                .tint(.secondary)
                #else
                Picker("播放页模式", selection: $settings.nowPlayingMode) {
                    ForEach(NowPlayingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                            .foregroundStyle(mode == settings.nowPlayingMode ? .primary : .secondary)
                    }
                }
                .tint(.secondary)
                #endif
                // Language row (beta2): sits between the player-page mode
                // picker and the artwork toggle. The trailing
                // value is the current language, shown in its own script;
                // the picker lists the current language first, then the
                // other two, with a checkmark on the current one (the
                // Picker's selection). Names are verbatim, never localized.
                Picker("语言", selection: Binding(
                    get: { settings.effectiveAppLanguage },
                    set: { settings.appLanguage = $0 }
                )) {
                    ForEach(settings.orderedAppLanguages) { language in
                        Text(verbatim: language.nativeName).tag(language)
                            .foregroundStyle(language == settings.effectiveAppLanguage ? .primary : .secondary)
                    }
                }
                .tint(.secondary)
                Toggle("点击封面打开专辑", isOn: $settings.openAlbumOnArtworkClick)
                    .tint(.green)
                #if os(iOS)
                Toggle("锁屏歌词", isOn: $settings.lockScreenLyrics)
                    .tint(.green)
                #endif
                Toggle("显示歌词翻译", isOn: $settings.showLyricsTranslation)
                    .tint(.green)
                Toggle("逐字歌词（卡拉OK）", isOn: $settings.verbatimLyrics)
                    .tint(.green)
                Picker("日文歌词读音", selection: $settings.lyricsAnnotation) {
                    ForEach(LyricsAnnotation.allCases) { annotation in
                        Text(annotation.displayName).tag(annotation)
                            .foregroundStyle(annotation == settings.lyricsAnnotation ? .primary : .secondary)
                    }
                }
                .tint(.secondary)
                Text("罗马音在歌词上方另起一行，汉字读音把假名标在汉字正上方；缺少官方罗马音时自动生成读音")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("主界面环境色", isOn: $settings.showMainWindowAmbientBackground)
                    .tint(.green)
                if settings.showMainWindowAmbientBackground {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("背景色强度")
                            Spacer()
                            Text("\(Int(settings.mainWindowAmbientBackgroundIntensity * 100))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $settings.mainWindowAmbientBackgroundIntensity,
                            in: SettingsManager.mainWindowAmbientBackgroundIntensityRange,
                            step: 0.1
                        )
                        .tint(.primary)
                        HStack {
                            Text("50%")
                            Spacer()
                            Text("150%")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                #if os(macOS)
                Toggle("桌面歌词", isOn: $settings.showDesktopLyrics)
                    .tint(.green)
                if settings.showDesktopLyrics {
                    Toggle("桌面歌词水平居中", isOn: $settings.desktopLyricsCentered)
                    .tint(.green)
                }
                Text("在屏幕上悬浮显示当前歌词，可拖动调整位置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }

            Section("存储") {
                NavigationLink(value: SettingsPage.storage) {
                    Label("存储空间", systemImage: "internaldrive")
                }
            }

            #if os(macOS)
            Section("通用") {
                NavigationLink(value: SettingsPage.shortcuts) {
                    Label("快捷键", systemImage: "keyboard")
                }
            }
            #endif

            SyncSettingsSection()

            Section("账号") {
                if let profile = account.profile {
                    LabeledContent("当前账号", value: profile.nickname)
                    Button("退出登录", role: .destructive) {
                        Task {
                            do { try await AccountStore.shared.logout() }
                            catch { ToastCenter.shared.show(error.localizedDescription) }
                        }
                    }
                } else {
                    Text("未登录")
                        .foregroundStyle(.secondary)
                }
            }

            Section("更新") {
                Toggle("启动时自动检查更新", isOn: $settings.autoCheckUpdates)
                    .tint(.green)
                Text("关闭后启动不再自动弹出更新提示，仍可手动检查更新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("关于") {
                LabeledContent("Kite", value: appVersion)
                #if os(iOS)
                Button {
                    IOSUpdater.shared.check(interactive: true)
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
                Text("装有 TrollStore（巨魔）可在应用内一键自动安装；否则可下载 IPA 用侧载工具重装（登录状态与设置保留）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
                Text("网易云音乐第三方客户端 · 数据来自网易云音乐")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("联系作者") {
                // No leading icons in this section. The three link rows are
                // plain-style buttons so they render in primary /
                // secondary colors instead of the app's red accent color
                // that a default Button would use.
                // Every row also has a long-press menu that copies the
                // contact value on the right; tapping the first three rows
                // still opens their link / mail app.
                Button {
                    if let url = URL(string: "https://t.me/Kite_090127") {
                        openURL(url)
                    }
                } label: {
                    HStack {
                        Text("Telegram")
                        Spacer()
                        Text("t.me/Kite_090127")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .tint(.secondary)
                .contextMenu {
                    Button("复制") {
                        Platform.copyToPasteboard(string: "t.me/Kite_090127")
                    }
                }
                Button {
                    if let url = URL(string: "https://x.com/kite_090127?s=11") {
                        openURL(url)
                    }
                } label: {
                    HStack {
                        Text("Twitter")
                        Spacer()
                        Text("x.com/kite_090127")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .tint(.secondary)
                .contextMenu {
                    Button("复制") {
                        Platform.copyToPasteboard(string: "x.com/kite_090127")
                    }
                }
                Button {
                    if let url = URL(string: "mailto:kite090127@gmail.com") {
                        openURL(url)
                    }
                } label: {
                    HStack {
                        Text("Email")
                        Spacer()
                        Text("kite090127@gmail.com")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                // The email address is data-detected as a link by the system
                // and a link's color comes from tint, not from the Text's
                // foregroundStyle — that is why this value stayed red in
                // beta3 while the other rows turned gray. Pin the tint to
                // secondary so the detected link matches the other rows.
                .tint(.secondary)
                .contextMenu {
                    Button("复制") {
                        Platform.copyToPasteboard(string: "kite090127@gmail.com")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationDestination(for: SettingsPage.self) { page in
            Group {
                switch page {
                case .storage:
                    StorageSpaceView {
                        #if os(iOS)
                        dismiss()
                        #endif
                        openDestination(.downloaded)
                    }
                #if os(macOS)
                case .shortcuts:
                    ShortcutSettingsView()
                #endif
                }
            }
            #if os(macOS)
            .navigationBarBackButtonHidden()
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    switch page {
                    case .storage: Text("存储空间").font(.headline)
                    case .shortcuts: Text("快捷键").font(.headline)
                    }
                }
            }
            #endif
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

}

#if os(macOS)
private struct SettingsToastOverlay: View {
    @ObservedObject private var toasts = ToastCenter.shared

    var body: some View {
        Group {
            if let toast = toasts.current {
                ToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 12)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.spring(duration: 0.3), value: toasts.current)
        .allowsHitTesting(false)
    }
}

/// Keep navigation and the title in the native, compact titlebar toolbar.
/// Settings scenes retain their view state when closed, so reset the path here.
struct SettingsWindowToolbar: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> ToolbarHost {
        let view = ToolbarHost()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: ToolbarHost, context: Context) {
        nsView.onClose = onClose
        nsView.updateToolbar()
    }

    final class ToolbarHost: NSView {
        var onClose: () -> Void = {}
        private var closeObserver: AnyCancellable?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            closeObserver = window.map { window in
                NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
                    .sink { [weak self] _ in self?.onClose() }
            }
            updateToolbar()
        }

        func updateToolbar() {
            guard let window, window.toolbarStyle != .unifiedCompact else { return }
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window, window.toolbarStyle != .unifiedCompact else { return }
                window.toolbarStyle = .unifiedCompact
            }
        }
    }
}
#endif
