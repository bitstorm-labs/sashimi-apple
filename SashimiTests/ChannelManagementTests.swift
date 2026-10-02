import XCTest
@testable import Sashimi

// MARK: - Decoding (sample JSON per the plugin contract)

final class ChannelManagementDecodingTests: XCTestCase {
    private let channelJSON = """
    {"Id":"6f1c2a9b0d3e4f5a8b7c6d5e4f3a2b1c","Name":"Solstice","Number":7,"Logo":"snowflake",
     "IsScheduled":true,
     "Dayparts":[
       {"Index":0,"Name":"Morning Cartoons","StartMinutes":360,"EndMinutes":720,"IsSeasonal":false,
        "AddedItems":[{"Id":"a1b2c3d4e5f60718293a4b5c6d7e8f90","Name":"Bluey","Type":"Series","ProductionYear":2018}],
        "RuleSummary":null},
       {"Index":1,"Name":"Sweater Weather","StartMinutes":1080,"EndMinutes":1440,"IsSeasonal":true,
        "AddedItems":[{"Id":"0f9e8d7c6b5a49382716051423324150","Name":"Elf","Type":"Movie"}],
        "RuleSummary":"Science Fiction"}
     ]}
    """

    func testManagedChannelDecodes() throws {
        let channel = try JSONDecoder().decode(ManagedChannel.self, from: Data(channelJSON.utf8))
        XCTAssertEqual(channel.id, "6f1c2a9b0d3e4f5a8b7c6d5e4f3a2b1c")
        XCTAssertEqual(channel.name, "Solstice")
        XCTAssertEqual(channel.number, 7)
        XCTAssertEqual(channel.logo, "snowflake")
        XCTAssertTrue(channel.isScheduled)
        XCTAssertEqual(channel.dayparts.map(\.name), ["Morning Cartoons", "Sweater Weather"])
        XCTAssertEqual(channel.dayparts[0].addedItems.first?.type, "Series")
        XCTAssertEqual(channel.dayparts[0].addedItems.first?.productionYear, 2018)
        XCTAssertNil(channel.dayparts[1].addedItems.first?.productionYear)
        XCTAssertNil(channel.dayparts[0].ruleSummary)
        XCTAssertEqual(channel.dayparts[1].ruleSummary, "Science Fiction")
        XCTAssertTrue(channel.dayparts[1].isSeasonal)
        XCTAssertEqual(channel.dayparts[0].timeRangeLabel, "06:00–12:00")
        XCTAssertEqual(channel.addedItemCount, 2)
        XCTAssertTrue(channel.hasRule)
    }

    func testOptionalChannelFieldsMayBeAbsent() throws {
        let json = #"{"Id":"c","Name":"Plain","IsScheduled":false,"Dayparts":[{"Index":0,"Name":"Plain","StartMinutes":0,"EndMinutes":1440,"IsSeasonal":false,"AddedItems":[]}]}"#
        let channel = try JSONDecoder().decode(ManagedChannel.self, from: Data(json.utf8))
        XCTAssertNil(channel.number)
        XCTAssertNil(channel.logo)
        XCTAssertNil(channel.dayparts[0].ruleSummary)
        XCTAssertNil(channel.dayparts[0].timeRangeLabel, "an all-day daypart has no time range to show")
        XCTAssertFalse(channel.hasRule)
    }

    func testPluginResponsesWithAByteOrderMarkDecode() throws {
        // The plugin's JSON starts with a UTF-8 BOM.
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(channelJSON.utf8)
        let channel = try JSONDecoder().decode(ManagedChannel.self, from: data)
        XCTAssertEqual(channel.name, "Solstice")
    }

