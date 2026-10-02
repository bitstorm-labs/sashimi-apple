import Foundation

/// The management calls, as a protocol so the view model's rules — what a
/// mutation refreshes, what it announces, what a failure leaves on screen —
/// can be tested without a server (the same seam `GuideClient` uses).
protocol ChannelManagementClient: Sendable {
    func getManagedChannels() async throws -> [ManagedChannel]
    func getChannelMembership(itemId: String) async throws -> [ChannelMembership]
    func getChannelLogoKeys() async throws -> [String]
    func createManagedChannel(_ body: CreateManagedChannelRequest) async throws -> ManagedChannel
    func updateManagedChannel(channelId: String, _ body: UpdateManagedChannelRequest) async throws -> ManagedChannel
    func deleteManagedChannel(channelId: String) async throws
    func addItemToChannel(channelId: String, itemId: String, daypartIndex: Int?) async throws -> ManagedChannel
    func removeItemFromChannel(channelId: String, itemId: String, daypartIndex: Int?) async throws -> ManagedChannel
}

extension JellyfinClient: ChannelManagementClient {}

extension SessionManager {
    /// Channel management is for the active server's administrators only. A
    /// detail page scoped to another saved server hides it: the management
    /// calls go to the active server.
    func canManageChannels(serverID: String?) -> Bool {
        isAdministrator && (serverID == nil || serverID == activeServerId)
    }
}

/// Add to Channel, New Channel and Manage Channels, shared by tvOS and iOS.
@MainActor
final class ChannelManagementViewModel: ObservableObject {
    @Published private(set) var channels: [ManagedChannel] = []
    /// The current item's memberships, for the Add to Channel menu.
    @Published private(set) var memberships: [ChannelMembership] = []
    @Published private(set) var logoKeys: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false
    /// A mutation is in flight; the UI disables its controls meanwhile so a
    /// double press cannot send the same change twice.
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    private let client: ChannelManagementClient
    private let onChange: @MainActor () -> Void
    private let lateRefreshDelay: Duration?
    private var lateRefresh: Task<Void, Never>?
    /// The item the menu is about, so a mutation refreshes its checkmarks.
    private var itemId: String?

    /// - Parameter lateRefreshDelay: how long after a change to re-read the
    ///   item's memberships for rule-sourced checkmarks; nil never does.
    init(
        client: ChannelManagementClient? = nil,
        lateRefreshDelay: Duration? = .seconds(5),
        onChange: (@MainActor () -> Void)? = nil
    ) {
        self.client = client ?? JellyfinClient.shared
        self.lateRefreshDelay = lateRefreshDelay
        self.onChange = onChange ?? { ChannelManagementViewModel.announceChange() }
    }

    var menuEntries: [ChannelMenuEntry] {
        ChannelMenuEntry.build(channels: channels, memberships: memberships)
    }

    func channel(id: String) -> ManagedChannel? {
        channels.first { $0.id == id }
    }

    // MARK: - Loading

    func loadChannels() async {
        isLoading = channels.isEmpty
        loadFailed = false
        defer { isLoading = false }
        do {
            channels = try await client.getManagedChannels()
        } catch {
            loadFailed = true
            errorMessage = Self.message(for: error, loading: true)
        }
    }

    /// Channels and the item's memberships, for the Add to Channel menu.
    func loadMenu(itemId: String) async {
        self.itemId = itemId
        isLoading = channels.isEmpty
        loadFailed = false
        defer { isLoading = false }
        do {
            async let channelList = client.getManagedChannels()
            async let membershipList = client.getChannelMembership(itemId: itemId)
            channels = try await channelList
            memberships = try await membershipList
        } catch {
            loadFailed = true
            errorMessage = Self.message(for: error, loading: true)
        }
    }

    func loadLogos() async {
        guard logoKeys.isEmpty else { return }
        // A missing logo list only costs the picker; the channel is still
        // creatable without one.
        logoKeys = (try? await client.getChannelLogoKeys()) ?? []
    }

    // MARK: - Add to Channel

    /// Whether choosing `option` would take its channel off air: removing the
    /// last hand-added title from a channel nothing else feeds.
    func removalTakesOffAir(_ option: ChannelMenuOption, itemId: String) -> Bool {
        guard case .remove(let daypartIndex) = option.action,
              let channel = channel(id: option.channelId) else { return false }
        return channel.removingTakesOffAir(itemId: itemId, daypartIndex: daypartIndex)
    }

    /// Toggle the item on a channel (or daypart): Added → removed, None → added.
    /// Rule-sourced checkmarks do nothing.
    @discardableResult
    func apply(_ option: ChannelMenuOption, itemId: String) async -> Bool {
        switch option.action {
        case .none:
            return false
        case .add(let daypartIndex):
            return await mutate(itemId: itemId) {
                try await self.client.addItemToChannel(
                    channelId: option.channelId, itemId: itemId, daypartIndex: daypartIndex)
            }
        case .remove(let daypartIndex):
            return await mutate(itemId: itemId) {
                try await self.client.removeItemFromChannel(
                    channelId: option.channelId, itemId: itemId, daypartIndex: daypartIndex)
            }
        }
    }

