import SwiftUI

/// A list's page on Apple TV, "Spotlight" (design §6): the focused title fills
/// the top with its backdrop, details and actions, and the list's posters run
/// in one row along the bottom. The backdrop follows focus.
struct ListSpotlightPage<Actions: View, Notice: View, Posters: View>: View {
    /// "WATCHLIST · 8 titles", over the title.
    let eyebrow: String
    /// Nil while loading or for an empty list.
    let spotlight: ListSpotlight?
    @ViewBuilder let actions: () -> Actions
    /// A line under the actions: the Plex card, an edit-mode hint.
    @ViewBuilder let notice: () -> Notice
    @ViewBuilder let posters: () -> Posters

    var body: some View {
        ZStack(alignment: .topLeading) {
            SashimiTheme.background.ignoresSafeArea()
            ListSpotlightBackdrop(spotlight: spotlight)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(eyebrow.uppercased())
                        .font(.system(size: 22, weight: .semibold))
                        .kerning(1.5)
                        .foregroundStyle(SashimiTheme.textSecondary)
                        .lineLimit(1)
                    if let spotlight {
                        details(spotlight)
                    }
                    HStack(spacing: 30) {
                        actions()
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 10)
                    .focusSection()
                    notice()
                }
                .frame(maxWidth: 1000, alignment: .leading)
                .animation(.easeInOut(duration: 0.25), value: spotlight?.id)

                Spacer(minLength: 20)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        posters()
                    }
                    .padding(.vertical, 24)
                    .padding(.horizontal, 80)
                }
                .scrollClipDisabled()
                .focusSection()
                .padding(.horizontal, -80)
            }
            .padding(.horizontal, 80)
            .padding(.top, 50)
            .padding(.bottom, 30)
        }
    }

    private func details(_ spotlight: ListSpotlight) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(spotlight.title)
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 8)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            HStack(spacing: 16) {
                if let tag = spotlight.tag {
                    SeerrStatusTag(label: tag, color: .white, fontSize: 20, onArtwork: true)
                }
                if !spotlight.details.isEmpty {
                    Text(spotlight.details)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(SashimiTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            if let overview = spotlight.overview {
                Text(overview)
                    .font(.system(size: 26))
                    .foregroundStyle(SashimiTheme.textPrimary.opacity(0.85))
                    .lineLimit(3)
                    .frame(maxWidth: 900, alignment: .leading)
            }
        }
        .id(spotlight.id)
        .transition(.opacity)
    }
}

/// The focused title's backdrop, top right, fading into the page on its left
/// and bottom. A title the server doesn't have shows its poster, blurred and grey.
struct ListSpotlightBackdrop: View {
    let spotlight: ListSpotlight?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                Color.clear
                image(width: geometry.size.width * 0.7)
                    .frame(width: geometry.size.width * 0.7, height: geometry.size.height * 0.8)
                    .clipped()
                    .mask(
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.45)],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .mask(
                        LinearGradient(stops: [.init(color: .black, location: 0.5), .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .id(spotlight?.id)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.5), value: spotlight?.id)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func image(width: CGFloat) -> some View {
        switch spotlight?.backdrop {
        case .library(let itemId, let imageType):
            AsyncItemImage(
                itemId: itemId,
                imageType: imageType,
                maxWidth: ImageSizing.pixelWidth(points: width),
                contentMode: .fill,
                fallbackImageTypes: imageType == "Backdrop" ? ["Thumb", "Primary"] : []
            )
        case .remote(let url):
            SeerrArtwork(url: url, title: "", cornerRadius: 0)
                .blur(radius: 30)
                .grayscale(1)
                .brightness(-0.3)
        case .none?, nil:
            Color.clear
        }
    }
}

/// A list page's Play / Request / Sign in to Requests button, for whatever
/// the Spotlight shows.
struct ListSpotlightActionButton: View {
    let action: ListSpotlight.Action
    let onPlay: (BaseItemDto) -> Void
    let onRequest: (SeerrTarget) -> Void
    let onSignIn: () -> Void

    var body: some View {
        switch action {
        case .play(let item):
            ActionButton(title: "Play", icon: "play.fill", isPrimary: true) { onPlay(item) }
        case .request(let target):
            ActionButton(title: "Request", icon: "arrow.down.circle", isPrimary: true) { onRequest(target) }
        case .signInToRequests:
            ActionButton(title: ListSpotlightText.signInToRequests, icon: "person.crop.circle", isPrimary: true) { onSignIn() }
        case .none:
            EmptyView()
        }
    }
}

/// Requests settings over a list's page, for Sign in to Requests.
struct RequestsSignInCover: View {
    var body: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()
            RequestsSettingsView()
        }
    }
}
