import SwiftUI

struct SettingsView: View {
    var showSignOut: Bool = true
    @EnvironmentObject private var sessionManager: SessionManager
    @State private var showingLogoutConfirmation = false

    var body: some View {
        List {
            Section("Home Screen") {
                NavigationLink("Row Order") {
                    HomeScreenSettingsView()
                }
            }

            Section("Playback") {
                NavigationLink("Playback Settings") {
                    PlaybackSettingsView()
                }
            }

            Section("Parental Controls") {
                NavigationLink("Restrictions") {
                    ParentalControlsView()
                }
            }

            Section("Security") {
                NavigationLink("Certificate Settings") {
                    CertificateSettingsView()
                }
            }

            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("Build", value: "1")
            }

            if showSignOut {
                Section {
                    Button(role: .destructive) {
                        showingLogoutConfirmation = true
                    } label: {
                        Text("Sign Out")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .confirmationDialog(
            "Sign Out",
            isPresented: $showingLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                sessionManager.logout()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to sign out?")
        }
    }
}

// MARK: - Home Screen Settings

enum HomeRowType: String, Codable, CaseIterable {
    case hero
    case continueWatching

    var displayName: String {
        switch self {
        case .hero: return "Featured"
        case .continueWatching: return "Continue Watching"
        }
    }
}

struct HomeRowConfig: Codable, Identifiable, Equatable {
    let id: String
    let type: HomeRowType?  // nil for library rows
    let libraryId: String?  // for library rows
    let libraryName: String?
    var isVisible: Bool

    var displayName: String {
        if let type = type {
            return type.displayName
        }
        return libraryName ?? "Unknown Library"
    }

    static func builtIn(_ type: HomeRowType, visible: Bool = true) -> HomeRowConfig {
        HomeRowConfig(id: type.rawValue, type: type, libraryId: nil, libraryName: nil, isVisible: visible)
    }

    static func library(id: String, name: String, visible: Bool = true) -> HomeRowConfig {
        HomeRowConfig(id: "library_\(id)", type: nil, libraryId: id, libraryName: name, isVisible: visible)
    }
}

@MainActor
class HomeScreenSettings: ObservableObject {
    static let shared = HomeScreenSettings()

    @Published var rowConfigs: [HomeRowConfig] = []
    @Published var needsRefresh = false

    private let userDefaultsKey = "homeScreenRowOrder"

    init() {
        loadSettings()
    }

    func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let configs = try? JSONDecoder().decode([HomeRowConfig].self, from: data) {
            rowConfigs = configs
        }
    }

    func saveSettings() {
        if let data = try? JSONEncoder().encode(rowConfigs) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
        needsRefresh = true
    }

    func updateWithLibraries(_ libraries: [JellyfinLibrary]) {
        var newConfigs: [HomeRowConfig] = []

        // Add built-in rows if not already present
        for type in HomeRowType.allCases {
            if let existing = rowConfigs.first(where: { $0.type == type }) {
                newConfigs.append(existing)
            } else {
                newConfigs.append(.builtIn(type))
            }
        }

        // Add library rows
        for library in libraries {
            if let existing = rowConfigs.first(where: { $0.libraryId == library.id }) {
                // Update name in case it changed
                var updated = existing
                if updated.libraryName != library.name {
                    updated = .library(id: library.id, name: library.name, visible: existing.isVisible)
                }
                newConfigs.append(updated)
            } else {
                newConfigs.append(.library(id: library.id, name: library.name))
            }
        }

        // Remove library rows that no longer exist
        rowConfigs = newConfigs.filter { config in
            if config.libraryId != nil {
                return libraries.contains { $0.id == config.libraryId }
            }
            return true
        }

        // Preserve order from saved settings
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let savedConfigs = try? JSONDecoder().decode([HomeRowConfig].self, from: data) {
            let savedOrder = savedConfigs.map { $0.id }
            rowConfigs.sort { a, b in
                let indexA = savedOrder.firstIndex(of: a.id) ?? Int.max
                let indexB = savedOrder.firstIndex(of: b.id) ?? Int.max
                return indexA < indexB
            }
        }
    }

    func moveRow(from source: IndexSet, to destination: Int) {
        rowConfigs.move(fromOffsets: source, toOffset: destination)
        saveSettings()
    }

    func toggleVisibility(for config: HomeRowConfig) {
        if let index = rowConfigs.firstIndex(where: { $0.id == config.id }) {
            rowConfigs[index].isVisible.toggle()
            saveSettings()
        }
    }

    func isRowVisible(_ type: HomeRowType) -> Bool {
        rowConfigs.first { $0.type == type }?.isVisible ?? true
    }

    func isLibraryVisible(_ libraryId: String) -> Bool {
        rowConfigs.first { $0.libraryId == libraryId }?.isVisible ?? true
    }

    func orderedLibraryIds() -> [String] {
        rowConfigs.compactMap { $0.libraryId }
    }
}

struct HomeScreenSettingsView: View {
    @StateObject private var settings = HomeScreenSettings.shared
    @State private var isLoading = true

    var body: some View {
        SettingsContainer {
            if isLoading {
                ProgressView("Loading...")
            } else if settings.rowConfigs.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                    Text("No rows configured")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Visit the Home tab first to load your libraries")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Home Screen Rows")
                            .font(.system(size: 38, weight: .bold))
                            .foregroundStyle(SashimiTheme.textPrimary)
                            .padding(.bottom, 8)

                        Text("Use arrows to reorder, tap checkmark to show/hide")
                            .font(.system(size: 18))
                            .foregroundStyle(SashimiTheme.textSecondary)
                            .padding(.bottom, 16)

                        ForEach(Array(settings.rowConfigs.enumerated()), id: \.element.id) { index, config in
                            HomeScreenRowItem(
                                config: config,
                                index: index,
                                totalCount: settings.rowConfigs.count,
                                onToggle: { settings.toggleVisibility(for: config) },
                                onMoveUp: { moveRow(from: index, direction: -1) },
                                onMoveDown: { moveRow(from: index, direction: 1) }
                            )
                        }
                    }
                    .padding(.horizontal, 60)
                    .padding(.vertical, 40)
                }
            }
        }
        .onAppear {
            if settings.rowConfigs.isEmpty {
                for type in HomeRowType.allCases {
                    settings.rowConfigs.append(.builtIn(type))
                }
            }
            isLoading = false
        }
    }

    private func moveRow(from index: Int, direction: Int) {
        let newIndex = index + direction
        guard newIndex >= 0 && newIndex < settings.rowConfigs.count else { return }
        settings.rowConfigs.swapAt(index, newIndex)
        settings.saveSettings()
    }
}

