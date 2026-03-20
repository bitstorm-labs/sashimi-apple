import SwiftUI

struct PhoneLibrariesTab: View {
    @State private var libraries: [JellyfinLibrary] = []

    var body: some View {
        List(libraries) { library in
            NavigationLink {
                MobileLibraryBrowseView(
                    libraryId: library.id,
                    libraryName: library.name,
                    collectionType: library.collectionType
                )
                .navigationTitle(library.name)
            } label: {
                Label(library.name, systemImage: iconFor(library.collectionType))
            }
            .listRowBackground(MobileColors.cardBackground)
        }
        .listStyle(.plain)
        .navigationTitle("Libraries")
        .task {
            do {
                libraries = try await JellyfinClient.shared.getLibraryViews()
            } catch {
                // Silently fail
            }
        }
    }

    private func iconFor(_ collectionType: String?) -> String {
        switch collectionType {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        default: return "folder"
        }
    }
}
