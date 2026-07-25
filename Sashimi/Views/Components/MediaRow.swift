import SwiftUI

struct MediaPosterButton: View {
    let item: BaseItemDto
    var libraryType: String?
    var libraryName: String?
    var isLandscape: Bool = false
    var isCircular: Bool = false  // For YouTube channel-style circular covers
    var badgeCount: Int?  // Shows "X new" badge when >= 1
    let onSelect: () -> Void
    var onPlayPause: (() -> Void)?  // Optional: immediate playback on Play/Pause button

    @FocusState private var isFocused: Bool
    @AppStorage("showQualityBadges") private var showQualityBadges = true
    @AppStorage("showReviewRatings") private var showReviewRatings = true
    @AppStorage("useEpisodeRatings") private var useEpisodeRatings = false

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
        let candidates: [String] = isLandscape
            // For YouTube/landscape, try Thumb first (more likely to have video thumbnail)
            ? ["Thumb", "Primary", "Backdrop", "Screenshot"]
            : ["Primary", "Thumb"]

        // The server already tells us which image types an item has, in
        // ImageTags — and this probed blindly instead, so a tile whose item has
        // no Thumb issued a doomed request and then waited 500ms before trying
        // the next type. In a grid showing 30 tiles that is a lot of wasted
        // round-trips and visible placeholder time.
        //
        // Only applied when the item itself is the sole candidate id. For
        // episodes we also fall back to season/series ids, and we hold no tags
        // for those, so those must still probe.
        guard imageFallbackIds == [item.id], let tags = item.imageTags, !tags.isEmpty else {
            return candidates
        }
        let available = candidates.filter { tags[$0] != nil }
        // If the tags name none of our candidates, fall back to probing rather
        // than rendering a guaranteed placeholder.
        return available.isEmpty ? candidates : available
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

                        // Quality badge (bottom-right; top-right is reserved for
                        // the watched/new indicators, so the two never overlap)
                        if showQualityBadges, !isLandscape, let quality = item.qualityBadge {
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    QualityBadge(label: quality, fontSize: 19,
                                                 horizontalPadding: 10, verticalPadding: 5, cornerRadius: 8)
                                        .padding(9)
                                }
                            }
                        }

                        // Review rating badge (bottom-left; TMDb community rating)
                        if showReviewRatings, !isLandscape,
                           let rating = item.coverReviewRating(useEpisodeRatings: useEpisodeRatings) {
                            VStack {
                                Spacer()
                                HStack {
                                    ReviewRatingBadge(rating: rating, fontSize: 19, logoHeight: 18,
                                                      horizontalPadding: 10, verticalPadding: 5, cornerRadius: 8)
                                        .padding(9)
                                    Spacer()
                                }
                            }
                        }

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
                        if let count = badgeCount, count >= 1 {
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
                // Circular overlays (outside the clip shape)
                .overlay(alignment: .topTrailing) {
                    if isCircular {
                        if let count = badgeCount, count >= 1 {
                            Text("\(count) new")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Color(red: 0.29, green: 0.55, blue: 0.73))
                                .clipShape(Capsule())
                                .offset(x: -4, y: 4)
                        } else if item.userData?.played == true {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 26))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.black, Color(red: 0.29, green: 0.73, blue: 0.47))
                                .offset(x: -8, y: 8)
                        }
                    }
                }
                .overlay(
                    Group {
                        if isCircular {
                            Circle()
                                .stroke(isFocused ? SashimiTheme.focus : .clear, lineWidth: 4)
                        } else {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(isFocused ? SashimiTheme.focus : .clear, lineWidth: 4)
                        }
                    }
                )
                .shadow(color: isFocused ? SashimiTheme.focusGlow : .clear, radius: 15, x: 0, y: 0)

                MarqueeText(
                    text: displayTitle,
                    isScrolling: isFocused,
                    height: 24,
                    alignment: .center
                )
                .font(.system(size: isCircular ? 20 : (isLandscape ? 20 : 22), weight: .medium))
                .foregroundStyle(SashimiTheme.textPrimary)
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
                    }
                }
                // The ping-pong loop is `while !Task.isCancelled` and was only
                // cancelled from the isScrolling change above. A marquee that
                // was focused when its view got dismissed therefore kept
                // looping on the main actor forever -- an unbounded leak per
                // dismissed detail view.
                .onDisappear {
                    animationTask?.cancel()
                    animationTask = nil
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
