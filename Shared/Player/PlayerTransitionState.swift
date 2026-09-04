import Foundation

/// The server-backed navigation state for one player presentation.
///
/// This is deliberately shared by tvOS and iOS. A transition replaces the
/// AVPlayer through `PlayerViewModel`, so both presentation layers can render
/// the same current item and boundary state without owning playback policy.
struct PlayerTransitionState: Equatable {
    enum LookupStatus: Equatable {
        case idle
        case loading
        case available
        case unavailable
        case notApplicable
        case failed
    }

    enum EndCard: Equatable {
        case nextEpisode
        case finalEpisode
        case lookupFailed
    }

    var currentItem: BaseItemDto?
    var previousEpisode: BaseItemDto?
    var nextEpisode: BaseItemDto?
    var lookupStatus: LookupStatus = .idle
    var endCard: EndCard?

    var isEpisodeNavigationAvailable: Bool {
        currentItem?.type == .episode && lookupStatus != .notApplicable
    }

    var canPlayPrevious: Bool {
        isEpisodeNavigationAvailable && previousEpisode != nil
    }

    var canPlayNext: Bool {
        isEpisodeNavigationAvailable && nextEpisode != nil
    }

    static let empty = PlayerTransitionState(
        currentItem: nil,
        previousEpisode: nil,
        nextEpisode: nil,
        lookupStatus: .idle,
        endCard: nil
    )
}
