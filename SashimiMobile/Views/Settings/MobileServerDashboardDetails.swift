import SwiftUI

// The Server dashboard's secondary screens and pieces on iPhone and iPad.

extension PlayMode {
    var mobileTint: Color {
        switch self {
        case .directPlay: return MobileColors.success
        case .convertingAudio: return MobileColors.link
        case .convertingVideo: return MobileColors.accentSecondary
        }
    }
}

extension DashboardTone {
    var mobileColor: Color {
        switch self {
        case .ok, .added: return MobileColors.success
        case .warning: return MobileColors.accentSecondary
        case .failure: return MobileColors.error
        case .playback: return MobileColors.accent
        case .signIn: return MobileColors.link
        case .neutral: return MobileColors.textTertiary
        }
    }
}

struct MobilePlayModeBadge: View {
    let mode: PlayMode
    var short = false

    var body: some View {
        Text(short ? mode.shortTitle : mode.title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(mode.mobileTint)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(mode.mobileTint.opacity(0.18), in: Capsule())
    }
}

struct MobileDotRow: View {
    let tone: DashboardTone
    let text: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tone.mobileColor)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(tone == .failure ? MobileColors.error : .primary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Recent activity, newest first. Shares the dashboard's model so it keeps
/// refreshing while open.
struct MobileServerActivityView: View {
    @ObservedObject var model: ServerDashboardViewModel

    var body: some View {
        List {
            if model.activity.isEmpty {
                Text("Nothing yet").foregroundStyle(.secondary)
            }
            ForEach(model.activity) { row in
                MobileDotRow(tone: row.tone, text: row.text, value: row.when)
            }
        }
        .navigationTitle("Activity")
        .refreshable { await model.refreshAll() }
        .onAppear { model.attach() }
        .onDisappear { model.detach() }
    }
}

struct MobileServerHealthView: View {
    @ObservedObject var model: ServerDashboardViewModel

    var body: some View {
        List {
            if model.health.isEmpty {
                Text("Nothing to report").foregroundStyle(.secondary)
            }
            ForEach(model.health) { row in
                MobileDotRow(tone: row.tone, text: row.title, value: row.value)
            }
        }
        .navigationTitle("Health")
        .refreshable { await model.refreshAll() }
        .onAppear { model.attach() }
        .onDisappear { model.detach() }
    }
}

/// Everything about one stream.
struct MobileStreamDetailsView: View {
    let session: DashboardSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.nowPlayingItem?.displayTitle ?? "")
                        .font(.headline)
                    MobilePlayModeBadge(mode: ServerDashboardLogic.playMode(session.transcodingInfo))
                    Text(ServerDashboardLogic.detailLine(for: session))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(ServerDashboardLogic.detailRows(for: session)) { row in
                    LabeledContent(row.label, value: row.value)
                }
            }
            if !session.supportsRemoteControl {
                Section {
                    Text("\(session.client ?? "This app") doesn't take remote commands, so it can't be stopped or messaged from here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Stream")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
