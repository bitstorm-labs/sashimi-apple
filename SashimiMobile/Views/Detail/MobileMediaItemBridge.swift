import SwiftUI

/// Bridge view that presents MobileDetailView from a MediaItem.
/// Fetches the full BaseItemDto from the server, then delegates to MobileDetailView.
struct MobileMediaItemDetailBridge: View {
    let mediaItem: MediaItem
    var libraryName: String?

    @State private var baseItem: BaseItemDto?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let baseItem {
                MobileDetailView(item: baseItem, libraryName: libraryName)
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Failed to Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Could not load item details.")
                )
            }
        }
        .task {
            do {
                baseItem = try await JellyfinClient.shared.getItem(itemId: mediaItem.rawId)
            } catch {
                // Error loading
            }
            isLoading = false
        }
    }
}

/// Bridge view that presents PhoneDetailView from a MediaItem.
struct PhoneMediaItemDetailBridge: View {
    let mediaItem: MediaItem
    var libraryName: String?

    @State private var baseItem: BaseItemDto?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let baseItem {
                PhoneDetailView(item: baseItem, libraryName: libraryName)
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Failed to Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Could not load item details.")
                )
            }
        }
        .task {
            do {
                baseItem = try await JellyfinClient.shared.getItem(itemId: mediaItem.rawId)
            } catch {
                // Error loading
            }
            isLoading = false
        }
    }
}
