import Foundation

/// A future programme the viewer asked about.
///
/// Shared because both guides present one: tvOS in a full-screen cover, iPad in
/// a sheet.
struct GuideSelection: Identifiable, Equatable {
    let row: GuideRow
    let entry: GuideEntry
    var id: String { "\(row.id)-\(entry.id)" }
}
