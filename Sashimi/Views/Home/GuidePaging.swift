import Foundation

/// How a channel's programmes are dealt out into pages of fixed-width cards.
///
/// Pure so the arithmetic can be tested without a view. The guide pages each
/// row independently: a shared offset is what made the previous grid's
/// in-progress blocks unreachable, because one row's scroll position carried
/// every other row's first card off the screen.
enum GuidePaging {
    static let slotsPerPage = 3

    static func pageCount(_ count: Int) -> Int {
        max(1, (count + slotsPerPage - 1) / slotsPerPage)
    }

    /// A page index that exists for this many programmes. The library moves
    /// underneath the guide every minute, so a remembered page can outlive the
    /// programmes it pointed at.
    static func clamp(page: Int, count: Int) -> Int {
        min(max(0, page), pageCount(count) - 1)
    }

    static func visible<T>(_ items: [T], page: Int) -> ArraySlice<T> {
        let page = clamp(page: page, count: items.count)
        let start = page * slotsPerPage
        guard start < items.count else { return [] }
        return items[start..<min(start + slotsPerPage, items.count)]
    }

    static func hasMore(_ count: Int, page: Int) -> Bool {
        clamp(page: page, count: count) < pageCount(count) - 1
    }
}
