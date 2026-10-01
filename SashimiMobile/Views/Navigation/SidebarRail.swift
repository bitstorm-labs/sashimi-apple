import SwiftUI

/// Sizes shared by the rail and the content beside it. Kept outside the
/// generic `SidebarRail` because generic types can't hold static stored
/// properties. They are the tvOS rail's (`MainTabView.sidebar`) scaled from a
/// 1920pt ten-foot screen down to an iPad held in the hand.
enum SidebarRailMetrics {
    /// The always-visible rail. The content is laid out beside this width and
    /// never moves when the rail expands.
    static let collapsedWidth: CGFloat = 76
    /// The expanded rail, drawn over the (dimmed) content.
    static let expandedWidth: CGFloat = 280
    /// Width of every icon column, so the icons, the logo and the avatar share
    /// one vertical axis.
    static let iconWidth: CGFloat = 32
    /// Minimum height of the header bar beside the rail, so the content doesn't
    /// jump when the download indicator comes and goes.
    static let barContentHeight: CGFloat = 40
    /// Size of the account avatar at the foot of the rail.
    static let avatarSize: CGFloat = 40

    /// Side insets of the rail's contents. Collapsed, they centre a 60pt
    /// column; expanded, they match the tvOS panel's lopsided inset.
    static let collapsedInset: CGFloat = 8
    static let expandedLeadingInset: CGFloat = 16
    static let expandedTrailingInset: CGFloat = 12
    /// Extra inset of each row's icon when expanded. Chosen so the icon column
    /// lines up under the centre of the 48pt expanded logo.
    static let expandedRowInset: CGFloat = 8

    static let logoCollapsed: CGFloat = 40
    static let logoExpanded: CGFloat = 48

    /// Jellyfin purple, sampled from the logo — the selected row's tint, as on
    /// the tvOS rail.
    static let selectedTint = Color(red: 189 / 255, green: 62 / 255, blue: 237 / 255)
    /// The tvOS rail's expand/collapse animation.
    static let animation = Animation.easeInOut(duration: 0.28)
}

/// The iPad's navigation rail, drawn to match the Apple TV's: the sushi mark
/// at the top, the destinations centred between it and the account avatar, the
/// version underneath. It is a slim icon strip that is always on screen and
/// expands over the content to icon + label when the mark is tapped.
/// Selection and collapse policy belong to the caller (`onSelect`), which owns
/// the navigation state.
struct SidebarRail<Footer: View>: View {
    let libraries: [JellyfinLibrary]
    let selection: SidebarSelection
    @Binding var isExpanded: Bool
    let onSelect: (SidebarSelection) -> Void
    /// Drawn at the foot of the rail, above the version (the account / server
    /// menu). It is told whether the rail is expanded so it can add a label.
    @ViewBuilder let footer: (_ isExpanded: Bool) -> Footer

    /// The rail lists destinations in the order Home lists them.
    @ObservedObject private var homeRows = HomeRowSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            logoButton

            // Centred between the logo and the avatar when it fits, as on tvOS.
            // A long library list scrolls instead: unlike the TV, a touch rail
            // has no focus to drag through the rows as it scrolls.
            GeometryReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(navItems, id: \.self) { item in
                            row(item)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding(.vertical, 16)

            footer(isExpanded)
                .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)

            versionLabel
        }
        .padding(.top, 12)
        .padding(.bottom, 16)
        .padding(
            .leading,
            isExpanded ? SidebarRailMetrics.expandedLeadingInset : SidebarRailMetrics.collapsedInset
        )
        .padding(
            .trailing,
            isExpanded ? SidebarRailMetrics.expandedTrailingInset : SidebarRailMetrics.collapsedInset
        )
        .frame(
            width: isExpanded ? SidebarRailMetrics.expandedWidth : SidebarRailMetrics.collapsedWidth,
            alignment: .leading
        )
        .frame(maxHeight: .infinity, alignment: .top)
        // Labels fade in while the width is still animating; keep them inside
        // the rail rather than painting over the content.
        .clipped()
        // Dim the contents while the rail rests, full when it is open. Applied
        // before .background so only the foreground fades, not the rail.
        .opacity(isExpanded ? 1 : 0.68)
        .background {
            LinearGradient(
                colors: [MobileColors.background, Color.black],
                startPoint: .top, endPoint: .bottom
            )
            .overlay(
                LinearGradient(
                    colors: [Color.black.opacity(isExpanded ? 0.35 : 0), Color.clear],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .ignoresSafeArea()
        }
        // Hairline right edge so the rail reads as a defined strip.
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1)
                .ignoresSafeArea()
        }
        .animation(SidebarRailMetrics.animation, value: isExpanded)
    }

    /// Home, then SashimiTV and the libraries in Home's row order, then Search,
    /// Downloads (iPad only) and Settings.
    private var navItems: [SidebarSelection] {
        var items: [SidebarSelection] = [.home]
        for destination in RailOrder.destinations(
            rowConfigs: homeRows.rows,
            libraryIds: libraries.map(\.id)
        ) {
            switch destination {
            case .finTV:
                items.append(.finTV)
            case .library(let id):
                guard let library = libraries.first(where: { $0.id == id }) else { continue }
                items.append(.library(
                    id: library.id,
                    name: library.name,
                    collectionType: library.collectionType
                ))
            }
        }
        items += [.search, .downloads, .settings]
        return items
    }

    /// The sushi mark, with the "Sashimi" wordmark beside it when expanded.
    /// It is the rail's open/close control.
    private var logoButton: some View {
        Button {
            withAnimation(SidebarRailMetrics.animation) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                let logoSize = isExpanded ? SidebarRailMetrics.logoExpanded : SidebarRailMetrics.logoCollapsed
                Image("SidebarLogoMark")
                    .resizable().scaledToFit()
                    .frame(width: logoSize, height: logoSize)
                if isExpanded {
                    Text("Sashimi")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)
            .frame(height: SidebarRailMetrics.logoExpanded)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Close menu" : "Open menu")
    }

    private func row(_ item: SidebarSelection) -> some View {
        let isSelected = selection == item
        return Button {
            onSelect(item)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: item.icon)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: SidebarRailMetrics.iconWidth)
                if isExpanded {
                    Text(item.displayName)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .transition(.opacity)
                }
            }
            .padding(.vertical, 11)
            .padding(.horizontal, isExpanded ? SidebarRailMetrics.expandedRowInset : 0)
            .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)
        }
        .buttonStyle(RailButtonStyle(isSelected: isSelected))
        // Collapsed rows are icon-only; name them for VoiceOver either way.
        .accessibilityLabel(item.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// "v1.6.18", as the tvOS rail shows it: under the avatar in both states.
    private var versionLabel: some View {
        Text("v" + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.4))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)
            .padding(.top, 6)
            .padding(.leading, isExpanded ? SidebarRailMetrics.expandedRowInset : 0)
    }
}

/// The tvOS rail's row tint, with a press standing in for focus: pressed is
/// white on the soft highlight tvOS draws under the focused row, selected is
/// Jellyfin purple, anything else is dimmed white. No selection band.
private struct RailButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint(isPressed: configuration.isPressed))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0))
            )
            .contentShape(Rectangle())
    }

    private func tint(isPressed: Bool) -> Color {
        if isPressed { return .white }
        if isSelected { return SidebarRailMetrics.selectedTint }
        return .white.opacity(0.55)
    }
}
