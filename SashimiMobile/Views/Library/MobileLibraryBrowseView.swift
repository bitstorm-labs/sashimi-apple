import SwiftUI
import NukeUI

struct MobileLibraryBrowseView: View {
    let libraryId: String
    let libraryName: String
    let collectionType: String?
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var items: [BaseItemDto] = []
    @State private var isLoading = true
    @State private var totalCount = 0

    private var isYouTubeLibrary: Bool {
        libraryName.lowercased().contains("youtube")
    }

    private var isTVLibrary: Bool {
        collectionType?.lowercased() == "tvshows"
    }

    private var includeTypes: [ItemType]? {
        switch collectionType {
        case "movies": return [.movie]
        case "tvshows": return [.series]
        default: return nil
        }
    }

    private var columns: [GridItem] {
        let minWidth = sizeClass == .compact ? PhoneSizing.posterWidth : MobileSizing.posterWidth
        return [GridItem(.adaptive(minimum: minWidth), spacing: MobileSpacing.md)]
    }

    var body: some View {
        ScrollView {
            if isLoading && items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else if items.isEmpty {
                ContentUnavailableView(
                    "No Items",
                    systemImage: "rectangle.stack",
                    description: Text("This library is empty.")
                )
                .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                LazyVGrid(columns: columns, spacing: MobileSpacing.md) {
                    ForEach(items, id: \.id) { item in
                        NavigationLink {
                            AdaptiveDetailView(item: item, libraryName: libraryName)
                        } label: {
                            MobileRecentlyAddedCard(
                                item: item,
                                width: sizeClass == .compact ? PhoneSizing.posterWidth : MobileSizing.posterWidth,
                                libraryName: libraryName,
                                isCircular: isYouTubeLibrary && item.type == .series,
                                isLandscape: false,
                                badgeCount: nil
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            ItemContextMenu(item: item)
                        }
                    }
                }
                .padding(.horizontal, MobileSpacing.md)
                .padding(.vertical, MobileSpacing.md)
            }
        }
        .background(MobileColors.background)
        .task {
            await loadItems()
        }
    }

    private func loadItems() async {
        do {
            let response = try await JellyfinClient.shared.getItems(
                parentId: libraryId,
                includeTypes: includeTypes,
                sortBy: "SortName",
                sortOrder: "Ascending",
                limit: 100,
                startIndex: 0
            )
            items = response.items
            totalCount = response.totalRecordCount

            // Load remaining items in background
            while items.count < totalCount {
                let more = try await JellyfinClient.shared.getItems(
                    parentId: libraryId,
                    includeTypes: includeTypes,
                    sortBy: "SortName",
                    sortOrder: "Ascending",
                    limit: 100,
                    startIndex: items.count
                )
                guard !more.items.isEmpty else { break }
                items.append(contentsOf: more.items)
            }
        } catch {
            // Show what we have
        }
        isLoading = false
    }
}