struct HomeScreenRowItem: View {
    let config: HomeRowConfig
    let index: Int
    let totalCount: Int
    let onToggle: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Move up button
            HomeRowMoveButton(
                direction: .up,
                isEnabled: index > 0,
                action: onMoveUp
            )

            // Move down button
            HomeRowMoveButton(
                direction: .down,
                isEnabled: index < totalCount - 1,
                action: onMoveDown
            )

            // Toggle visibility button
            HomeRowToggleButton(config: config, onToggle: onToggle)
        }
    }
}

enum MoveDirection {
    case up, down

    var icon: String {
        switch self {
        case .up: return "chevron.up"
        case .down: return "chevron.down"
        }
    }
}

struct HomeRowMoveButton: View {
    let direction: MoveDirection
    let isEnabled: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: direction.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isEnabled ? (isFocused ? .white : SashimiTheme.textSecondary) : SashimiTheme.textTertiary.opacity(0.3))
                .frame(width: 50, height: 50)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isFocused ? SashimiTheme.accent : SashimiTheme.cardBackground)
                )
        }
        .buttonStyle(.card)
        .focused($isFocused)
        .disabled(!isEnabled)
    }
}

struct HomeRowToggleButton: View {
    let config: HomeRowConfig
    let onToggle: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 16) {
                Image(systemName: config.isVisible ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(config.isVisible ? SashimiTheme.accent : SashimiTheme.textTertiary)

                Text(config.displayName)
                    .font(.system(size: 22))
                    .foregroundStyle(config.isVisible ? SashimiTheme.textPrimary : SashimiTheme.textSecondary)

                Spacer()

                if config.type != nil {
                    Text("Built-in")
                        .font(.caption)
                        .foregroundStyle(SashimiTheme.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(SashimiTheme.cardBackground.opacity(0.5)))
                }
            }
        }
        .buttonStyle(.card)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isFocused ? SashimiTheme.accent.opacity(0.15) : SashimiTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(SashimiTheme.accent.opacity(isFocused ? 1.0 : 0), lineWidth: 3)
        )
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .focused($isFocused)
    }
}

// MARK: - Settings Container (styled background with width constraint)

struct SettingsContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()

            content
                .frame(maxWidth: 900)
        }
    }
}

// MARK: - Custom Settings Row Button Style

struct SettingsRowButtonStyle: ButtonStyle {
    @FocusState.Binding var isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isFocused ? SashimiTheme.accent.opacity(0.2) : SashimiTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(SashimiTheme.accent.opacity(isFocused ? 1.0 : 0), lineWidth: 3)
            )
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}

// MARK: - Settings Row View (custom focus styling)

struct SettingsRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            content()
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isFocused ? SashimiTheme.accent.opacity(0.15) : SashimiTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(SashimiTheme.accent.opacity(isFocused ? 1.0 : 0), lineWidth: 3)
        )
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .focused($isFocused)
    }
}

struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(SashimiTheme.textPrimary)
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? SashimiTheme.accent : SashimiTheme.textTertiary)
            }
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isFocused ? SashimiTheme.accent.opacity(0.15) : SashimiTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(SashimiTheme.accent.opacity(isFocused ? 1.0 : 0), lineWidth: 3)
        )
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .focused($isFocused)
    }
}

// MARK: - Playback Settings

@MainActor
class PlaybackSettings: ObservableObject {
    static let shared = PlaybackSettings()

    @AppStorage("maxBitrate") var maxBitrate = 20_000_000
    @AppStorage("autoPlayNextEpisode") var autoPlayNextEpisode = true
    @AppStorage("autoSkipIntro") var autoSkipIntro = false
    @AppStorage("autoSkipCredits") var autoSkipCredits = false
    @AppStorage("resumeThresholdSeconds") var resumeThresholdSeconds = 30
    @AppStorage("preferredAudioLanguage") var preferredAudioLanguage = ""
    @AppStorage("preferredSubtitleLanguage") var preferredSubtitleLanguage = ""
    @AppStorage("subtitlesEnabled") var subtitlesEnabled = false
    @AppStorage("forceDirectPlay") var forceDirectPlay = false
}

struct PlaybackSettingsView: View {
    @StateObject private var settings = PlaybackSettings.shared

    var body: some View {
        SettingsContainer {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Playback Settings")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(SashimiTheme.textPrimary)
                        .padding(.bottom, 8)

                    // Video Quality Section
                    SettingsSection(title: "Video Quality") {
                        SettingsNavigationRow(title: "Maximum Bitrate", subtitle: bitrateLabel) {
                            VideoQualitySettingsView()
                        }
                        SettingsToggleRow(title: "Force Direct Play", isOn: $settings.forceDirectPlay)
                    }

                    Text("Direct play streams the original file without transcoding.")
                        .font(.system(size: 16))
                        .foregroundStyle(SashimiTheme.textTertiary)
                        .padding(.horizontal, 8)

                    // Playback Behavior Section
                    SettingsSection(title: "Playback Behavior") {
                        SettingsToggleRow(title: "Auto-Play Next Episode", isOn: $settings.autoPlayNextEpisode)
                        SettingsToggleRow(title: "Auto-Skip Intro", isOn: $settings.autoSkipIntro)
                        SettingsToggleRow(title: "Auto-Skip Credits", isOn: $settings.autoSkipCredits)
                    }

                    Text("Auto-skip requires the intro-skipper plugin on your server.")
                        .font(.system(size: 16))
                        .foregroundStyle(SashimiTheme.textTertiary)
                        .padding(.horizontal, 8)

                    // Resume Section
                    SettingsSection(title: "Resume Playback") {
                        SettingsNavigationRow(title: "Resume Threshold", subtitle: resumeLabel) {
                            ResumeThresholdSettingsView()
                        }
                    }

                    // Audio Section
                    SettingsSection(title: "Audio") {
                        SettingsNavigationRow(title: "Preferred Language", subtitle: audioLanguageLabel) {
                            LanguagePickerView(title: "Audio Language", selection: $settings.preferredAudioLanguage)
                        }
                    }

                    // Subtitles Section
                    SettingsSection(title: "Subtitles") {
                        SettingsToggleRow(title: "Enable Subtitles", isOn: $settings.subtitlesEnabled)
                        if settings.subtitlesEnabled {
                            SettingsNavigationRow(title: "Preferred Language", subtitle: subtitleLanguageLabel) {
                                LanguagePickerView(title: "Subtitle Language", selection: $settings.preferredSubtitleLanguage)
                            }
                        }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 40)
            }
        }
    }

    private var bitrateLabel: String {
        let bitrate = settings.maxBitrate
        if bitrate == 0 { return "Auto" }
        if bitrate >= 1_000_000 { return "\(bitrate / 1_000_000) Mbps" }
        return "\(bitrate / 1000) Kbps"
    }

    private var resumeLabel: String {
        let seconds = settings.resumeThresholdSeconds
        if seconds == 0 { return "Always ask" }
        if seconds >= 60 { return "\(seconds / 60) minute\(seconds >= 120 ? "s" : "")" }
        return "\(seconds) seconds"
    }

    private var audioLanguageLabel: String {
        settings.preferredAudioLanguage.isEmpty ? "System Default" : languageName(for: settings.preferredAudioLanguage)
    }

    private var subtitleLanguageLabel: String {
        settings.preferredSubtitleLanguage.isEmpty ? "System Default" : languageName(for: settings.preferredSubtitleLanguage)
    }

    private func languageName(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}

