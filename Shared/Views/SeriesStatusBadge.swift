import SwiftUI

/// Whether a show is still being made, as a tag on the info row of the show's
/// detail screen and those of its seasons and episodes. Jellyfin only knows
/// Continuing / Ended (a canceled show reads Ended) plus Unreleased for one
/// that hasn't aired.
enum SeriesStatus: Equatable {
    case continuing
    case ended
    case upcoming

    /// A series reads its own status; a season or episode reads its show's
    /// (`seriesStatus`, from the series item the screen loads). Nil for a
    /// movie or anything else, and for a status Jellyfin doesn't have.
    init?(item: BaseItemDto, seriesStatus: String? = nil) {
        let raw: String?
        switch item.type {
        case .series: raw = item.status
        case .season, .episode: raw = seriesStatus
        default: return nil
        }
        switch raw?.lowercased() {
        case "continuing": self = .continuing
        case "ended": self = .ended
        case "unreleased": self = .upcoming
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .continuing: return "Continuing"
        case .ended: return "Ended"
        case .upcoming: return "Upcoming"
        }
    }

    var color: Color {
        switch self {
        case .continuing: return Color(red: 63 / 255, green: 191 / 255, blue: 127 / 255)
        case .ended: return Color(red: 184 / 255, green: 182 / 255, blue: 196 / 255)
        case .upcoming: return Color(red: 92 / 255, green: 173 / 255, blue: 230 / 255)
        }
    }
}

/// The status tag: the word in the status colour on a faint tint of it, a
/// rounded rectangle with the same 1pt white outline as the quality and
/// language badges beside it (#760, #833). Sized by the caller so the tvOS
/// row can render larger than the iOS one; the corner follows the size
/// (4pt on iOS at 12, 6pt on tvOS at 18) like those badges.
struct SeriesStatusBadge: View {
    let status: SeriesStatus
    var fontSize: CGFloat = 12

    private var cornerRadius: CGFloat { fontSize / 3 }

    var body: some View {
        Text(status.label)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(status.color)
            .padding(.horizontal, fontSize * 0.75)
            .padding(.vertical, fontSize * 0.3)
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(status.color.opacity(0.14)))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
            )
            .accessibilityLabel("Status: \(status.label)")
    }
}
