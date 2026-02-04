import SwiftUI

struct MobileMediaRow<Destination: View>: View {
    let title: String
    let items: [BaseItemDto]
    let libraryName: String?
    let cardWidth: CGFloat
    let showProgress: Bool
    let destination: (BaseItemDto) -> Destination

    init(
        title: String,
        items: [BaseItemDto],
        libraryName: String? = nil,
        cardWidth: CGFloat = MobileSizing.posterWidth,
        showProgress: Bool = true,
        @ViewBuilder destination: @escaping (BaseItemDto) -> Destination
    ) {
        self.title = title
        self.items = items
        self.libraryName = libraryName
        self.cardWidth = cardWidth
        self.showProgress = showProgress
        self.destination = destination
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            // Section header
            HStack {
                Text(title)
                    .font(MobileTypography.headline)
                    .foregroundStyle(MobileColors.textPrimary)

                Spacer()

                if items.count > 6 {
                    NavigationLink {
                        MobileMediaGridView(title: title, items: items, libraryName: libraryName, destination: destination)
                    } label: {
                        Text("See All")
                            .font(MobileTypography.body)
                            .foregroundStyle(MobileColors.accent)
                    }
                }
            }
            .padding(.horizontal, MobileSpacing.md)

            // Horizontal scroll
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: MobileSpacing.sm) {
                    ForEach(items, id: \.id) { item in
                        NavigationLink {
                            destination(item)
                        } label: {
                            MobileMediaPosterButton(
                                item: item,
                                width: cardWidth,
                                showProgress: showProgress,
                                libraryName: libraryName
                            ) {
                                // Navigation is handled by NavigationLink
                            }
                            .disabled(true) // Disable button, let NavigationLink handle tap
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, MobileSpacing.md)
            }
        }
    }
}

// MARK: - Grid View for "See All"

struct MobileMediaGridView<Destination: View>: View {
    let title: String
    let items: [BaseItemDto]
    let libraryName: String?
    let destination: (BaseItemDto) -> Destination

    private let columns = [
        GridItem(.adaptive(minimum: MobileSizing.posterWidth), spacing: MobileSpacing.md)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: MobileSpacing.md) {
                ForEach(items, id: \.id) { item in
                    NavigationLink {
                        destination(item)
                    } label: {
                        MobileMediaPosterButton(
                            item: item,
                            libraryName: libraryName
                        ) {
                            // Navigation handled by NavigationLink
                        }
                        .disabled(true)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(MobileSpacing.md)
        }
        .navigationTitle(title)
    }
}
