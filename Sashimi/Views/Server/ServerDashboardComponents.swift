import SwiftUI

// The pieces of the tvOS Server dashboard (layout A).

extension PlayMode {
    var tint: Color {
        switch self {
        case .directPlay: return SashimiTheme.success
        case .convertingAudio: return SashimiTheme.link
        case .convertingVideo: return SashimiTheme.accentSecondary
        }
    }
}

extension DashboardTone {
    var color: Color {
        switch self {
        case .ok, .added: return SashimiTheme.success
        case .warning: return SashimiTheme.accentSecondary
        case .failure: return SashimiTheme.error
        case .playback: return SashimiTheme.accent
        case .signIn: return SashimiTheme.link
        case .neutral: return SashimiTheme.textTertiary
        }
    }
}

struct PlayModeBadge: View {
    let mode: PlayMode

    var body: some View {
        Text(mode.title)
            .font(Typography.captionSmall.weight(.bold))
            .foregroundStyle(mode.tint)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(mode.tint.opacity(0.18), in: Capsule())
    }
}

/// "3 streaming" in the header.
struct ServerCountPill: View {
    let value: String
    let label: String
    var tint: Color = SashimiTheme.textPrimary

    var body: some View {
        HStack(spacing: 8) {
            Text(value).fontWeight(.bold).foregroundStyle(tint)
            Text(label).foregroundStyle(SashimiTheme.textPrimary)
        }
        .font(Typography.bodySmall)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(SashimiTheme.cardBackground, in: RoundedRectangle(cornerRadius: CornerRadius.large))
    }
}

/// One stream. Selecting it opens the stream sheet (Details, Stop, Message).
struct ServerSessionCard: View {
    let session: DashboardSession
    let action: () -> Void
    @FocusState private var isFocused: Bool

    private var item: DashboardNowPlaying? { session.nowPlayingItem }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 20) {
                    SmartPosterImage(itemIds: item?.posterItemIds ?? [], maxWidth: 240, imageTypes: ["Primary"])
                        .frame(width: 120, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium))

                    VStack(alignment: .leading, spacing: 8) {
                        Text(item?.displayTitle ?? "")
                            .font(Typography.title)
                            .foregroundStyle(SashimiTheme.textPrimary)
                            .lineLimit(2)
                        Text(ServerDashboardLogic.viewerLine(session))
                            .font(Typography.bodySmall)
                            .foregroundStyle(SashimiTheme.textSecondary)
                            .lineLimit(1)
                        PlayModeBadge(mode: ServerDashboardLogic.playMode(session.transcodingInfo))
                        Text(ServerDashboardLogic.detailLine(for: session))
                            .font(Typography.caption)
                            .foregroundStyle(SashimiTheme.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }

                SashimiProgressBar(
                    progress: ServerDashboardLogic.progressFraction(
                        positionTicks: session.playState?.positionTicks,
                        runTimeTicks: item?.runTimeTicks
                    ),
                    height: 8
                )

                HStack {
                    Text(ServerDashboardLogic.progressText(
                        positionTicks: session.playState?.positionTicks,
                        runTimeTicks: item?.runTimeTicks
                    ) ?? "")
                    Spacer()
                    Text(ServerDashboardLogic.rateLine(session))
                }
                .font(Typography.caption)
                .foregroundStyle(SashimiTheme.textSecondary)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusHighlight(isFocused, cornerRadius: CornerRadius.xl)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityLabel("\(item?.displayTitle ?? ""), \(ServerDashboardLogic.viewerLine(session))")
    }
}

/// Activity or Health. Focusable so Down from the streams reaches it and the
/// page scrolls; it has no action.
struct ServerDashboardPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(Typography.title)
                .foregroundStyle(SashimiTheme.textSecondary)
                .padding(.bottom, 6)
            content()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .focusable()
        .focused($isFocused)
        .focusHighlight(isFocused, cornerRadius: CornerRadius.xl, scales: false)
    }
}

/// A coloured dot, a line of text and a trailing value.
struct ServerDotRow: View {
    let tone: DashboardTone
    let text: String
    let value: String

    var body: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(tone.color)
                .frame(width: 12, height: 12)
            Text(text)
                .foregroundStyle(tone == .failure ? SashimiTheme.error : SashimiTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(SashimiTheme.textTertiary)
                .lineLimit(1)
        }
        .font(Typography.bodySmall)
    }
}

/// A non-interactive message that can still hold focus, so the screen never
/// leaves the remote with nothing to land on.
struct ServerFocusableMessage: View {
    let icon: String
    let title: String
    var message: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundStyle(SashimiTheme.textTertiary)
            Text(title)
                .font(Typography.headlineSmall)
                .foregroundStyle(SashimiTheme.textPrimary)
            if let message {
                Text(message)
                    .font(Typography.body)
                    .foregroundStyle(SashimiTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity)
        .focusable()
        .focused($isFocused)
        .focusHighlight(isFocused, cornerRadius: CornerRadius.xl, scales: false)
    }
}