// MARK: - Settings Section Container

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(SashimiTheme.textSecondary)
                .padding(.leading, 8)

            VStack(spacing: 8) {
                content()
            }
        }
    }
}

// MARK: - Settings Navigation Row

struct SettingsNavigationRow<Destination: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder let destination: () -> Destination
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationLink(destination: destination) {
            HStack {
                Text(title)
                    .font(.system(size: 22))
                    .foregroundStyle(SashimiTheme.textPrimary)

                Spacer()

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 18))
                        .foregroundStyle(SashimiTheme.textTertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SashimiTheme.textTertiary)
            }
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isFocused ? SashimiTheme.accent.opacity(0.15) : SashimiTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(SashimiTheme.accent.opacity(isFocused ? 1.0 : 0), lineWidth: 3)
        )
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .focused($isFocused)
    }
}

struct VideoQualitySettingsView: View {
    @AppStorage("maxBitrate") private var maxBitrate = 20_000_000

    let bitrateOptions = [
        (label: "Auto", value: 0),
        (label: "4K - 120 Mbps", value: 120_000_000),
        (label: "4K - 80 Mbps", value: 80_000_000),
        (label: "1080p - 40 Mbps", value: 40_000_000),
        (label: "1080p - 20 Mbps", value: 20_000_000),
        (label: "720p - 8 Mbps", value: 8_000_000),
        (label: "480p - 3 Mbps", value: 3_000_000),
    ]

    var body: some View {
        SettingsContainer {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Video Quality")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(SashimiTheme.textPrimary)
                        .padding(.bottom, 8)

                    ForEach(bitrateOptions, id: \.value) { option in
                        SettingsOptionRow(
                            title: option.label,
                            isSelected: maxBitrate == option.value
                        ) {
                            maxBitrate = option.value
                        }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 40)
            }
        }
    }
}

// MARK: - Settings Option Row (for pickers)

struct SettingsOptionRow: View {
    let title: String
    var subtitle: String = ""
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 22))
                        .foregroundStyle(SashimiTheme.textPrimary)

                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 16))
                            .foregroundStyle(SashimiTheme.textTertiary)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(SashimiTheme.accent)
                }
            }
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isFocused ? SashimiTheme.accent.opacity(0.15) : SashimiTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(SashimiTheme.accent.opacity(isFocused ? 1.0 : 0), lineWidth: 3)
        )
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .focused($isFocused)
    }
}

struct ResumeThresholdSettingsView: View {
    @AppStorage("resumeThresholdSeconds") private var resumeThresholdSeconds = 30

    let thresholdOptions = [
        (label: "Always ask", value: 0),
        (label: "30 seconds", value: 30),
        (label: "1 minute", value: 60),
        (label: "2 minutes", value: 120),
        (label: "5 minutes", value: 300),
        (label: "10 minutes", value: 600),
    ]

    var body: some View {
        SettingsContainer {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Resume Threshold")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(SashimiTheme.textPrimary)
                        .padding(.bottom, 8)

                    Text("Only ask to resume if watched more than this amount")
                        .font(.system(size: 18))
                        .foregroundStyle(SashimiTheme.textSecondary)
                        .padding(.bottom, 16)

                    ForEach(thresholdOptions, id: \.value) { option in
                        SettingsOptionRow(
                            title: option.label,
                            isSelected: resumeThresholdSeconds == option.value
                        ) {
                            resumeThresholdSeconds = option.value
                        }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 40)
            }
        }
    }
}

struct LanguagePickerView: View {
    let title: String
    @Binding var selection: String

    let languages = [
        (code: "", name: "System Default"),
        (code: "en", name: "English"),
        (code: "es", name: "Spanish"),
        (code: "fr", name: "French"),
        (code: "de", name: "German"),
        (code: "it", name: "Italian"),
        (code: "pt", name: "Portuguese"),
        (code: "ja", name: "Japanese"),
        (code: "ko", name: "Korean"),
        (code: "zh", name: "Chinese"),
        (code: "ru", name: "Russian"),
        (code: "ar", name: "Arabic"),
        (code: "hi", name: "Hindi"),
        (code: "nl", name: "Dutch"),
        (code: "pl", name: "Polish"),
        (code: "sv", name: "Swedish"),
        (code: "da", name: "Danish"),
        (code: "no", name: "Norwegian"),
        (code: "fi", name: "Finnish"),
    ]

    var body: some View {
        SettingsContainer {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(title)
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(SashimiTheme.textPrimary)
                        .padding(.bottom, 8)

                    ForEach(languages, id: \.code) { language in
                        SettingsOptionRow(
                            title: language.name,
                            isSelected: selection == language.code
                        ) {
                            selection = language.code
                        }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 40)
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(SessionManager.shared)
}
