import SwiftUI

// MARK: - Shared Context Menu

struct ItemContextMenu: View {
    let item: BaseItemDto
    /// Fired after a mutation so the hosting row can refresh (optional).
    var onChange: (() -> Void)?

    var body: some View {
        if item.userData?.played == true {
            Button {
                Task {
                    try? await JellyfinClient.shared.markUnplayed(itemId: item.id)
                    onChange?()
                }
            } label: {
                Label("Mark as Unwatched", systemImage: "eye.slash")
            }
        } else {
            Button {
                Task {
                    try? await JellyfinClient.shared.markPlayed(itemId: item.id)
                    onChange?()
                }
            } label: {
                Label("Mark as Watched", systemImage: "eye")
            }
        }

        // Episodes in Continue Watching: marking the EPISODE watched just
        // advances Next Up to the next episode — the show never leaves the
        // row. Marking the whole SERIES watched is the only mechanism the
        // Jellyfin API offers to dismiss a show from Continue Watching
        // (verified against 10.11; no hide-from-next-up endpoint exists).
        if item.type == .episode, let seriesId = item.seriesId {
            Button {
                Task {
                    try? await JellyfinClient.shared.markPlayed(itemId: seriesId)
                    onChange?()
                }
            } label: {
                Label("Mark Series as Watched", systemImage: "eye.circle")
            }
        }

        if item.userData?.isFavorite == true {
            Button {
                Task { try? await JellyfinClient.shared.removeFavorite(itemId: item.id) }
            } label: {
                Label("Remove from Favorites", systemImage: "heart.slash")
            }
        } else {
            Button {
                Task { try? await JellyfinClient.shared.markFavorite(itemId: item.id) }
            } label: {
                Label("Add to Favorites", systemImage: "heart")
            }
        }
    }
}
