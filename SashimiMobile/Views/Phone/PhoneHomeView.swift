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
        .navigationBarHidden(true)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 8) {
                Image("SidebarLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                Text("Sashimi")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(MobileColors.textPrimary)
                Spacer()
            }
            .padding(.horizontal, MobileSpacing.md)
            .padding(.vertical, MobileSpacing.xs)
            .background(MobileColors.background)
        }
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
                    PhoneMediaItemDetailBridge(mediaItem: item, libraryName: libNames[item.rawId])
                }
            }

        case .library(let libraryId, let libraryName):
            let library = viewModel.libraries.first(where: { $0.rawId == libraryId })
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
