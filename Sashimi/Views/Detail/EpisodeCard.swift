import SwiftUI

struct EpisodeCard: View {
    let episode: BaseItemDto
    var isCurrentEpisode: Bool = false
    var showEpisodeThumbnail: Bool = false
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @State private var pulseAnimation: Bool = false

    // All possible image sources in order: episode, season, series
    private var fallbackImageIds: [String] {
        var ids = [episode.id]
        if let seasonId = episode.seasonId {
            ids.append(seasonId)
        }
        if let seriesId = episode.seriesId {
            ids.append(seriesId)
        }
        return ids
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    if showEpisodeThumbnail {
                        // Try episode thumbnail first, fall back to season/series poster
                        SmartPosterImage(itemIds: fallbackImageIds, maxWidth: 400)
                            .frame(width: 240, height: 135)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        SmartPosterImage(itemIds: fallbackImageIds, maxWidth: 400)
                            .frame(width: 150, height: 225)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    if episode.progressPercent > 0 {
                        VStack {
                            Spacer()
                            SashimiProgressBar(progress: episode.progressPercent, height: 4, showBackground: false)
                        }
                    }

                    if episode.userData?.played == true {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.black, Color(red: 0.29, green: 0.73, blue: 0.47))
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isCurrentEpisode && !isFocused ? .white : (isFocused ? SashimiTheme.focus : .clear),
                            lineWidth: isCurrentEpisode && !isFocused ? 4 : 3
                        )
                        .opacity(isCurrentEpisode && !isFocused ? (pulseAnimation ? 1.0 : 0.4) : 1.0)
                )
                .shadow(color: isFocused ? SashimiTheme.focusGlow : (isCurrentEpisode ? Color.white.opacity(pulseAnimation ? 0.6 : 0.2) : .clear), radius: 12)
                .onAppear {
                    if isCurrentEpisode {
                        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                            pulseAnimation = true
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    MarqueeText(
                        text: episode.name,
                        isScrolling: isFocused,
                        height: 28
                    )
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)

                    HStack(spacing: 6) {
                        // Only show S#:E# for non-YouTube content
                        if !(episode.path?.lowercased().contains("youtube") ?? false) {
                            Text("S\(String(episode.parentIndexNumber ?? 1)):E\(String(episode.indexNumber ?? 0))")
                                .font(.system(size: 20))
                                .foregroundStyle(SashimiTheme.textTertiary)
                        }

                        if let runtime = episode.runTimeTicks {
                            Text("• \(runtime / 10_000_000 / 60) min")
                                .font(.system(size: 20))
                                .foregroundStyle(SashimiTheme.textTertiary)
                        }
                    }
                }
                .frame(width: showEpisodeThumbnail ? 240 : 150, alignment: .leading)
            }
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(episodeAccessibilityLabel)
        .accessibilityHint("Double-tap to play")
    }

    private var episodeAccessibilityLabel: String {
        var parts: [String] = []
        parts.append("Episode \(episode.indexNumber ?? 0)")
        parts.append(episode.name)

        if episode.userData?.played == true {
            parts.append("watched")
        } else if episode.progressPercent > 0 {
            parts.append("\(Int(episode.progressPercent * 100)) percent watched")
        }

        if isCurrentEpisode {
            parts.append("now playing")
        }

        return parts.joined(separator: ", ")
    }
}
