import SwiftUI

struct PhoneHomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @StateObject private var rowSettings = HomeRowSettings.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileSpacing.lg) {
                if viewModel.isLoading && viewModel.continueWatchingItems.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    contentView
                }
            }
            .padding(.vertical, MobileSpacing.sm)
        }
        .background(MobileColors.background)
        .navigationTitle("Home")
        .refreshable {
            await viewModel.loadContent()
        }
        .task {
            await viewModel.loadContent()
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

    @ViewBuilder
    private var contentView: some View {
        ForEach(rowSettings.rows.filter { $0.isEnabled }) { row in
            rowView(for: row)
        }

        if viewModel.continueWatchingItems.isEmpty && viewModel.libraries.isEmpty {
            ContentUnavailableView(
                "No Content",
                systemImage: "tv",
                description: Text("Start watching something to see it here.")
            )
            .frame(maxWidth: .infinity, minHeight: 300)
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
                    libraryNames: libNames,
                    cardWidth: PhoneSizing.continueWatchingWidth
                ) { item in
                    PhoneDetailView(item: item, libraryName: libNames[item.id])
                }
            }

        case .library(let libraryId, let libraryName):
            let library = viewModel.libraries.first(where: { $0.id == libraryId })
            MobileRecentlyAddedRow(
                libraryId: libraryId,
                libraryName: libraryName,
                collectionType: library?.collectionType,
                cardWidth: PhoneSizing.posterWidth
            ) { item in
                PhoneDetailView(item: item, libraryName: libraryName)
            }
        }
    }
}
