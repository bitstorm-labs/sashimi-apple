import Foundation

// The slices of Jellyfin's admin endpoints the Server dashboard reads, checked
// against a live 12.2.0 server. Fields the dashboard must never show (paths,
// DeviceIds, tokens) are deliberately not decoded. RemoteEndPoint is read only
// to decide Local or Remote and is dropped at decode time: the address itself
// never reaches a view.

// MARK: - Sessions (`/Sessions`)

struct DashboardSession: Decodable, Identifiable, Equatable {
    let id: String
    let userName: String?
    let client: String?
    let applicationVersion: String?
    let deviceName: String?
    let supportsRemoteControl: Bool
    let nowPlayingItem: DashboardNowPlaying?
    let playState: DashboardPlayState?
    let transcodingInfo: DashboardTranscodingInfo?
    /// Where the viewer is, from `RemoteEndPoint`; nil when the server didn't say.
    let network: DashboardNetwork?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case userName = "UserName"
        case client = "Client"
        case applicationVersion = "ApplicationVersion"
        case deviceName = "DeviceName"
        case supportsRemoteControl = "SupportsRemoteControl"
        case nowPlayingItem = "NowPlayingItem"
        case playState = "PlayState"
        case transcodingInfo = "TranscodingInfo"
        case remoteEndPoint = "RemoteEndPoint"
    }

    init(
        id: String,
        userName: String?,
        client: String?,
        applicationVersion: String?,
        deviceName: String?,
        supportsRemoteControl: Bool,
        nowPlayingItem: DashboardNowPlaying?,
        playState: DashboardPlayState?,
        transcodingInfo: DashboardTranscodingInfo?,
        network: DashboardNetwork? = nil
    ) {
        self.id = id
        self.userName = userName
        self.client = client
        self.applicationVersion = applicationVersion
        self.deviceName = deviceName
        self.supportsRemoteControl = supportsRemoteControl
        self.nowPlayingItem = nowPlayingItem
        self.playState = playState
        self.transcodingInfo = transcodingInfo
        self.network = network
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userName = try container.decodeIfPresent(String.self, forKey: .userName)
        client = try container.decodeIfPresent(String.self, forKey: .client)
        applicationVersion = try container.decodeIfPresent(String.self, forKey: .applicationVersion)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        supportsRemoteControl = try container.decodeIfPresent(Bool.self, forKey: .supportsRemoteControl) ?? false
        nowPlayingItem = try container.decodeIfPresent(DashboardNowPlaying.self, forKey: .nowPlayingItem)
        playState = try container.decodeIfPresent(DashboardPlayState.self, forKey: .playState)
        transcodingInfo = try container.decodeIfPresent(DashboardTranscodingInfo.self, forKey: .transcodingInfo)
        network = DashboardNetwork(remoteEndPoint: try container.decodeIfPresent(String.self, forKey: .remoteEndPoint))
    }
}

/// Local or Remote: all the card says about where a viewer is.
enum DashboardNetwork: Equatable {
    case local, remote

    /// Nil for a missing or blank address.
    init?(remoteEndPoint: String?) {
        guard let remoteEndPoint, !remoteEndPoint.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        self = ServerDashboardLogic.isLocalAddress(remoteEndPoint) ? .local : .remote
    }
}

