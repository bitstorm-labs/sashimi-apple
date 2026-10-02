import SwiftUI
import NukeUI

/// One of the plugin's logos by key (`/VirtualChannels/Logos/{key}`), for the
/// logo picker and the management screens, where the configured key matters
/// rather than whichever seasonal logo is in effect today. Without a key, or
/// when the image cannot be had, it shows initials so a list never carries
/// empty squares.
struct ChannelLogoKeyView: View {
    let key: String?
    /// What the initials are taken from: the channel's name, or the key's.
    let name: String
    let size: CGFloat

    @State private var url: URL?

    var body: some View {
        ZStack {
            if let url {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else if state.error != nil {
                        monogram
                    }
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .task(id: key) {
            guard let key else {
                url = nil
                return
            }
            url = await JellyfinClient.shared.channelLogoURL(key: key)
        }
    }

    private var monogram: some View {
        Text(Self.initials(for: name))
            .font(.system(size: size * 0.34, weight: .heavy))
            .foregroundStyle(Color.primary.opacity(0.85))
            .frame(width: size, height: size)
            .background(Circle().fill(Color.primary.opacity(0.12)))
    }

    /// "Cozy Autumn" or "cozy-autumn" → "CA".
    static func initials(for name: String) -> String {
        let words = name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    /// "cozy-autumn" → "Cozy Autumn", for the label under a picker tile.
    static func displayName(for key: String) -> String {
        key.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

extension ManagedChannel {
    /// "12 titles added", or what makes a scheduled channel different.
    var managementSummary: String {
        let count = addedItemCount
        let added = count == 1 ? "1 title added" : "\(count) titles added"
        guard isScheduled else { return added }
        let parts = dayparts.count == 1 ? "1 daypart" : "\(dayparts.count) dayparts"
        return "Scheduled · \(parts) · \(added)"
    }
}

extension ChannelMenuEntry {
    /// Under a scheduled channel's name: which dayparts already carry the title.
    var scheduledSummary: String {
        let added = dayparts.filter { $0.state == .added }.map(\.title)
        if !added.isEmpty { return "✓ " + added.joined(separator: ", ") }
        if dayparts.contains(where: { $0.state == .viaRule }) { return "Airs through a rule" }
        return "Scheduled · pick a daypart"
    }
}

extension ManagedItem {
    /// "Series · 2018".
    var detailLine: String {
        [type, productionYear.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }
}

extension ManagedDaypart {
    /// "18:00–24:00 · Seasonal", or "All day".
    var scheduleLine: String {
        [timeRangeLabel ?? "All day", isSeasonal ? "Seasonal" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// The rule summary ("Science Fiction, Library: Movies") as the read-only
    /// line on a channel. Rules stay in the dashboard in v1.
    var ruleSentence: String? {
        guard let ruleSummary, !ruleSummary.isEmpty else { return nil }
        return "Also airs: \(ruleSummary) — edit rules in the Jellyfin dashboard."
    }
}
