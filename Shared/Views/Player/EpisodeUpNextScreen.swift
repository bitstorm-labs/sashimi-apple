import NukeUI
import SwiftUI

/// The full-screen card shown when an episode ends: the next episode with a
/// countdown (Auto-play on), or the series-complete / lookup-failed message.
///
/// One layout for Apple TV, iPad and iPhone, sized by `Metrics`; the state and
/// its rules live in `EpisodeUpNext`, the actions in `PlayerViewModel`.
struct EpisodeUpNextScreen: View {
    let upNext: EpisodeUpNext
    /// Image candidates for an item, tried in order (a download's local file
    /// first when offline, then the server).
    let imageURLs: (BaseItemDto, EpisodeUpNextImageRole) -> [URL]
    var serverID: String?
    let onPlay: () -> Void
    let onSkip: () -> Void
    let onCancel: () -> Void
    let onReplay: () -> Void
    let onDone: () -> Void

    @ObservedObject private var playbackSettings = PlaybackSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var appeared = false
    #if os(tvOS)
    @FocusState private var focus: EpisodeUpNextAction?
    #endif

    /// The apps' shared purple (SashimiTheme.accent / MobileColors.accent).
    static let accent = Color(red: 140 / 255, green: 92 / 255, blue: 199 / 255)
    /// The accent lifted toward white so the small eyebrow reads on the dark,
    /// purple-tinted background.
    /// The Play button's unfilled part while the countdown runs.
    static let accentDeep = Color(red: 74 / 255, green: 50 / 255, blue: 108 / 255)
    static let eyebrowTint = Color(red: 178 / 255, green: 142 / 255, blue: 222 / 255)

