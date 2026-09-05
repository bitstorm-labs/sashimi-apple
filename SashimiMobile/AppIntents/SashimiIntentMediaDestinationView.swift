import SwiftUI

/// Resolves an entity's server-scoped identity before handing it to the
/// existing server-scoped detail route.
struct SashimiIntentMediaDestinationView: View {
    let entity: SashimiMediaEntity

    @State private var source: ServerMediaResult?
    @State private var initialSeasonID: String?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let source {
                ServerScopedMediaDetailView(source: source, initialSeasonID: initialSeasonID)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Unable to Open Title", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Opening \(entity.title)…")
            }
        }
        .task(id: entity.id) {
            await resolveEntity()
        }
        .toolbar {
            // The resolved detail route supplies its own Back button. Keep
            // this one only while the intent is still resolving so the
            // parent and child routes cannot contribute duplicate controls.
            if source == nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .accessibilityLabel("Back")
                }
            }
        }
    }

    @MainActor
    private func resolveEntity() async {
        guard let server = SessionManager.shared.servers.first(where: { $0.id == entity.serverID }) else {
            errorMessage = "The saved server for this title is no longer available."
            return
        }

        guard let scope = await SessionManager.shared.beginServerScope(for: entity.serverID) else {
            errorMessage = "Reconnect \(server.displayName) in Sashimi, then try again."
            return
        }

        do {
            let resolvedItem = try await JellyfinClient.shared.getItem(itemId: entity.itemID)
            let destinationItem: BaseItemDto
            if resolvedItem.type == .season {
                guard let seriesID = resolvedItem.seriesId ?? resolvedItem.parentId else {
                    throw DestinationResolutionError.missingSeries
                }
                destinationItem = try await JellyfinClient.shared.getItem(itemId: seriesID)
                initialSeasonID = resolvedItem.id
            } else {
                destinationItem = resolvedItem
                initialSeasonID = nil
            }
            await SessionManager.shared.endServerScope(scope)
            guard !Task.isCancelled else { return }
            source = ServerMediaResult(
                item: destinationItem,
                serverID: server.id,
                serverName: server.displayName,
                serverURL: server.url
            )
        } catch is CancellationError {
            await SessionManager.shared.endServerScope(scope)
        } catch {
            await SessionManager.shared.endServerScope(scope)
            guard !Task.isCancelled else { return }
            errorMessage = "\(entity.title) is no longer available on \(server.displayName)."
        }
    }

    private enum DestinationResolutionError: Error {
        case missingSeries
    }
}

/// Resolves the Continue Watching item again inside its owning server scope
/// before presenting the existing player. Jellyfin item IDs are server-local,
/// and the fresh response is what carries the saved playback position used by
/// PlayerViewModel's normal resume path.
struct SashimiIntentPlaybackDestinationView: View {
    let entity: SashimiMediaEntity

    @State private var item: BaseItemDto?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let item {
                MobilePlayerView(
                    item: item,
                    serverID: entity.serverID,
                    onPlaybackReady: {
                        SashimiIntentCoordinator.shared.acknowledgePlaybackReady(for: entity)
                    },
                    onPlaybackFailed: {
                        SashimiIntentCoordinator.shared.acknowledgePlaybackFailure(for: entity)
                    }
                )
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Unable to Play Title", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Back") {
                        dismiss()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Preparing \(entity.title)…")
            }
        }
        .task(id: entity.id) {
            await resolvePlaybackItem()
        }
    }

    @MainActor
    private func resolvePlaybackItem() async {
        await SessionManager.shared.restoreSessionForIntent()
        guard let server = SessionManager.shared.servers.first(where: { $0.id == entity.serverID }) else {
            failHandoff("The saved server for this title is no longer available.")
            return
        }

        guard let client = SessionManager.shared.makeClient(for: entity.serverID) else {
            failHandoff("Reconnect \(server.displayName) in Sashimi, then try again.")
            return
        }

        do {
            let resolvedItem = try await client.getItem(itemId: entity.itemID)
            guard !Task.isCancelled else {
                return
            }
            item = resolvedItem
        } catch is CancellationError {
            // Dismissal cancels the resolution task.
        } catch {
            guard !Task.isCancelled else {
                return
            }
            failHandoff("\(entity.title) is no longer available on \(server.displayName).")
        }
    }

    private func failHandoff(_ message: String) {
        errorMessage = message
        SashimiIntentCoordinator.shared.acknowledgePlaybackFailure(for: entity)
    }
}
