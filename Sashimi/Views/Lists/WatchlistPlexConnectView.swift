import SwiftUI

/// Connect Plex for the Watchlist on Apple TV: the plex.tv/link code, as
/// Settings › Requests shows it. It needs nothing from Requests, so it works
/// where Requests was never set up. Menu cancels.
struct WatchlistPlexConnectView: View {
    @StateObject private var model = PlexConnectModel()
    @Environment(\.dismiss) private var dismiss
    @State private var started = false

    var body: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 40) {
                ChannelScreenHeader(title: WatchlistText.connect, subtitle: WatchlistText.cardBody)
                panel
                    .focusSection()
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(.horizontal, 120)
            .padding(.vertical, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            // Once per visit: a second onAppear would throw away the code on screen.
            guard !started else { return }
            started = true
            model.startCodeFlow()
        }
        .onDisappear { model.cancel() }
        .onChange(of: model.state) { _, state in
            if state == .linked {
                ToastManager.shared.show(WatchlistText.nowSyncs, type: .success)
                dismiss()
            }
        }
        .onExitCommand { close() }
    }

    @ViewBuilder
    private var panel: some View {
        switch model.state {
        case .awaitingPlex(let code):
            card {
                PlexCodePanel(code: code)
                ActionButton(title: "Cancel", icon: "xmark") { close() }
                    .padding(.top, 10)
            }
        case .idle, .linking, .linked:
            card {
                // Focusable, or the cover leaves the remote with nowhere to go.
                ProgressView()
                    .tint(SashimiTheme.accent)
                    .scaleEffect(1.5)
                    .focusable()
                    .focusEffectDisabled()
                Text(model.state == .idle ? "Getting a code…" : "Connecting…")
                    .font(Typography.body)
                    .foregroundStyle(SashimiTheme.textSecondary)
            }
        case .conflict(let current, let new):
            card {
                Text(WatchlistText.switchQuestion(newUsername: new))
                    .font(Typography.title)
                    .foregroundStyle(SashimiTheme.textPrimary)
                Text(WatchlistText.switchMessage(currentUsername: current))
                    .font(Typography.body)
                    .foregroundStyle(SashimiTheme.textSecondary)
                HStack(spacing: 30) {
                    ActionButton(title: WatchlistText.switchButton, icon: "arrow.left.arrow.right", isPrimary: true) {
                        Task { await model.confirmSwitch() }
                    }
                    ActionButton(title: WatchlistText.keep(current), icon: "xmark") { close() }
                }
                .padding(.top, 10)
            }
        case .failed(let message):
            card {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.body)
                    .foregroundStyle(SashimiTheme.warning)
                HStack(spacing: 30) {
                    ActionButton(title: "Try Again", icon: "arrow.clockwise", isPrimary: true) {
                        model.startCodeFlow()
                    }
                    ActionButton(title: "Cancel", icon: "xmark") { close() }
                }
                .padding(.top, 10)
            }
        }
    }

    private func close() {
        model.cancel()
        dismiss()
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 20) {
            content()
        }
        .multilineTextAlignment(.center)
        .padding(50)
        .frame(maxWidth: .infinity, minHeight: 520)
        .background(RoundedRectangle(cornerRadius: CornerRadius.large).fill(SashimiTheme.cardBackground))
    }
}
