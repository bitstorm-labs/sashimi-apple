import NukeUI
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
                    NavigationLink {
                        AdaptiveDetailView(item: item)
                    } label: {
                        SearchResultRow(item: item)
                    }
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

    private var posterURL: URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }
        return URL(string: "\(serverURL)/Items/\(item.id)/Images/Primary?maxWidth=200")
    }

    private func iconForType(_ type: ItemType) -> String {
        switch type {
        case .movie:
            return "film"
        case .series:
            return "tv"
        case .episode:
            return "play.rectangle"
        case .season:
            return "tv"
        case .boxSet:
            return "square.stack"
        default:
            return "photo"
        }
    }

    var body: some View {
        HStack(spacing: MobileSpacing.sm) {
            LazyImage(url: posterURL) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: MobileCornerRadius.small)
                        .fill(MobileColors.cardBackground)
                        .overlay {
                            Image(systemName: iconForType(item.type ?? .unknown))
                                .font(.system(size: 20))
                                .foregroundStyle(MobileColors.textTertiary)
                        }
                }
            }
            .frame(width: 60, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.small))

            VStack(alignment: .leading, spacing: MobileSpacing.xxs) {
                Text(item.name)
                    .font(MobileTypography.title)
                    .foregroundStyle(MobileColors.textPrimary)
                    .lineLimit(2)

                if let year = item.productionYear {
                    Text(String(year))
                        .font(MobileTypography.bodySmall)
                        .foregroundStyle(MobileColors.textSecondary)
                }

                if let type = item.type {
                    Label(type.rawValue.capitalized, systemImage: iconForType(type))
                        .font(MobileTypography.caption)
                        .foregroundStyle(MobileColors.textTertiary)
                }
            }

            Spacer()
        }
        .padding(.vertical, MobileSpacing.xxs)
    }
}
