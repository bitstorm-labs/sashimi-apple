import SwiftUI

// MARK: - Hero Section
struct HeroSection: View {
    let slides: [HeroSlide]
    let libraryNames: [String: String]
    @Binding var currentIndex: Int
    /// The platform's sizes and colours. tvOS passes `.tv`, the original
    /// ten-foot values; iPad passes the same composition scaled down.
    let layout: HeroLayout
    /// Artwork owner for the image requests; nil means the active server.
    var serverID: String?
    /// True while the viewer is touching the hero (iPad), so it never rotates
    /// out from under a finger. Releasing restarts the full slide interval.
    var isPaused = false

    @State private var autoAdvanceTimer: Timer?

    /// Seconds each hero item stays on screen before auto-advancing
    private let slideDuration: Double = 6

    /// Every fixed size below is the tvOS value times this (1 on tvOS).
    private var scale: CGFloat { layout.scale }

    private var safeIndex: Int {
        guard !slides.isEmpty else { return 0 }
        return min(currentIndex, slides.count - 1)
    }

    private var currentSlide: HeroSlide {
        slides[safeIndex]
    }

    /// Everything below reads the slide's item; a channel slide differs only in
    /// carrying the stamp that identifies it.
    private var currentItem: BaseItemDto {
        currentSlide.item
    }

    // Detect YouTube content by checking library name
    private var isYouTubeContent: Bool {
        guard let libraryName = libraryNames[currentItem.id] else { return false }
        return libraryName.lowercased().contains("youtube")
    }

    // Fallback image IDs for hero display - prefer series backdrop for episodes
    private var heroFallbackIds: [String] {
        var ids: [String] = []
        // A channel slide leads with the same art its card shows, so a YouTube
        // programme — not in the library-name map, so never detected as
        // YouTube below — gets its thumbnail instead of a missing backdrop.
        if currentSlide.channel != nil {
            ids.append(currentItem.channelArtwork.itemId)
        }
        if currentItem.type == .episode {
            // For YouTube: use episode thumbnail
            if isYouTubeContent {
                ids.append(currentItem.id)
            } else {
                // For regular episodes: try series first for high-res backdrop
                if let seriesId = currentItem.seriesId {
                    ids.append(seriesId)
                }
                if let seasonId = currentItem.seasonId {
                    ids.append(seasonId)
                }
                ids.append(currentItem.id)
            }
        } else {
            ids.append(currentItem.id)
        }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    // Image types for hero - YouTube uses episode thumbnail, others use Backdrop
    private var heroImageTypes: [String] {
        if currentSlide.channel != nil {
            let lead = currentItem.channelArtwork.imageType
            return [lead] + ["Backdrop", "Art", "Thumb", "Primary"].filter { $0 != lead }
        }
        if isYouTubeContent {
            // YouTube episodes have thumbnails as Primary or Thumb
            return ["Primary", "Thumb", "Backdrop"]
        }
        return ["Backdrop", "Art", "Thumb"]
    }

    // Display title (channel/series name for episodes, item name for movies)
    private var displayTitle: String {
        if currentItem.type == .episode {
            return (currentItem.seriesName ?? currentItem.name).cleanedYouTubeTitle
        }
        return currentItem.name
    }

    // VoiceOver accessibility description
    private var accessibilityDescription: String {
        var parts: [String] = []

        if currentItem.type == .episode {
            parts.append((currentItem.seriesName ?? currentItem.name).cleanedYouTubeTitle)
            parts.append(formatEpisodeInfo(currentItem))
        } else {
            parts.append(currentItem.name)
        }

        if let type = currentItem.type {
            parts.append(type.rawValue)
        }

        if let year = currentItem.productionYear {
            parts.append("from \(year)")
        }

        if slides.count > 1 {
            parts.append("Item \(safeIndex + 1) of \(slides.count)")
            parts.append("Swipe left or right to browse")
        }

        return parts.joined(separator: ", ")
    }

    var body: some View {
        GeometryReader { geometry in
                ZStack(alignment: .bottomLeading) {
                    // Transparent base so the page gradient behind the hero shows
                    // through — a solid SashimiTheme.background fill read lighter
                    // than the rest of the screen (which fades to pure black).
                    Color.clear

                    // Backdrop image positioned on the right with soft left edge.
                    // The fade mask is applied to the IMAGE, not the 0.7-width
                    // container: a .fit image sizes to its fitted bounds (a 16:9
                    // backdrop fills ~0.5 of the hero width), so a container-
                    // relative ramp over the leftmost 25% never reached the
                    // image's actual left edge — leaving a harsh vertical line
                    // mid-hero. Image-relative, the ramp always covers the edge.
                    HStack(spacing: 0) {
                        Spacer()
                        SmartPosterImage(
                            itemIds: heroFallbackIds,
                            // 1920, not 3840. tvOS lays out in a 1920x1080 space
                            // and this slot renders ~910x512pt, so a 4K request
                            // was a 33 MB RGBA decode (3840*2160*4) for an image
                            // that is downsampled on sight. Jellyfin treats
                            // maxWidth as a cap, so any item with 4K artwork
                            // really did return 4K -- and the hero rotates every
                            // 6 seconds.
                            maxWidth: 1920,
                            imageTypes: heroImageTypes,
                            contentMode: .fit,
                            serverID: serverID
                        )
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: .white, location: 0.35)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .id(currentItem.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .frame(width: layout.imageWidth(in: geometry.size), height: geometry.size.height)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.6), value: currentItem.id)
                    }

                    // Left text scrim: black (not charcoal) so the text area
                    // matches the page's fade-to-black rather than reading lighter.
                    // The title is white with a shadow, so a light scrim isn't
                    // needed for legibility over the dark background.
                    HStack(spacing: 0) {
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(0.5), location: 0.0),
                                .init(color: .black.opacity(0.4), location: 0.6),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geometry.size.width * 0.35)
                        Spacer()
                    }

