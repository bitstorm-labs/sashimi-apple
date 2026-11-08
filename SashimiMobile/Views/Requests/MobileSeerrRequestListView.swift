import NukeUI
import SwiftUI

/// The Requests page's request list on iPhone, iPad and Mac (#845): a
/// filter, Everyone / Mine for those allowed to see everyone's, and each
/// request with who asked and where it's at. Actions are swipes and the row's
/// menu, only those the account may use; the destructive ones ask first.
struct MobileSeerrRequestListView: View {
    let onOpen: (SeerrTarget) -> Void

    @StateObject private var model = SeerrRequestListModel()
    @ObservedObject private var session = SeerrSession.shared
    @State private var confirming: (action: SeerrRequestAction, row: SeerrRequestRow)?

    var body: some View {
        List {
            Section {
                filters
                if let count = model.count {
                    Text(count.summary)
                        .font(MobileTypography.caption)
                        .foregroundStyle(MobileColors.textTertiary)
                        .listRowBackground(Color.clear)
                }
                if let error = model.errorMessage, !model.rows.isEmpty {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(MobileTypography.caption)
                        .foregroundStyle(MobileColors.warning)
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                if model.rows.isEmpty {
                    emptyState
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(model.rows) { row in
                        rowView(row)
                    }
                    if model.canLoadMore {
                        ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await model.reload() }
        .task(id: "\(model.filter.rawValue)-\(model.scope.rawValue)-\(session.requestsRevision)") {
            await model.reload()
        }
        .confirmationDialog(
            "\(confirming?.action.title ?? "")?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { pending in
            Button(pending.action.title, role: .destructive) {
                Task { await model.perform(pending.action, on: pending.row) }
            }
            Button("Keep It", role: .cancel) {}
        } message: { pending in
            Text("\(pending.row.displayTitle), requested by \(pending.row.requesterName).")
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            if model.canChooseScope {
                Picker("Whose", selection: $model.scope) {
                    ForEach(SeerrRequestScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Picker("Show", selection: $model.filter) {
                ForEach(SeerrRequestFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
        }
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isLoading || !model.hasLoaded {
            ProgressView().frame(maxWidth: .infinity)
        } else if let error = model.errorMessage {
            ContentUnavailableView("Couldn't Load Requests", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ContentUnavailableView(
                model.filter == .all ? "No Requests Yet" : "No \(model.filter.title) Requests",
                systemImage: "tray",
                description: Text("Find something in Discover to request it.")
            )
        }
    }

    private func rowView(_ row: SeerrRequestRow) -> some View {
        let actions = model.actions(for: row)
        return Button {
            onOpen(row.target)
        } label: {
            MobileSeerrRequestListRow(
                row: row,
                showsRequester: model.showsRequester,
                serverURL: session.serverURL,
                isBusy: model.busy.contains(row.id)
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(MobileColors.cardBackground)
        .onAppear { Task { await model.loadMoreIfNeeded(after: row) } }
        .swipeActions(edge: .trailing) {
            ForEach(actions.filter(\.isDestructive)) { action in
                Button(action.title, systemImage: action.systemImage, role: .destructive) { confirming = (action, row) }
            }
        }
        .swipeActions(edge: .leading) {
            if actions.contains(.approve) {
                Button("Approve", systemImage: "checkmark.circle") {
                    Task { await model.perform(.approve, on: row) }
                }
                .tint(.green)
            }
        }
        .contextMenu {
            ForEach(actions) { action in
                Button(action.title, systemImage: action.systemImage, role: action.isDestructive ? .destructive : nil) {
                    if action.isDestructive {
                        confirming = (action, row)
                    } else {
                        Task { await model.perform(action, on: row) }
                    }
                }
            }
        }
    }
}

struct MobileSeerrRequestListRow: View {
    let row: SeerrRequestRow
    let showsRequester: Bool
    let serverURL: URL?
    let isBusy: Bool

    var body: some View {
        HStack(alignment: .top, spacing: MobileSpacing.sm) {
            SeerrArtwork(url: SeerrImages.poster(row.posterPath, width: 185), title: "", cornerRadius: 6)
                .frame(width: 48, height: 72)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(MobileTypography.title)
                    .foregroundStyle(MobileColors.textPrimary)
                    .lineLimit(2)
                Text("\(row.kindLabel) \u{00B7} \(row.requestedLabel())")
                    .font(MobileTypography.caption)
                    .foregroundStyle(MobileColors.textTertiary)
                if showsRequester {
                    requester
                }
                HStack(spacing: 6) {
                    SeerrStatusTag(label: row.requestStatus.label, color: row.requestStatus.tone.color, fontSize: 11)
                    if let media = row.mediaStatus {
                        SeerrStatusTag(label: media.label, color: media.tone.color, fontSize: 11)
                    }
                    if isBusy { ProgressView().controlSize(.small) }
                }
                if let progress = row.progress {
                    ProgressView(value: progress)
                        .tint(SeerrBadge.coming.color)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var requester: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(MobileColors.background)
                Image(systemName: "person.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(MobileColors.textTertiary)
                if let serverURL, let url = row.request.requestedBy?.avatarURL(server: serverURL) {
                    LazyImage(url: url) { state in
                        if let image = state.image { image.resizable().scaledToFill() }
                    }
                    .clipShape(Circle())
                }
            }
            .frame(width: 18, height: 18)
            Text(row.requesterName)
                .font(MobileTypography.caption)
                .foregroundStyle(MobileColors.textSecondary)
        }
    }
}