    func testProblemDetailsMessageIsTheDetail() {
        let body = #"{"type":"https://tools.ietf.org/html/rfc9110#section-15.5.1","title":"Bad Request","status":400,"detail":"Unknown logo key 'nope'."}"#
        XCTAssertEqual(ProblemDetails.message(in: Data(body.utf8)), "Unknown logo key 'nope'.")
        XCTAssertNil(ProblemDetails.message(in: Data(#"{"title":"Not Found","status":404}"#.utf8)))
        XCTAssertNil(ProblemDetails.message(in: Data()))
    }

    func testMembershipDecodesEveryState() throws {
        let json = """
        [{"ChannelId":"a","DaypartIndex":0,"State":"Added"},
         {"ChannelId":"b","DaypartIndex":1,"State":"ViaRule","RuleSummary":"Science Fiction"},
         {"ChannelId":"c","DaypartIndex":0,"State":"None","RuleSummary":null},
         {"ChannelId":"d","DaypartIndex":0,"State":"SomethingNew"}]
        """
        let rows = try JSONDecoder().decode([ChannelMembership].self, from: Data(json.utf8))
        XCTAssertEqual(rows.map(\.state), [.added, .viaRule, .none, .none])
        XCTAssertEqual(rows[1].ruleSummary, "Science Fiction")
        XCTAssertEqual(rows[1].daypartIndex, 1)
    }

    func testUserPolicyAdministratorFlag() throws {
        let admin = #"{"Id":"u","Name":"Mondo","Policy":{"IsAdministrator":true,"IsDisabled":false}}"#
        let viewer = #"{"Id":"u","Name":"Kid","Policy":{"IsAdministrator":false}}"#
        let trimmed = #"{"Id":"u","Name":"Someone"}"#
        XCTAssertEqual(try JSONDecoder().decode(UserDto.self, from: Data(admin.utf8)).policy?.isAdministrator, true)
        XCTAssertEqual(try JSONDecoder().decode(UserDto.self, from: Data(viewer.utf8)).policy?.isAdministrator, false)
        XCTAssertNil(try JSONDecoder().decode(UserDto.self, from: Data(trimmed.utf8)).policy)
    }

    func testRequestBodiesUseJellyfinKeysAndOmitUnsetFields() throws {
        func object(_ value: some Encodable) throws -> [String: Any] {
            let data = try JSONEncoder().encode(value)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        let create = try object(CreateManagedChannelRequest(name: "Cozy", logo: "leaf", seedItemId: "abc"))
        XCTAssertEqual(create["Name"] as? String, "Cozy")
        XCTAssertEqual(create["Logo"] as? String, "leaf")
        XCTAssertEqual(create["SeedItemId"] as? String, "abc")

        let rename = try object(UpdateManagedChannelRequest(name: "Renamed"))
        XCTAssertEqual(rename.keys.sorted(), ["Name"], "a PATCH must not send a null logo that would clear it")

        let addDefault = try object(AddChannelItemRequest(itemId: "abc", daypartIndex: nil))
        XCTAssertEqual(addDefault.keys.sorted(), ["ItemId"])
        let addDaypart = try object(AddChannelItemRequest(itemId: "abc", daypartIndex: 2))
        XCTAssertEqual(addDaypart["DaypartIndex"] as? Int, 2)
    }
}

// MARK: - Fixtures

enum ChannelFixtures {
    static let seriesID = "a1b2c3d4e5f60718293a4b5c6d7e8f90"

    static func item(_ id: String, _ name: String, type: String = "Series") -> ManagedItem {
        ManagedItem(id: id, name: name, type: type, productionYear: nil)
    }

    static func plain(_ id: String, name: String, added: [ManagedItem] = [], rule: String? = nil) -> ManagedChannel {
        ManagedChannel(
            id: id, name: name, number: 1, logo: nil, isScheduled: false,
            dayparts: [ManagedDaypart(index: 0, name: name, addedItems: added, ruleSummary: rule)]
        )
    }

    static func scheduled(_ id: String, name: String) -> ManagedChannel {
        ManagedChannel(
            id: id, name: name, number: 2, logo: nil, isScheduled: true,
            dayparts: [
                ManagedDaypart(index: 0, name: "Morning", startMinutes: 360, endMinutes: 720),
                ManagedDaypart(index: 1, name: "Sweater Weather", startMinutes: 1080, endMinutes: 1440, isSeasonal: true)
            ]
        )
    }
}

// MARK: - Membership → menu state

final class ChannelMenuMappingTests: XCTestCase {
    func testUnscheduledChannelsFoldTheirMembershipIntoOneToggle() {
        let channels = [
            ChannelFixtures.plain("added", name: "Cartoons"),
            ChannelFixtures.plain("rule", name: "Sci-Fi"),
            ChannelFixtures.plain("none", name: "Westerns")
        ]
        let memberships = [
            ChannelMembership(channelId: "added", daypartIndex: 0, state: .added, ruleSummary: nil),
            ChannelMembership(channelId: "rule", daypartIndex: 0, state: .viaRule, ruleSummary: "Science Fiction"),
            ChannelMembership(channelId: "none", daypartIndex: 0, state: .none, ruleSummary: nil)
        ]

        let entries = ChannelMenuEntry.build(channels: channels, memberships: memberships)
        let options = entries.compactMap(\.single)

        XCTAssertEqual(options.map(\.state), [.added, .viaRule, .none])
        XCTAssertEqual(options.map(\.isChecked), [true, true, false])
        XCTAssertEqual(options.map(\.isEnabled), [true, false, true], "a rule-sourced checkmark is shown but disabled")
        XCTAssertEqual(options[0].action, .remove(daypartIndex: 0))
        XCTAssertEqual(options[1].action, .none)
        XCTAssertEqual(options[1].viaLabel, "(via Science Fiction)")
        XCTAssertEqual(options[2].action, .add(daypartIndex: nil), "adding lets the server pick the default daypart")
        XCTAssertFalse(entries[0].isScheduled)
    }

    func testAddedBeatsViaRuleOnAnUnscheduledChannel() {
        let channel = ChannelFixtures.plain("c", name: "Mixed")
        let memberships = [
            ChannelMembership(channelId: "c", daypartIndex: 0, state: .viaRule, ruleSummary: "Comedy"),
            ChannelMembership(channelId: "c", daypartIndex: 0, state: .added, ruleSummary: nil)
        ]
        let option = ChannelMenuEntry.build(channels: [channel], memberships: memberships)[0].single
        XCTAssertEqual(option?.state, .added)
        XCTAssertEqual(option?.action, .remove(daypartIndex: 0))
    }

    func testAChannelMissingFromMembershipIsUnchecked() {
        let entries = ChannelMenuEntry.build(channels: [ChannelFixtures.plain("c", name: "New")], memberships: [])
        XCTAssertEqual(entries[0].single?.state, ChannelMembershipState.none)
        XCTAssertFalse(entries[0].isChecked)
    }

    func testScheduledChannelsOfferOneToggleperDaypart() {
        let channel = ChannelFixtures.scheduled("s", name: "Solstice")
        let memberships = [
            ChannelMembership(channelId: "s", daypartIndex: 0, state: .none, ruleSummary: nil),
            ChannelMembership(channelId: "s", daypartIndex: 1, state: .added, ruleSummary: nil)
        ]
        let entry = ChannelMenuEntry.build(channels: [channel], memberships: memberships)[0]

        XCTAssertTrue(entry.isScheduled)
        XCTAssertNil(entry.single)
        XCTAssertEqual(entry.dayparts.map(\.title), ["Morning", "Sweater Weather"])
        XCTAssertEqual(entry.dayparts[0].action, .add(daypartIndex: 0), "a daypart pick names its daypart")
        XCTAssertEqual(entry.dayparts[1].action, .remove(daypartIndex: 1))
        XCTAssertTrue(entry.isChecked, "the channel reads as checked when any daypart carries the title")
    }

    func testRemovingTheLastAddedTitleFromAChannelWithoutARuleTakesItOffAir() {
        let id = ChannelFixtures.seriesID
        let lonely = ChannelFixtures.plain("c", name: "Lonely", added: [ChannelFixtures.item(id, "Bluey")])
        let ruled = ChannelFixtures.plain("r", name: "Ruled", added: [ChannelFixtures.item(id, "Bluey")], rule: "Kids")
        let busy = ChannelFixtures.plain("b", name: "Busy", added: [
            ChannelFixtures.item(id, "Bluey"), ChannelFixtures.item("other", "Elf", type: "Movie")
        ])
        XCTAssertTrue(lonely.removingTakesOffAir(itemId: id))
        XCTAssertFalse(ruled.removingTakesOffAir(itemId: id), "a rule keeps the channel on air")
        XCTAssertFalse(busy.removingTakesOffAir(itemId: id))
    }

    func testOffAirCheckMirrorsWhatTheServerRemoves() {
        // A series leaves only the daypart named; a film leaves the whole
        // channel, because the managed collection belongs to the channel.
        let series = ChannelFixtures.item("show", "Bluey")
        let film = ChannelFixtures.item("film", "Elf", type: "Movie")
        let twoDayparts = ManagedChannel(
            id: "s", name: "Solstice", number: 3, logo: nil, isScheduled: true,
            dayparts: [
                ManagedDaypart(index: 0, name: "Morning", addedItems: [series, film]),
                ManagedDaypart(index: 1, name: "Evening", addedItems: [series, film])
            ]
        )
        let onlyTheFilm = ChannelFixtures.plain("f", name: "Films", added: [film])

        XCTAssertFalse(twoDayparts.removingTakesOffAir(itemId: "show", daypartIndex: 0))
        XCTAssertFalse(twoDayparts.removingTakesOffAir(itemId: "film", daypartIndex: 0), "the series still airs")
        XCTAssertTrue(onlyTheFilm.removingTakesOffAir(itemId: "film", daypartIndex: 0))

        let seriesOnly = ManagedChannel(
            id: "o", name: "Only", number: 4, logo: nil, isScheduled: true,
            dayparts: [
                ManagedDaypart(index: 0, name: "Morning", addedItems: [series]),
                ManagedDaypart(index: 1, name: "Evening", addedItems: [series])
            ]
        )
        XCTAssertFalse(seriesOnly.removingTakesOffAir(itemId: "show", daypartIndex: 0), "the evening still has it")
        XCTAssertTrue(seriesOnly.removingTakesOffAir(itemId: "show", daypartIndex: nil), "nil removes it everywhere")
    }

    func testChannelTargetResolvesEpisodesAndSeasonsToTheirSeries() throws {
        func item(_ json: String) throws -> BaseItemDto {
            try JSONDecoder().decode(BaseItemDto.self, from: Data(json.utf8))
        }
        let episode = try item(#"{"Id":"ep","Name":"The Pool","Type":"Episode","SeriesId":"series","SeriesName":"Bluey"}"#)
        let season = try item(#"{"Id":"s1","Name":"Season 1","Type":"Season","SeriesId":"series","SeriesName":"Bluey"}"#)
        let movie = try item(#"{"Id":"m","Name":"Elf","Type":"Movie"}"#)
        let folder = try item(#"{"Id":"f","Name":"Stuff","Type":"Folder"}"#)

        XCTAssertEqual(ChannelTarget(item: episode), ChannelTarget(itemId: "series", title: "Bluey"))
        XCTAssertEqual(ChannelTarget(item: season), ChannelTarget(itemId: "series", title: "Bluey"))
        XCTAssertEqual(ChannelTarget(item: movie), ChannelTarget(itemId: "m", title: "Elf"))
        XCTAssertNil(ChannelTarget(item: folder))
    }
}

// MARK: - View model flows

@MainActor
final class ChannelManagementViewModelTests: XCTestCase {
    /// A server in memory: channels plus which (channel, daypart) carry which item.
    private final class StubClient: ChannelManagementClient, @unchecked Sendable {
        var channels: [ManagedChannel]
        var added: Set<String> = []  // "channel#daypart#item"
        var failNext: Error?
        var failMembership: Error?
        private(set) var calls: [String] = []

        init(channels: [ManagedChannel]) { self.channels = channels }

        private func failIfAsked() throws {
            if let error = failNext {
                failNext = nil
                throw error
            }
        }

        func getManagedChannels() async throws -> [ManagedChannel] {
            calls.append("list")
            try failIfAsked()
            return channels
        }

        func getChannelMembership(itemId: String) async throws -> [ChannelMembership] {
            calls.append("membership \(itemId)")
            if let failMembership { throw failMembership }
            return channels.flatMap { channel in
                channel.dayparts.map { daypart in
                    let isAdded = added.contains("\(channel.id)#\(daypart.index)#\(itemId)")
                    return ChannelMembership(
                        channelId: channel.id, daypartIndex: daypart.index,
                        state: isAdded ? .added : .none, ruleSummary: nil)
                }
            }
        }

        func getChannelLogoKeys() async throws -> [String] { ["leaf", "snowflake"] }

        func createManagedChannel(_ body: CreateManagedChannelRequest) async throws -> ManagedChannel {
            calls.append("create \(body.name) \(body.logo ?? "-") \(body.seedItemId ?? "-")")
            try failIfAsked()
            let items = body.seedItemId.map { [ChannelFixtures.item($0, "Seed")] } ?? []
            let channel = ChannelFixtures.plain("new", name: body.name, added: items)
            channels.append(channel)
            if let seed = body.seedItemId { added.insert("new#0#\(seed)") }
            return channel
        }

        func updateManagedChannel(channelId: String, _ body: UpdateManagedChannelRequest) async throws -> ManagedChannel {
            calls.append("update \(channelId) \(body.name ?? "-") \(body.logo ?? "-")")
            try failIfAsked()
            guard let index = channels.firstIndex(where: { $0.id == channelId }) else {
                throw JellyfinError.httpError(statusCode: 404)
            }
            let old = channels[index]
            channels[index] = ManagedChannel(
                id: old.id, name: body.name ?? old.name, number: old.number,
                logo: body.logo ?? old.logo, isScheduled: old.isScheduled, dayparts: old.dayparts)
            return channels[index]
        }

        func deleteManagedChannel(channelId: String) async throws {
            calls.append("delete \(channelId)")
            try failIfAsked()
            channels.removeAll { $0.id == channelId }
        }

        func addItemToChannel(channelId: String, itemId: String, daypartIndex: Int?) async throws -> ManagedChannel {
            calls.append("add \(channelId) \(itemId) \(daypartIndex.map(String.init) ?? "default")")
            try failIfAsked()
            added.insert("\(channelId)#\(daypartIndex ?? 0)#\(itemId)")
            return try XCTUnwrap(channels.first { $0.id == channelId })
        }

        func removeItemFromChannel(channelId: String, itemId: String, daypartIndex: Int?) async throws -> ManagedChannel {
            calls.append("remove \(channelId) \(itemId) \(daypartIndex.map(String.init) ?? "default")")
            try failIfAsked()
            added.remove("\(channelId)#\(daypartIndex ?? 0)#\(itemId)")
            return try XCTUnwrap(channels.first { $0.id == channelId })
        }
    }

    private let item = ChannelFixtures.seriesID
    private var changes = 0

    private func makeModel(_ client: StubClient) -> ChannelManagementViewModel {
        changes = 0
        return ChannelManagementViewModel(client: client, lateRefreshDelay: nil) { [weak self] in self?.changes += 1 }
    }

    func testAddingFromTheMenuChecksTheChannelAndAnnouncesTheChange() async throws {
        let client = StubClient(channels: [ChannelFixtures.plain("c", name: "Cartoons")])
        let model = makeModel(client)
        await model.loadMenu(itemId: item)
        let option = try XCTUnwrap(model.menuEntries.first?.single)
        XCTAssertEqual(option.state, ChannelMembershipState.none)

        let didApply = await model.apply(option, itemId: item)

        XCTAssertTrue(didApply)
        XCTAssertTrue(client.calls.contains("add c \(item) default"))
        XCTAssertEqual(model.menuEntries.first?.single?.state, .added, "the checkmark comes from the server's answer")
        XCTAssertEqual(changes, 1, "the guide and rows are told to reload")
    }

    func testTogglingAnAddedChannelRemovesItFromItsDaypart() async throws {
        let client = StubClient(channels: [ChannelFixtures.scheduled("s", name: "Solstice")])
        client.added = ["s#1#\(item)"]
        let model = makeModel(client)
        await model.loadMenu(itemId: item)
        let option = try XCTUnwrap(model.menuEntries.first?.dayparts.last)
        XCTAssertEqual(option.state, .added)

        await model.apply(option, itemId: item)

        XCTAssertTrue(client.calls.contains("remove s \(item) 1"))
        XCTAssertEqual(model.menuEntries.first?.dayparts.last?.state, ChannelMembershipState.none)
    }

    func testAFailedMembershipShowsAnErrorNotUncheckedChannels() async {
        // Channels listed without their memberships read as "on no channel";
        // the menu must show the failure instead of a wrong set of checkmarks.
        let client = StubClient(channels: [ChannelFixtures.plain("c", name: "Cartoons")])
        client.added = ["c#0#\(item)"]
        client.failMembership = JellyfinError.httpError(statusCode: 500)
        let model = makeModel(client)

        await model.loadMenu(itemId: item)

        XCTAssertTrue(model.loadFailed)
        XCTAssertTrue(model.menuEntries.isEmpty, "no unchecked rows for a title that is in fact on the channel")
    }

    func testARuleSourcedCheckmarkDoesNothing() async {
        let client = StubClient(channels: [ChannelFixtures.plain("c", name: "Sci-Fi")])
        let model = makeModel(client)
        let option = ChannelMenuOption(channelId: "c", daypartIndex: 0, title: "Sci-Fi", state: .viaRule, ruleSummary: "Science Fiction")

        let didApply = await model.apply(option, itemId: item)

        XCTAssertFalse(didApply)
        XCTAssertFalse(client.calls.contains { $0.hasPrefix("add") || $0.hasPrefix("remove") })
        XCTAssertEqual(changes, 0)
    }

    func testCreatingAChannelSeedsItWithTheTitleAndListsIt() async throws {
        let client = StubClient(channels: [])
        let model = makeModel(client)
        await model.loadMenu(itemId: item)

        let created = await model.createChannel(name: "  Cozy Autumn ", logo: "leaf", seedItemId: item)

        XCTAssertEqual(created?.name, "Cozy Autumn", "the name is trimmed before it is sent")
        XCTAssertTrue(client.calls.contains("create Cozy Autumn leaf \(item)"))
        XCTAssertEqual(model.channels.map(\.id), ["new"])
        XCTAssertEqual(model.menuEntries.first?.single?.state, .added)
        XCTAssertEqual(changes, 1)
    }

    func testABlankNameIsRefusedWithoutCallingTheServer() async {
        let client = StubClient(channels: [])
        let model = makeModel(client)

        let created = await model.createChannel(name: "   ", logo: nil, seedItemId: nil)

        XCTAssertNil(created)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(client.calls.contains { $0.hasPrefix("create") })
    }

    func testRenameAndLogoUpdateTheListedChannel() async {
        let client = StubClient(channels: [ChannelFixtures.plain("c", name: "Old")])
        let model = makeModel(client)
        await model.loadChannels()

        await model.rename(channelId: "c", to: "New")
        await model.setLogo(channelId: "c", logo: "snowflake")

        XCTAssertEqual(model.channel(id: "c")?.name, "New")
        XCTAssertEqual(model.channel(id: "c")?.logo, "snowflake")
        XCTAssertEqual(changes, 2)
    }

    func testClearingTheLogoSendsAnEmptyKey() async {
        let client = StubClient(channels: [ManagedChannel(
            id: "c", name: "Logo", number: 1, logo: "leaf", isScheduled: false,
            dayparts: [ManagedDaypart(index: 0, name: "Logo")])])
        let model = makeModel(client)
        await model.loadChannels()

        await model.setLogo(channelId: "c", logo: nil)

        XCTAssertTrue(client.calls.contains("update c - "), "\"\" removes the logo; null would leave it unchanged")
    }

    func testTheServersOwnExplanationIsShown() async {
        let client = StubClient(channels: [ChannelFixtures.plain("a", name: "A")])
        let model = makeModel(client)
        await model.loadChannels()
        client.failNext = JellyfinError.serverMessage(statusCode: 400, message: "Unknown logo key 'nope'.")

        await model.setLogo(channelId: "a", logo: "nope")

        XCTAssertEqual(model.errorMessage, "Unknown logo key 'nope'.")
    }

    func testRenamingToTheSameNameSendsNothing() async {
        let client = StubClient(channels: [ChannelFixtures.plain("c", name: "Same")])
        let model = makeModel(client)
        await model.loadChannels()

        await model.rename(channelId: "c", to: "Same ")

        XCTAssertFalse(client.calls.contains { $0.hasPrefix("update") })
        XCTAssertEqual(changes, 0)
    }

    func testDeletingAChannelDropsItFromTheList() async {
        let client = StubClient(channels: [ChannelFixtures.plain("a", name: "A"), ChannelFixtures.plain("b", name: "B")])
        let model = makeModel(client)
        await model.loadChannels()

        let deleted = await model.deleteChannel(channelId: "a")

        XCTAssertTrue(deleted)
        XCTAssertEqual(model.channels.map(\.id), ["b"])
        XCTAssertEqual(changes, 1)
    }

    func testAFailedMutationKeepsTheListAndSaysWhy() async {
        let client = StubClient(channels: [ChannelFixtures.plain("a", name: "A")])
        let model = makeModel(client)
        await model.loadChannels()
        client.failNext = JellyfinError.httpError(statusCode: 404)

        let deleted = await model.deleteChannel(channelId: "a")

        XCTAssertFalse(deleted)
        XCTAssertEqual(model.channels.map(\.id), ["a"], "nothing is removed from the screen that the server kept")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(changes, 0)
    }

    func testAnOldPluginWithoutTheManagementAPISaysSo() async {
        let client = StubClient(channels: [])
        client.failNext = JellyfinError.httpError(statusCode: 404)
        let model = makeModel(client)

        await model.loadChannels()

        XCTAssertTrue(model.loadFailed)
        XCTAssertEqual(model.errorMessage, ChannelManagementViewModel.message(for: JellyfinError.httpError(statusCode: 404), loading: true))
        XCTAssertTrue(model.errorMessage?.contains("plugin") ?? false)
    }

    func testRemovalWarningOnlyForTheLastTitleOfARulelessChannel() async throws {
        let client = StubClient(channels: [
            ChannelFixtures.plain("c", name: "Lonely", added: [ChannelFixtures.item(item, "Bluey")])
        ])
        client.added = ["c#0#\(item)"]
        let model = makeModel(client)
        await model.loadMenu(itemId: item)
        let option = try XCTUnwrap(model.menuEntries.first?.single)

        XCTAssertTrue(model.removalTakesOffAir(option, itemId: item))
    }

    func testRemovingFromManageChannelsUsesTheDaypart() async {
        let client = StubClient(channels: [ChannelFixtures.scheduled("s", name: "Solstice")])
        let model = makeModel(client)
        await model.loadChannels()

        await model.removeItem("elf", from: "s", daypartIndex: 1)

        XCTAssertTrue(client.calls.contains("remove s elf 1"))
        XCTAssertEqual(changes, 1)
    }
}
