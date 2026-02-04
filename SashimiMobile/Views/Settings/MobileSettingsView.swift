import SwiftUI

struct MobileSettingsView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @StateObject private var playbackSettings = PlaybackSettings.shared

    var body: some View {
        List {
            // Server Section
            Section("Server") {
                if let serverURL = UserDefaults.standard.string(forKey: "serverURL") {
                    LabeledContent("Server URL", value: serverURL)
                }

                if let username = sessionManager.currentUser?.name {
                    LabeledContent("Logged in as", value: username)
                }
            }

            // Playback Section
            Section("Playback") {
                Toggle("Auto-Play Next Episode", isOn: $playbackSettings.autoPlayNextEpisode)
                Toggle("Auto-Skip Intro", isOn: $playbackSettings.autoSkipIntro)
                Toggle("Auto-Skip Credits", isOn: $playbackSettings.autoSkipCredits)
                Toggle("Force Direct Play", isOn: $playbackSettings.forceDirectPlay)
            }

            // Video Quality Section
            Section("Video Quality") {
                Picker("Maximum Bitrate", selection: $playbackSettings.maxBitrate) {
                    Text("Auto").tag(0)
                    Text("4K (80 Mbps)").tag(80_000_000)
                    Text("1080p (20 Mbps)").tag(20_000_000)
                    Text("720p (8 Mbps)").tag(8_000_000)
                    Text("480p (3 Mbps)").tag(3_000_000)
                }
            }

            // About Section
            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
            }

            // Sign Out
            Section {
                Button("Sign Out", role: .destructive) {
                    sessionManager.logout()
                }
            }
        }
        .navigationTitle("Settings")
    }
}
