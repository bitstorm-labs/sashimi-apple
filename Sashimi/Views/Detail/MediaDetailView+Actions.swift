import SwiftUI

extension MediaDetailView {
    func queueServerMedia(_ source: ServerMediaResult) {
        pendingServerMedia = source
        showingPersonDetail = nil
    }

    func presentPendingServerMedia() {
        guard let source = pendingServerMedia else { return }
        pendingServerMedia = nil
        selectedServerMedia = source
    }

    func deleteItem() async {
        do {
            try await JellyfinClient.shared.deleteItem(itemId: item.id)
            ToastManager.shared.show("Item deleted", type: .success)
            // Small delay to let the toast appear before dismissing
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run {
                dismiss()
            }
        } catch {
            ToastManager.shared.show("Failed to delete: \(error.localizedDescription)")
        }
    }

    func refreshItemState() async {
        do {
            let refreshedItem = try await JellyfinClient.shared.getItem(itemId: item.id)

            isWatched = refreshedItem.userData?.played ?? false
            hasProgress = refreshedItem.progressPercent > 0 && !(refreshedItem.userData?.played ?? false)
            isFavorite = refreshedItem.userData?.isFavorite ?? false
        } catch {
            // Silently ignore - non-critical refresh
        }

        // Watching an episode changes which one is next, and whether the strip
        // should show a checkmark. loadContent() is bound to .task, which does
        // NOT re-run here: the player is a fullScreenCover, so it never removed
        // this view and .task never re-fires. Without this the button still read
        // "Play S1:E1" after finishing S1:E1, and pressing it replayed it.
        if isSeries || isEpisode {
            await loadContent()
        }
    }

    /// Optimistic favorite toggle (reverts on failure), matching toggleWatched.
    private func toggleFavorite() async {
        let newState = !isFavorite
        isFavorite = newState
        do {
            if newState {
                try await JellyfinClient.shared.markFavorite(itemId: item.id)
            } else {
                try await JellyfinClient.shared.removeFavorite(itemId: item.id)
            }
            ToastManager.shared.show(
                newState ? "Added to Favorites" : "Removed from Favorites", type: .success
            )
        } catch {
            isFavorite = !newState
            ToastManager.shared.show("Failed to update favorite")
        }
    }

    private func refreshMetadata() async {
        isRefreshing = true
        do {
            // Refresh metadata on server
            try await JellyfinClient.shared.refreshMetadata(itemId: item.id)
            ToastManager.shared.show("Metadata refresh started", type: .info)

            // Wait a moment for server to process
            try await Task.sleep(for: .seconds(2))

            // Reload content to pick up new metadata/images
            await loadContent()

            // Force image views to reload by changing the refresh ID
            refreshID = UUID()
        } catch {
            ToastManager.shared.show("Failed to refresh metadata")
        }
        isRefreshing = false
    }

    /// Play the item's local trailer inline. The button only appears when a
    /// local trailer exists (LocalTrailerCount > 0), matching Roku.
    private func playLocalTrailer() async {
        ThemeSongPlayer.shared.stopForPlayback()
        if let trailer = try? await JellyfinClient.shared.getLocalTrailers(itemId: item.id).first {
            selectedEpisode = trailer
            startFromBeginning = true
            showingPlayer = true
        }
    }

    /// Shuffle: play a random episode of this series.
    private func shuffleEpisode() async {
        let seriesId = isSeries ? item.id : (item.seriesId ?? item.id)
        if let ep = try? await JellyfinClient.shared.getRandomItem(parentId: seriesId, itemTypes: [.episode]) {
            selectedEpisode = ep
            startFromBeginning = false
            ThemeSongPlayer.shared.stopForPlayback()
            showingPlayer = true
        }
    }

