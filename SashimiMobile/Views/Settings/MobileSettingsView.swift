import SwiftUI

struct MobileSettingsView: View {
    @ObservedObject private var serverManager = ServerManager.shared
    @StateObject private var playbackSettings = PlaybackSettings.shared
    @State private var showingDeleteAllDownloads = false

    var body: some View {
        List {
            // Server Section
            Section("Server") {
                if let serverURL = UserDefaults.standard.string(forKey: "serverURL") {
                    LabeledContent("Server URL", value: serverURL)
                }

                if let username = serverManager.currentUserName {
                    LabeledContent("Logged in as", value: username)
                }
            }

            // Home Screen Section
            Section("Home Screen") {
                NavigationLink("Customize Row Order") {
                    HomeRowOrderView()
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

            // Downloads Section
            Section("Downloads") {
                LabeledContent("Storage Used", value: DownloadFileManager.formattedTotalSize())
                LabeledContent("Available Space", value: ByteCountFormatter.string(
                    fromByteCount: DownloadFileManager.availableDiskSpace(),
                    countStyle: .file
                ))
                Button("Delete All Downloads", role: .destructive) {
                    showingDeleteAllDownloads = true
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
                    serverManager.logout()
                }
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Delete All Downloads?", isPresented: $showingDeleteAllDownloads) {
            Button("Delete All", role: .destructive) {
                Task { await DownloadManager.shared.deleteAllDownloads() }
            }
        } message: {
            Text("This will remove all downloaded files from your device.")
        }
    }
}

struct HomeRowOrderView: View {
    @ObservedObject private var settings = HomeRowSettings.shared

    var body: some View {
        List {
            Section {
                ForEach(settings.rows) { row in
                    HStack {
                        Image(systemName: row.isEnabled ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(row.isEnabled ? .green : .gray)
                            .onTapGesture {
                                if let index = settings.rows.firstIndex(where: { $0.id == row.id }) {
                                    settings.toggleRow(at: index)
                                }
                            }

                        Text(row.displayName)

                        Spacer()

                        Image(systemName: "line.3.horizontal")
                            .foregroundColor(.secondary)
                    }
                }
                .onMove { source, destination in
                    settings.moveRow(from: source, to: destination)
                }
            } header: {
                Text("Drag to reorder, tap to enable/disable")
            }
        }
        .navigationTitle("Row Order")
        .environment(\.editMode, .constant(.active))
    }
}
