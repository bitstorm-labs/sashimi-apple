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
    /// Long-press (tvOS) / context-menu (iOS) entry point on a season tab.
    /// Offline, synthetic seasons built from downloads have no server id, so
    /// they get no menu.
    @MainActor
    func seasonWatchMenu(
        for season: BaseItemDto,
        action: SeasonWatchAction,
        request: Binding<SeasonWatchRequest?>
    ) -> some View {
        contextMenu {
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
