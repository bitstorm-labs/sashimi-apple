import SwiftUI

struct MobileHomeView: View {
    @StateObject private var viewModel = HomeViewModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if viewModel.isLoading && viewModel.continueWatchingItems.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    // Continue Watching Section
                    if !viewModel.continueWatchingItems.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Continue Watching")
                                .font(.title2)
                                .fontWeight(.bold)
                                .padding(.horizontal)

                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 16) {
                                    ForEach(viewModel.continueWatchingItems, id: \.id) { item in
                                        PlaceholderCard(item: item)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }

                    // Recently Added Section
                    if !viewModel.recentlyAddedItems.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Recently Added")
                                .font(.title2)
                                .fontWeight(.bold)
                                .padding(.horizontal)

                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 16) {
                                    ForEach(viewModel.recentlyAddedItems, id: \.id) { item in
                                        PlaceholderCard(item: item)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }

                    // Library Sections
                    ForEach(viewModel.libraries, id: \.id) { library in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(library.name)
                                .font(.title2)
                                .fontWeight(.bold)
                                .padding(.horizontal)

                            Text("Library content coming soon")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        }
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Home")
        .refreshable {
            await viewModel.loadContent()
        }
        .task {
            await viewModel.loadContent()
        }
    }
}

// Temporary placeholder card until we build the real components
private struct PlaceholderCard: View {
    let item: BaseItemDto

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 150, height: 225)
                .overlay {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }

            Text(item.name ?? "Unknown")
                .font(.caption)
                .lineLimit(2)
                .frame(width: 150, alignment: .leading)
        }
    }
}
