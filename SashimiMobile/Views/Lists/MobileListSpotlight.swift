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
                        .notOnServerDimmed(poster.isDimmed)
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

/// A list's page on iPhone, iPad and Mac (design §6, "Spotlight"): the
/// selected title's backdrop, details and actions over the poster grid. The
/// backdrop sits where the detail pages' does (#894): on a landscape page
/// bright across the right two thirds with the details on the dark left
/// side, as on Apple TV; on a portrait page across the top with the details
/// under it. A tap on a poster selects it (`ListSpotlightTap`) and scrolls
/// back up to show it; `selectionCount` counts those taps.
struct MobileListSpotlightPage<Actions: View, Notice: View, Content: View>: View {
    let eyebrow: String
    let spotlight: ListSpotlight?
    /// Goes up by one each time a tap selects a title.
    let selectionCount: Int
    @ViewBuilder let actions: () -> Actions
    /// Under the actions: the Plex card, an edit-mode hint.
    @ViewBuilder let notice: () -> Notice
    @ViewBuilder let content: () -> Content

    @State private var pageSize: CGSize = .zero
    /// The page's right safe-area margin (a sideways iPhone): the picture
    /// runs on under it to the screen's edge.
    @State private var trailingInset: CGFloat = 0
    private static var topId: String { "spotlight-top" }

    var body: some View {
        let layout = SpotlightBackdropLayout.fitting(pageSize)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: MobileSpacing.md) {
                    details(layout: layout)
                        .id(Self.topId)
                    content()
                        .padding(.horizontal, MobileSpacing.md)
                }
                .padding(.bottom, MobileSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .topTrailing) { backdrop(layout: layout) }
            }
            .onChange(of: selectionCount) { _, _ in
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(Self.topId, anchor: .top) }
            }
        }
        .background(MobileColors.background)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { pageSize = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.trailing } action: { trailingInset = $0 }
    }

    private func details(layout: SpotlightBackdropLayout) -> some View {
        VStack(alignment: .leading, spacing: MobileSpacing.xs) {
            Text(eyebrow.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .kerning(1)
                .foregroundStyle(MobileColors.textSecondary)
                .lineLimit(1)
            if let spotlight {
                VStack(alignment: .leading, spacing: MobileSpacing.xs) {
                    Text(spotlight.title)
                        .font(MobileTypography.displayLarge)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 6)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
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
                .id(spotlight.id)
                .transition(.opacity)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MobileSpacing.sm) {
                    actions()
                }
                .font(.system(size: 15, weight: .semibold))
                .padding(.vertical, 2)
            }
            .padding(.top, MobileSpacing.xxs)
            notice()
        }
        .animation(.easeInOut(duration: 0.25), value: spotlight?.id)
        .frame(maxWidth: layout.detailsMaxWidth(in: pageSize), alignment: .leading)
        .padding(.horizontal, MobileSpacing.md)
        .padding(.top, layout.contentStartsAt == nil ? MobileSpacing.xl : layout.contentInset(in: pageSize))
        .frame(minHeight: layout.detailsMinHeight(in: pageSize), alignment: .top)
    }

    /// The picture alone, in the detail pages' frame and fade.
    private func backdrop(layout: SpotlightBackdropLayout) -> some View {
        let frame = layout.frame(in: pageSize)
        let pixels = layout.requestPixelWidth(in: pageSize, scale: ImageSizing.displayScale)
        // Widened by the right safe-area margin and moved under it, so the
        // picture reaches the screen's edge rather than stopping short of it.
        return image(pixelWidth: pixels)
            .frame(width: frame.width + trailingInset, height: frame.height)
            .clipped()
            .spotlightFade(layout)
            .offset(x: trailingInset)
            .id(spotlight?.id)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.4), value: spotlight?.id)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func image(pixelWidth: Int) -> some View {
        switch spotlight?.backdrop {
        case .library(let itemId, let imageType):
            LazyImage(url: JellyfinClient.shared.syncImageURL(itemId: itemId, imageType: imageType, maxWidth: pixelWidth)) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Color.clear
                }
            }
            .pipeline(SashimiImagePipeline.shared)
        case .remote(let url):
            if spotlight?.hasBackdropImage == true {
                SeerrArtwork(url: url, title: "", cornerRadius: 0)
            } else {
                // A poster standing in for a backdrop: only a soft wash of it.
                SeerrArtwork(url: url, title: "", cornerRadius: 0)
                    .blur(radius: 24)
                    .grayscale(1)
                    .brightness(-0.3)
            }
        case .none?, nil:
            Color.clear
        }
    }
}

/// Opens the title the Spotlight shows: the second way in, beside Play.
struct MobileListSpotlightDetailsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(ListSpotlightText.details, systemImage: "info.circle") }
            .buttonStyle(.bordered)
    }
}

extension View {
    /// The selected poster's ring, around the picture (not its caption).
    func listSpotlightSelected(_ isSelected: Bool, width: CGFloat = PhoneSizing.posterWidth) -> some View {
        overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: MobileCornerRadius.medium)
                .strokeBorder(MobileColors.accent, lineWidth: 3)
                .frame(width: width, height: width / PosterAspectRatio.portrait)
                .opacity(isSelected ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: isSelected)
                .allowsHitTesting(false)
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
