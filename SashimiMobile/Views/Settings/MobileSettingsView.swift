import SwiftUI

struct MobileSettingsView: View {
    @ObservedObject private var sessionManager = SessionManager.shared
    @StateObject private var playbackSettings = PlaybackSettings.shared
    @State private var showingDeleteAllDownloads = false
    @State private var showAddServer = false

    var body: some View {
        List {
            // Servers (multi-server switcher; swipe to remove)
            Section("Servers") {
                ForEach(sessionManager.servers) { server in
                    Button {
                        Task { await sessionManager.switchServer(to: server.id) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                    .foregroundStyle(.primary)
                                Text("\(server.username) • \(server.url.absoluteString)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if server.id == sessionManager.activeServerId {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { sessionManager.servers[$0].id }
                    Task { for id in ids { await sessionManager.removeServer(id: id) } }
                }

                Button {
                    showAddServer = true
                } label: {
                    Label("Add Server", systemImage: "plus.circle.fill")
                }
            }

            // Home Screen Section
            Section("Home Screen") {
                NavigationLink("Customize Row Order") {
                    HomeRowOrderView()
                }
            }

            // Display Section
            Section("Display") {
                Toggle("Show Quality Badges", isOn: $playbackSettings.showQualityBadges)
            }

            // Playback Section
            Section("Playback") {
                Toggle("Auto-Play Next Episode", isOn: $playbackSettings.autoPlayNextEpisode)
                Toggle("Auto-Skip Intro", isOn: $playbackSettings.autoSkipIntro)
                Toggle("Auto-Skip Credits", isOn: $playbackSettings.autoSkipCredits)
                Toggle("Force Direct Play", isOn: $playbackSettings.forceDirectPlay)
                // tvOS parity — same values as the tvOS Resume Threshold screen
                Picker("Resume Threshold", selection: $playbackSettings.resumeThresholdSeconds) {
                    Text("Always resume").tag(0)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                    Text("10 minutes").tag(600)
                }
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
                    sessionManager.logout()
                }
            }
        }
        .sheet(isPresented: $showAddServer) {
            MobileAddServerSheet()
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

/// Auth flow presented for adding an additional server; dismisses once the
/// server list grows.
struct MobileAddServerSheet: View {
    @ObservedObject private var sessionManager = SessionManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var initialCount = 0

    var body: some View {
        NavigationStack {
            MobileAuthView(onCancel: { dismiss() })
                .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { initialCount = sessionManager.servers.count }
        .onChange(of: sessionManager.servers.count) { _, newCount in
            if newCount > initialCount { dismiss() }
        }
        .onDisappear {
            // The probe repointed the shared client at the candidate server;
            // re-point it at whatever server is active now so the session works.
            Task { await sessionManager.restoreActiveClient() }
        }
    }
}
