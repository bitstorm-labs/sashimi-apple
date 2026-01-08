import SwiftUI

struct LibraryView: View {
    @State private var libraries: [LibraryView_Model] = []
    @State private var selectedLibrary: LibraryView_Model?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 300, maximum: 400), spacing: 40)
                    ], spacing: 40) {
                        ForEach(libraries) { library in
                            NavigationLink(value: library) {
                                LibraryCard(library: library)
                            }
                            .buttonStyle(CardButtonStyle())
                        }
                    }
                    .padding(60)
                }
            }
            .navigationDestination(for: LibraryView_Model.self) { library in
                LibraryDetailView(library: library)
            }
        }
        .task {
            await loadLibraries()
        }
    }

    private func loadLibraries() async {
        do {
            let views = try await JellyfinClient.shared.getLibraryViews()
            libraries = views.map { LibraryView_Model(from: $0) }
        } catch {
            ToastManager.shared.show("Failed to load libraries")
        }
        isLoading = false
    }
}

struct LibraryView_Model: Identifiable, Hashable {
    let id: String
    let name: String
    let collectionType: String?

    init(from library: JellyfinLibrary) {
        self.id = library.id
        self.name = library.name
        self.collectionType = library.collectionType
    }
}

struct LibraryCard: View {
    let library: LibraryView_Model

    var body: some View {
        VStack {
            AsyncItemImage(
                itemId: library.id,
                imageType: "Primary",
                maxWidth: 400
            )
            .frame(width: 300, height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.black.opacity(0.4))

                Text(library.name)
                    .font(.title3)
                    .fontWeight(.semibold)
            }
        }
    }
}

struct LibraryDetailView: View {
    let library: LibraryView_Model

    @State private var items: [BaseItemDto] = []
    @State private var isLoading = true
    @State private var selectedItem: BaseItemDto?

    // Detect YouTube library by name
    private var isYouTubeLibrary: Bool {
        library.name.lowercased().contains("youtube")
    }

    private var gridColumns: [GridItem] {
        if isYouTubeLibrary {
            return [GridItem(.adaptive(minimum: 300, maximum: 340), spacing: 24)]
        }
        return [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 30)]
    }

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView()
            } else {
                LazyVGrid(columns: gridColumns, spacing: isYouTubeLibrary ? 30 : 40) {
                    ForEach(items) { item in
                        MediaPosterButton(item: item, isLandscape: isYouTubeLibrary) {
                            selectedItem = item
                        }
                    }
                }
                .padding(60)
            }
        }
        .navigationTitle(library.name)
        .task {
            await loadItems()
        }
        .fullScreenCover(item: $selectedItem) { item in
            MediaDetailView(item: item, forceYouTubeStyle: isYouTubeLibrary)
        }
        .onChange(of: selectedItem) { oldValue, newValue in
            if oldValue != nil && newValue == nil {
                Task { await loadItems() }
            }
        }
    }

    private func loadItems() async {
        do {
            let includeTypes: [ItemType]? = switch library.collectionType {
            case "tvshows": [.series]
            case "movies": [.movie]
            default: nil
            }

            let response = try await JellyfinClient.shared.getItems(
                parentId: library.id,
                includeTypes: includeTypes,
                sortBy: "SortName",
                limit: 100
            )
            items = response.items
        } catch {
            ToastManager.shared.show("Failed to load library items")
        }
        isLoading = false
    }
}
