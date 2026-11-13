import Foundation

/// The rules every Sashimi client shares for syncing settings across devices
/// (WORK-106, plans/sashimi/2026-11-12-settings-sync-schema.md). Pure, so the
/// spec's test vectors run here exactly as they do on Android and Roku.
///
/// Storage: the user's DisplayPreferences entry `sashimi-settings` (client
/// `sashimi`). Each synced setting is one `CustomPrefs` entry whose value is
/// a JSON string `{"v":<value>,"t":<epoch ms>}`; the newest `t` wins, key by key.
enum SettingsSync {
    static let preferencesId = "sashimi-settings"
    static let preferencesClient = "sashimi"
    static let schemaKey = "schema"
    static let schemaVersion = "1"
    /// The stamp a seeded setting gets: older than any real change.
    static let seedStamp: Int64 = 1
    static let homeRowsKey = "homeRows"
    static let sideMenuKey = "sideMenu"

    /// One row of a layout value: a shared id and whether it shows.
    struct LayoutEntry: Equatable, Hashable {
        let id: String
        let on: Bool
    }

    /// One entry of the side menu's combined order (`sideMenu`): a shared
    /// id and, for destinations only, whether the side menu shows it. Home
    /// rows that are not destinations (the hero, Continue Watching, shared
    /// lists) carry no `menu`: absent is not the same as switched off, so
    /// the optional Bool is on purpose.
    struct MenuEntry: Equatable, Hashable {
        let id: String
        let menu: Bool? // swiftlint:disable:this discouraged_optional_boolean

        init(id: String, menu: Bool? = nil) { // swiftlint:disable:this discouraged_optional_boolean
            self.id = id
            self.menu = menu
        }
    }

    enum Value: Equatable {
        case bool(Bool)
        case int(Int)
        case string(String)
        case layout([LayoutEntry])
        case menuLayout([MenuEntry])
    }

    struct Stamped: Equatable {
        let value: Value
        let t: Int64
    }

    /// What a value may be. Anything else from another device is ignored.
    enum Kind: Equatable {
        case bool
        case int(allowed: [Int])
        case string(allowed: [String])
        case layout
        case menuLayout
    }

    struct Key: Equatable {
        let name: String
        let kind: Kind
    }

    static let resumeThresholds = [0, 10, 30, 60, 120, 300, 600]
    static let languages = ["", "en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh",
                            "ru", "ar", "hi", "nl", "pl", "sv", "da", "no", "fi"]
    static let shuffleModes = ["randomEpisode", "randomShowNextEpisode"]
    static let viewModes = ["normal", "zoom", "stretch"]

    /// Every shared key and its kind.
    static let keys: [Key] = [
        Key(name: "autoPlayNextEpisode", kind: .bool),
        Key(name: "autoSkipIntro", kind: .bool),
        Key(name: "autoSkipCredits", kind: .bool),
        Key(name: "resumeThresholdSeconds", kind: .int(allowed: resumeThresholds)),
        Key(name: "forceDirectPlay", kind: .bool),
        Key(name: "subtitlesEnabled", kind: .bool),
        Key(name: "preferredAudioLanguage", kind: .string(allowed: languages)),
        Key(name: "preferredSubtitleLanguage", kind: .string(allowed: languages)),
        Key(name: "tvShuffleMode", kind: .string(allowed: shuffleModes)),
        Key(name: "defaultViewMode", kind: .string(allowed: viewModes)),
        Key(name: "showQualityBadges", kind: .bool),
        Key(name: "showReviewRatings", kind: .bool),
        Key(name: "useEpisodeRatings", kind: .bool),
        Key(name: "use24HourTime", kind: .bool),
        Key(name: homeRowsKey, kind: .layout),
        Key(name: sideMenuKey, kind: .menuLayout),
    ]

    static func key(_ name: String) -> Key? {
        keys.first { $0.name == name }
    }

    // MARK: Codec

    /// A remote entry as read from CustomPrefs.
    enum Remote: Equatable {
        case missing
        /// Not JSON, or no usable `t`.
        case unreadable
        /// Readable `t`, but a value this app does not accept.
        case invalid(t: Int64)
        case valid(Stamped)
    }

    static func decode(_ raw: String?, kind: Kind) -> Remote {
        guard let raw else { return .missing }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let tNumber = object["t"] as? NSNumber, !isBool(tNumber) else { return .unreadable }
        let t = tNumber.int64Value
        guard let value = value(from: object["v"], kind: kind) else { return .invalid(t: t) }
        return .valid(Stamped(value: value, t: t))
    }

    static func encode(_ stamped: Stamped) -> String {
        json(["v": jsonValue(stamped.value), "t": NSNumber(value: stamped.t)])
    }

