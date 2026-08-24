import SwiftUI

private enum ServerMediaStyle {
    static let accent = Color(red: 140 / 255, green: 92 / 255, blue: 199 / 255)
    static let modalBackground = Color(red: 0.05, green: 0.05, blue: 0.07)
    static let rowBackground = Color.white.opacity(0.08)
    static let focusedRowBackground = Color.white.opacity(0.18)
    static let secondaryText = Color.white.opacity(0.72)
    static let border = Color.white.opacity(0.28)
}

private enum ServerSourceOrdering {
    static func ordered(
        _ sources: [ServerMediaResult],
        by servers: [ServerConfig]
    ) -> [ServerMediaResult] {
        let savedOrder = Dictionary(
            uniqueKeysWithValues: servers.enumerated().map { ($0.element.id, $0.offset) }
        )

        return sources.sorted {
            let leftIndex = savedOrder[$0.serverID] ?? Int.max
            let rightIndex = savedOrder[$1.serverID] ?? Int.max
            if leftIndex != rightIndex {
                return leftIndex < rightIndex
            }
            return $0.serverName.localizedCaseInsensitiveCompare($1.serverName) == .orderedAscending
        }
    }
}

/// Compact server labels used under a title wherever the same media exists on
/// more than one saved server. They remain a horizontal scroll surface so an
/// arbitrary number of configured servers does not widen or clip a card.
struct ServerSourcePillsView: View {
    let sources: [ServerMediaResult]
    @ObservedObject private var sessionManager = SessionManager.shared

    var body: some View {
        Group {
            if sessionManager.servers.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(orderedSources) { source in
                            ServerSourcePill(label: source.serverName)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var orderedSources: [ServerMediaResult] {
        ServerSourceOrdering.ordered(sources, by: sessionManager.servers)
    }
}

struct ServerSourcePill: View {
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "server.rack")
                .font(.caption2.weight(.bold))
            Text(label)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(ServerMediaStyle.accent)
        .overlay {
            Capsule()
                .stroke(ServerMediaStyle.border, lineWidth: 1)
        }
        .clipShape(Capsule())
    }
}

/// Reusable modal used whenever a title has more than one server source.
/// Choosing a source closes the picker and hands the complete server-scoped
/// result to the caller, which then opens the platform-specific detail view.
struct ServerMediaSourcePickerView: View {
    let group: ServerMediaResultGroup
    let onSelect: (ServerMediaResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isCancelFocused: Bool
    @ObservedObject private var sessionManager = SessionManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 14) {
                        Text("Choose a Server")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .layoutPriority(1)

                        Spacer(minLength: 8)

                        Button {
                            dismiss()
                        } label: {
                            Label("Cancel", systemImage: "xmark")
                                .font(.headline)
                                .foregroundStyle(isCancelFocused ? .black : .white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(isCancelFocused ? Color.white : ServerMediaStyle.accent)
                                .clipShape(Capsule())
                                .overlay {
                                    Capsule()
                                        .stroke(ServerMediaStyle.border, lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .focused($isCancelFocused)
                        .accessibilityHint("Close the server picker")
                    }

                    Text(group.primary.item.displayTitle)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)

                    Text("Select where you want to open this title.")
                        .font(.subheadline)
                        .foregroundStyle(ServerMediaStyle.secondaryText)
                }

                Divider()
                    .overlay(Color.white.opacity(0.16))

                VStack(alignment: .leading, spacing: 14) {
                    Text("Available servers")
                        .font(.headline)
                        .foregroundStyle(ServerMediaStyle.secondaryText)

                    VStack(spacing: 12) {
                        ForEach(orderedSources) { source in
                            ServerSourceOptionRow(source: source) {
                                onSelect(source)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 1000, alignment: .leading)
            .padding(.horizontal, pickerHorizontalPadding)
            .padding(.vertical, pickerVerticalPadding)
        }
        .background(ServerMediaStyle.modalBackground.ignoresSafeArea())
        .presentationBackground(ServerMediaStyle.modalBackground)
        .preferredColorScheme(.dark)
    }

    private var orderedSources: [ServerMediaResult] {
        ServerSourceOrdering.ordered(group.sources, by: sessionManager.servers)
    }

    private var pickerHorizontalPadding: CGFloat {
#if os(tvOS)
        return 56
#else
        return 20
#endif
    }

    private var pickerVerticalPadding: CGFloat {
#if os(tvOS)
        return 44
#else
        return 24
#endif
    }
}

private struct ServerSourceOptionRow: View {
    let source: ServerMediaResult
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(source.serverName)
                        .font(.headline)
                        .foregroundStyle(.white)

                    MediaSourceQualityBadgesView(item: source.item)
                }

                Spacer(minLength: 12)

                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isFocused ? ServerMediaStyle.focusedRowBackground : ServerMediaStyle.rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isFocused ? ServerMediaStyle.accent : ServerMediaStyle.border,
                        lineWidth: isFocused ? 2 : 1
                    )
                    .padding(3)
            }
            .scaleEffect(isFocused ? 1.02 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Open \(source.item.displayTitle) on \(source.serverName)")
    }
}

private struct MediaSourceQualityBadgesView: View {
    let item: BaseItemDto

