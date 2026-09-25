import SwiftUI

/// A chip in the guide's day bar. Its own focus state, because the plain
/// button style that stops tvOS drawing its default platter also stops it
/// showing which chip has focus — the bar had no focus indicator at all.
struct GuideChip: View {
    let label: String
    var systemImage: String?
    let selected: Bool
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(label)
            }
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(selected || focused ? Color.black : SashimiTheme.textPrimary)
            .padding(.horizontal, 22).padding(.vertical, 9)
            .background(Capsule().fill(
                focused ? Color.white : (selected ? SashimiTheme.accent : SashimiTheme.cardBackground)
            ))
            .scaleEffect(focused ? 1.08 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: focused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($focused)
    }
}

/// Every reminder set on this device. Select one to clear it.
struct RemindersListView: View {
    @ObservedObject private var reminders = StationReminders.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Text("Reminders")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(SashimiTheme.textPrimary)
                    Spacer()
                    if !reminders.reminders.isEmpty {
                        Button("Clear All") { reminders.clearAll() }
                    }
                }
                if reminders.reminders.isEmpty {
                    Text("No reminders. Long-press a programme in the guide to set one.")
                        .font(.system(size: 26))
                        .foregroundStyle(SashimiTheme.textSecondary)
                    Button("Done") { dismiss() }
                } else {
                    Text("Select a reminder to clear it.")
                        .font(.system(size: 22))
                        .foregroundStyle(SashimiTheme.textTertiary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(reminders.reminders.sorted { $0.startsAt < $1.startsAt }) { reminder in
                                Button {
                                    reminders.remove(reminder)
                                } label: {
                                    HStack(spacing: 20) {
                                        Image(systemName: "bell.slash")
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(reminder.title).font(.system(size: 30, weight: .semibold))
                                            Text("\(reminder.startsAt.formatted(.dateTime.weekday(.wide).hour().minute())) · \(reminder.channelName)")
                                                .font(.system(size: 22))
                                                .opacity(0.75)
                                        }
                                        Spacer()
                                    }
                                    .padding(.vertical, 8)
                                    .frame(width: 1200, alignment: .leading)
                                }
                            }
                        }
                        .padding(.vertical, 20)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(80)
        }
    }
}
