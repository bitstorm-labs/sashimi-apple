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
    var isCircular: Bool = false  // For YouTube channel-style circular covers
    var badgeCount: Int?  // Shows "X new" badge when > 1
    let onSelect: () -> Void
    var onPlayPause: (() -> Void)?  // Optional: immediate playback on Play/Pause button

    @FocusState private var isFocused: Bool

    // Card dimensions
    private var cardWidth: CGFloat { isCircular ? 200 : (isLandscape ? 320 : 220) }
    private var cardHeight: CGFloat { isCircular ? 200 : (isLandscape ? 180 : 330) }

    private var displayTitle: String {
        if isLandscape {
            // For landscape (YouTube), show video title
            return item.name
        }
        switch item.type {
        case .movie:
            return item.name
        case .series:
            return item.name.cleanedYouTubeTitle
        case .episode:
            return (item.seriesName ?? item.name).cleanedYouTubeTitle
        default:
            return item.name
        }
    }

    private var subtitleText: String? {
        // No subtitle for landscape (YouTube) - title only
        if isLandscape {
            return nil
        }
        return nil
    }

    private func formatDate(_ isoDate: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoDate) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "M-d-yyyy"
            return displayFormatter.string(from: date)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoDate) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "M-d-yyyy"
            return displayFormatter.string(from: date)
        }
        return ""
    }

    // Fallback image IDs
    private var imageFallbackIds: [String] {
        var ids: [String] = []
        if isLandscape {
            // Landscape mode (YouTube): try item's thumbnail first, then series as last resort
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
            // For YouTube/landscape, try Thumb first (more likely to have video thumbnail)
            return ["Thumb", "Primary", "Backdrop", "Screenshot"]
        }
        return ["Primary", "Thumb"]
    }

    // VoiceOver accessibility description
    private var accessibilityDescription: String {
        var parts: [String] = []

        // Title
        parts.append(displayTitle)

        // Type
        if let type = item.type {
            parts.append(type.rawValue)
        }

        // Year
        if let year = item.productionYear {
            parts.append("from \(year)")
        }

        // Progress
        if item.progressPercent > 0 {
            let percent = Int(item.progressPercent * 100)
            parts.append("\(percent)% watched")
        }

        // Watched status
        if item.userData?.played == true {
            parts.append("watched")
        }

        // Favorite status
        if item.userData?.isFavorite == true {
            parts.append("favorite")
        }

        return parts.joined(separator: ", ")
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .center, spacing: 10) {
                ZStack(alignment: isCircular ? .center : .bottomLeading) {
                    if isCircular {
                        // Centered circular image
                        Circle()
                            .fill(SashimiTheme.cardBackground)
                            .frame(width: cardWidth, height: cardHeight)
                            .overlay(
                                SmartPosterImage(
                                    itemIds: imageFallbackIds,
                                    maxWidth: 400,
                                    imageTypes: imageTypes,
                                    contentMode: .fit
                                )
                                .clipShape(Circle())
                            )
                    } else {
                        SmartPosterImage(
                            itemIds: imageFallbackIds,
                            maxWidth: isLandscape ? 640 : 400,
                            imageTypes: imageTypes,
                            contentMode: .fill
                        )
                        .frame(width: cardWidth, height: cardHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        // Watched indicator (small corner checkmark) - inside for non-circular
                        if item.userData?.played == true {
                            VStack {
                                HStack {
                                    Spacer()
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 29))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.black, Color(red: 0.29, green: 0.73, blue: 0.47))
                                        .padding(6)
                                }
                                Spacer()
                            }
                        }

                        // "X new" badge for multiple episodes
                        if let count = badgeCount, count > 1 {
                            VStack {
                                HStack {
                                    Spacer()
                                    Text("\(count) new")
                                        .font(.system(size: 19, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 5)
                                        .background(Color(red: 0.29, green: 0.55, blue: 0.73))
                                        .clipShape(Capsule())
                                        .padding(9)
                                }
                                Spacer()
                            }
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
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(isCircular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 12)))
                // Watched indicator for circular images - outside the clip
                .overlay(alignment: .topTrailing) {
                    if isCircular && item.userData?.played == true {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 26))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.black, Color(red: 0.29, green: 0.73, blue: 0.47))
                            .offset(x: -8, y: 8)
                    }
                }
                .overlay(
                    Group {
                        if isCircular {
                            Circle()
                                .stroke(isFocused ? SashimiTheme.accent : .clear, lineWidth: 4)
                        } else {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(isFocused ? SashimiTheme.accent : .clear, lineWidth: 4)
                        }
                    }
                )
                .shadow(color: isFocused ? SashimiTheme.focusGlow : .clear, radius: 15, x: 0, y: 0)

                VStack(alignment: .center, spacing: 2) {
                    MarqueeText(
                        text: displayTitle,
                        isScrolling: isFocused,
                        height: 24,
                        alignment: .center
                    )
                    .font(.system(size: isCircular ? 20 : (isLandscape ? 20 : 22), weight: .medium))
                    .foregroundStyle(SashimiTheme.textPrimary)

                    if let subtitle = subtitleText {
                        Text(subtitle)
                            .font(.system(size: 16))
                            .foregroundStyle(SashimiTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(width: cardWidth, alignment: .center)
            }
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Double-tap to view details")
        .contextMenu {
            // Mark as watched/unwatched
            Button {
                Task {
                    await toggleWatched()
                }
            } label: {
                Label(
                    item.userData?.played == true ? "Mark as Unwatched" : "Mark as Watched",
                    systemImage: item.userData?.played == true ? "eye.slash" : "eye"
                )
            }

            // Refresh metadata
            Button {
                Task {
                    await refreshMetadata()
                }
            } label: {
                Label("Refresh Metadata", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .onPlayPauseCommand {
            if let playPause = onPlayPause {
                playPause()
            }
        }
    }

    private func toggleWatched() async {
        do {
            if item.userData?.played == true {
                try await JellyfinClient.shared.markUnplayed(itemId: item.id)
                ToastManager.shared.show("Marked as unwatched", type: .success)
            } else {
                try await JellyfinClient.shared.markPlayed(itemId: item.id)
                ToastManager.shared.show("Marked as watched", type: .success)
            }
        } catch {
            ToastManager.shared.show("Failed to update watch status")
        }
    }

    private func refreshMetadata() async {
        do {
            try await JellyfinClient.shared.refreshMetadata(itemId: item.id)
            ToastManager.shared.show("Metadata refresh started", type: .info)
        } catch {
            ToastManager.shared.show("Failed to refresh metadata")
        }
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
    var alignment: HorizontalAlignment = .leading
    var startDelay: Double = 0.5
    var pingPong: Bool = false

    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var scrollDirection: Bool = true // true = left, false = right
    @State private var animationTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func baseOffset(for containerWidth: CGFloat) -> CGFloat {
        // If text fits, center it (or align as specified)
        guard textWidth <= containerWidth else { return 0 }
        switch alignment {
        case .center:
            return (containerWidth - textWidth) / 2
        case .trailing:
            return containerWidth - textWidth
        default:
            return 0
        }
    }

    private var scrollAmount: CGFloat {
        max(0, textWidth - containerWidth + 20)
    }

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
                .offset(x: shouldScroll ? offset : baseOffset(for: geo.size.width))
                .onChange(of: isScrolling) { _, scrolling in
                    // Skip animation if Reduce Motion is enabled
                    guard !reduceMotion else { return }

                    animationTask?.cancel()

                    if scrolling && needsScroll {
                        if pingPong {
                            animationTask = Task {
                                await startPingPongAnimation()
                            }
                        } else {
                            withAnimation(.linear(duration: Double(scrollAmount) / 30).delay(startDelay)) {
                                offset = -scrollAmount
                            }
                        }
                    } else {
                        withAnimation(.easeOut(duration: 0.3)) {
                            offset = 0
                        }
                        scrollDirection = true
                    }
                }
        }
        .frame(height: height)
        .clipped()
    }

    @MainActor
    private func startPingPongAnimation() async {
        // Initial delay
        try? await Task.sleep(for: .milliseconds(Int(startDelay * 1000)))

        while !Task.isCancelled {
            let duration = Double(scrollAmount) / 30

            // Scroll left
            withAnimation(.linear(duration: duration)) {
                offset = -scrollAmount
            }
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000) + 800))

            guard !Task.isCancelled else { break }

            // Scroll right (back)
            withAnimation(.linear(duration: duration)) {
                offset = 0
            }
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000) + 800))
        }
    }
}
