import SwiftUI

/// Bridge view that presents MediaDetailView from a MediaItem.
/// Fetches the full BaseItemDto from the server using the rawId,
/// then delegates to MediaDetailView for the actual display.
struct MediaItemDetailBridge: View {
    let mediaItem: MediaItem
    var forceYouTubeStyle: Bool = false

    @State private var baseItem: BaseItemDto?
    @State private var isLoading = true
    @State private var loadError = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let baseItem {
                MediaDetailView(item: baseItem, forceYouTubeStyle: forceYouTubeStyle)
            } else if isLoading {
                ZStack {
                    SashimiTheme.background.ignoresSafeArea()
                    ProgressView()
                        .scaleEffect(1.5)
                }
            } else {
                ZStack {
                    SashimiTheme.background.ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(SashimiTheme.textTertiary)
                        Text("Failed to load item")
                            .foregroundStyle(SashimiTheme.textSecondary)
                        Button("Dismiss") { dismiss() }
                    }
                }
            }
        }
        .task {
            await loadItem()
        }
    }

    private func loadItem() async {
        isLoading = true
        do {
            baseItem = try await JellyfinClient.shared.getItem(itemId: mediaItem.rawId)
        } catch {
            loadError = true
        }
        isLoading = false
    }
}

/// Bridge view that presents PlayerView from a MediaItem.
struct MediaItemPlayerBridge: View {
    let mediaItem: MediaItem
    var startFromBeginning: Bool = false

    @State private var baseItem: BaseItemDto?
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let baseItem {
                PlayerView(item: baseItem, startFromBeginning: startFromBeginning)
            } else if isLoading {
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView()
                        .scaleEffect(1.5)
                }
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    Text("Failed to load")
                        .foregroundStyle(.white)
                }
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
