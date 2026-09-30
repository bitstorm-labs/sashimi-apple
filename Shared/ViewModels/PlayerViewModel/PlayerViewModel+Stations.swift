import Foundation
import AVFoundation

extension PlayerViewModel {
    // MARK: - Stations: flipping and idents

    /// The banner that flashes up when a station is tuned, changed or moves on
    /// to its next programme — a cable box's info banner: station, what is on
    /// and how far in, and what is next.
    struct StationBanner: Equatable, Identifiable {
        let id = UUID()
        let channelName: String
        let channelDescription: String?
        let title: String
        let detail: String?
        let isNew: Bool
        let startsAt: Date?
        let endsAt: Date?
        let nextTitle: String?
        let nextStartsAt: Date?
        var logoURL: URL?
        /// Paused on a live channel, and how far behind live that has left
        /// the viewer — a channel does not wait.
        var isPaused = false
        var minutesBehindLive = 0
    }

    /// The card a channel shows during a break between slots.
    struct UpNext: Equatable {
        let logoURL: URL?
        let channelName: String
        let title: String
        let detail: String?
        let startsAt: Date
    }

    func upNextCard(for item: BaseItemDto, channelID: String, startsAt: Date) async -> UpNext {
        if stations.isEmpty { stations = (try? await client.getVirtualChannels()) ?? [] }
        let key = Self.stationKey(channelID)
        let station = stations.first { Self.stationKey($0.id) == key }
        var logoURL: URL?
        if let logo = station?.logo {
            logoURL = await client.channelLogoURL(channelId: channelID, key: logo)
        }
        let isEpisode = item.type == .episode
        var detail: String?
        if isEpisode {
            if item.hasDatedEpisodeNumbers {
                detail = item.name
            } else if let season = item.parentIndexNumber, let episode = item.indexNumber {
                detail = "S\(season)E\(episode) · \(item.name)"
            }
        } else if let year = item.productionYear {
            detail = String(year)
        }
        return UpNext(
            logoURL: logoURL,
            channelName: (station?.name ?? "SashimiTV").uppercased(),
            title: isEpisode ? (item.seriesName ?? item.name).cleanedYouTubeTitle : item.name,
            detail: detail,
            startsAt: startsAt
        )
    }
    /// The station's mark, laid faintly over the picture while it plays:
    /// white logo and name.
    struct StationMark: Equatable {
        let logoURL: URL?
        let name: String
    }

    /// Play/Pause on a channel. Pausing puts the viewer behind live, which the
    /// banner then says; the next programme boundary (or a channel change)
    /// rejoins live, because both tune at the channel's current offset.
    func toggleStationPause() {
        guard isWatchingStation, let player else { return }
        if player.rate == 0 {
            if let since = stationPausedAt { secondsBehindLive += Date().timeIntervalSince(since) }
            stationPausedAt = nil
            player.play()
        } else {
            player.pause()
            stationPausedAt = Date()
        }
        Task { await announceStation() }
    }

    /// Back on live: a new programme or station joins at the channel's own offset.
    private func rejoinLive() {
        stationPausedAt = nil
        secondsBehindLive = 0
    }

    var isWatchingStation: Bool { channelContext != nil }

    /// Channel up/down: tune the station above or below this one in guide
    /// order, skipping any that are off air, wrapping at the ends.
    func changeStation(by delta: Int) async {
        guard let current = channelContext, delta != 0 else { return }
        if stations.isEmpty { stations = (try? await client.getVirtualChannels()) ?? [] }
        let count = stations.count
        let key = Self.stationKey(current.channelID)
        guard count > 1, let here = stations.firstIndex(where: { Self.stationKey($0.id) == key }) else { return }

        for step in 1..<count {
            let station = stations[((here + delta * step) % count + count) % count]
            if await tune(station, kind: "channel-change") { return }
        }
    }

    /// Tune a station picked from the guide over the picture.
    func tuneStation(id: String) async {
        guard isWatchingStation else { return }
        if stations.isEmpty { stations = (try? await client.getVirtualChannels()) ?? [] }
        let key = Self.stationKey(id)
        guard let station = stations.first(where: { Self.stationKey($0.id) == key }) else { return }
        _ = await tune(station, kind: "guide")
    }

    /// Join `station` where it is now. False when it is off air or its
    /// programme cannot be fetched, so channel up/down can skip past it.
    private func tune(_ station: VirtualChannel, kind: String) async -> Bool {
        guard let now = try? await client.getChannelNowPlaying(channelId: station.id),
              let item = try? await client.getItem(itemId: now.itemId) else { return false }
        guard !Task.isCancelled else { return true }
        channelContext = ChannelPlaybackContext(channelID: station.id, now: now)
        diag(.nextEpisode, [
            PlayerDiagnostics.field("item", item.id),
            PlayerDiagnostics.field("kind", kind),
            PlayerDiagnostics.field("channel", station.id)
        ])
        rejoinLive()
        // The new station's bar goes up before its stream loads: the station
        // should answer the press at once, the picture can take a moment.
        await announceStation()
        await loadMedia(item: item)
        return true
    }

