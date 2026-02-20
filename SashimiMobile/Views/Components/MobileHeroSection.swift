import SwiftUI
import NukeUI

struct MobileHeroSection<Destination: View>: View {
    let items: [BaseItemDto]
    let libraryNames: [String: String]
    let destination: (BaseItemDto) -> Destination

    @State private var currentIndex: Int = 0
    @State private var autoAdvanceTimer: Timer?
    @State private var progress: Double = 0

    private var safeIndex: Int {
        guard !items.isEmpty else { return 0 }
        return min(currentIndex, items.count - 1)
    }

    private var currentItem: BaseItemDto {
        items[safeIndex]
    }

    // Detect YouTube content by checking library name
    private var isYouTubeContent: Bool {
        guard let libraryName = libraryNames[currentItem.id] else { return false }
        return libraryName.lowercased().contains("youtube")
    }

    // Image ID for hero display
    private var heroImageId: String {
        if currentItem.type == .episode {
            if isYouTubeContent {
                return currentItem.id
            } else if let seriesId = currentItem.seriesId {
                return seriesId
            }
        }
        return currentItem.id
    }

    // Image type for hero
    private var heroImageType: String {
        if isYouTubeContent {
            return "Primary"
        }
        return "Backdrop"
    }

    private var imageURL: URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }
        return URL(string: "\(serverURL)/Items/\(heroImageId)/Images/\(heroImageType)?maxWidth=1920")
    }

    // Display title
    private var displayTitle: String {
        if currentItem.type == .episode {
            return (currentItem.seriesName ?? currentItem.name).cleanedYouTubeTitle
        }
        return currentItem.name
    }

    var body: some View {
        NavigationLink {
            destination(currentItem)
        } label: {
            GeometryReader { geometry in
                ZStack(alignment: .bottomLeading) {
                    // Background
                    MobileColors.background

                    // Backdrop image on right with soft left edge
                    HStack(spacing: 0) {
                        Spacer()
                        heroImage
                            .frame(width: geometry.size.width * 0.6, height: geometry.size.height)
                            .mask(
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0.0),
                                        .init(color: .white, location: 0.3)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    }

                    // Bottom gradient
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .clear, location: 0.3),
                            .init(color: MobileColors.background.opacity(0.7), location: 0.6),
                            .init(color: MobileColors.background, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    // Content overlay
                    VStack(alignment: .leading, spacing: 8) {
                        Spacer()

                        // Title
                        Text(displayTitle)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .frame(maxWidth: geometry.size.width * 0.55, alignment: .leading)
                            .shadow(color: .black.opacity(0.8), radius: 6, x: 0, y: 2)

                        // Episode info or video title
                        if currentItem.type == .episode {
                            if isYouTubeContent {
                                Text(currentItem.name)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .lineLimit(1)
                                    .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                            } else {
                                Text(formatEpisodeInfo(currentItem))
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                            }
                        }

                        // Metadata row
                        HStack(spacing: 12) {
                            if let rating = currentItem.communityRating {
                                HStack(spacing: 4) {
                                    Image("TMDBLogo")
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(height: 14)
                                    Text(String(format: "%.1f", rating))
                                        .fontWeight(.semibold)
                                }
                            }

                            if isYouTubeContent {
                                if let dateStr = currentItem.premiereDate {
                                    Text(formatDate(dateStr))
                                }
                                HStack(spacing: 4) {
                                    Image(systemName: "play.rectangle.fill")
                                    Text("YouTube")
                                }
                                .foregroundStyle(.red)
                            } else {
                                if let year = currentItem.productionYear {
                                    Text(String(year))
                                }

                                if let runtime = currentItem.runTimeTicks {
                                    Text(formatRuntime(runtime))
                                }
                            }
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))

                        // Description
                        if let overview = currentItem.overview, !overview.isEmpty {
                            Text(overview)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(3)
                                .frame(maxWidth: geometry.size.width * 0.55, alignment: .leading)
                        }

                        // Page indicators
                        if items.count > 1 {
                            HStack(spacing: 6) {
                                ForEach(0..<min(items.count, 10), id: \.self) { index in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(.white.opacity(0.3))
                                            .frame(width: index == safeIndex ? 24 : 6, height: 3)
                                        if index == safeIndex {
                                            Capsule()
                                                .fill(.white)
                                                .frame(width: 24 * progress, height: 3)
                                        } else if index < safeIndex {
                                            Capsule()
                                                .fill(.white.opacity(0.7))
                                                .frame(width: 6, height: 3)
                                        }
                                    }
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(MobileSpacing.md)
                }
            }
            .frame(maxWidth: 720)
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.large))
            .overlay(
                RoundedRectangle(cornerRadius: MobileCornerRadius.large)
                    .stroke(.white.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .onAppear {
            startAutoAdvance()
        }
        .onDisappear {
            stopAutoAdvance()
        }
        // Swipe gestures to manually change
        .gesture(
            DragGesture(minimumDistance: 50)
                .onEnded { value in
                    if value.translation.width < 0 {
                        // Swipe left - next
                        withAnimation {
                            currentIndex = (currentIndex + 1) % items.count
                        }
                        progress = 0
                    } else if value.translation.width > 0 {
                        // Swipe right - previous
                        withAnimation {
                            currentIndex = (currentIndex - 1 + items.count) % items.count
                        }
                        progress = 0
                    }
                }
        )
    }

    private var heroImage: some View {
        Group {
            if let url = imageURL {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle()
                            .fill(MobileColors.cardBackground)
                    }
                }
            } else {
                Rectangle()
                    .fill(MobileColors.cardBackground)
            }
        }
    }

    private func startAutoAdvance() {
        guard items.count > 1 else { return }
        progress = 0
        autoAdvanceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            DispatchQueue.main.async {
                progress += 0.1 / 8  // 8 seconds per item
                if progress >= 1.0 {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        currentIndex = (currentIndex + 1) % items.count
                    }
                    progress = 0
                }
            }
        }
    }

    private func stopAutoAdvance() {
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil
    }

    private func formatRuntime(_ ticks: Int64) -> String {
        let seconds = ticks / 10_000_000
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private func formatEpisodeInfo(_ item: BaseItemDto) -> String {
        let season = item.parentIndexNumber ?? 1
        let episode = item.indexNumber ?? 1
        return "S\(season) E\(episode) - \(item.name)"
    }

    private func formatDate(_ isoDate: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoDate) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .none
            return displayFormatter.string(from: date)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoDate) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .none
            return displayFormatter.string(from: date)
        }
        return ""
    }
}
