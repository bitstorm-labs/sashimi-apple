import SwiftUI

/// A pending "mark season (un)watched" awaiting the user's confirmation.
struct SeasonWatchRequest: Equatable {
    let season: BaseItemDto
    let action: SeasonWatchAction
}

extension View {
    /// Confirms a season-wide watched change before applying it: it rewrites
    /// the played state of every episode in the season at once.
    func seasonWatchConfirmation(
        _ request: Binding<SeasonWatchRequest?>,
        onConfirm: @escaping (SeasonWatchRequest) -> Void
    ) -> some View {
        confirmationDialog(
            request.wrappedValue?.action.title ?? "",
            isPresented: Binding(
                get: { request.wrappedValue != nil },
                set: { if !$0 { request.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: request.wrappedValue
        ) { pending in
            Button(pending.action.title) { onConfirm(pending) }
            Button("Cancel", role: .cancel) { }
        } message: { pending in
            Text(pending.action.confirmationMessage(seasonName: pending.season.name))
        }
    }
}

extension View {
    /// Long-press (tvOS) / context-menu (iOS) entry point on a season tab:
    /// Open Season (the season page, #760) and the season-wide watched mark.
    /// Offline, synthetic seasons built from downloads have no server id, so
    /// they get no menu.
    @MainActor
    func seasonTabMenu(
        for season: BaseItemDto,
        action: SeasonWatchAction,
        request: Binding<SeasonWatchRequest?>,
        openSeason: @escaping () -> Void
    ) -> some View {
        contextMenu {
            if SeasonPageText.canOpen(season, isConnected: NetworkMonitor.shared.isConnected) {
                Button(action: openSeason) {
                    Label("Open Season", systemImage: "rectangle.stack")
                }
            }
            if SeasonWatchAction.canApply(to: season, isConnected: NetworkMonitor.shared.isConnected) {
                Button {
                    request.wrappedValue = SeasonWatchRequest(season: season, action: action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
            }
        }
    }
}
