import Foundation

/// A remote command Sashimi acts on. Everything else the server can send is
/// dropped at parse time.
enum RemoteControlCommand: Equatable, Sendable {
    /// Playstate `Stop`: close the player as if the viewer pressed Back.
    case stop
    /// GeneralCommand `DisplayMessage`: show a banner.
    case displayMessage(RemoteMessage)
}

/// The text of a `DisplayMessage` command.
struct RemoteMessage: Equatable, Sendable {
    let header: String?
    let text: String
    /// The sender's `TimeoutMs`, when it gave a usable one.
    let timeoutMs: Int?

    /// How long the banner stays when the sender gave no timeout.
    static let defaultDuration: TimeInterval = 8
    static let minimumDuration: TimeInterval = 2
    static let maximumDuration: TimeInterval = 60

    /// Seconds on screen: the sender's `TimeoutMs`, kept between a length
    /// someone can read and one that cannot strand a banner over a film.
    var displayDuration: TimeInterval {
        guard let timeoutMs, timeoutMs > 0 else { return Self.defaultDuration }
        return min(max(TimeInterval(timeoutMs) / 1000, Self.minimumDuration), Self.maximumDuration)
    }
}

/// One frame of Jellyfin's `/socket` protocol, reduced to what Sashimi needs.
///
/// Frames are `{"MessageType": …, "Data": …, "MessageId": …}`. Verified against
/// the live 12.2 server: `ForceKeepAlive` carries the timeout in seconds as
/// `Data`; `Playstate` carries `{"Command": "Stop"}`; `GeneralCommand` carries
/// `{"Name": "DisplayMessage", "Arguments": {"Header", "Text", "TimeoutMs"}}`
/// with every argument a STRING (the dashboard's numeric TimeoutMs arrives as
/// `"4000"`).
enum RemoteControlMessage: Equatable, Sendable {
    /// The server wants a `KeepAlive` at least this often (seconds).
    case forceKeepAlive(seconds: Int)
    /// The server's answer to our keep-alive.
    case keepAlive
    case command(RemoteControlCommand)
    /// Anything Sashimi does not act on.
    case ignored

    static let keepAliveFrame = #"{"MessageType":"KeepAlive"}"#

    static let defaultKeepAliveInterval: TimeInterval = 30
    static let minimumKeepAliveInterval: TimeInterval = 5

    /// Jellyfin's own clients ping at half the server's timeout.
    static func keepAliveInterval(forTimeout seconds: Int) -> TimeInterval {
        guard seconds > 0 else { return defaultKeepAliveInterval }
        return max(TimeInterval(seconds) / 2, minimumKeepAliveInterval)
    }

    static func parse(_ text: String) -> RemoteControlMessage {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = object["MessageType"] as? String else { return .ignored }
        let data = object["Data"]

        switch type {
        case "ForceKeepAlive":
            return .forceKeepAlive(seconds: integer(data) ?? 0)
        case "KeepAlive":
            return .keepAlive
        case "Playstate":
            guard let command = (data as? [String: Any])?["Command"] as? String,
                  command == "Stop" else { return .ignored }
            return .command(.stop)
        case "GeneralCommand":
            return parseGeneralCommand(data as? [String: Any])
        default:
            return .ignored
        }
    }

    private static func parseGeneralCommand(_ data: [String: Any]?) -> RemoteControlMessage {
        guard let data, data["Name"] as? String == "DisplayMessage",
              let arguments = data["Arguments"] as? [String: Any] else { return .ignored }
        let header = trimmed(arguments["Header"])
        let text = trimmed(arguments["Text"]) ?? ""
        guard header != nil || !text.isEmpty else { return .ignored }
        return .command(.displayMessage(RemoteMessage(
            header: header,
            text: text,
            timeoutMs: integer(arguments["TimeoutMs"])
        )))
    }

    /// A non-empty trimmed string, or nil.
    private static func trimmed(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else { return nil }
        return string
    }

    /// Jellyfin sends numbers both as JSON numbers and as strings.
    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}

/// Exponential backoff for reconnecting the socket: 1, 2, 4 … seconds, capped.
struct RemoteControlReconnectPolicy: Sendable {
    var initialDelay: TimeInterval = 1
    var maximumDelay: TimeInterval = 60

    func delay(forAttempt attempt: Int) -> TimeInterval {
        let exponent = Double(min(max(attempt, 0), 32))
        return min(initialDelay * pow(2, exponent), maximumDelay)
    }
}
