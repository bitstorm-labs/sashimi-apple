import SwiftUI

struct MobileHomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @StateObject private var rowSettings = HomeRowSettings.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileSpacing.xl) {
                if viewModel.isLoading && viewModel.continueWatchingItems.isEmpty {
                    loadingView
                } else {
                    contentView
                }
            }
            .padding(.vertical, MobileSpacing.md)
        }
        .background(MobileColors.background)
        .refreshable {
            await viewModel.loadContent()
        }
        .task {
            await viewModel.loadContent()
        }
        .onAppear {
            // Refresh when navigating back to home (e.g. after watching something)
            if !viewModel.continueWatchingItems.isEmpty || !viewModel.libraries.isEmpty {
                Task { await viewModel.loadContent() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackDidStop)) { _ in
            Task {
                try? await Task.sleep(for: .seconds(0.5))
                await viewModel.loadContent()
            }
        }
        .onChange(of: viewModel.libraries) { _, libraries in
            rowSettings.updateLibraries(libraries)
        }
    }

    private var loadingView: some View {
        ProgressView()
            .frame(maxWidth: .infinity, minHeight: 300)
    }

    @ViewBuilder
    private var contentView: some View {
        ForEach(rowSettings.rows.filter { $0.isEnabled }) { row in
            rowView(for: row)
        }

        // Empty state
        if viewModel.continueWatchingItems.isEmpty && viewModel.libraries.isEmpty {
            emptyStateView
        }
    }

    @ViewBuilder
    private func rowView(for row: HomeRowConfig) -> some View {
        switch row.type {
        case .builtIn(.continueWatching):
            if !viewModel.continueWatchingItems.isEmpty {
                let libNames = viewModel.continueWatchingLibraryNames
                MobileContinueWatchingRow(
                    items: viewModel.continueWatchingItems,
                    libraryNames: libNames
                ) { item in
                    MobileMediaItemDetailBridge(mediaItem: item, libraryName: libNames[item.rawId])
                }
            }

        case .library(let libraryId, let libraryName):
            let library = viewModel.libraries.first(where: { $0.rawId == libraryId })
            MobileRecentlyAddedRow(
                libraryId: libraryId,
                libraryName: libraryName,
                collectionType: library?.collectionType
            ) { item in
                MobileDetailView(item: item, libraryName: libraryName)
            }
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView(
            "No Content",
            systemImage: "tv",
            description: Text("Start watching something to see it here.")
        )
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}
