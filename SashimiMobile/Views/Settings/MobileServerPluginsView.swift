import SwiftUI

/// Settings › Server Plugins on iPhone, iPad and Mac: the same rows as tvOS in
/// a list. Settings owns the model (it already loaded it for the subtitle).
struct MobileServerPluginsView: View {
    @ObservedObject var model: ServerPluginsViewModel
    @ObservedObject private var sessionManager = SessionManager.shared
    /// Previews and tests drive the model directly; the screen otherwise
    /// refreshes through the signed-in session.
    var onRefresh: (() async -> Void)?

    init(model: ServerPluginsViewModel, onRefresh: (() async -> Void)? = nil) {
        self.model = model
        self.onRefresh = onRefresh
    }

    var body: some View {
        content
            .navigationTitle("Server Plugins")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.state == .loading)
                }
            }
    }

    private func refresh() async {
        if let onRefresh {
            await onRefresh()
        } else {
            await model.refresh(for: sessionManager)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView("Asking the server…")
        case .failed:
            List {
                Section {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Couldn't reach \(ServerPluginsViewModel.serverName(for: sessionManager))")
                                    .foregroundStyle(MobileColors.textPrimary)
                                Text("Plugin status is unknown until it answers. Tap to try again.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(MobileColors.accentSecondary)
                        }
                    }
                }
            }
        case .loaded(let report):
            List {
                Section {
                    ForEach(report.rows) { row in
                        MobileServerPluginRow(row: row, showsVersion: report.isAdministrator)
                    }
                } header: {
                    Text(report.serverLine)
                } footer: {
                    if !report.isAdministrator {
                        Text("Versions are visible to server admins.")
                    }
                }
            }
            .refreshable { await refresh() }
        }
    }
}

struct MobileServerPluginRow: View {
    let row: ServerPluginRow
    let showsVersion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.plugin.title)
                    .font(.body.weight(.semibold))
                if showsVersion, let version = row.version ?? (row.badge == .notInstalled ? "—" : nil) {
                    Text(version)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Image(systemName: row.badge.symbolName)
                        .font(.caption2)
                        .foregroundStyle(row.badge.tone.mobileColor)
                    Text(row.badge.label)
                        .font(.subheadline)
                        .foregroundStyle(row.badge.tone == .neutral ? .secondary : .primary)
                        .multilineTextAlignment(.trailing)
                }
            }
            Text(row.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let line = row.providerLine {
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
/// Admin view from fixture data (the device test account is not an admin).
private struct MobileServerPluginsPreviewClient: ServerPluginsClient {
    func getInstalledPlugins() async throws -> [InstalledPluginInfo] {
        [
            InstalledPluginInfo(name: "Sashimi Lists", version: "0.1.0", status: .active, id: "d95b448462cb487392c566a65b86b420"),
            InstalledPluginInfo(name: "Channels", version: "0.11.0", status: .restart, id: "7a3f1c925d644b089f216c8e5b0a4d73"),
            InstalledPluginInfo(name: "Theme Songs", version: "1.0.4", status: .active, id: "d8d1d1a14d9e4d559a2e0a0a1f5b7c31"),
            InstalledPluginInfo(name: "Intro Skipper", version: "12.0.6", status: .active, id: "c83d86bba1e04c35a113e2101cf4ee6b"),
            InstalledPluginInfo(name: "TheIntroDB", version: "1.3.0", status: .active, id: "c9e41b9563e445e29db6b83df21ae5e7")
        ]
    }

    func probePluginRoute(path: String, query: [URLQueryItem]) async -> PluginProbeResult {
        path == "/ContinueWatching" ? .notDetected : .detected
    }

    func getPublicServerInfo() async throws -> DashboardSystemInfo {
        DashboardSystemInfo(serverName: "popcorn", version: "12.4.0")
    }
}

private struct MobileServerPluginsPreview: View {
    let isAdmin: Bool
    @StateObject private var model = ServerPluginsViewModel(client: MobileServerPluginsPreviewClient())

    var body: some View {
        NavigationStack {
            MobileServerPluginsView(model: model) { await load() }
        }
        .task { await load() }
    }

    private func load() async {
        await model.refresh(key: "preview", isAdministrator: isAdmin, fallbackServerName: "popcorn")
    }
}

#Preview("Admin") { MobileServerPluginsPreview(isAdmin: true) }
#Preview("Non-admin") { MobileServerPluginsPreview(isAdmin: false) }
#endif
