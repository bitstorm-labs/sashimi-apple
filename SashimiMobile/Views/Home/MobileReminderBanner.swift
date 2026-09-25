import SwiftUI

/// Hosts SashimiTV reminders at the iPad/iPhone root: ticks the clock and shows
/// a banner with a Watch button when one is due. The system notification is
/// scheduled separately by StationReminders, for when the app is closed.
private struct MobileStationReminderHost: ViewModifier {
    @ObservedObject private var reminders = StationReminders.shared
    @State private var tuned: TunedChannel?
    private let clock = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let due = reminders.due {
                    MobileReminderBanner(
                        reminder: due,
                        onWatch: { watch(due) },
                        onDismiss: { reminders.dismiss() }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: reminders.due)
            .onReceive(clock) { _ in reminders.tick() }
            .onAppear { reminders.tick() }
            .fullScreenCover(item: $tuned) { tuned in
                MobilePlayerView(item: tuned.item, channelContext: tuned.context)
            }
    }

    private func watch(_ reminder: StationReminders.Reminder) {
        reminders.dismiss()
        Task {
            guard let result = await GuideViewModel().tuneIn(to: reminder.channelID),
                  let item = try? await JellyfinClient.shared.getItem(itemId: result.itemID) else { return }
            tuned = TunedChannel(item: item, context: result.context)
        }
    }
}

extension View {
    func mobileStationReminders() -> some View { modifier(MobileStationReminderHost()) }
}

struct MobileReminderBanner: View {
    let reminder: StationReminders.Reminder
    let onWatch: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let minutes = Int((reminder.startsAt.timeIntervalSince(context.date) / 60).rounded(.up))
            HStack(spacing: 12) {
                Image(systemName: "bell.fill").foregroundStyle(MobileColors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(reminder.title).font(.headline).foregroundStyle(.white)
                    Text(minutes > 0 ? "Starts in \(minutes) min on \(reminder.channelName)" : "On now on \(reminder.channelName)")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 8)
                Button("Watch", action: onWatch)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(MobileColors.accent)
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityLabel("Dismiss reminder")
            }
            .padding(14)
            .frame(maxWidth: 640)
            .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.88)))
        }
    }
}

/// Every reminder on this device; swipe to clear one, or clear them all.
struct MobileRemindersList: View {
    @ObservedObject private var reminders = StationReminders.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(reminders.reminders.sorted { $0.startsAt < $1.startsAt }) { reminder in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reminder.title).font(.headline)
                        Text("\(reminder.startsAt.formatted(.dateTime.weekday(.wide).hour().minute())) · \(reminder.channelName)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) { reminders.remove(reminder) } label: { Label("Clear", systemImage: "bell.slash") }
                    }
                }
            }
            .overlay {
                if reminders.reminders.isEmpty {
                    ContentUnavailableView("No reminders", systemImage: "bell",
                                           description: Text("Long-press a programme in the guide to set one."))
                }
            }
            .navigationTitle("Reminders")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear All", role: .destructive) { reminders.clearAll() }
                        .disabled(reminders.reminders.isEmpty)
                }
            }
        }
    }
}
