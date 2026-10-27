import ActivityKit
import SwiftUI
import WidgetKit

@main
struct KiteLyricsWidgetBundle: WidgetBundle {
    var body: some Widget {
        LockScreenLyricsWidget()
    }
}

/// Lock Screen + Dynamic Island presentation for the lyrics Live Activity.
///
/// The attributes type comes from the app package
/// (Sources/Kite/Core/Player/LockScreenLyricsAttributes.swift), which this
/// target compiles directly — ActivityKit matches the activity started by
/// the app with this UI by that shared type.
struct LockScreenLyricsWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LockScreenLyricsAttributes.self) { context in
            LockScreenLyricsCard(context: context)
                .activityBackgroundTint(Color.black.opacity(0.72))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isPlaying ? "music.note" : "pause.fill")
                        .font(.title3)
                        .frame(width: 28)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: "quote.opening")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.line.isEmpty ? context.state.trackTitle : context.state.line)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if !context.state.nextLine.isEmpty {
                            Text(context.state.nextLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "music.note")
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
            } minimal: {
                Image(systemName: "music.note")
            }
        }
    }
}

/// The Lock Screen card: song on top, the line being sung large, the next
/// line dimmed below it.
private struct LockScreenLyricsCard: View {
    let context: ActivityViewContext<LockScreenLyricsAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .font(.caption.weight(.bold))
                Text(context.state.trackTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(context.state.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if context.state.line.isEmpty {
                Text(context.state.trackTitle)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
            } else {
                Text(context.state.line)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                if !context.state.nextLine.isEmpty {
                    Text(context.state.nextLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}
