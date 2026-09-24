import Foundation

/// How a channel's programmes are dealt out into a strip of fixed-width cards.
///
/// A row shows three cards starting at an offset, and paging moves the offset
/// by three. Offsets rather than fixed pages so a jump can land the programme
/// airing at the chosen instant as the FIRST card; with fixed pages it could
/// fall anywhere in its triple. Pure so the arithmetic can be tested without
/// a view. Each row keeps its own offset: a shared position is what made the
/// previous grid's in-progress blocks unreachable.
enum GuidePaging {
    static let slotsPerPage = 3

    /// An offset that exists for this many programmes. The library moves
    /// underneath the guide, so a remembered offset can outlive its rows.
    static func clamp(offset: Int, count: Int) -> Int {
        min(max(0, offset), max(0, count - 1))
    }

    static func visible<T>(_ items: [T], offset: Int) -> ArraySlice<T> {
        guard !items.isEmpty else { return [] }
        let start = clamp(offset: offset, count: items.count)
        return items[start..<min(start + slotsPerPage, items.count)]
    }

    static func hasMore(_ count: Int, offset: Int) -> Bool {
        clamp(offset: offset, count: count) + slotsPerPage < count
    }

    static func next(offset: Int, count: Int) -> Int {
        clamp(offset: offset + slotsPerPage, count: count)
    }

    static func previous(offset: Int, count: Int) -> Int {
        clamp(offset: offset - slotsPerPage, count: count)
    }
}
