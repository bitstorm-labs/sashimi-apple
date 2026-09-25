import Foundation

/// One slide in the Home hero rotation.
///
/// A slide is usually the latest item from a library. It can also be what a
/// channel is airing right now, which looks the same — the programme is still
/// the headline, because that is what a viewer is choosing between — with the
/// channel stamped above it.
struct HeroSlide: Identifiable, Equatable {
    let item: BaseItemDto
    /// Present only when this slide came from a channel.
    let channel: Stamp?

    struct Stamp: Equatable {
        let id: String
        let name: String
        let endsAt: Date?
        var number: Int?
        var logo: String?

        /// Matches the wording the FinTV cards use, so the same programme does
        /// not describe its remaining time two different ways on one screen.
        func timeRemaining(at date: Date) -> String? {
            guard let endsAt else { return nil }
            let seconds = max(0, Int(endsAt.timeIntervalSince(date)))
            if seconds >= 3600 {
                return "\(seconds / 3600)h \((seconds % 3600) / 60)m left"
            }
            if seconds >= 60 { return "\(seconds / 60)m left" }
            return "\(seconds)s left"
        }
    }

    /// Two channels can be airing the same item, and a channel can be airing
    /// something a library row also offers, so the item id alone is not unique
    /// across the rotation.
    var id: String { channel.map { "channel:\($0.id)" } ?? "item:\(item.id)" }

    static func library(_ item: BaseItemDto) -> HeroSlide {
        HeroSlide(item: item, channel: nil)
    }
}

/// How channel slides sit among the library ones.
enum HeroRotation {
    /// Spread `inserts` evenly through `base` rather than grouping them.
    ///
    /// Grouped, six channels at six seconds each is a half-minute of FinTV
    /// before anything else appears, and the last channel in the block is
    /// nearly a minute from being seen.
    static func interleave(base: [HeroSlide], inserts: [HeroSlide]) -> [HeroSlide] {
        guard !inserts.isEmpty else { return base }
        guard !base.isEmpty else { return inserts }

        // One insert every `step` base slides, rounded down so the inserts are
        // used up at or before the end rather than bunching at the front.
        let step = max(1, base.count / inserts.count)
        var out: [HeroSlide] = []
        var remaining = inserts

        for (index, slide) in base.enumerated() {
            out.append(slide)
            if !remaining.isEmpty && (index + 1) % step == 0 {
                out.append(remaining.removeFirst())
            }
        }
        // Whatever did not fit — base shorter than the insert count, or the
        // final partial step — still belongs in the rotation.
        out.append(contentsOf: remaining)
        return out
    }
}
