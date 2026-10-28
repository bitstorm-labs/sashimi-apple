import SwiftUI

/// Keeps Home's list rows in step with the user's subscriptions: refreshes
/// them beside Home (never ahead of it) and gives each subscribed list a row
/// after Continue Watching. Waits for the first load of both the rows and the
/// subscriptions, so a slow start never drops a row the user placed.
private struct SharedListHomeSync: ViewModifier {
    @ObservedObject var rowSettings: HomeRowSettings
    @ObservedObject private var store = SharedListsStore.shared

    func body(content: Content) -> some View {
        content
            .task { await store.refresh() }
            .onAppear { Task { await store.refresh() } }
            .onChange(of: store.subscribedLists) { _, _ in sync() }
            .onChange(of: store.hasLoaded) { _, _ in sync() }
            .onChange(of: rowSettings.rows.isEmpty) { _, _ in sync() }
    }

    private func sync() {
        guard store.hasLoaded, !rowSettings.rows.isEmpty else { return }
        let lists = store.subscribedLists
        rowSettings.updateWithLists(lists, titles: Dictionary(lists.map {
            ($0.id, store.rowTitle(of: $0))
        }, uniquingKeysWith: { first, _ in first }))
    }
}

extension View {
    func sharedListHomeSync(_ rowSettings: HomeRowSettings) -> some View {
        modifier(SharedListHomeSync(rowSettings: rowSettings))
    }
}
