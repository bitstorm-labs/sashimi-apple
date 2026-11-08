import NukeUI
import SwiftUI

/// The Requests page's request list (#845), like Seerr web's /requests:
/// a filter, Everyone / Mine for those allowed to see everyone's, and each
/// request with who asked and where it's at. Selecting one offers what the
/// account may do with it; the destructive ones ask first.
struct SeerrRequestListSection: View {
    @StateObject private var model = SeerrRequestListModel()
    @ObservedObject private var session = SeerrSession.shared
    @State private var chosen: SeerrRequestRow?
    @State private var confirming: (action: SeerrRequestAction, row: SeerrRequestRow)?
    @State private var openTarget: SeerrTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            controls
                .padding(.horizontal, 60)
            if let count = model.count {
                Text(count.summary)
                    .font(Typography.caption)
                    .foregroundStyle(SashimiTheme.textTertiary)
                    .padding(.horizontal, 60)
            }
            if let error = model.errorMessage, !model.rows.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.caption)
                    .foregroundStyle(SashimiTheme.warning)
                    .padding(.horizontal, 60)
            }
            content
        }
        .task(id: "\(model.filter.rawValue)-\(model.scope.rawValue)-\(session.requestsRevision)") {
            await model.reload()
        }
        .fullScreenCover(item: $openTarget) { target in
            SeerrDetailView(target: target)
        }
        .confirmationDialog(
            chosen?.displayTitle ?? "",
            isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }),
            titleVisibility: .visible,
            presenting: chosen
        ) { row in
            Button("Open") { openTarget = row.target }
            ForEach(model.actions(for: row)) { action in
                Button(action.title, role: action.isDestructive ? .destructive : nil) {
                    if action.isDestructive {
                        // After this dialog has gone, or the alert has
                        // nothing to present over.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { confirming = (action, row) }
                    } else {
                        Task { await model.perform(action, on: row) }
                    }
                }
            }
            Button("Close", role: .cancel) {}
        }
        .destructiveConfirmation(
            "\(confirming?.action.title ?? "")?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            message: confirming.map { "\($0.row.displayTitle), requested by \($0.row.requesterName)." } ?? "",
            confirmTitle: confirming?.action.title ?? "OK"
        ) {
            guard let confirming else { return }
            Task { await model.perform(confirming.action, on: confirming.row) }
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            ForEach(SeerrRequestFilter.allCases) { filter in
                GuideChip(label: filter.title, selected: model.filter == filter) {
                    model.filter = filter
                }
            }
            if model.canChooseScope {
                Spacer(minLength: 40)
                ForEach(SeerrRequestScope.allCases) { scope in
                    GuideChip(
                        label: scope.title,
                        systemImage: scope == .mine ? "person" : "person.3",
                        selected: model.scope == scope
                    ) {
                        model.scope = scope
                    }
                }
            }
            Spacer()
        }
        .focusSection()
    }

    @ViewBuilder
    private var content: some View {
        if model.rows.isEmpty {
            Group {
                if model.isLoading || !model.hasLoaded {
                    ProgressView().tint(SashimiTheme.accent).scaleEffect(1.5)
                        .frame(maxWidth: .infinity)
                } else if let error = model.errorMessage {
                    ErrorStateView(title: "Couldn't load requests", message: error) {
                        Task { await model.reload() }
                    }
                } else {
                    Text(model.filter == .all ? "No requests yet." : "No \(model.filter.title.lowercased()) requests.")
                        .font(Typography.bodySmall)
                        .foregroundStyle(SashimiTheme.textTertiary)
                        .padding(.horizontal, 60)
                }
            }
            .padding(.top, 40)
        } else {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(model.rows) { row in
                    SeerrRequestListCard(
                        row: row,
                        showsRequester: model.showsRequester,
                        serverURL: session.serverURL,
                        isBusy: model.busy.contains(row.id)
                    ) {
                        chosen = row
                    }
                    .onAppear { Task { await model.loadMoreIfNeeded(after: row) } }
                }
                if model.canLoadMore {
                    ProgressView().tint(SashimiTheme.accent).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 60)
            .focusSection()
        }
    }
}

/// One request: poster, title, type and seasons, who asked and when, the
/// request's and the title's state, and download progress.
struct SeerrRequestListCard: View {
    let row: SeerrRequestRow
    let showsRequester: Bool
    let serverURL: URL?
    let isBusy: Bool
    let onSelect: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 28) {
                SeerrArtwork(url: SeerrImages.poster(row.posterPath, width: 185), title: row.title, cornerRadius: 8)
                    .frame(width: 80, height: 120)
                VStack(alignment: .leading, spacing: 8) {
                    Text(row.title)
                        .font(Typography.titleSmall)
                        .foregroundStyle(SashimiTheme.textPrimary)
                        .lineLimit(1)
                    Text("\(row.kindLabel) \u{00B7} \(row.requestedLabel())")
                        .font(Typography.caption)
                        .foregroundStyle(isFocused ? .white.opacity(0.8) : SashimiTheme.textTertiary)
                    if showsRequester {
                        requester
                    }
                    if let progress = row.progress {
                        ProgressView(value: progress)
                            .tint(SeerrBadge.coming.color)
                            .frame(maxWidth: 360)
                    }
                }
                Spacer(minLength: 20)
                if isBusy {
                    ProgressView()
                }
                HStack(spacing: 12) {
                    if let media = row.mediaStatus {
                        SeerrStatusTag(label: media.label, color: media.tone.color, fontSize: 18)
                    }
                    SeerrStatusTag(label: row.requestStatus.label, color: row.requestStatus.tone.color, fontSize: 18)
                }
            }
            .padding(16)
            .focusHighlight(isFocused, cornerRadius: CornerRadius.medium)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var requester: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(SashimiTheme.cardBackground)
                Image(systemName: "person.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(SashimiTheme.textTertiary)
                if let serverURL, let url = row.request.requestedBy?.avatarURL(server: serverURL) {
                    LazyImage(url: url) { state in
                        if let image = state.image { image.resizable().scaledToFill() }
                    }
                    .clipShape(Circle())
                }
            }
            .frame(width: 30, height: 30)
            Text(row.requesterName)
                .font(Typography.caption)
                .foregroundStyle(SashimiTheme.textSecondary)
        }
    }

    private var accessibilityText: String {
        var parts = [row.title, row.kindLabel, row.requestedLabel(), row.requestStatus.label]
        if showsRequester { parts.insert("by \(row.requesterName)", at: 2) }
        if let media = row.mediaStatus { parts.append(media.label) }
        return parts.joined(separator: ", ")
    }
}