struct DashboardNowPlaying: Decodable, Equatable {
    let id: String
    let name: String?
    let type: String?
    let seriesName: String?
    let seriesId: String?
    let parentIndexNumber: Int?
    let indexNumber: Int?
    let runTimeTicks: Int64?
    let container: String?
    let mediaStreams: [DashboardMediaStream]
    let productionYear: Int?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case seriesName = "SeriesName"
        case seriesId = "SeriesId"
        case parentIndexNumber = "ParentIndexNumber"
        case indexNumber = "IndexNumber"
        case runTimeTicks = "RunTimeTicks"
        case container = "Container"
        case mediaStreams = "MediaStreams"
        case productionYear = "ProductionYear"
    }

    init(
        id: String,
        name: String?,
        type: String?,
        seriesName: String?,
        seriesId: String?,
        parentIndexNumber: Int?,
        indexNumber: Int?,
        runTimeTicks: Int64?,
        container: String?,
        mediaStreams: [DashboardMediaStream],
        productionYear: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.seriesName = seriesName
        self.seriesId = seriesId
        self.parentIndexNumber = parentIndexNumber
        self.indexNumber = indexNumber
        self.runTimeTicks = runTimeTicks
        self.container = container
        self.mediaStreams = mediaStreams
        self.productionYear = productionYear
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        seriesName = try container.decodeIfPresent(String.self, forKey: .seriesName)
        seriesId = try container.decodeIfPresent(String.self, forKey: .seriesId)
        parentIndexNumber = try container.decodeIfPresent(Int.self, forKey: .parentIndexNumber)
        indexNumber = try container.decodeIfPresent(Int.self, forKey: .indexNumber)
        runTimeTicks = try container.decodeIfPresent(Int64.self, forKey: .runTimeTicks)
        self.container = try container.decodeIfPresent(String.self, forKey: .container)
        mediaStreams = try container.decodeIfPresent([DashboardMediaStream].self, forKey: .mediaStreams) ?? []
        productionYear = try container.decodeIfPresent(Int.self, forKey: .productionYear)
    }

    /// "The 100 · S6:E10 · Matryoshka" for an episode, the name otherwise.
    var displayTitle: String {
        let title = name ?? ""
        guard let seriesName, !seriesName.isEmpty else { return title }
        var parts = [seriesName]
        if let season = parentIndexNumber, let episode = indexNumber {
            parts.append("S\(season):E\(episode)")
        }
        if !title.isEmpty { parts.append(title) }
        return parts.joined(separator: " · ")
    }

    /// The poster to show: an episode's series poster, else its own.
    var posterItemIds: [String] {
        [seriesId, id].compactMap { $0 }
    }
}

struct DashboardMediaStream: Decodable, Equatable {
    let type: String?
    let codec: String?
    let width: Int?
    let height: Int?
    let videoRangeType: String?
    let bitRate: Int?
    let index: Int?
    let isDefault: Bool
    let displayTitle: String?
    let channels: Int?
    let realFrameRate: Double?
    let averageFrameRate: Double?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case codec = "Codec"
        case width = "Width"
        case height = "Height"
        case videoRangeType = "VideoRangeType"
        case bitRate = "BitRate"
        case index = "Index"
        case isDefault = "IsDefault"
        case displayTitle = "DisplayTitle"
        case channels = "Channels"
        case realFrameRate = "RealFrameRate"
        case averageFrameRate = "AverageFrameRate"
    }

    init(
        type: String?,
        codec: String?,
        width: Int?,
        height: Int?,
        videoRangeType: String?,
        bitRate: Int?,
        index: Int?,
        isDefault: Bool,
        displayTitle: String?,
        channels: Int? = nil,
        realFrameRate: Double? = nil,
        averageFrameRate: Double? = nil
    ) {
        self.type = type
        self.codec = codec
        self.width = width
        self.height = height
        self.videoRangeType = videoRangeType
        self.bitRate = bitRate
        self.index = index
        self.isDefault = isDefault
        self.displayTitle = displayTitle
        self.channels = channels
        self.realFrameRate = realFrameRate
        self.averageFrameRate = averageFrameRate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        codec = try container.decodeIfPresent(String.self, forKey: .codec)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        videoRangeType = try container.decodeIfPresent(String.self, forKey: .videoRangeType)
        bitRate = try container.decodeIfPresent(Int.self, forKey: .bitRate)
        index = try container.decodeIfPresent(Int.self, forKey: .index)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        displayTitle = try container.decodeIfPresent(String.self, forKey: .displayTitle)
        channels = try container.decodeIfPresent(Int.self, forKey: .channels)
        realFrameRate = try container.decodeIfPresent(Double.self, forKey: .realFrameRate)
        averageFrameRate = try container.decodeIfPresent(Double.self, forKey: .averageFrameRate)
    }
}