    private var primaryAudioStream: MediaStream? {
        item.mediaStreams?.first(where: { $0.type == "Audio" && $0.isDefault == true })
            ?? item.mediaStreams?.first(where: { $0.type == "Audio" })
    }

    var body: some View {
        HStack(spacing: 8) {
            if let quality = item.qualityBadge {
                QualityBadge(
                    label: quality,
                    fontSize: 16,
                    horizontalPadding: 9,
                    verticalPadding: 5,
                    cornerRadius: 6
                )
            }

            if let primaryAudioStream {
                AudioQualityBadge(stream: primaryAudioStream)
            }
        }
    }
}

private struct AudioQualityBadge: View {
    let stream: MediaStream

    private var label: String? {
        var parts: [String] = []
        if let codec = stream.codec, !codec.isEmpty {
            parts.append(Self.formatCodec(codec))
        }
        if let channels = stream.channels, channels > 0 {
            parts.append(Self.formatChannels(channels))
        }
        if parts.isEmpty, let displayTitle = stream.displayTitle, !displayTitle.isEmpty {
            return displayTitle
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var logoName: String? {
        guard let codec = stream.codec?.uppercased() else { return nil }
        switch codec {
        case "AC3": return "DolbyDigital"
        case "EAC3": return "DolbyDigitalPlus"
        case "TRUEHD": return "DolbyTrueHD"
        case "DTS", "DCA": return "DTS"
        default: return nil
        }
    }

    var body: some View {
        Group {
            if let label {
                HStack(spacing: 6) {
                    if let logoName {
                        Image(logoName)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 16)
                    } else {
                        Image(systemName: "hifispeaker.fill")
                            .font(.caption.weight(.bold))
                    }

                    Text(label)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .allowsTightening(true)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.78))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                }
            }
        }
    }

    private static func formatCodec(_ codec: String) -> String {
        switch codec.uppercased() {
        case "AC3": return "Dolby Digital"
        case "EAC3": return "Dolby Digital+"
        case "TRUEHD": return "Dolby TrueHD"
        case "DCA", "DTS": return "DTS"
        default: return codec.uppercased()
        }
    }

    private static func formatChannels(_ channels: Int) -> String {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }
}

/// Shared server-session scope for title detail routes. The detail view is
/// built only after the selected server's client is configured. The lifecycle
/// task stays attached to the route so its cancellation awaits restoration of
/// the exact parent client scope.
struct ServerScopedMediaDetailView: View {
    let source: ServerMediaResult

    @State private var isReady = false
    @State private var scopeError: String?
    @Environment(\.dismiss) private var dismiss

#if os(tvOS)
    private let backToolbarPlacement: ToolbarItemPlacement = .navigationBarLeading
#else
    private let backToolbarPlacement: ToolbarItemPlacement = .topBarLeading
#endif

    private var isYouTubeStyle: Bool {
        source.item.libraryName?.localizedCaseInsensitiveContains("youtube") == true
    }

    var body: some View {
        Group {
            if let scopeError {
                ContentUnavailableView {
                    Label("Unable to Open Title", systemImage: "key.slash")
                } description: {
                    Text(scopeError)
                } actions: {
                    Button("Back") {
                        dismiss()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isReady {
#if os(tvOS)
                MediaDetailView(
                    item: source.item,
                    forceYouTubeStyle: isYouTubeStyle,
                    serverID: source.serverID
                )
#else
                AdaptiveDetailView(
                    item: source.item,
                    libraryName: source.item.libraryName,
                    serverID: source.serverID
                )
#endif
            } else {
                ProgressView("Connecting to \(source.serverName)...")
            }
        }
        .task(id: source.id) {
            await manageServerScope()
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: backToolbarPlacement) {
                Button {
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .accessibilityLabel("Back to results")
            }
        }
    }

    private func manageServerScope() async {
        guard let scope = await SessionManager.shared.beginServerScope(for: source.serverID) else {
            guard !Task.isCancelled else { return }
            scopeError = "The saved session for \(source.serverName) is unavailable. Reconnect this server in Settings, then try again."
            return
        }

        if Task.isCancelled {
            await SessionManager.shared.endServerScope(scope)
            return
        }

        isReady = true
        // SwiftUI cancels a view's task when the route disappears. Sleeping
        // keeps the scope alive for the detail route and lets cancellation
        // continue into the awaited restoration below.
        do {
            try await Task.sleep(for: .seconds(365 * 24 * 60 * 60))
        } catch {
            // Route cancellation is the normal way to reach restoration.
        }
        await SessionManager.shared.endServerScope(scope)
    }
}
