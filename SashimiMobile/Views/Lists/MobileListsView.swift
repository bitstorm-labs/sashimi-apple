import SwiftUI
import NukeUI

/// The Lists destination on iPhone (from Libraries) and iPad/Mac (the side
/// menu): your lists, then everyone's public lists.
struct MobileListsView: View {
    @StateObject private var model = ListsPageViewModel()
    @ObservedObject private var store = SharedListsStore.shared
    @State private var creating = false

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 260), spacing: MobileSpacing.md, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileSpacing.xl) {
                if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    section("Your lists") {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: MobileSpacing.md) {
                            ForEach(model.mine) { card in
                                cardLink(card, isOwn: true)
                            }
                            Button { creating = true } label: {
                                // A definite 16:9 frame with the label laid over it,
                                // the same size as a list's cover.
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(MobileColors.textTertiary, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .overlay {
                                        Label("New List", systemImage: "plus")
                                            .font(MobileTypography.title)
                                            .foregroundStyle(MobileColors.textSecondary)
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    section("From others") {
                        if model.others.isEmpty {
                            Text(model.failed ? "Couldn't load lists." : "No one has shared a list yet.")
                                .font(MobileTypography.body)
                                .foregroundStyle(MobileColors.textTertiary)
                        } else {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: MobileSpacing.md) {
                                ForEach(model.others) { card in
                                    cardLink(card, isOwn: false)
                                }
                            }
                        }
                    }
                }
            }
            .padding(MobileSpacing.md)
        }
        .background(MobileColors.background)
        .navigationTitle("Lists")
        .refreshable { await model.load() }
        .task { await model.load() }
        .sheet(isPresented: $creating) {
            MobileNewListSheet(title: "New List", confirmTitle: "Create") { name, isPublic in
                Task {
                    _ = await model.create(name: name, isPublic: isPublic)
                    creating = false
                }
            }
            .dismissesOnOutsideTap()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            Text(title)
                .font(MobileTypography.headline)
                .foregroundStyle(MobileColors.textPrimary)
            content()
        }
    }

    private func cardLink(_ card: ListCard, isOwn: Bool) -> some View {
        NavigationLink {
            MobileListDetailView(list: card.list)
        } label: {
            MobileListCard(card: card, isOwn: isOwn, isSubscribed: store.isSubscribed(card.id))
        }
        .buttonStyle(.plain)
    }
}

struct MobileListCard: View {
    let card: ListCard
    let isOwn: Bool
    let isSubscribed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.xxs) {
            MobileListCover(card: card)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topTrailing) {
                    if isSubscribed {
                        Label("Subscribed", systemImage: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.75), in: Capsule())
                            .padding(6)
                    }
                }
            Text(card.list.name)
                .font(MobileTypography.title)
                .foregroundStyle(MobileColors.textPrimary)
                .lineLimit(1)
            Text(card.subtitle(isOwn: isOwn))
                .font(MobileTypography.caption)
                .foregroundStyle(MobileColors.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The first four different titles as a 2x2 collage of posters, or the
/// first title's poster alone (`SharedLists.coverPosterIds`).
struct MobileListCover: View {
    let card: ListCard

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                MobileColors.cardBackground
                if card.coverIds.count == 4 {
                    let cell = CGSize(width: geometry.size.width / 2, height: geometry.size.height / 2)
                    VStack(spacing: 0) {
                        ForEach(0..<2, id: \.self) { row in
                            HStack(spacing: 0) {
                                ForEach(0..<2, id: \.self) { column in
                                    poster(card.coverIds[row * 2 + column], width: cell.width)
                                        .frame(width: cell.width, height: cell.height)
                                        .clipped()
                                }
                            }
                        }
                    }
                } else if let first = card.coverIds.first {
                    poster(first, width: geometry.size.width)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 30))
                        .foregroundStyle(MobileColors.textTertiary)
                }
            }
        }
    }

    private func poster(_ itemId: String, width: CGFloat) -> some View {
        LazyImage(url: JellyfinClient.shared.syncImageURL(
            itemId: itemId, imageType: "Primary", maxWidth: ImageSizing.pixelWidth(points: width)
        )) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            }
        }
        .pipeline(SashimiImagePipeline.shared)
    }
}

/// Name and Public switch for a new list.
struct MobileNewListSheet: View {
    let title: String
    let confirmTitle: String
    let onCreate: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isPublic = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Section {
                    Toggle("Public", isOn: $isPublic)
                } footer: {
                    Text(isPublic ? ListText.publicFootnote : "Only you can see it.")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) { onCreate(name, isPublic) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