    /// A canonical string for a value, for spotting local changes.
    static func encodeValue(_ value: Value) -> String {
        json(["v": jsonValue(value)])
    }

    static func decodeValue(_ encoded: String, kind: Kind) -> Value? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(encoded.utf8))) as? [String: Any] else { return nil }
        return value(from: object["v"], kind: kind)
    }

    static func isValid(_ value: Value, kind: Kind) -> Bool {
        switch (value, kind) {
        case (.bool, .bool), (.layout, .layout), (.menuLayout, .menuLayout): return true
        case (.int(let int), .int(let allowed)): return allowed.contains(int)
        case (.string(let string), .string(let allowed)): return allowed.contains(string)
        default: return false
        }
    }

    private static func value(from any: Any?, kind: Kind) -> Value? {
        let parsed: Value?
        switch kind {
        case .bool:
            parsed = (any as? NSNumber).flatMap { isBool($0) ? .bool($0.boolValue) : nil }
        case .int:
            guard let number = any as? NSNumber, !isBool(number),
                  number.doubleValue.rounded() == number.doubleValue else { return nil }
            parsed = .int(number.intValue)
        case .string:
            parsed = (any as? String).map(Value.string)
        case .layout:
            guard let array = any as? [Any] else { return nil }
            var entries: [LayoutEntry] = []
            for element in array {
                guard let object = element as? [String: Any], let id = object["id"] as? String,
                      let on = object["on"] as? NSNumber, isBool(on) else { return nil }
                entries.append(LayoutEntry(id: id, on: on.boolValue))
            }
            parsed = .layout(entries)
        case .menuLayout:
            guard let array = any as? [Any] else { return nil }
            var entries: [MenuEntry] = []
            for element in array {
                guard let object = element as? [String: Any], let id = object["id"] as? String else { return nil }
                var menu: Bool? // swiftlint:disable:this discouraged_optional_boolean
                if let flag = object["menu"] {
                    guard let number = flag as? NSNumber, isBool(number) else { return nil }
                    menu = number.boolValue
                }
                entries.append(MenuEntry(id: id, menu: menu))
            }
            parsed = .menuLayout(entries)
        }
        guard let parsed, isValid(parsed, kind: kind) else { return nil }
        return parsed
    }

    private static func jsonValue(_ value: Value) -> Any {
        switch value {
        case .bool(let bool): return bool
        case .int(let int): return int
        case .string(let string): return string
        case .layout(let entries): return entries.map { ["id": $0.id, "on": $0.on] as [String: Any] }
        case .menuLayout(let entries):
            return entries.map { entry -> [String: Any] in
                var object: [String: Any] = ["id": entry.id]
                if let menu = entry.menu { object["menu"] = menu }
                return object
            }
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// JSON `true` and `1` both arrive as NSNumber; only a CFBoolean is a bool.
    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
    }

    // MARK: Merge

    enum Decision: Equatable {
        /// The remote value is newer and valid here: apply it, stamp = its `t`.
        case apply(Stamped)
        /// The local value is newer (or the server has none): write it with this `t`.
        case write(t: Int64)
        case none
    }

    /// Reconcile's rule for one key. `localStamp` is nil when the setting has
    /// never changed here and was never seeded.
    static func decide(kind: Kind, localValue: Value?, localStamp: Int64?, remote: Remote) -> Decision {
        let canWrite = localStamp != nil && localValue.map { isValid($0, kind: kind) } == true
        switch remote {
        case .unreadable:
            return .none
        case .missing:
            guard canWrite, let localStamp else { return .none }
            return .write(t: localStamp)
        case .invalid(let t):
            // Never overwritten just because the value is unknown here; only a
            // genuinely newer local change replaces it.
            guard canWrite, let localStamp, localStamp > t else { return .none }
            return .write(t: localStamp)
        case .valid(let stamped):
            guard let localStamp else { return .apply(stamped) }
            if stamped.t > localStamp { return .apply(stamped) }
            if localStamp > stamped.t, canWrite { return .write(t: localStamp) }
            return .none
        }
    }

    // MARK: DisplayPreferences

    /// The string-valued CustomPrefs of a DisplayPreferences body.
    static func customPrefs(in data: Data?) -> [String: String] {
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let prefs = object?["CustomPrefs"] as? [String: Any] ?? [:]
        return prefs.compactMapValues { $0 as? String }
    }

    /// The body to POST: the stored entry with only `writes` (and the schema)
    /// replaced. Every other CustomPrefs key and top-level field survives.
    static func displayPreferencesBody(stored: Data?, writes: [String: String]) -> Data {
        var object = stored.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if object["Client"] == nil { object["Client"] = preferencesClient }
        if object["Id"] == nil { object["Id"] = preferencesId }
        var prefs = object["CustomPrefs"] as? [String: Any] ?? [:]
        for (key, value) in writes { prefs[key] = value }
        prefs[schemaKey] = schemaVersion
        object["CustomPrefs"] = prefs
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    // MARK: Layouts

    /// Applying a remote layout to this device's rows (all in shared ids):
    /// rows the layout names take its order and `on`; a row it doesn't name
    /// stays right after the row it follows here; ids this device lacks are
    /// skipped.
    static func applyLayout(local: [LayoutEntry], remote: [LayoutEntry]) -> [LayoutEntry] {
        applyOrder(local: local, remote: remote, id: \.id)
    }

    /// `applyLayout`'s rule for any entry type with an id.
    static func applyOrder<Entry>(local: [Entry], remote: [Entry], id: (Entry) -> String) -> [Entry] {
        let localIds = Set(local.map(id))
        var result: [Entry] = []
        var placed: Set<String> = []
        for entry in remote where localIds.contains(id(entry)) && placed.insert(id(entry)).inserted {
            result.append(entry)
        }
        for (index, row) in local.enumerated() where !placed.contains(id(row)) {
            let at = index == 0 ? 0 : (result.firstIndex { id($0) == id(local[index - 1]) }.map { $0 + 1 } ?? result.count)
            result.insert(row, at: at)
            placed.insert(id(row))
        }
        return result
    }

    /// The layout this device writes: its own rows in its order, with every
    /// remote entry it doesn't have put back after the same predecessor it had
    /// remotely, so one device never drops another's rows (or unknown ids).
    static func writeLayout(local: [LayoutEntry], remote: [LayoutEntry]?) -> [LayoutEntry] {
        writeOrder(local: local, remote: remote, id: \.id)
    }

    /// `writeLayout`'s rule for any entry type with an id. `carry` picks the
    /// remote entries to put back (all of them by default).
    static func writeOrder<Entry>(local: [Entry], remote: [Entry]?, id: (Entry) -> String,
                                  carry: (Entry) -> Bool = { _ in true }) -> [Entry] {
        var result = local
        var ids = Set(local.map(id))
        guard let remote else { return result }
        for (index, entry) in remote.enumerated() where !ids.contains(id(entry)) && carry(entry) {
            // Straight after the nearest remote entry before it that is here
            // (always the one right before it, unless `carry` skipped it).
            var anchor: Int?
            for previous in remote[..<index].reversed() {
                anchor = result.firstIndex { id($0) == id(previous) }
                if anchor != nil { break }
            }
            result.insert(entry, at: anchor.map { $0 + 1 } ?? 0)
            ids.insert(id(entry))
        }
        return result
    }

    /// Whether going from `old` to `new` is a user's edit (a row moved or was
    /// switched on or off), rather than rows coming or going on their own
    /// (a new library, a list subscribed elsewhere).
    static func isLayoutEdit(from old: [LayoutEntry], to new: [LayoutEntry]) -> Bool {
        let common = Set(old.map(\.id)).intersection(new.map(\.id))
        return old.filter { common.contains($0.id) } != new.filter { common.contains($0.id) }
    }

    /// Shared ids ↔ each Apple platform's local row ids (spec mapping table).
    enum RowIds {
        static func shared(tvOS id: String) -> String {
            switch id {
            case "channels": return "fintv"
            default:
                if id.hasPrefix("library_") { return "library:" + id.dropFirst("library_".count) }
                if id.hasPrefix("list_") { return "list:" + id.dropFirst("list_".count) }
                return id
            }
        }

        static func tvOS(shared id: String) -> String {
            switch id {
            case "fintv": return "channels"
            default:
                if id.hasPrefix("library:") { return "library_" + id.dropFirst("library:".count) }
                if id.hasPrefix("list:") { return "list_" + id.dropFirst("list:".count) }
                return id
            }
        }

        /// iPhone/iPad/Mac: built-ins by raw value, a library by its bare id.
        static func shared(mobile id: String) -> String {
            switch id {
            case "continue_watching": return "continueWatching"
            case "channels": return "fintv"
            case "requests": return "requests"
            default:
                if id.hasPrefix("list_") { return "list:" + id.dropFirst("list_".count) }
                return "library:" + id
            }
        }

        /// Nil for rows these devices don't have (the hero).
        static func mobile(shared id: String) -> String? {
            switch id {
            case "continueWatching": return "continue_watching"
            case "fintv": return "channels"
            case "requests": return "requests"
            default:
                if id.hasPrefix("library:") { return String(id.dropFirst("library:".count)) }
                if id.hasPrefix("list:") { return "list_" + id.dropFirst("list:".count) }
                return nil
            }
        }
    }
}
