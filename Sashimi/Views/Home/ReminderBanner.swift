import SwiftUI

/// Hosts SashimiTV reminders at the app's root: ticks the clock, shows the
/// banner when one is due, and tunes in on Play/Pause.
private struct StationReminderHost: ViewModifier {
    @ObservedObject private var reminders = StationReminders.shared
    @State private var tuned: TunedChannel?
    private let clock = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                // Deliberately not focusable — a banner that took focus would
                // pull it out of wherever the viewer is, the exact class of bug
                // the rail had. Play/Pause answers it instead.
                if let due = reminders.due {
                    ReminderBanner(reminder: due)
                        .padding(.top, 40)
                        .allowsHitTesting(false)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.35), value: reminders.due)
            .onReceive(clock) { _ in reminders.tick() }
            .onAppear { reminders.tick() }
            .onPlayPauseCommand {
                guard let due = reminders.due else { return }
                reminders.dismiss()
                Task {
                    guard let result = await GuideViewModel().tuneIn(to: due.channelID),
                          let item = try? await JellyfinClient.shared.getItem(itemId: result.itemID) else { return }
                    tuned = TunedChannel(item: item, context: result.context)
                }
            }
            .fullScreenCover(item: $tuned) { tuned in
                PlayerView(item: tuned.item, channelContext: tuned.context)
            }
    }
}

extension View {
    func stationReminders() -> some View { modifier(StationReminderHost()) }
}

/// "Survivor starts in 5 min on 3 · Unscripted — press ⏯ to watch."
struct ReminderBanner: View {
    let reminder: StationReminders.Reminder

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let minutes = Int((reminder.startsAt.timeIntervalSince(context.date) / 60).rounded(.up))
            let station = reminder.channelNumber.map { "\($0) · \(reminder.channelName)" } ?? reminder.channelName
            HStack(spacing: 18) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(SashimiTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(reminder.title)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                    Text(minutes > 0
                         ? "Starts in \(minutes) min on \(station)"
                         : "On now on \(station)")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 24)
                Label("Watch", systemImage: "playpause.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Capsule().fill(SashimiTheme.accent))
            }
            .padding(.horizontal, 28).padding(.vertical, 20)
            .frame(width: 1100)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(.black.opacity(0.85))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.1), lineWidth: 1))
            )
        }
    }
}
