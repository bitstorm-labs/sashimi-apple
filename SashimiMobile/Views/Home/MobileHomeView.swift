import SwiftUI

struct MobileHomeView: View {
    @StateObject private var viewModel = HomeViewModel()

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
        .navigationTitle("Home")
        .background(MobileColors.background)
        .refreshable {
            await viewModel.loadContent()
        }
        .task {
            await viewModel.loadContent()
        }
    }

    private var loadingView: some View {
        ProgressView()
            .frame(maxWidth: .infinity, minHeight: 300)
    }

    @ViewBuilder
    private var contentView: some View {
        // Continue Watching Section
        if !viewModel.continueWatchingItems.isEmpty {
            MobileMediaRow(
                title: "Continue Watching",
                items: viewModel.continueWatchingItems,
                cardWidth: MobileSizing.continueWatchingWidth,
                showProgress: true
            ) { item in
                MobileDetailView(item: item)
            }
        }

        // Recently Added Section
        if !viewModel.recentlyAddedItems.isEmpty {
            MobileMediaRow(
                title: "Recently Added",
                items: viewModel.recentlyAddedItems,
                showProgress: false
            ) { item in
                MobileDetailView(item: item)
            }
        }

        // Hero Items Section (if available)
        if !viewModel.heroItems.isEmpty {
            MobileMediaRow(
                title: "Featured",
                items: viewModel.heroItems,
                cardWidth: MobileSizing.landscapeCardWidth,
                showProgress: false
            ) { item in
                MobileDetailView(item: item)
            }
        }

        // Libraries placeholder
        if viewModel.continueWatchingItems.isEmpty && viewModel.recentlyAddedItems.isEmpty {
            emptyStateView
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
