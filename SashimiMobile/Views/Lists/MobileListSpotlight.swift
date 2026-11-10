import NukeUI
import SwiftUI

/// A list's cover on the Lists page (design §6, "Poster stack"): the first
/// poster full size, the next two fanned behind it. Fans out a little under
/// the pointer (iPad, Mac).
struct MobilePosterStackCover: View {
    let posters: [ListCoverPoster]
    /// The SF Symbol on the placeholder poster of an empty list.
    let placeholder: String

    @State private var isHovered = false

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height * PosterStack.frontHeight
            let width = height * 2 / 3
            let left = geometry.size.width * PosterStack.leadingInset
            let top = (geometry.size.height - height) / 2
            ZStack(alignment: .topLeading) {
                if posters.isEmpty {
                    ZStack {
                        MobileColors.cardBackground
                        Image(systemName: placeholder)
                            .font(.system(size: 30))
                            .foregroundStyle(MobileColors.textTertiary)
                    }
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.medium))
                    .offset(x: left, y: top)
                }
                ForEach(PosterStack.layers(count: posters.count, fanned: isHovered), id: \.index) { layer in
                    let poster = posters[layer.index]
                    WatchlistArtworkView(artwork: poster.artwork, title: poster.title, width: width)
                        .grayscale(poster.isDimmed ? 1 : 0)
                        .brightness(poster.isDimmed ? -0.45 : 0)
                        .frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.medium))
                        .shadow(color: .black.opacity(layer.index == 0 ? 0.6 : 0.4), radius: layer.index == 0 ? 8 : 4,
                                x: layer.index == 0 ? 3 : 1)
                        .scaleEffect(layer.scale)
                        .rotationEffect(.degrees(layer.rotation))
                        .opacity(layer.opacity)
                        .offset(x: left + layer.xOffset * width, y: top)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isHovered)
        }
        .aspectRatio(PosterStack.aspectRatio, contentMode: .fit)
        .onHover { isHovered = $0 }
    }
}

/// The top of a list's page on iPhone, iPad and Mac (design §6, "Spotlight"):
/// the selected title's backdrop with its details and actions, above the
/// poster grid. The first title is selected; on iPad and Mac the pointer
/// selects the title under it.
struct MobileListSpotlightHeader<Actions: View>: View {
    let eyebrow: String
    let spotlight: ListSpotlight?
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.xs) {
            ZStack(alignment: .bottomLeading) {
                backdrop
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxHeight: 380)
                    .clipped()
                    .overlay(
                        LinearGradient(colors: [.clear, MobileColors.background], startPoint: .center, endPoint: .bottom)
                    )
                    .id(spotlight?.id)
                    .transition(.opacity)
                VStack(alignment: .leading, spacing: MobileSpacing.xxs) {
                    Text(eyebrow.uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .kerning(1)
                        .foregroundStyle(MobileColors.textSecondary)
                        .lineLimit(1)
                    if let spotlight {
                        Text(spotlight.title)
                            .font(MobileTypography.displayLarge)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 6)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, MobileSpacing.md)
                .padding(.bottom, MobileSpacing.xs)
            }
            .animation(.easeInOut(duration: 0.3), value: spotlight?.id)

            VStack(alignment: .leading, spacing: MobileSpacing.xs) {
                if let spotlight {
                    HStack(spacing: MobileSpacing.xs) {
                        if let tag = spotlight.tag {
                            Text(tag)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                        }
                        if !spotlight.details.isEmpty {
                            Text(spotlight.details)
                                .font(MobileTypography.caption)
                                .foregroundStyle(MobileColors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    if let overview = spotlight.overview {
                        Text(overview)
                            .font(MobileTypography.bodySmall)
                            .foregroundStyle(MobileColors.textPrimary.opacity(0.85))
                            .lineLimit(3)
                            .frame(maxWidth: 640, alignment: .leading)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: MobileSpacing.sm) {
                        actions()
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.vertical, 2)
                }
            }
            .padding(.horizontal, MobileSpacing.md)
        }
    }

    @ViewBuilder
    private var backdrop: some View {
        switch spotlight?.backdrop {
        case .library(let itemId, let imageType):
            ZStack {
                MobileColors.cardBackground
                LazyImage(url: JellyfinClient.shared.syncImageURL(
                    itemId: itemId, imageType: imageType, maxWidth: ImageSizing.pixelWidth(points: 900)
                )) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    }
                }
                .pipeline(SashimiImagePipeline.shared)
            }
        case .remote(let url):
            SeerrArtwork(url: url, title: "", cornerRadius: 0)
                .blur(radius: 24)
                .grayscale(1)
                .brightness(-0.3)
        case .none?, nil:
            MobileColors.cardBackground
        }
    }
}

/// Play, or Request / Sign in to Requests for a title the server doesn't have.
struct MobileListSpotlightAction: View {
    let action: ListSpotlight.Action
    let onPlay: (BaseItemDto) -> Void

    var body: some View {
        switch action {
        case .play(let item):
            Button { onPlay(item) } label: { Label(ListSpotlightText.play, systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .tint(MobileColors.accent)
        case .request(let target):
            NavigationLink { MobileSeerrDetailView(target: target) } label: {
                Label(ListSpotlightText.request, systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(MobileColors.accent)
        case .signInToRequests:
            NavigationLink { MobileRequestsSettingsView() } label: {
                Label(ListSpotlightText.signInToRequests, systemImage: "person.crop.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(MobileColors.accent)
        case .none:
            EmptyView()
        }
    }
}
