import SwiftUI

#if os(iOS)
struct IOSPlaybackQueueView: View {
    @EnvironmentObject private var player: PlayerService
    let backdrop: ArtworkColors
    @EnvironmentObject private var toasts: ToastCenter

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    PlaybackHandoffList()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    if let current = player.currentTrack {
                        PlaybackQueueSectionLabel("正在播放")
                        PlaybackQueueRow(track: current, isCurrent: true)

                        if !player.upcomingTracks.isEmpty {
                            PlaybackQueueSectionLabel("即将播放")
                                .padding(.top, 10)
                            ForEach(
                                Array(player.upcomingTracks.prefix(100).enumerated()),
                                id: \.offset
                            ) { index, track in
                                PlaybackQueueRow(track: track, isCurrent: false, upcomingIndex: index)
                            }
                        }
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 28, weight: .light))
                            Text("播放队列是空的")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
                .padding(10)
            }
            .navigationTitle("播放队列")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(player.upcomingTracks.count + (player.hasCurrentTrack ? 1 : 0)) 首")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .background(queueBackdrop)
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if let toast = toasts.current {
                ToastView(toast: toast).padding(.top, 8)
            }
        }
    }

    private var queueBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [backdrop.primary, backdrop.secondary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Color.black.opacity(0.45)
        }
        .ignoresSafeArea()
    }
}

private struct PlaybackQueueSectionLabel: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

private struct PlaybackQueueRow: View {
    let track: Track
    let isCurrent: Bool
    var upcomingIndex: Int? = nil

    @EnvironmentObject private var player: PlayerService

    var body: some View {
        Button {
            guard !isCurrent else { return }
            if let upcomingIndex { player.jumpToUpcoming(at: upcomingIndex, matching: track.id) }
            else { player.jumpTo(track) }
        } label: {
            HStack(spacing: 10) {
                CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(96), animated: false)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(isCurrent ? Theme.accent : .primary)
                        .lineLimit(1)
                    Text(track.artistNames)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if isCurrent {
                    PlayingIndicator(animating: player.isPlaying)
                } else {
                    Text(Formatters.duration(track.duration))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
