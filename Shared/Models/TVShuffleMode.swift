import Foundation

/// How a TV library's Shuffle button picks what to play (roku#141 parity).
enum TVShuffleMode: String, CaseIterable, Identifiable {
    /// Any episode in the library, at random. The original behaviour.
    case randomEpisode
    /// A random series, then the episode its Play button would start.
    case randomShowNextEpisode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .randomEpisode: "Random Episode"
        case .randomShowNextEpisode: "Random Show, Next Episode"
        }
    }

    var detail: String {
        switch self {
        case .randomEpisode:
            "Plays any episode in the library at random."
        case .randomShowNextEpisode:
            "Picks a random show and plays its next episode. A finished show starts over."
        }
    }
}
