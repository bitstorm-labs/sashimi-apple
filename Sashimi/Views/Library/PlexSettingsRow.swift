import SwiftUI

/// Settings › Plex: the one Plex row, beside the server and account settings.
/// It runs the Watchlist's own Connect Plex (the plex.tv/link code), so it
/// needs nothing from Requests. Hidden without the Watchlist plugin. Settings
/// owns and loads `model`: while the row is hidden there is no view to load from.
struct PlexSettingsRow: View {
    @ObservedObject var model: PlexSettingsModel
    @State private var connecting = false
    @State private var confirmDisconnect = false
    @State private var choosing = false

    var body: some View {
        if model.row != .hidden {
            VStack(alignment: .leading, spacing: 10) {
                SettingsOptionRow(icon: "link", title: WatchlistText.plexRowTitle, subtitle: model.summary) {
                    select()
                }
                Text(model.footer)
                    .font(Typography.caption)
                    .foregroundStyle(SashimiTheme.textTertiary)
                    .padding(.horizontal, 28)
            }
            .fullScreenCover(isPresented: $connecting) {
                WatchlistPlexConnectView()
            }
            .confirmationDialog(WatchlistText.plexRowTitle, isPresented: $choosing, titleVisibility: .visible) {
                ForEach(model.actions, id: \.self) { action in
                    if action == .disconnect {
                        Button(action.title, role: .destructive) { confirmDisconnect = true }
                    } else {
                        Button(action.title) { connecting = true }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(model.status)
            }
            .destructiveConfirmation(
                WatchlistText.disconnectQuestion,
                isPresented: $confirmDisconnect,
                message: WatchlistText.disconnectMessage,
                confirmTitle: WatchlistText.disconnect
            ) {
                Task {
                    if !(await model.disconnect()) { ToastManager.shared.show("Couldn't disconnect Plex. Try again.") }
                }
            }
        }
    }

    /// One thing to do runs it; Reconnect or Disconnect asks which.
    private func select() {
        guard model.actions.count == 1, let only = model.actions.first else {
            choosing = true
            return
        }
        if only == .disconnect { confirmDisconnect = true } else { connecting = true }
    }
}
