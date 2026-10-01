import SwiftUI

/// Widths shared by the rail and the content beside it. Kept outside the
/// generic `SidebarRail` because generic types can't hold static stored
/// properties.
enum SidebarRailMetrics {
    /// Width of every icon column, so the icons and the ☰ toggle line up on
    /// one vertical axis in both states.
    static let iconWidth: CGFloat = 24
    /// The always-visible rail. The content is laid out beside this width and
    /// never moves when the rail expands.
    static let collapsedWidth: CGFloat = iconWidth + MobileSpacing.md * 2
    /// The expanded rail, drawn over the (dimmed) content.
    static let expandedWidth: CGFloat = 260
    /// Minimum height of the header bar's content (the 40pt avatar used to set
    /// it). The ☰ row uses the same height so it sits level with the header.
    static let barContentHeight: CGFloat = 40
    /// Size of the account avatar at the foot of the rail.
    static let avatarSize: CGFloat = 40
}

/// The iPad's TV-style navigation rail: a slim icon-only strip that is always
/// on screen, expanding over the content to icon + label when ☰ is tapped.
/// Selection and collapse policy belong to the caller (`onSelect`), which
/// owns the navigation state.
struct SidebarRail<Footer: View>: View {
    let libraries: [JellyfinLibrary]
    let selection: SidebarSelection
    @Binding var isExpanded: Bool
    let onSelect: (SidebarSelection) -> Void
    /// Drawn pinned to the foot of the rail (the account / server menu). It is
    /// told whether the rail is expanded so it can add a label.
    @ViewBuilder let footer: (_ isExpanded: Bool) -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toggleRow

            // The section group sits vertically centred between ☰ and Settings,
            // as on the tvOS rail, in both states so icons don't jump when the
            // rail opens. It scrolls from the top when a long library list
            // can't fit, so Settings and the account menu are never pushed off
            // the bottom (the fault a user reported on Roku's rail).
            GeometryReader { geometry in
                ScrollView(.vertical, showsIndicators: false) {
                    sectionList
                        .frame(
                            maxWidth: .infinity,
                            minHeight: geometry.size.height,
                            alignment: .leading
                        )
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxHeight: .infinity)

            divider
            row(.settings)

            footer(isExpanded)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Centres the avatar on the icon column above it.
                .padding(.horizontal, (SidebarRailMetrics.collapsedWidth - SidebarRailMetrics.avatarSize) / 2)
                .padding(.top, MobileSpacing.sm)
                .padding(.bottom, MobileSpacing.xs)

            // Expanded only, but its line is reserved in both states: if it
            // came and went, the space above would change height and the
            // centred section icons would jump as the rail opens.
            if let version = Self.versionLabel {
                Text(version)
                    .font(MobileTypography.caption)
                    .foregroundStyle(MobileColors.textTertiary)
                    .lineLimit(1)
                    .padding(.horizontal, MobileSpacing.md)
                    .padding(.bottom, MobileSpacing.sm)
                    .opacity(isExpanded ? 1 : 0)
                    .accessibilityHidden(!isExpanded)
            }
        }
        .frame(
            width: isExpanded ? SidebarRailMetrics.expandedWidth : SidebarRailMetrics.collapsedWidth
        )
        .frame(maxHeight: .infinity, alignment: .top)
        // Labels fade in while the width is still animating; keep them inside
        // the rail rather than painting over the content.
        .clipped()
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: isExpanded ? MobileCornerRadius.xl : 0,
                topTrailingRadius: isExpanded ? MobileCornerRadius.xl : 0
            )
            .fill(MobileColors.cardBackground)
            .shadow(color: .black.opacity(isExpanded ? 0.4 : 0), radius: 12, x: 4)
            .ignoresSafeArea()
        }
    }

    /// "Version 1.6.17 (1234)", read from the bundle as the Settings screen's
    /// About section does. Shown only in the expanded rail.
    private static var versionLabel: String? {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return nil }
        if let build = info?["CFBundleVersion"] as? String {
            return "Version \(version) (\(build))"
        }
        return "Version \(version)"
    }

    /// Home, SashimiTV, the libraries, Search and Downloads.
    private var sectionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(.home)
            // The guide is iPad-only: three hours of grid wants a wide
            // screen, and the phone gets the channels row on Home.
            row(.finTV)

            divider

            ForEach(libraries) { library in
                row(.library(
                    id: library.id,
                    name: library.name,
                    collectionType: library.collectionType
                ))
            }

            divider

            row(.search)
            row(.downloads)
        }
    }

    private var toggleRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: MobileSpacing.md) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 22))
                    .frame(width: SidebarRailMetrics.iconWidth)
                if isExpanded {
                    HStack(spacing: MobileSpacing.xs) {
                        Image("SidebarLogo")
                            .resizable().scaledToFit()
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.medium))
                        Text("Sashimi")
                            .font(.system(size: 20, weight: .bold))
                            .lineLimit(1)
                    }
                    .transition(.opacity)
                }
            }
            .foregroundStyle(MobileColors.textPrimary)
            .frame(
                maxWidth: .infinity,
                minHeight: SidebarRailMetrics.barContentHeight,
                alignment: .leading
            )
            .padding(.horizontal, MobileSpacing.md)
            .padding(.vertical, MobileSpacing.sm)
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
            HStack(spacing: MobileSpacing.md) {
                Image(systemName: item.icon)
                    .font(.system(size: 20))
                    .frame(width: SidebarRailMetrics.iconWidth)
                if isExpanded {
                    Text(item.displayName)
                        .font(MobileTypography.body)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            .foregroundStyle(isSelected ? MobileColors.accent : MobileColors.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MobileSpacing.md)
            .padding(.vertical, MobileSpacing.sm)
            .background(isSelected ? MobileColors.accent.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Collapsed rows are icon-only; name them for VoiceOver either way.
        .accessibilityLabel(item.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var divider: some View {
        Rectangle()
            .fill(MobileColors.textTertiary.opacity(0.3))
            .frame(height: 1)
            .padding(.horizontal, MobileSpacing.sm)
            .padding(.vertical, MobileSpacing.xs)
    }
}