                    // Bottom gradient — fade to black (not charcoal) so the title
                    // area and the hero's lower edge match the page's fade-to-black.
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .clear, location: 0.4),
                            .init(color: .black.opacity(0.6), location: 0.7),
                            .init(color: .black, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    // Content overlay
                    VStack(alignment: .leading, spacing: 20 * scale) {
                        Spacer()

                        // Channel slides say which channel before they say what
                        // is on: the programme is still the headline, because
                        // that is what a viewer is choosing between, but without
                        // this the slide is indistinguishable from a library one.
                        if let stamp = currentSlide.channel {
                            channelEyebrow(stamp)
                        }

                        // Title
                        Text(displayTitle)
                            .font(.system(size: 64 * scale, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .shadow(color: .black.opacity(0.8), radius: 10 * scale, x: 0, y: 4 * scale)

                        // Episode info for TV shows, video title for YouTube
                        if currentItem.type == .episode {
                            if isYouTubeContent || currentItem.hasDatedEpisodeNumbers {
                                // YouTube: show video title
                                Text(currentItem.name)
                                    .font(.system(size: 28 * scale, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .shadow(color: .black.opacity(0.6), radius: 4 * scale, x: 0, y: 2 * scale)
                                    .lineLimit(2)
                            } else {
                                // Regular TV: show S:E info
                                Text(formatEpisodeInfo(currentItem))
                                    .font(.system(size: 28 * scale, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .shadow(color: .black.opacity(0.6), radius: 4 * scale, x: 0, y: 2 * scale)
                            }
                        }

                        // Metadata row
                        HStack(spacing: 20 * scale) {
                            if let rating = currentItem.communityRating {
                                HStack(spacing: 8 * scale) {
                                    Image("TMDBLogo")
                                        .resizable().scaledToFit()
                                        .frame(height: 24 * scale)
                                    Text(String(format: "%.1f", rating))
                                        .fontWeight(.semibold)
                                }
                            }

                            if let criticRating = currentItem.criticRating {
                                HStack(spacing: 6 * scale) {
                                    Text("🍅")
                                    Text("\(criticRating)%")
                                        .fontWeight(.semibold)
                                }
                            }

                            if isYouTubeContent {
                                // Show full date for YouTube
                                if let dateStr = DateFormatting.formatDate(currentItem.premiereDate) {
                                    Text(dateStr)
                                }
                                HStack(spacing: 6 * scale) {
                                    Image(systemName: "play.rectangle.fill")
                                    Text("YouTube")
                                }
                                .foregroundStyle(.red)
                            } else {
                                if let year = currentItem.productionYear {
                                    Text(String(year))
                                }

                                if let runtime = DateFormatting.formatRuntime(currentItem.runTimeTicks) {
                                    Text(runtime)
                                }
                            }

                            // Driven off a clock rather than the fetch, so it
                            // counts down between refreshes instead of sitting
                            // at whatever it said when the slide appeared.
                            if let stamp = currentSlide.channel {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    if let remaining = stamp.timeRemaining(at: context.date) {
                                        Text(remaining)
                                            .foregroundStyle(layout.accent)
                                            .monospacedDigit()
                                    }
                                }
                            }
                        }
                        .font(.system(size: 24 * scale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))

                        // Description
                        if let overview = currentItem.overview, !overview.isEmpty {
                            Text(overview)
                                .font(.system(size: 22 * scale))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(3)
                                .frame(maxWidth: 800 * scale, alignment: .leading)
                                .padding(.top, 4 * scale)
                        }

                        Spacer()
                    }
                    // Wider margin than the rows below (which sit at 40 against
                    // the rail): this is 64pt display type, and tightening it to
                    // match the poster rows pushed the block uncomfortably far
                    // left. Large type needs the extra breathing room.
                    .padding(.horizontal, 80 * scale)
                    // Centre the text in the hero's *solid* area, not its full
                    // height. The bottom 10% is masked to transparent (and the
                    // first row overlaps it), so centring on the raw height puts
                    // the block visibly low. Reserving the faded band lifts it
                    // to the optical centre.
                    .padding(.bottom, geometry.size.height * 0.1)
                    // iPad only: the hero runs up behind the status bar and the
                    // header strip, so centre the text in what is left visible.
                    .padding(.top, layout.topInset)
                }
            }
            .heroFrame(layout)
            // Non-interactive ambient wallpaper: full-bleed (edge to edge), not a
            // card — no focus, no border, no scale (focus skips it to the first
            // row). Fade only the bottom edge to transparent so the hero dissolves
            // into the page background instead of ending on a hard horizontal seam
            // (its fill is lighter than the page gradient lower down). Fade starts
            // at 0.9 so the title/metadata above it stay fully opaque.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0.0),
                        .init(color: .white, location: 0.9),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityDescription)
        .onAppear {
            startAutoAdvance()
        }
        .onDisappear {
            stopAutoAdvance()
        }
        .onChange(of: isPaused) { _, paused in
            if paused {
                stopAutoAdvance()
            } else {
                startAutoAdvance()
            }
        }
    }

    /// LIVE, then the station the way every other channel label reads:
    /// logo, then name.
    private func channelEyebrow(_ stamp: HeroSlide.Stamp) -> some View {
        HStack(spacing: 14 * scale) {
            HStack(spacing: 8 * scale) {
                Circle().fill(Color.red).frame(width: 10 * scale, height: 10 * scale)
                Text("LIVE")
                    .font(.system(size: 18 * scale, weight: .bold))
                    .tracking(1.2 * scale)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14 * scale)
            .padding(.vertical, 7 * scale)
            .background(Capsule().fill(.black.opacity(0.55)))

            HStack(spacing: 10 * scale) {
                if stamp.logo != nil {
                    ChannelLogoView(channelId: stamp.id, logo: stamp.logo, mono: true, size: 26 * scale)
                }
                Text(stamp.name.uppercased())
            }
            .font(.system(size: 20 * scale, weight: .heavy))
            .tracking(1.4 * scale)
            .foregroundStyle(.white)
            .padding(.horizontal, 16 * scale)
            .padding(.vertical, 7 * scale)
            .background(Capsule().fill(.black.opacity(0.55)))
            .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
        }
        .shadow(color: .black.opacity(0.6), radius: 6 * scale, x: 0, y: 2 * scale)
    }

    private func startAutoAdvance() {
        guard slides.count > 1, !isPaused else { return }
        // A second onAppear without an intervening onDisappear (tab switch,
        // navigation pop) would otherwise orphan the previous timer, which
        // keeps mutating currentIndex — the hero then advances at a multiple
        // of the intended rate and never settles.
        autoAdvanceTimer?.invalidate()
        // One tick per slide advances the hero.
        autoAdvanceTimer = Timer.scheduledTimer(withTimeInterval: slideDuration, repeats: true) { _ in
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.6)) {
                    currentIndex = (currentIndex + 1) % slides.count
                }
            }
        }
    }

    private func stopAutoAdvance() {
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil
    }

    private func formatEpisodeInfo(_ item: BaseItemDto) -> String {
        if item.hasDatedEpisodeNumbers { return item.name }
        let season = item.parentIndexNumber ?? 1
        let episode = item.indexNumber ?? 1
        return "S\(season) E\(episode) • \(item.name)"
    }
}

