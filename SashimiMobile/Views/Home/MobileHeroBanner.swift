import NukeUI
import SwiftUI

/// Slim 32:9 auto-advancing hero for the iPad home (tvOS/Roku parity, compact
/// treatment): backdrop, title, year · runtime · rating, page capsules.
/// Advances every 6 seconds; swipe to browse; tap opens detail.
struct MobileHeroBanner: View {
    let items: [BaseItemDto]
    let libraryNames: [String: String]

    @State private var index = 0
    private let slideDuration: TimeInterval = 6

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(items.enumerated()), id: \.element.id) { pos, item in
                NavigationLink {
                    AdaptiveDetailView(item: item, libraryName: libraryNames[item.id])
                } label: {
                    heroCard(item)
                }
                .buttonStyle(.plain)
                .tag(pos)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .aspectRatio(32 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.large))
        .overlay(alignment: .bottomTrailing) { pageCapsules }
        .padding(.horizontal, MobileSpacing.md)
        .onReceive(Timer.publish(every: slideDuration, on: .main, in: .common).autoconnect()) { _ in
            guard items.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.5)) {
                index = (index + 1) % items.count
            }
        }
    }

    private func heroCard(_ item: BaseItemDto) -> some View {
        ZStack(alignment: .bottomLeading) {
            LazyImage(url: backdropURL(item)) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(MobileColors.cardBackground)
                }
            }

            // Left-side scrim for text legibility
            LinearGradient(
                colors: [.black.opacity(0.75), .black.opacity(0.35), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle(item))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.8), radius: 6, y: 2)
                Text(metaLine(item))
                    .font(MobileTypography.caption)
                    .foregroundStyle(MobileColors.textSecondary)
                    .lineLimit(1)
            }
            .padding(.leading, MobileSpacing.md)
            .padding(.bottom, MobileSpacing.sm)
            .frame(maxWidth: 500, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private var pageCapsules: some View {
        HStack(spacing: 5) {
            ForEach(0..<items.count, id: \.self) { pos in
                Capsule()
                    .fill(pos == index ? MobileColors.accent : Color.white.opacity(0.3))
                    .frame(width: pos == index ? 30 : 12, height: 4)
                    .animation(.easeInOut(duration: 0.3), value: index)
            }
        }
        .padding(.trailing, MobileSpacing.md)
        .padding(.bottom, MobileSpacing.sm)
    }

    private func displayTitle(_ item: BaseItemDto) -> String {
        if item.type == .episode {
            return (item.seriesName ?? item.name).cleanedYouTubeTitle
        }
        return item.name.cleanedYouTubeTitle
    }

    private func metaLine(_ item: BaseItemDto) -> String {
        var parts: [String] = []
        if let year = item.productionYear { parts.append(String(year)) }
        if let ticks = item.runTimeTicks, ticks > 0 {
            let minutes = Int(ticks / 10_000_000 / 60)
            parts.append(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m")
        }
        if let rating = item.communityRating, rating > 0 {
            parts.append(String(format: "★ %.1f", rating))
        }
        return parts.joined(separator: " · ")
    }

    /// Own backdrop when it exists, else the series backdrop (episodes),
    /// else the Primary image.
    private func backdropURL(_ item: BaseItemDto) -> URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }
        if item.backdropImageTags?.isEmpty == false {
            return URL(string: "\(serverURL)/Items/\(item.id)/Images/Backdrop?maxWidth=1600")
        }
        if item.type == .episode, let seriesId = item.seriesId {
            return URL(string: "\(serverURL)/Items/\(seriesId)/Images/Backdrop?maxWidth=1600")
        }
        return URL(string: "\(serverURL)/Items/\(item.id)/Images/Primary?maxWidth=1600")
    }
}
