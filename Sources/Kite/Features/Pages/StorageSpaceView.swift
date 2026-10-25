import SwiftUI

@MainActor
struct StorageSpaceView: View {
    let onManageDownloads: () -> Void
    @StateObject private var model = StorageSpaceModel()
    @EnvironmentObject private var settings: SettingsManager
    #if os(iOS)
    @State private var automaticLimitMB: Int?
    #endif
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    if let capacity = model.snapshot?.device {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(deviceName).font(.headline)
                                Spacer()
                                capacityText(capacity)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(deviceName).font(.headline)
                                capacityText(capacity)
                            }
                        }
                        StorageCapacityBar(capacity: capacity, appBytes: model.snapshot?.appBytes ?? 0)
                    } else if model.isLoading {
                        HStack { ProgressView(); Text("正在计算存储空间…").foregroundStyle(.secondary) }
                    } else {
                        Text("暂时无法读取设备容量").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent(model.snapshot?.partial == true ? String(localized: "已统计的 Kite 占用") : String(localized: "Kite 占用")) {
                    Text(model.snapshot.map { format($0.appBytes) } ?? "—")
                        .font(.body.weight(.semibold)).monospacedDigit()
                }
            }

            Section {
                usageRow("图片缓存", icon: "photo.on.rectangle", category: .imageCache)
                Button(role: .destructive) { Task { await model.clear(.imageCache) } } label: {
                    HStack {
                        Text("清除图片缓存")
                        if model.clearingCategory == .imageCache { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                    .disabled(busy || (model.snapshot?[.imageCache] ?? 0) == 0)
            } footer: {
                Text("清除后保留已下载歌曲的封面。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                usageRow("歌曲缓存", icon: "music.note", category: .musicCache)
                #if os(macOS)
                Picker("上限", selection: $settings.audioCacheLimit) {
                    Text("512 MB").tag(Int64(512) << 20)
                    Text("2 GB").tag(Int64(2) << 30)
                    Text("8 GB").tag(Int64(8) << 30)
                    Text("不限").tag(Int64(0))
                }
                .tint(.secondary)
                #else
                Toggle("歌曲缓存", isOn: $settings.enableAudioCache)
                    .tint(.green)
                if settings.enableAudioCache {
                    Picker("上限", selection: cacheLimitSelection) {
                        if let automaticLimitMB {
                            Text("自动（\(format(Int64(automaticLimitMB) * 1_000_000))）").tag(0)
                        } else {
                            Text("自动").tag(0)
                        }
                        ForEach(manualCacheLimitsMB, id: \.self) { megabytes in
                            Text(format(Int64(megabytes) * 1_000_000)).tag(megabytes)
                        }
                    }
                    .tint(.secondary)
                }
                #endif
                Button(role: .destructive) { Task { await model.clear(.musicCache) } } label: {
                    HStack {
                        Text("清除歌曲缓存")
                        if model.clearingCategory == .musicCache { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                    .disabled(busy || (model.snapshot?[.musicCache] ?? 0) == 0)
            } footer: {
                Text("暂存最近播放的歌曲，不含已下载音乐。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Button(action: onManageDownloads) {
                    HStack {
                        Label("已下载", systemImage: "arrow.down.circle")
                        Spacer()
                        Text(size(.downloads)).foregroundStyle(.secondary).monospacedDigit()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } footer: {
                if let other = model.snapshot?.otherAccountDownloads, other > 0 {
                    Text("其他账号的下载占用 \(format(other))。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section {
                usageRow("应用数据", icon: "internaldrive", category: .appData)
            } footer: {
                Text("应用、歌词、离线封面与账号资料。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let message = model.message ?? (model.snapshot?.partial == true ? String(localized: "部分存储信息不可用") : nil) {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("存储空间")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: scenePhase) {
            if scenePhase == .active, !model.isClearing {
                await model.reload()
            }
        }
        #if os(macOS)
        .onChange(of: settings.audioCacheLimit) { _, _ in
            Task { await model.reload() }
        }
        #else
        .task(id: [settings.enableAudioCache ? (settings.audioCacheAutomatic ? -1 : settings.audioCacheSizeMB) : 0]) {
            guard settings.enableAudioCache else { await DownloadManager.shared.refreshCachedTracks(); return }
            let limit = await settings.effectiveAudioCacheSizeMB(refresh: true)
            automaticLimitMB = settings.audioCacheAutomatic ? limit : nil
            try? await AudioCache.shared.enforce(maximumSizeMB: limit)
            await DownloadManager.shared.refreshCachedTracks()
            await model.reload()
        }
        #endif
    }

    private var busy: Bool { model.isLoading || model.isClearing }
    #if os(iOS)
    /// Tag 0 is the automatic limit; the rest are megabytes.
    private var cacheLimitSelection: Binding<Int> {
        Binding(get: { settings.audioCacheAutomatic ? 0 : settings.audioCacheSizeMB },
                set: { value in
                    if value == 0 { settings.audioCacheAutomatic = true }
                    else { settings.audioCacheAutomatic = false; settings.audioCacheSizeMB = value }
                })
    }
    private var manualCacheLimitsMB: [Int] {
        var sizes = [500, 1_000, 2_000, 5_000, 10_000]
        // A size chosen on the old slider stays selectable until it is changed.
        if !settings.audioCacheAutomatic, !sizes.contains(settings.audioCacheSizeMB) {
            sizes.append(settings.audioCacheSizeMB)
            sizes.sort()
        }
        return sizes
    }
    #endif
    private var deviceName: String {
        #if os(macOS)
        return "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }
    private func size(_ category: StorageCategory) -> String {
        guard let snapshot = model.snapshot, !snapshot.unavailableCategories.contains(category) else { return "—" }
        return format(snapshot[category])
    }
    private func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private func capacityText(_ capacity: DeviceStorageCapacity) -> some View {
        Text("已用 \(format(capacity.used))，共 \(format(capacity.total))")
            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
    }
    private func usageRow(_ title: LocalizedStringKey, icon: String, category: StorageCategory) -> some View {
        LabeledContent {
            Text(size(category)).monospacedDigit().foregroundStyle(.secondary)
        } label: { Label(title, systemImage: icon) }
    }
}
