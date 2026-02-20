import SwiftUI

struct MobileSearchView: View {
    @State private var searchText = ""
    @State private var searchResults: [BaseItemDto] = []
    @State private var isSearching = false

    var body: some View {
        List {
            if searchText.isEmpty {
                ContentUnavailableView(
                    "Search",
                    systemImage: "magnifyingglass",
                    description: Text("Search for movies, shows, and more.")
                )
            } else if isSearching {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if searchResults.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("No results found for \"\(searchText)\"")
                )
            } else {
                ForEach(searchResults, id: \.id) { item in
                    SearchResultRow(item: item)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Search")
        .searchable(text: $searchText, prompt: "Movies, shows, and more")
        .onChange(of: searchText) { _, newValue in
            Task {
                await performSearch(query: newValue)
            }
        }
    }

    private func performSearch(query: String) async {
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        do {
            searchResults = try await JellyfinClient.shared.search(query: query, limit: 50)
        } catch {
            searchResults = []
        }
    }
}

private struct SearchResultRow: View {
    let item: BaseItemDto

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 60, height: 90)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name ?? "Unknown")
                    .font(.headline)

                if let year = item.productionYear {
                    Text(String(year))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let type = item.type {
                    Text(type.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}
