import SwiftUI

// MARK: - Context menu actions

/// What a poster's context menu (right-click on the Mac, long press on
/// iPhone/iPad) offers for an item. Pure, so the rules are tested.
enum ItemContextAction: Equatable {
    case play
    case download
    /// An episode of a series: the episode download menu (#744) — this
    /// episode (when not downloaded yet), this and the next N, the unwatched
    /// scopes and Keep Next. Replaces the plain Download.
    case episodeDownloads
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
        if isOnline, item.type == .episode, item.seriesId != nil {
            actions.append(.episodeDownloads)
        } else if isOnline, !hasDownload, [.movie, .episode, .video].contains(item.type) {
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
    /// A context menu's bulk episode download, run by the app root's
    /// `BulkDownloadFlow` (a context menu can't present its own dialogs).
    @Published var episodeDownload: EpisodeDownloadRequest?
}

struct EpisodeDownloadRequest: Identifiable {
    enum Action: Equatable {
        case scope(EpisodeDownloadScope)
        case keepNext(Int)
    }

    let id = UUID()
    let episode: BaseItemDto
    let action: Action
}

// MARK: - Shared Context Menu

struct ItemContextMenu: View {
    let item: BaseItemDto
    /// In a sheet the app root can't present over it (#781): the sheet's
    /// presenter closes it and plays instead.
    @Environment(\.playerHandoff) private var playerHandoff

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
                if let playerHandoff {
                    playerHandoff.send(PlayerRequest(item: item))
                } else {
                    ItemActionRouter.shared.playItem = item
                }
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

        if actions.contains(.episodeDownloads) {
            episodeDownloadMenu(hasDownload: DownloadManager.shared.downloadStatus(for: item.id) != nil)
        }

        if actions.contains(.addToChannel), let target = ChannelTarget(item: item) {
            Button {
                ItemActionRouter.shared.channelTarget = target
            } label: {
                Label("Add to Channel…", systemImage: "rectangle.stack.badge.plus")
            }
        }
    }

    /// Same entries as the episode page's download menu.
    private func episodeDownloadMenu(hasDownload: Bool) -> some View {
        Menu {
            Section(EpisodeDownloadPlanner.menuTitle(item)) {
                if !hasDownload {
                    Menu {
                        ForEach(DownloadQuality.allCases.filter { $0 != .original }) { quality in
                            Button(quality.displayName) {
                                DownloadManager.shared.enqueueDownload(item: item, quality: quality)
                            }
                        }
                    } label: {
                        Label("This Episode", systemImage: "arrow.down.circle")
                    }
                }
                Menu {
                    ForEach(EpisodeDownloadPlanner.nextCounts, id: \.self) { count in
                        Button(EpisodeDownloadPlanner.nextCountTitle(count)) { request(.scope(.thisAndNext(count))) }
                    }
                } label: {
                    Label("This and the Next\u{2026}", systemImage: "arrow.down.to.line")
                }
            }
            Section {
                Button {
                    request(.scope(.unwatchedInSeason))
                } label: {
                    Label(EpisodeDownloadPlanner.seasonTitle(item), systemImage: "arrow.down.circle")
                }
                Button {
                    request(.scope(.unwatchedInSeries))
                } label: {
                    Label("Unwatched in Series", systemImage: "arrow.down.circle")
                }
                if let seriesId = item.seriesId {
                    let current = KeepNextEpisodesStore.shared.count(
                        serverID: SessionManager.shared.activeServerId, seriesId: seriesId
                    )
                    Menu {
                        KeepNextEpisodesPicker(selection: current) { request(.keepNext($0)) }
                    } label: {
                        Label(
                            current > 0 ? "Keep Next Episodes Downloaded: \(current)" : "Keep Next Episodes Downloaded",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                }
            }
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
        }
    }

    private func request(_ action: EpisodeDownloadRequest.Action) {
        ItemActionRouter.shared.episodeDownload = EpisodeDownloadRequest(episode: item, action: action)
    }
}
