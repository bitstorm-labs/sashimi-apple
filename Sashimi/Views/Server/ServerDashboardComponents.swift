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

extension DashboardStreamState {
    var color: Color {
        switch self {
        case .playing: return SashimiTheme.success
        case .paused: return SashimiTheme.accentSecondary
        case .other: return SashimiTheme.textTertiary
        }
    }
}

/// One pill on a stream card. The play-mode pill takes the badge's colour.
struct ServerStreamPill: View {
    let pill: DashboardPill
    let mode: PlayMode

    var body: some View {
        let tint = pill.kind.foreground ?? mode.tint
        Text(pill.text)
            .font(Typography.captionSmall.weight(.heavy))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(pill.kind.background ?? mode.tint.opacity(0.18), in: Capsule())
    }
}

/// The pills, wrapping onto a second line rather than clipping.
struct ServerStreamPills: View {
    let session: DashboardSession

    var body: some View {
        let mode = ServerDashboardLogic.playMode(session.transcodingInfo)
        WrappingHStack(spacing: 8, lineSpacing: 8) {
            ForEach(ServerDashboardLogic.pills(session)) { pill in
                ServerStreamPill(pill: pill, mode: mode)
            }
        }
    }
}

/// One stream, OpsDec style: poster with a state dot, title, viewer, progress,
/// pills, then why and where. Selecting it opens the stream sheet (Details,
/// Stop, Message).
struct ServerSessionCard: View {
    let session: DashboardSession
    let action: () -> Void
    @FocusState private var isFocused: Bool

    private var item: DashboardNowPlaying? { session.nowPlayingItem }
    private var title: DashboardCardTitle { ServerDashboardLogic.cardTitle(item) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 20) {
                    poster
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title.title)
                            .font(Typography.title)
                            .foregroundStyle(SashimiTheme.textPrimary)
                            .lineLimit(2)
                        titleLine
                        viewer
                        Text(ServerDashboardLogic.deviceLine(session))
                            .font(Typography.caption)
                            .foregroundStyle(SashimiTheme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                VStack(spacing: 6) {
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
                        Text(ServerDashboardLogic.percentText(session))
                    }
                    .font(Typography.caption)
                    .foregroundStyle(SashimiTheme.textSecondary)
                }

                ServerStreamPills(session: session)

                footer
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusHighlight(isFocused, cornerRadius: CornerRadius.xl)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityLabel("\(title.title), \(ServerDashboardLogic.viewerLine(session))")
    }

    private var poster: some View {
        SmartPosterImage(itemIds: item?.posterItemIds ?? [], maxWidth: 240, imageTypes: ["Primary"])
            .frame(width: 120, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium))
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(ServerDashboardLogic.streamState(session).color)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(SashimiTheme.background, lineWidth: 2))
                    .padding(8)
            }
    }

    private var titleLine: some View {
        HStack(spacing: 10) {
            if !title.sub.isEmpty {
                Text(title.sub).lineLimit(1)
            }
            if !title.ep.isEmpty {
                Text(title.ep)
                    .fontWeight(.heavy)
                    .foregroundStyle(SashimiTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(SashimiTheme.accent.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .font(Typography.bodySmall)
        .foregroundStyle(SashimiTheme.textSecondary)
    }

    private var viewer: some View {
        HStack(spacing: 10) {
            Text(ServerDashboardLogic.initial(of: session.userName))
                .font(Typography.captionSmall.weight(.heavy))
                .foregroundStyle(SashimiTheme.textPrimary)
                .frame(width: 36, height: 36)
                .background(SashimiTheme.textTertiary.opacity(0.45), in: Circle())
            Text(session.userName ?? "")
                .font(Typography.bodySmall.weight(.semibold))
                .foregroundStyle(SashimiTheme.textPrimary)
                .lineLimit(1)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Rectangle()
                .fill(SashimiTheme.textTertiary.opacity(0.3))
                .frame(height: 2)
            HStack(alignment: .firstTextBaseline) {
                Text(ServerDashboardLogic.footerReason(session)).lineLimit(1)
                Spacer(minLength: 12)
                Text(ServerDashboardLogic.whereLabel(session))
            }
            .font(Typography.caption)
            .foregroundStyle(SashimiTheme.textTertiary)
        }
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