    // MARK: - Channels

    /// A trimmed, non-empty name, or nil when there is nothing to save.
    static func validatedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Create a channel, optionally starting it with a title.
    func createChannel(name: String, logo: String?, seedItemId: String?) async -> ManagedChannel? {
        guard let name = Self.validatedName(name) else {
            errorMessage = "Give the channel a name."
            return nil
        }
        var created: ManagedChannel?
        _ = await mutate(itemId: seedItemId) {
            let channel = try await self.client.createManagedChannel(
                CreateManagedChannelRequest(name: name, logo: logo, seedItemId: seedItemId))
            created = channel
            return channel
        }
        return created
    }

    @discardableResult
    func rename(channelId: String, to name: String) async -> Bool {
        guard let name = Self.validatedName(name) else {
            errorMessage = "A channel needs a name."
            return false
        }
        guard channel(id: channelId)?.name != name else { return true }
        return await mutate(itemId: itemId) {
            try await self.client.updateManagedChannel(channelId: channelId, UpdateManagedChannelRequest(name: name))
        }
    }

    /// Set the channel's logo; nil takes it away.
    @discardableResult
    func setLogo(channelId: String, logo: String?) async -> Bool {
        guard channel(id: channelId)?.logo != logo else { return true }
        let body = UpdateManagedChannelRequest(logo: logo ?? UpdateManagedChannelRequest.noLogo)
        return await mutate(itemId: itemId) {
            try await self.client.updateManagedChannel(channelId: channelId, body)
        }
    }

    @discardableResult
    func removeItem(_ itemId: String, from channelId: String, daypartIndex: Int?) async -> Bool {
        await mutate(itemId: self.itemId) {
            try await self.client.removeItemFromChannel(
                channelId: channelId, itemId: itemId, daypartIndex: daypartIndex)
        }
    }

    @discardableResult
    func deleteChannel(channelId: String) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.deleteManagedChannel(channelId: channelId)
            channels.removeAll { $0.id == channelId }
            memberships.removeAll { $0.channelId == channelId }
            onChange()
            return true
        } catch {
            errorMessage = Self.message(for: error, loading: false)
            return false
        }
    }

    // MARK: - Plumbing

    /// Run one mutation that answers with the channel's new state: fold it
    /// into the list, refresh the item's checkmarks, and tell the rest of the
    /// app its channels changed.
    private func mutate(itemId: String?, _ call: @escaping () async throws -> ManagedChannel) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let updated = try await call()
            if let index = channels.firstIndex(where: { $0.id == updated.id }) {
                channels[index] = updated
            } else {
                channels.append(updated)
            }
            if let itemId {
                // The server resolved the change (an episode to its series, a
                // movie into the managed collection); its answer is the truth.
                await refreshMemberships(itemId: itemId)
                scheduleLateMembershipRefresh(itemId: itemId)
            }
            onChange()
            return true
        } catch {
            errorMessage = Self.message(for: error, loading: false)
            return false
        }
    }

    private func refreshMemberships(itemId: String) async {
        guard let fresh = try? await client.getChannelMembership(itemId: itemId),
              self.itemId == nil || self.itemId == itemId else { return }
        memberships = fresh
    }

    /// "Added" is immediate, but "ViaRule" comes from the channel's cached
    /// running order and lags a change by the seconds a rebuild takes — ask
    /// once more after that, so a rule checkmark appears or clears on its own.
    private func scheduleLateMembershipRefresh(itemId: String) {
        guard let lateRefreshDelay else { return }
        lateRefresh?.cancel()
        lateRefresh = Task { [weak self] in
            try? await Task.sleep(for: lateRefreshDelay)
            guard !Task.isCancelled else { return }
            await self?.refreshMemberships(itemId: itemId)
        }
    }

    /// Posts now, and once more after the plugin's usual ~30 s for the
    /// rebuilt schedule — a guide reloaded the instant after a change can
    /// still show the old one.
    static func announceChange() {
        NotificationCenter.default.post(name: .sashimiChannelsDidChange, object: nil)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(35))
            NotificationCenter.default.post(name: .sashimiChannelsDidChange, object: nil)
        }
    }

    static func message(for error: Error, loading: Bool) -> String {
        if case JellyfinError.serverMessage(_, let message) = error {
            return message
        }
        if case JellyfinError.httpError(let code) = error {
            switch code {
            case 400:
                return "The server didn't accept that change."
            case 403:
                return "Only server administrators can manage channels."
            case 404 where loading:
                return "This server's Channels plugin can't manage channels yet. Update the plugin and try again."
            case 404:
                return "That channel or title no longer exists, or it comes from a rule set in the dashboard."
            case 503:
                return "The Channels plugin isn't running on the server."
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
