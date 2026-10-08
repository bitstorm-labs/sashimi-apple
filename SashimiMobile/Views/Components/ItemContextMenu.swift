import SwiftUI

// MARK: - Context menu actions

/// What a poster's context menu (right-click on the Mac, long press on
/// iPhone/iPad) offers for an item. Pure, so the rules are tested.
enum ItemContextAction: Equatable {
    case play
    case download
    case addToChannel

    static func available(
        for item: BaseItemDto,
        isOnline: Bool,
        canManageChannels: Bool,
        hasDownload: Bool
    ) -> [ItemContextAction] {
        var actions: [ItemContextAction] = []
        switch item.type {
        case .movie, .episode, .video, .series, .season:
            // A series or season resolves to its next episode in the player.
            if isOnline || hasDownload { actions.append(.play) }
        default:
            break
        }
        if isOnline, !hasDownload, [.movie, .episode, .video].contains(item.type) {
            actions.append(.download)
        }
        if isOnline, canManageChannels, ChannelTarget(item: item) != nil {
            actions.append(.addToChannel)
        }
        return actions
    }
}

/// Carries a context-menu Play or Add to Channel to the app root, which
/// presents the player or the channel sheet over whatever is on screen.
@MainActor
final class ItemActionRouter: ObservableObject {
    static let shared = ItemActionRouter()

    @Published var playItem: BaseItemDto?
    @Published var channelTarget: ChannelTarget?
}

// MARK: - Shared Context Menu

struct ItemContextMenu: View {
    let item: BaseItemDto

    private var actions: [ItemContextAction] {
        ItemContextAction.available(
            for: item,
            isOnline: NetworkMonitor.shared.isOnline,
            canManageChannels: SessionManager.shared.canManageChannels(serverID: nil),
            hasDownload: DownloadManager.shared.downloadStatus(for: item.id) != nil
        )
    }

    var body: some View {
        let actions = actions
        if actions.contains(.play) {
            Button {
                ItemActionRouter.shared.playItem = item
            } label: {
                Label("Play", systemImage: "play.fill")
            }
        }

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

        if actions.contains(.download) {
            // Original needs a compatibility check first; the detail page's
            // download button offers it.
            Menu {
                ForEach(DownloadQuality.allCases.filter { $0 != .original }) { quality in
                    Button(quality.displayName) {
                        DownloadManager.shared.enqueueDownload(item: item, quality: quality)
                    }
                }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }

        if actions.contains(.addToChannel), let target = ChannelTarget(item: item) {
            Button {
                ItemActionRouter.shared.channelTarget = target
            } label: {
                Label("Add to Channel…", systemImage: "rectangle.stack.badge.plus")
            }
        }
    }
}
