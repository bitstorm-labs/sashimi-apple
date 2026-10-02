import SwiftUI

/// The 1 / 3 / 5 / Off choices for "Keep next episodes downloaded", as an
/// inline picker for use inside a Menu. Shows a checkmark on the current one.
struct KeepNextEpisodesPicker: View {
    let selection: Int
    let onSelect: (Int) -> Void

    var body: some View {
        Picker("Keep Next Episodes Downloaded", selection: Binding(get: { selection }, set: onSelect)) {
            ForEach(KeepNextEpisodesOption.counts, id: \.self) { count in
                Text(KeepNextEpisodesOption.countTitle(count)).tag(count)
            }
            Text("Off").tag(0)
        }
        .pickerStyle(.inline)
    }
}

/// "Keeping next 3" on a show's header in Downloads, a menu to change the
/// count or turn it off. Hidden while the show has the setting off.
struct KeepNextEpisodesHeaderControl: View {
    let serverID: String?
    let seriesId: String

    @ObservedObject private var store = KeepNextEpisodesStore.shared

    var body: some View {
        let count = store.count(serverID: serverID, seriesId: seriesId)
        if count > 0, let serverID {
            Menu {
                KeepNextEpisodesPicker(selection: count) { newCount in
                    store.set(count: newCount, serverID: serverID, seriesId: seriesId)
                    KeepNextEpisodesService.shared.scheduleSync(after: .zero)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(KeepNextEpisodesOption.keepingTitle(count))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MobileColors.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Keep next episodes downloaded: \(count)")
        }
    }
}
