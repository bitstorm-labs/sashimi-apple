import NukeUI
import SwiftUI

// MARK: - Supporting types

enum EpisodeUpNextAction: Hashable {
    case play, skip, cancel, replay, done

    var title: String {
        switch self {
        case .play: return "Play"
        case .skip: return "Skip"
        case .cancel: return "Cancel"
        case .replay: return "Replay"
        case .done: return "Done"
        }
    }

    var systemImage: String {
        switch self {
        case .play: return "play.fill"
        case .skip: return "forward.end.fill"
        case .cancel: return "xmark"
        case .replay: return "gobackward"
        case .done: return "checkmark"
        }
    }
}

enum EpisodeUpNextImageRole {
    /// The crisp 16:9 card: the episode's own still.
    case thumbnail
    /// Full-bleed behind everything, blurred: the show's backdrop.
    case backdrop
}

extension EpisodeUpNextScreen {
    /// Server artwork for the card. The episode still first; the show's
    /// backdrop behind it.
    static func serverImageURLs(
        for item: BaseItemDto,
        role: EpisodeUpNextImageRole,
        serverID: String?
    ) -> [URL] {
        let serverURL = serverID.flatMap { id in SessionManager.shared.servers.first { $0.id == id }?.url }
        let series = item.seriesId
        let candidates: [(String?, String)]
        switch role {
        case .thumbnail:
            candidates = [(item.id, "Primary"), (series, "Thumb"), (series, "Backdrop")]
        case .backdrop:
            candidates = [(series, "Backdrop"), (item.id, "Primary")]
        }
        return candidates.compactMap { itemID, type in
            itemID.flatMap {
                JellyfinClient.shared.syncImageURL(
                    itemId: $0,
                    imageType: type,
                    maxWidth: role == .thumbnail ? 960 : 1280,
                    serverURL: serverURL
                )
            }
        }
    }
}

/// Tries each URL in turn; a local file loads directly, a remote one goes
/// through the app's pipeline (cache and certificate trust).
struct EpisodeUpNextImage: View {
    let urls: [URL]
    let serverID: String?
    @State private var index = 0

    var body: some View {
        if index < urls.count {
            let url = urls[index]
            if url.isFileURL {
                if let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable()
                } else {
                    Color.clear.onAppear { index += 1 }
                }
            } else {
                LazyImage(request: SashimiImagePipeline.request(url: url, serverID: serverID)) { state in
                    if let image = state.image {
                        image.resizable()
                    } else if state.error != nil {
                        Color.clear.onAppear { index += 1 }
                    } else {
                        Color.clear
                    }
                }
                .pipeline(SashimiImagePipeline.shared)
                .id(url)
            }
        } else {
            Color.clear
        }
    }
}

/// The countdown: a ring filling around the seconds left.
struct EpisodeUpNextCountdownRing: View {
    let progress: Double
    let seconds: Int
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.3), lineWidth: size * 0.1)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.white, style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(seconds)")
                .font(.system(size: size * 0.48, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct EpisodeUpNextButtonStyle: ButtonStyle {
    let metrics: EpisodeUpNextScreen.Metrics

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, metrics: metrics)
    }

    private struct Styled: View {
        let configuration: Configuration
        let metrics: EpisodeUpNextScreen.Metrics
        @Environment(\.isEnabled) private var isEnabled
        #if os(tvOS)
        @Environment(\.isFocused) private var isFocused
        #else
        private let isFocused = false
        #endif

        var body: some View {
            configuration.label
                .overlay(Capsule().strokeBorder(.white, lineWidth: isFocused ? 3 : 0))
                .shadow(color: isFocused ? .white.opacity(0.4) : .clear, radius: 18)
                .scaleEffect(isFocused ? 1.08 : (configuration.isPressed ? 0.96 : 1))
                .opacity(isEnabled ? 1 : 0.45)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

// MARK: - Metrics

extension EpisodeUpNextScreen {
    struct Metrics {
        var isStacked: Bool
        var horizontalPadding: CGFloat
        var maxContentWidth: CGFloat
        var thumbnailWidth: CGFloat
        var textColumnWidth: CGFloat
        var columnSpacing: CGFloat
        var blockSpacing: CGFloat
        var lineSpacing: CGFloat
        var eyebrowSize: CGFloat
        var seriesSize: CGFloat
        var titleSize: CGFloat
        var metaSize: CGFloat
        var bodySize: CGFloat
        var buttonFontSize: CGFloat
        var buttonHeight: CGFloat
        var buttonHorizontalPadding: CGFloat
        var buttonSpacing: CGFloat
        var ringSize: CGFloat
        var cornerRadius: CGFloat
        var shadowRadius: CGFloat
        var entranceOffset: CGFloat
        /// Off only in the narrowest fallback: Skip and Cancel as icons.
        var showsSecondaryTitles = true

        /// The button row when the full one does not fit (a phone in
        /// portrait): tighter padding and type.
        func compacted() -> Metrics {
            var metrics = self
            metrics.buttonFontSize *= 0.92
            metrics.buttonHorizontalPadding *= 0.62
            metrics.buttonSpacing *= 0.7
            metrics.ringSize *= 0.88
            return metrics
        }

        func iconOnly() -> Metrics {
            var metrics = compacted()
            metrics.showsSecondaryTitles = false
            return metrics
        }

        init(size: CGSize) {
            #if os(tvOS)
            // 10-ft: the 1920-point canvas, inside the TV-safe margins.
            isStacked = false
            horizontalPadding = 90
            maxContentWidth = 1700
            thumbnailWidth = 740
            textColumnWidth = 860
            columnSpacing = 80
            blockSpacing = 44
            lineSpacing = 12
            eyebrowSize = 26
            seriesSize = 30
            titleSize = 62
            metaSize = 30
            bodySize = 29
            buttonFontSize = 30
            buttonHeight = 80
            buttonHorizontalPadding = 38
            buttonSpacing = 28
            ringSize = 46
            cornerRadius = 22
            shadowRadius = 36
            entranceOffset = 30
            #else
            let wide = size.width > size.height
            let compactHeight = size.height < 500
            isStacked = !wide
            let isPad = min(size.width, size.height) >= 700
            let scale: CGFloat = isPad ? 1.25 : 1
            horizontalPadding = isPad ? 48 : 24
            let available = size.width - horizontalPadding * 2
            maxContentWidth = isStacked ? min(available, isPad ? 620 : 520) : min(available, 1100)
            if isStacked {
                thumbnailWidth = maxContentWidth
                textColumnWidth = maxContentWidth
            } else {
                thumbnailWidth = min(available * (compactHeight ? 0.4 : 0.44), compactHeight ? 300 : 520)
                textColumnWidth = min(available - thumbnailWidth - 40, 560)
            }
            columnSpacing = isPad ? 44 : 28
            blockSpacing = (compactHeight ? 14 : 22) * scale
            lineSpacing = (compactHeight ? 4 : 6) * scale
            eyebrowSize = 13 * scale
            seriesSize = 15 * scale
            titleSize = (compactHeight ? 22 : 26) * scale
            metaSize = 15 * scale
            bodySize = 15 * scale
            buttonFontSize = 16 * scale
            buttonHeight = (compactHeight ? 42 : 48) * scale
            buttonHorizontalPadding = 18 * scale
            buttonSpacing = 10 * scale
            ringSize = 26 * scale
            cornerRadius = 14 * scale
            shadowRadius = 22
            entranceOffset = 16
            #endif
        }
    }
}
