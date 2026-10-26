import SwiftUI

extension MediaDetailView {
    // MARK: - More menu

    /// Go to Series / Go to Season / Add to Channel first (#760), then the
    /// item's own actions.
    var moreMenu: some View {
        Menu {
            ForEach(menuEntries, id: \.title) { entry in
                Button {
                    open(entry)
                } label: {
                    Label(entry.title, systemImage: entry.systemImage)
                }
            }

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
    }

    private var menuEntries: [DetailMenuEntry] {
        DetailMenuEntry.entries(for: item, canManageChannels: session.canManageChannels(serverID: serverID))
    }

    private func open(_ entry: DetailMenuEntry) {
        switch entry {
        case .goToSeries(let seriesId):
            present(itemId: seriesId, failure: "Failed to load series") { showingSeriesDetail = $0 }
        case .goToSeason(let seasonId, _):
            if let season = selectedSeason, season.id == seasonId {
                showingSeasonDetail = season
            } else {
                present(itemId: seasonId, failure: "Failed to load season") { showingSeasonDetail = $0 }
            }
        case .addToChannel(let target):
            channelTarget = target
        }
    }

    private func present(itemId: String, failure: String, _ show: @escaping (BaseItemDto) -> Void) {
        Task {
            do {
                show(try await JellyfinClient.shared.getItem(itemId: itemId))
            } catch {
                ToastManager.shared.show(failure)
            }
        }
    }

    /// The season page, for a season tab pressed again or its Open Season.
    func openSeasonPage(_ season: BaseItemDto) {
        guard SeasonPageText.canOpen(season, isConnected: NetworkMonitor.shared.isConnected) else { return }
        showingSeasonDetail = season
    }
}