    var body: some View {
        GeometryReader { proxy in
            let metrics = Metrics(size: proxy.size)
            ZStack {
                background
                content(metrics)
                    .padding(.horizontal, metrics.horizontalPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(appeared ? 1 : 0)
                    .scaleEffect(appeared || reduceMotion ? 1 : 0.97)
                    .offset(y: appeared || reduceMotion ? 0 : metrics.entranceOffset)
            }
        }
        .ignoresSafeArea(edges: platformIgnoredEdges)
        .onAppear {
            withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.45)) { appeared = true }
        }
        #if os(tvOS)
        .defaultFocus($focus, actions.first)
        .onExitCommand {
            // Menu cancels the countdown first; on a settled card it leaves.
            if actions.contains(.cancel) { onCancel() } else { onDone() }
        }
        .onChange(of: actions) { _, available in
            // A button that went away (Cancel, an exhausted Skip) hands
            // focus to the first action rather than dropping it.
            if let focused = focus, !available.contains(focused) { focus = available.first }
        }
        #endif
    }

    private var platformIgnoredEdges: Edge.Set {
        #if os(tvOS)
        return .all
        #else
        return []
        #endif
    }

    // MARK: - Background

    private var background: some View {
        // The artwork is an overlay of a flexible base, so a filled image
        // wider than the screen can never widen the layout around it.
        Color(red: 0.07, green: 0.07, blue: 0.09)
            .overlay {
                if !reduceTransparency {
                    EpisodeUpNextImage(urls: imageURLs(upNext.artworkItem, .backdrop), serverID: serverID)
                        .scaledToFill()
                        .blur(radius: 50, opaque: true)
                        .scaleEffect(1.15)
                        .opacity(0.9)
                        .id(upNext.artworkItem.id)
                        .transition(.opacity)
                }
            }
            .overlay {
                scrims
            }
            .animation(.easeInOut(duration: 0.5), value: upNext.artworkItem.id)
            .clipped()
            .ignoresSafeArea()
    }

    private var scrims: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.35), .black.opacity(0.62), .black.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [Self.accent.opacity(0.22), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 900
            )
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ metrics: Metrics) -> some View {
        if metrics.isStacked {
            VStack(alignment: .leading, spacing: metrics.blockSpacing) {
                episodeBlock(metrics)
                buttons(metrics)
            }
            .frame(maxWidth: metrics.maxContentWidth)
        } else {
            HStack(alignment: .center, spacing: metrics.columnSpacing) {
                thumbnail(metrics)
                VStack(alignment: .leading, spacing: metrics.blockSpacing) {
                    details(metrics)
                    buttons(metrics)
                }
                .frame(maxWidth: metrics.textColumnWidth, alignment: .leading)
            }
            .frame(maxWidth: metrics.maxContentWidth)
        }
    }

    @ViewBuilder
    private func episodeBlock(_ metrics: Metrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.blockSpacing) {
            thumbnail(metrics)
            details(metrics)
        }
    }

    private func thumbnail(_ metrics: Metrics) -> some View {
        ZStack {
            Color.white.opacity(0.06)
            EpisodeUpNextImage(urls: imageURLs(upNext.artworkItem, .thumbnail), serverID: serverID)
                .scaledToFill()
        }
        .frame(width: metrics.thumbnailWidth, height: metrics.thumbnailWidth * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: metrics.shadowRadius, y: metrics.shadowRadius / 3)
        .id(upNext.artworkItem.id)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.35), value: upNext.skipCount)
        .accessibilityHidden(true)
    }

    private func details(_ metrics: Metrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.lineSpacing) {
            Text(upNext.eyebrow)
                .font(.system(size: metrics.eyebrowSize, weight: .heavy))
                .tracking(metrics.eyebrowSize * 0.18)
                .foregroundStyle(Self.eyebrowTint)
            if upNext.kind == .nextEpisode, let series = upNext.seriesName {
                Text(series)
                    .font(.system(size: metrics.seriesSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Text(upNext.title)
                .font(.system(size: metrics.titleSize, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
            metaLine(metrics)
            if let message = upNext.message {
                Text(message)
                    .font(.system(size: metrics.bodySize))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(3)
                    .lineSpacing(metrics.bodySize * 0.12)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, metrics.lineSpacing)
            }
        }
        .id("details-\(upNext.artworkItem.id)")
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.35), value: upNext.skipCount)
    }

    @ViewBuilder
    private func metaLine(_ metrics: Metrics) -> some View {
        let parts = [upNext.kind == .nextEpisode ? upNext.episodeLabel : nil, upNext.runtimeText].compactMap { $0 }
        let rating = upNext.rating(showReviewRatings: playbackSettings.showReviewRatings)
        if !parts.isEmpty || rating != nil {
            HStack(spacing: metrics.metaSize * 0.6) {
                if !parts.isEmpty {
                    Text(parts.joined(separator: "  ·  "))
                        .font(.system(size: metrics.metaSize, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .monospacedDigit()
                }
                if let rating {
                    if !parts.isEmpty {
                        Text("·")
                            .font(.system(size: metrics.metaSize, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    HStack(spacing: metrics.metaSize * 0.3) {
                        Image("TMDBLogo")
                            .resizable().scaledToFit()
                            .frame(height: metrics.metaSize * 0.95)
                        Text(String(format: "%.1f", rating))
                            .font(.system(size: metrics.metaSize, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(format: "TMDB rating %.1f", rating))
                }
            }
        }
    }

    // MARK: - Buttons

    private func buttons(_ metrics: Metrics) -> some View {
        // Never wrap a label: fall back to a tighter row, then to icon-only
        // Skip / Cancel, when the full row does not fit (iPhone portrait).
        ViewThatFits(in: .horizontal) {
            buttonRow(metrics)
            buttonRow(metrics.compacted())
            buttonRow(metrics.iconOnly())
        }
    }

    private func buttonRow(_ metrics: Metrics) -> some View {
        HStack(spacing: metrics.buttonSpacing) {
            ForEach(actions, id: \.self) { action in
                button(for: action, metrics: metrics)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: actions)
    }

    @ViewBuilder
    private func button(for action: EpisodeUpNextAction, metrics: Metrics) -> some View {
        let label = Button {
            perform(action)
        } label: {
            if action == .play {
                playLabel(metrics)
            } else {
                secondaryLabel(action, metrics: metrics, isPrimary: action == .done && upNext.kind != .nextEpisode)
            }
        }
        .buttonStyle(EpisodeUpNextButtonStyle(metrics: metrics))
        .disabled(action == .skip && !upNext.canSkip)
        .accessibilityLabel(accessibilityLabel(for: action))
        #if os(tvOS)
        label.focused($focus, equals: action)
        #else
        label
        #endif
    }

    private func playLabel(_ metrics: Metrics) -> some View {
        // `.animation` re-renders every frame while counting, so the fill
        // and the ring sweep smoothly; Reduce Motion ticks once a second.
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : nil, paused: !upNext.isCountingDown)) { context in
            let progress = upNext.progress(at: context.date)
            HStack(spacing: metrics.buttonFontSize * 0.5) {
                Image(systemName: "play.fill")
                Text("Play")
                    .lineLimit(1)
                    .fixedSize()
                if let seconds = upNext.displayedSeconds(at: context.date) {
                    EpisodeUpNextCountdownRing(progress: progress, seconds: seconds, size: metrics.ringSize)
                        .padding(.leading, metrics.buttonFontSize * 0.15)
                }
            }
            .font(.system(size: metrics.buttonFontSize, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, metrics.buttonHorizontalPadding * 1.15)
            .frame(height: metrics.buttonHeight)
            .background {
                GeometryReader { proxy in
                    // Counting down, the button fills with the accent from
                    // the left as the seconds run out.
                    ZStack(alignment: .leading) {
                        if upNext.showsCountdown {
                            Self.accentDeep
                            Self.accent.frame(width: proxy.size.width * progress)
                        } else {
                            Self.accent
                        }
                    }
                }
            }
            .clipShape(Capsule())
        }
    }

    private func secondaryLabel(_ action: EpisodeUpNextAction, metrics: Metrics, isPrimary: Bool) -> some View {
        HStack(spacing: metrics.buttonFontSize * 0.45) {
            Image(systemName: action.systemImage)
            if metrics.showsSecondaryTitles {
                Text(action.title)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .font(.system(size: metrics.buttonFontSize, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, metrics.buttonHorizontalPadding)
        .frame(height: metrics.buttonHeight)
        .background {
            if isPrimary {
                Capsule().fill(Self.accent)
            } else if reduceTransparency {
                Capsule().fill(Color(white: 0.2))
            } else {
                Capsule().fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(.white.opacity(0.08)))
            }
        }
        .overlay(Capsule().strokeBorder(.white.opacity(isPrimary ? 0 : 0.16), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Actions

extension EpisodeUpNextScreen {
    private var actions: [EpisodeUpNextAction] {
        switch upNext.kind {
        case .nextEpisode:
            var actions: [EpisodeUpNextAction] = [.play]
            if upNext.showsSkip { actions.append(.skip) }
            actions += upNext.isCancelled ? [.replay, .done] : [.cancel]
            return actions
        case .finalEpisode, .lookupFailed:
            return [.done, .replay]
        }
    }

    private func perform(_ action: EpisodeUpNextAction) {
        switch action {
        case .play: onPlay()
        case .skip: onSkip()
        case .cancel: onCancel()
        case .replay: onReplay()
        case .done: onDone()
        }
    }

    private func accessibilityLabel(for action: EpisodeUpNextAction) -> String {
        guard action == .play else { return action.title }
        let episode = [upNext.episodeLabel, upNext.episode?.name].compactMap { $0 }.joined(separator: " ")
        if let seconds = upNext.displayedSeconds(at: Date()) {
            return "Play \(episode), starts in \(seconds) seconds"
        }
        return "Play \(episode)"
    }
}
