import SwiftUI

struct MediaRow: View {
    let title: String
    var subtitle: String?
    let items: [BaseItemDto]
    var isLandscape: Bool = false
    let onSelect: (BaseItemDto) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(SashimiTheme.textPrimary)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 18))
                        .foregroundStyle(SashimiTheme.textTertiary)
                }
            }
            .padding(.horizontal, 80)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: isLandscape ? 24 : 36) {
                    ForEach(items) { item in
                        MediaPosterButton(item: item, isLandscape: isLandscape) {
                            onSelect(item)
                        }
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 20)
            }
        }
    }
}

struct MediaPosterButton: View {
    let item: BaseItemDto
    var libraryType: String?
    var libraryName: String?
    var isLandscape: Bool = false
    var badgeCount: Int?  // Shows "X new" badge when > 1
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool

    // Card dimensions
    private var cardWidth: CGFloat { isLandscape ? 320 : 220 }
    private var cardHeight: CGFloat { isLandscape ? 180 : 330 }

    private var displayTitle: String {
        if isLandscape {
            // For landscape (YouTube), show video title
            return item.name
        }
        switch item.type {
        case .movie:
            return item.name
        case .series:
            return item.name
        case .episode:
            return item.seriesName ?? item.name
        default:
            return item.name
        }
    }

    private var subtitleText: String? {
        if isLandscape, item.type == .episode {
            // Show channel/series name for YouTube videos
            return item.seriesName
        }
        return nil
    }

    // Fallback image IDs
    private var imageFallbackIds: [String] {
        var ids: [String] = []
        if isLandscape {
            // Landscape mode: show item's own thumbnail first
            ids.append(item.id)
            if let seriesId = item.seriesId {
                ids.append(seriesId)
            }
        } else if item.type == .episode || item.type == .video {
            // Portrait mode: season/series poster for episodes
            if let seasonId = item.seasonId {
                ids.append(seasonId)
            }
            if let seriesId = item.seriesId {
                ids.append(seriesId)
            }
            ids.append(item.id)
        } else {
            ids.append(item.id)
        }
        return ids
    }

    // Image types to try
    private var imageTypes: [String] {
        if isLandscape {
            return ["Primary", "Thumb", "Backdrop"]
        }
        return ["Primary", "Thumb"]
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    SmartPosterImage(
                        itemIds: imageFallbackIds,
                        maxWidth: isLandscape ? 640 : 400,
                        imageTypes: imageTypes
                    )
                    .frame(width: cardWidth, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Watched indicator (small corner checkmark)
                    if item.userData?.played == true {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.green)
                                    .background(
                                        Circle()
                                            .fill(.black.opacity(0.6))
                                            .padding(-2)
                                    )
                                    .padding(6)
                            }
                            Spacer()
                        }
                    }

                    // "X new" badge for multiple episodes
                    if let count = badgeCount, count > 1 {
                        VStack {
                            HStack {
                                Text("\(count) new")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(SashimiTheme.accent)
                                    .clipShape(Capsule())
                                    .padding(8)
                                Spacer()
                            }
                            Spacer()
                        }
                    }

                    // Progress bar for landscape cards
                    if isLandscape, item.progressPercent > 0 {
                        VStack {
                            Spacer()
                            GeometryReader { geo in
                                Rectangle()
                                    .fill(SashimiTheme.accent)
                                    .frame(width: geo.size.width * item.progressPercent, height: 3)
                            }
                            .frame(height: 3)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isFocused ? SashimiTheme.accent : .clear, lineWidth: 4)
                )
                .shadow(color: isFocused ? SashimiTheme.accent.opacity(0.6) : .clear, radius: 20)

                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(
                        text: displayTitle,
                        isScrolling: isFocused,
                        height: 24
                    )
                    .font(.system(size: isLandscape ? 20 : 22, weight: .medium))
                    .foregroundStyle(SashimiTheme.textPrimary)

                    if let subtitle = subtitleText {
                        Text(subtitle)
                            .font(.system(size: 16))
                            .foregroundStyle(SashimiTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(width: cardWidth, alignment: .leading)
            }
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
    }
}

struct PlainNoHighlightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

struct MarqueeText: View {
    let text: String
    let isScrolling: Bool
    var height: CGFloat = 28

    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let needsScroll = textWidth > geo.size.width
            // Disable scrolling if user has Reduce Motion enabled
            let shouldScroll = needsScroll && isScrolling && !reduceMotion

            Text(text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background(GeometryReader { textGeo in
                    Color.clear.onAppear {
                        textWidth = textGeo.size.width
                        containerWidth = geo.size.width
                    }
                })
                .offset(x: shouldScroll ? offset : 0)
                .onChange(of: isScrolling) { _, scrolling in
                    // Skip animation if Reduce Motion is enabled
                    guard !reduceMotion else { return }

                    if scrolling && needsScroll {
                        withAnimation(.linear(duration: Double(textWidth - containerWidth) / 30).delay(0.5)) {
                            offset = -(textWidth - containerWidth + 20)
                        }
                    } else {
                        withAnimation(.easeOut(duration: 0.3)) {
                            offset = 0
                        }
                    }
                }
        }
        .frame(height: height)
        .clipped()
    }
}