    // MARK: - Action Buttons
    var actionButtonsRow: some View {
        HStack(spacing: 30) {
            // Series: show play button for next episode
            if isSeries, let nextEp = nextEpisodeToPlay {
                let epHasProgress = (nextEp.userData?.playbackPositionTicks ?? 0) > 0
                let seasonNum = nextEp.parentIndexNumber ?? 1
                let epNum = nextEp.indexNumber ?? 1
                ActionButton(
                    title: epHasProgress ? "Resume S\(seasonNum):E\(epNum)" : "Play S\(seasonNum):E\(epNum)",
                    icon: "play.fill",
                    isPrimary: true
                ) {
                    selectedEpisode = nextEp
                    startFromBeginning = false
                    ThemeSongPlayer.shared.stopForPlayback()
                    showingPlayer = true
                }
            }

            // Series: shuffle a random episode
            if isSeries {
                ActionButton(
                    title: "Shuffle",
                    icon: "shuffle",
                    isPrimary: false
                ) {
                    Task { await shuffleEpisode() }
                }
            }

            // Non-series: show regular play buttons
            if !isSeries {
                ActionButton(
                    title: hasProgress ? "Resume" : "Play",
                    icon: "play.fill",
                    isPrimary: true
                ) {
                    startFromBeginning = false
                    ThemeSongPlayer.shared.stopForPlayback()
                    showingPlayer = true
                }

                if hasProgress {
                    ActionButton(
                        title: "Start Over",
                        icon: "arrow.counterclockwise",
                        isPrimary: false
                    ) {
                        startFromBeginning = true
                        ThemeSongPlayer.shared.stopForPlayback()
                        showingPlayer = true
                    }
                }
            }

            // Trailer button — only when a local trailer exists (Trailarr),
            // played inline. No remote (YouTube) hand-off, matching Roku.
            if !isEpisode, (item.localTrailerCount ?? 0) > 0 {
                ActionButton(
                    title: "Trailer",
                    icon: "film",
                    isPrimary: false
                ) {
                    Task { await playLocalTrailer() }
                }
            }

            ActionButton(
                title: "Watched",
                icon: isWatched ? "checkmark.circle.fill" : "checkmark.circle",
                isActive: isWatched
            ) {
                Task { await toggleWatched() }
            }

            // Episode: show Series button
            if isEpisode, let seriesId = item.seriesId {
                ActionButton(
                    title: "Series",
                    icon: "tv",
                    isPrimary: false
                ) {
                    navigateToSeries(seriesId: seriesId)
                }
            }

            // Admins: put this title (an episode's series) on a SashimiTV channel.
            if session.canManageChannels(serverID: serverID), let target = ChannelTarget(item: item) {
                ActionButton(
                    title: "Add to Channel",
                    icon: "rectangle.stack.badge.plus",
                    isPrimary: false
                ) {
                    channelTarget = target
                }
            }

            Menu {
                Button {
                    Task { await toggleFavorite() }
                } label: {
                    Label(
                        isFavorite ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: isFavorite ? "heart.fill" : "heart"
                    )
                }

                if item.overview?.isEmpty == false {
                    Button {
                        showingFullOverview = true
                    } label: {
                        Label("Full Overview", systemImage: "text.alignleft")
                    }
                }

                Button {
                    showingFileInfo = true
                } label: {
                    Label("File Info", systemImage: "info.circle")
                }

                Button {
                    Task { await refreshMetadata() }
                } label: {
                    Label(isRefreshing ? "Refreshing..." : "Refresh Metadata", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing)

                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "ellipsis.circle")
                    Text("More")
                }
                .font(.subheadline)
                .fontWeight(.semibold)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(SashimiTheme.cardBackground)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isMoreButtonFocused ? SashimiTheme.focus : .clear, lineWidth: 3)
                )
                .shadow(color: isMoreButtonFocused ? SashimiTheme.focusGlow : .clear, radius: 12)
                .scaleEffect(isMoreButtonFocused ? 1.05 : 1.0)
                .animation(.spring(response: 0.3), value: isMoreButtonFocused)
            }
            .focused($isMoreButtonFocused)
            .menuStyle(.borderlessButton)

            Spacer()
        }
    }

    private func toggleWatched() async {
        let newState = !isWatched
        let previousProgress = hasProgress
        isWatched = newState
        if newState {
            // When marking as watched, clear progress (it's complete)
            hasProgress = false
        }
        do {
            if newState {
                try await JellyfinClient.shared.markPlayed(itemId: item.id)
            } else {
                try await JellyfinClient.shared.markUnplayed(itemId: item.id)
            }
        } catch {
            isWatched = !newState
            hasProgress = previousProgress
            ToastManager.shared.show("Failed to update watched status")
        }
    }

    private func navigateToSeries(seriesId: String) {
        Task {
            do {
                let series = try await JellyfinClient.shared.getItem(itemId: seriesId)
                showingSeriesDetail = series
            } catch {
                ToastManager.shared.show("Failed to load series")
            }
        }
    }
}