struct DashboardPlayState: Decodable, Equatable {
    let positionTicks: Int64?
    let isPaused: Bool
    /// False when the server sent no IsPaused: the card's dot goes grey, not green.
    let reportsPause: Bool
    /// "DirectPlay" | "DirectStream" | "Transcode"
    let playMethod: String?
    let audioStreamIndex: Int?

    enum CodingKeys: String, CodingKey {
        case positionTicks = "PositionTicks"
        case isPaused = "IsPaused"
        case playMethod = "PlayMethod"
        case audioStreamIndex = "AudioStreamIndex"
    }

    init(positionTicks: Int64?, isPaused: Bool, playMethod: String?, audioStreamIndex: Int?, reportsPause: Bool = true) {
        self.positionTicks = positionTicks
        self.isPaused = isPaused
        self.reportsPause = reportsPause
        self.playMethod = playMethod
        self.audioStreamIndex = audioStreamIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        positionTicks = try container.decodeIfPresent(Int64.self, forKey: .positionTicks)
        let paused = try container.decodeIfPresent(Bool.self, forKey: .isPaused)
        isPaused = paused == true
        reportsPause = paused != nil
        playMethod = try container.decodeIfPresent(String.self, forKey: .playMethod)
        audioStreamIndex = try container.decodeIfPresent(Int.self, forKey: .audioStreamIndex)
    }
}

struct DashboardTranscodingInfo: Decodable, Equatable {
    let audioCodec: String?
    let videoCodec: String?
    let container: String?
    /// False when absent: a session the server can't vouch for is not called direct.
    let isVideoDirect: Bool
    let isAudioDirect: Bool
    let bitrate: Int?
    let width: Int?
    let height: Int?
    let hardwareAccelerationType: String?
    let transcodeReasons: [String]
    let audioChannels: Int?
    /// Frames encoded per second; over the source's fps it is the speed ("1.8x").
    let framerate: Double?

    enum CodingKeys: String, CodingKey {
        case audioCodec = "AudioCodec"
        case videoCodec = "VideoCodec"
        case container = "Container"
        case isVideoDirect = "IsVideoDirect"
        case isAudioDirect = "IsAudioDirect"
        case bitrate = "Bitrate"
        case width = "Width"
        case height = "Height"
        case hardwareAccelerationType = "HardwareAccelerationType"
        case transcodeReasons = "TranscodeReasons"
        case audioChannels = "AudioChannels"
        case framerate = "Framerate"
    }