    /// Show the banner for what is on now. Called on tune-in, on each channel
    /// change and when the channel rolls to its next programme. One short guide
    /// request supplies now and next with names, episode numbers and the new
    /// flag, so the banner reads the same as the guide.
    func announceStation() async {
        guard let channel = channelContext else { return }
        if stations.isEmpty { stations = (try? await client.getVirtualChannels()) ?? [] }
        let key = Self.stationKey(channel.channelID)
        let station = stations.first { Self.stationKey($0.id) == key }

        let guide = (try? await client.getChannelGuide(hours: 0.5)) ?? []
        let row = guide.first { Self.stationKey($0.id) == key }
        let clock = Date()
        let now = row?.programs.first { $0.isAiring(at: clock) } ?? row?.programs.first
        let next = row?.programs.first { $0.startUtc >= (now?.endUtc ?? clock) }
        let labels = row.map { GuideRow(channel: $0, items: [:]) }

        var title = currentItem.map { $0.type == .episode ? ($0.seriesName ?? $0.name) : $0.name } ?? ""
        var detail: String?
        if let labels, let now {
            title = labels.title(for: now)
            detail = labels.subtitle(for: now)
            // Many episodes are named after their show; "S10E19 · Australian
            // Survivor" under "Australian Survivor (2002)" says nothing twice.
            let bareTitle = title.replacingOccurrences(of: #" \(\d{4}\)$"#, with: "", options: .regularExpression)
            if let episodeName = now.name, now.type == "Episode", let label = detail, label.hasPrefix("S"),
               episodeName != title, episodeName != bareTitle {
                detail = "\(label) · \(episodeName)"
            }
        }

        let logoKey = station?.logo ?? row?.logo
        var logoURL: URL?
        var monoURL: URL?
        if let logoKey {
            logoURL = await client.channelLogoURL(channelId: channel.channelID, key: logoKey)
            monoURL = await client.channelLogoURL(channelId: channel.channelID, key: logoKey, mono: true)
        }
        stationMark = StationMark(
            logoURL: monoURL,
            name: (station?.name ?? row?.name ?? "SashimiTV").uppercased()
        )
        var behind = secondsBehindLive
        if let since = stationPausedAt { behind += clock.timeIntervalSince(since) }

        stationBanner = StationBanner(
            channelName: station?.name ?? row?.name ?? "SashimiTV",
            channelDescription: station?.description,
            title: title,
            detail: detail,
            isNew: now?.isNew ?? false,
            // The guide clips the programme on air to the moment it was asked
            // for and says how far in it already is; the real start is that far
            // back. Without this the bar read "15:23 – 15:24" for a programme
            // an hour in (seen in a simulator frame).
            startsAt: now.map { $0.startUtc.addingTimeInterval(-$0.startPositionSeconds) },
            endsAt: now?.endUtc ?? channel.endsAt,
            nextTitle: next.flatMap { entry in labels?.title(for: entry) },
            nextStartsAt: next?.startUtc,
            logoURL: logoURL,
            isPaused: stationPausedAt != nil,
            minutesBehindLive: Int(behind / 60)
        )
    }

    /// Clear the banner once it has been on screen long enough. The view calls
    /// this, not a timer here: playback opens with the transport bar up, the
    /// banner is hidden behind it, and a timer started at tune-in expired
    /// before anyone saw it (seen in simulator frames).
    func dismissStationBanner(_ id: UUID) {
        if stationBanner?.id == id { stationBanner = nil }
    }

    /// Clear whatever bar is up — the guide is about to cover it.
    func dismissStationBannerNow() {
        stationBanner = nil
    }

    /// Channel ids arrive with and without dashes depending on the endpoint.
    static func stationKey(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Move to whatever the channel is airing now.
    ///
    /// Re-queried rather than trusting the `nextItemID` carried in the context:
    /// that was the successor *when the viewer tuned in*, and a programme lasts
    /// long enough for the schedule underneath it to have been rebuilt — an
    /// episode deleted by a cleanup tool shifts everything after it. The
    /// carried id is for warming the next item, not for deciding what to play.
    /// What the channel airs once the programme that just ended is over.
    ///
    /// The stream can finish a moment before the server's schedule does — its
    /// clock runs a few seconds ahead of the device's, and a programme joined
    /// mid-way starts that far out. Asked at once, the server still names the
    /// finished programme with a second or two left, and tuning that replays
    /// its last frames: seen on a real Apple TV as three black reloads in a
    /// row before the channel moved on, which read as a crash. So while the
    /// answer is the item that just ended, wait for its scheduled end and ask
    /// again, a few times at most.
    private func nowPlayingAfterBoundary(channelID: String) async throws -> ChannelNowPlaying? {
        let finished = currentItem?.id
        for _ in 0..<4 {
            let now = try await client.getChannelNowPlaying(channelId: channelID)
            guard let now, now.itemId == finished else { return now }
            let wait = min(max(now.endUtc.timeIntervalSinceNow, 0) + 1, 20)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return nil }
        }
        return try await client.getChannelNowPlaying(channelId: channelID)
    }

    func rollToNextChannelProgramme(attempt: Int) async {
        guard let channel = channelContext else { return }

        do {
            guard let next = try await nowPlayingAfterBoundary(channelID: channel.channelID) else {
                // The channel went off air between programmes — a gap in the
                // broadcast day. Stop rather than inventing something to play.
                diag(.playbackEnded, [
                    PlayerDiagnostics.field("phase", "channel-off-air"),
                    PlayerDiagnostics.field("channel", channel.channelID)
                ])
                playbackEnded = true
                return
            }

            let item = try await client.getItem(itemId: next.itemId)
            guard !Task.isCancelled else { return }

            channelContext = ChannelPlaybackContext(channelID: channel.channelID, now: next)
            diag(.nextEpisode, [
                PlayerDiagnostics.field("item", item.id),
                PlayerDiagnostics.field("automatic", true),
                PlayerDiagnostics.field("kind", "channel"),
                PlayerDiagnostics.field("joinSeconds", next.startPositionSeconds)
            ])
            rejoinLive()
            await loadMedia(item: item)
            await announceStation()
        } catch {
            // A failed roll ends the session rather than stranding the viewer on
            // a finished programme with no way forward.
            diagFailure(.loadFailed, [PlayerDiagnostics.field("phase", "channel-roll")]
                        + PlayerDiagnostics.fields(for: error))
            playbackEnded = true
        }
    }
}
