import SwiftUI

// MARK: - Shared Context Menu

struct ItemContextMenu: View {
    let item: BaseItemDto

    var body: some View {
        if item.userData?.played == true {
            Button {
                Task { try? await JellyfinClient.shared.markUnplayed(itemId: item.id) }
            } label: {
                Label("Mark as Unwatched", systemImage: "eye.slash")
            }
        } else {
            Button {
                Task { try? await JellyfinClient.shared.markPlayed(itemId: item.id) }
            } label: {
                Label("Mark as Watched", systemImage: "eye")
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
