import Foundation

/// The season picker (mockup D). Every season not already on the server or
/// asked for starts ticked; seasons on the server are listed but can't be
/// picked; season 0 (specials) never appears.
struct SeerrSeasonPlan: Equatable {
    enum State: Equatable {
        /// Aired, not on the server, nobody's asked: ticked by default.
        case requestable
        /// Pickable, but not ticked by default.
        case notAired
        /// Someone already asked (pending or on its way).
        case requested
        /// Some episodes are on the server.
        case partiallyAvailable
        case onServer

        var isPickable: Bool { self == .requestable || self == .notAired }
    }

    struct Season: Equatable, Identifiable {
        let number: Int
        let episodeCount: Int?
        let state: State
        var id: Int { number }
    }

    /// One line of the sheet: a season, or a run of seasons on the server
    /// ("Seasons 1–9 · On server").
    struct Row: Equatable, Identifiable {
        let id: String
        let title: String
        let detail: String
        let seasons: [Int]
        let isPickable: Bool
    }

    let seasons: [Season]
    private(set) var selected: Set<Int>
    /// Off on the server → a show is requested whole: every missing season.
    let partialRequestsEnabled: Bool

    init(details: SeerrTitleDetails, now: Date = Date(), partialRequestsEnabled: Bool = true) {
        let statuses = Dictionary(
            (details.mediaInfo?.seasons ?? []).map { ($0.seasonNumber, $0.status) },
            uniquingKeysWith: { first, _ in first }
        )
        let activeRequests = (details.mediaInfo?.requests ?? []).filter {
            $0.requestStatus != .declined && $0.requestStatus != .failed
        }
        let requested = Set(activeRequests.flatMap { $0.seasons ?? [] }.map(\.seasonNumber))

        seasons = details.seasons
            .filter { $0.seasonNumber > 0 }
            .sorted { $0.seasonNumber < $1.seasonNumber }
            .map { season in
                let state: State
                switch statuses[season.seasonNumber].flatMap({ $0 }).flatMap(SeerrMediaStatus.init(rawValue:)) {
                case .available: state = .onServer
                case .partiallyAvailable: state = .partiallyAvailable
                case .pending, .processing: state = .requested
                default:
                    if requested.contains(season.seasonNumber) {
                        state = .requested
                    } else if let aired = SeerrDates.parse(season.airDate), aired <= now {
                        state = .requestable
                    } else {
                        state = .notAired
                    }
                }
                return Season(number: season.seasonNumber, episodeCount: season.episodeCount, state: state)
            }
        self.partialRequestsEnabled = partialRequestsEnabled
        let missing = seasons.filter { $0.state == .requestable }.map(\.number)
        selected = Set(missing)
    }

    /// Aired seasons nobody has asked for and the server doesn't have.
    var missing: [Int] { seasons.filter { $0.state == .requestable }.map(\.number) }

    var hasMissingSeasons: Bool { !missing.isEmpty }

    var allMissingSelected: Bool {
        !missing.isEmpty && Set(missing).isSubset(of: selected)
    }

    /// What `POST /request` gets: sorted, never 0.
    var requestSeasons: [Int] { selected.filter { $0 > 0 }.sorted() }

    var buttonTitle: String {
        let count = requestSeasons.count
        return count == 1 ? "Request 1 season" : "Request \(count) seasons"
    }

    var rows: [Row] {
        var rows: [Row] = []
        var run: [Season] = []
        func flushRun() {
            guard let first = run.first, let last = run.last else { return }
            let title = run.count == 1 ? "Season \(first.number)" : "Seasons \(first.number)–\(last.number)"
            rows.append(Row(id: "server-\(first.number)", title: title, detail: "On server",
                            seasons: run.map(\.number), isPickable: false))
            run = []
        }
        for season in seasons {
            if season.state == .onServer {
                run.append(season)
                continue
            }
            flushRun()
            rows.append(Row(
                id: "season-\(season.number)",
                title: "Season \(season.number)",
                detail: Self.detail(for: season),
                seasons: [season.number],
                isPickable: partialRequestsEnabled && season.state.isPickable
            ))
        }
        flushRun()
        return rows
    }

    mutating func toggle(_ number: Int) {
        guard let season = seasons.first(where: { $0.number == number }), season.state.isPickable else { return }
        guard partialRequestsEnabled else {
            selected = Set(missing)
            return
        }
        if selected.contains(number) {
            selected.remove(number)
        } else {
            selected.insert(number)
        }
    }

    mutating func setAllMissing(_ on: Bool) {
        selected = on ? selected.union(missing) : []
    }

    private static func detail(for season: Season) -> String {
        switch season.state {
        case .requestable:
            guard let count = season.episodeCount, count > 0 else { return "" }
            return count == 1 ? "1 episode" : "\(count) episodes"
        case .notAired: return "Not aired"
        case .requested: return "Requested"
        case .partiallyAvailable: return "Partly on server"
        case .onServer: return "On server"
        }
    }
}

extension SeerrSeasonPlan: Identifiable {
    /// Stable for one show's sheet: the seasons, not the ticks.
    var id: String { seasons.map { "\($0.number)" }.joined(separator: ",") }
}