    init(
        audioCodec: String?,
        videoCodec: String?,
        container: String?,
        isVideoDirect: Bool,
        isAudioDirect: Bool,
        bitrate: Int?,
        width: Int?,
        height: Int?,
        hardwareAccelerationType: String?,
        transcodeReasons: [String],
        audioChannels: Int? = nil,
        framerate: Double? = nil
    ) {
        self.audioCodec = audioCodec
        self.videoCodec = videoCodec
        self.container = container
        self.isVideoDirect = isVideoDirect
        self.isAudioDirect = isAudioDirect
        self.bitrate = bitrate
        self.width = width
        self.height = height
        self.hardwareAccelerationType = hardwareAccelerationType
        self.transcodeReasons = transcodeReasons
        self.audioChannels = audioChannels
        self.framerate = framerate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        audioCodec = try container.decodeIfPresent(String.self, forKey: .audioCodec)
        videoCodec = try container.decodeIfPresent(String.self, forKey: .videoCodec)
        self.container = try container.decodeIfPresent(String.self, forKey: .container)
        isVideoDirect = try container.decodeIfPresent(Bool.self, forKey: .isVideoDirect) ?? false
        isAudioDirect = try container.decodeIfPresent(Bool.self, forKey: .isAudioDirect) ?? false
        bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        hardwareAccelerationType = try container.decodeIfPresent(String.self, forKey: .hardwareAccelerationType)
        // An array on current servers; older ones sent one comma-separated string.
        if let list = try? container.decodeIfPresent([String].self, forKey: .transcodeReasons) {
            transcodeReasons = list
        } else {
            let joined = try? container.decodeIfPresent(String.self, forKey: .transcodeReasons)
            transcodeReasons = (joined ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        audioChannels = try container.decodeIfPresent(Int.self, forKey: .audioChannels)
        framerate = try container.decodeIfPresent(Double.self, forKey: .framerate)
    }
}

// MARK: - Activity (`/System/ActivityLog/Entries`)

struct ActivityLogPage: Decodable {
    let items: [ActivityLogEntry]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

struct ActivityLogEntry: Decodable, Identifiable, Equatable {
    let id: Int
    let name: String
    let shortOverview: String?
    let type: String
    let date: Date
    let severity: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case shortOverview = "ShortOverview"
        case type = "Type"
        case date = "Date"
        case severity = "Severity"
    }

    init(id: Int, name: String, shortOverview: String?, type: String, date: Date, severity: String?) {
        self.id = id
        self.name = name
        self.shortOverview = shortOverview
        self.type = type
        self.date = date
        self.severity = severity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        shortOverview = try container.decodeIfPresent(String.self, forKey: .shortOverview)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        date = ServerDate.parse(try container.decodeIfPresent(String.self, forKey: .date)) ?? .distantPast
        severity = try container.decodeIfPresent(String.self, forKey: .severity)
    }
}

// MARK: - Scheduled tasks (`/ScheduledTasks`)

struct ScheduledTaskInfo: Decodable, Equatable {
    let name: String
    let key: String?
    let state: String?
    let lastExecutionResult: TaskResult?

    struct TaskResult: Decodable, Equatable {
        /// "Completed" | "Failed" | "Cancelled" | "Aborted"
        let status: String?
        let endTimeUtc: Date?

        enum CodingKeys: String, CodingKey {
            case status = "Status"
            case endTimeUtc = "EndTimeUtc"
        }

        init(status: String?, endTimeUtc: Date?) {
            self.status = status
            self.endTimeUtc = endTimeUtc
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            endTimeUtc = ServerDate.parse(try container.decodeIfPresent(String.self, forKey: .endTimeUtc))
        }
    }

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case key = "Key"
        case state = "State"
        case lastExecutionResult = "LastExecutionResult"
    }
}

// MARK: - System (`/System/Info`, `/System/Info/Storage`, `/System/Configuration/encoding`)

struct DashboardSystemInfo: Decodable, Equatable {
    let serverName: String?
    let version: String?

    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName"
        case version = "Version"
    }
}

struct SystemStorageInfo: Decodable, Equatable {
    let transcodingTempFolder: FolderStorage?
    let libraries: [LibraryStorage]

    struct FolderStorage: Decodable, Equatable {
        let freeSpace: Int64
        let usedSpace: Int64
        /// Identifies the drive, so libraries on one array count once. Never shown.
        let deviceId: String?

        enum CodingKeys: String, CodingKey {
            case freeSpace = "FreeSpace"
            case usedSpace = "UsedSpace"
            case deviceId = "DeviceId"
        }
    }

    struct LibraryStorage: Decodable, Equatable {
        let name: String?
        let folders: [FolderStorage]

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case folders = "Folders"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            folders = try container.decodeIfPresent([FolderStorage].self, forKey: .folders) ?? []
        }
    }

    enum CodingKeys: String, CodingKey {
        case transcodingTempFolder = "TranscodingTempFolder"
        case libraries = "Libraries"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transcodingTempFolder = try container.decodeIfPresent(FolderStorage.self, forKey: .transcodingTempFolder)
        libraries = try container.decodeIfPresent([LibraryStorage].self, forKey: .libraries) ?? []
    }
}

struct EncodingOptionsSummary: Decodable, Equatable {
    /// "none" (or empty) when hardware transcoding is off; "qsv", "vaapi", "nvenc", …
    let hardwareAccelerationType: String?

    enum CodingKeys: String, CodingKey {
        case hardwareAccelerationType = "HardwareAccelerationType"
    }
}

// MARK: - Dates

/// Jellyfin writes seven fractional digits ("2026-10-18T19:46:07.6650781Z");
/// the shared ISO parser reads them.
enum ServerDate {
    static func parse(_ string: String?) -> Date? {
        DateFormatting.parseDate(string)
    }
}
