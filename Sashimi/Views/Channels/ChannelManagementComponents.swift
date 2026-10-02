import SwiftUI

/// A full-width choosable row in the channel-management screens: logo, name,
/// a detail line, and a trailing mark. Settings-style focus treatment.
struct ChannelChoiceRow: View {
    enum Trailing: Equatable {
        case none
        case checkmark
        /// Checked through a rule: shown, dimmed, with its reason.
        case viaRule(String)
        case chevron
        case remove
    }

    let logoKey: String?
    var showsLogo = true
    let title: String
    var detail: String?
    var systemImage: String?
    var trailing: Trailing = .none
    var isEnabled = true
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 22) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 30, weight: .semibold))
                        .frame(width: 56, height: 56)
                } else if showsLogo {
                    ChannelLogoKeyView(key: logoKey, name: title, size: 56)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(SashimiTheme.textPrimary)
                        .lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 20))
                            .foregroundStyle(SashimiTheme.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 12)
                trailingMark
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 16)
            .focusHighlight(isFocused, cornerRadius: 16)
            .opacity(isEnabled ? 1 : 0.55)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .disabled(!isEnabled)
    }

    @ViewBuilder
    private var trailingMark: some View {
        switch trailing {
        case .none:
            EmptyView()
        case .checkmark:
            Image(systemName: "checkmark")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(SashimiTheme.accent)
        case .viaRule(let label):
            HStack(spacing: 10) {
                Text(label)
                    .font(.system(size: 20))
                    .foregroundStyle(SashimiTheme.textTertiary)
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(SashimiTheme.textTertiary)
            }
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(SashimiTheme.textSecondary)
        case .remove:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(isFocused ? SashimiTheme.error : SashimiTheme.textSecondary)
        }
    }
}

/// The logo picker: "No logo" then every key the plugin ships, six across.
/// Its own focus section so Down from the name field lands in it and Down
/// out of it reaches whatever follows, rather than the beam skipping rows.
struct ChannelLogoGrid: View {
    let keys: [String]
    let selected: String?
    var isEnabled = true
    let onSelect: (String?) -> Void

    private let columns = Array(repeating: GridItem(.fixed(150), spacing: 24), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
            LogoTile(key: nil, isSelected: selected == nil, isEnabled: isEnabled) { onSelect(nil) }
            ForEach(keys, id: \.self) { key in
                LogoTile(key: key, isSelected: selected == key, isEnabled: isEnabled) { onSelect(key) }
            }
        }
        .focusSection()
    }

    private struct LogoTile: View {
        let key: String?
        let isSelected: Bool
        let isEnabled: Bool
        let action: () -> Void

        @FocusState private var isFocused: Bool

        var body: some View {
            Button(action: action) {
                VStack(spacing: 10) {
                    ZStack(alignment: .topTrailing) {
                        if let key {
                            ChannelLogoKeyView(key: key, name: key, size: 84)
                        } else {
                            Image(systemName: "nosign")
                                .font(.system(size: 40))
                                .foregroundStyle(SashimiTheme.textSecondary)
                                .frame(width: 84, height: 84)
                        }
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(SashimiTheme.accent)
                                .background(Circle().fill(Color.white))
                                .offset(x: 14, y: -10)
                        }
                    }
                    Text(key.map(ChannelLogoKeyView.displayName(for:)) ?? "No logo")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isSelected ? SashimiTheme.textPrimary : SashimiTheme.textSecondary)
                        .lineLimit(1)
                }
                .frame(width: 150, height: 150)
                .focusHighlight(isFocused, cornerRadius: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(SashimiTheme.accent, lineWidth: isSelected && !isFocused ? 3 : 0)
                )
            }
            .buttonStyle(PlainNoHighlightButtonStyle())
            .focused($isFocused)
            .disabled(!isEnabled)
            .accessibilityLabel(key.map(ChannelLogoKeyView.displayName(for:)) ?? "No logo")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

/// A screen title over a one-line explanation.
struct ChannelScreenHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(SashimiTheme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 24))
                    .foregroundStyle(SashimiTheme.textSecondary)
            }
        }
    }
}

/// Loading and failure states that still give focus somewhere to rest. A
/// full-screen cover with nothing focusable leaves the remote dead.
struct ChannelLoadState: View {
    let isLoading: Bool
    let message: String?
    let retry: () -> Void

    var body: some View {
        if isLoading {
            ProgressView()
                .padding(.top, 40)
                .focusable()
                .focusEffectDisabled()
        } else {
            VStack(alignment: .leading, spacing: 24) {
                Text(message ?? "Couldn't load channels.")
                    .font(.system(size: 26))
                    .foregroundStyle(SashimiTheme.textSecondary)
                ActionButton(title: "Try Again", icon: "arrow.clockwise", action: retry)
            }
            .padding(.top, 40)
        }
    }
}