// MARK: - Layout

/// What differs between the tvOS hero and the iPad one. The composition —
/// gradients, masks, text block, rotation — is one shared view; only the
/// sizes and the frame change.
struct HeroLayout {
    /// Multiplier for every fixed size (type, spacing, padding). 1 on tvOS.
    var scale: CGFloat = 1
    /// The hero's height. nil keeps the tvOS frame: 32:9 of its width.
    var height: CGFloat?
    /// Height of the chrome drawn over the hero's top edge (status bar and
    /// header on iPad), which the text block is centred below.
    var topInset: CGFloat = 0
    /// Let the backdrop box grow past 70% of the width when that is what a
    /// 16:9 backdrop needs to fill the hero's height (an iPad in portrait).
    /// Off on tvOS, whose 32:9 frame never needs it.
    var widensImageToFillHeight = false
    /// The countdown colour on a channel slide (each target's theme accent).
    var accent: Color

    func imageWidth(in size: CGSize) -> CGFloat {
        let base = size.width * 0.7
        guard widensImageToFillHeight else { return base }
        return min(size.width, max(base, size.height * 16 / 9))
    }
}

private extension View {
    @ViewBuilder
    func heroFrame(_ layout: HeroLayout) -> some View {
        if let height = layout.height {
            frame(height: height)
        } else {
            aspectRatio(32/9, contentMode: .fit)
        }
    }
}
