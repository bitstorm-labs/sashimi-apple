import SwiftUI

struct MobileLibraryView: View {
    @StateObject private var viewModel = HomeViewModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if viewModel.isLoading && viewModel.libraries.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if viewModel.libraries.isEmpty {
                    ContentUnavailableView(
                        "No Libraries",
                        systemImage: "rectangle.stack",
                        description: Text("Connect to a Jellyfin server to see your libraries.")
                    )
                } else {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 150), spacing: 16)
                    ], spacing: 16) {
                        ForEach(viewModel.libraries, id: \.id) { library in
                            LibraryCard(library: library)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Library")
        .task {
            await viewModel.loadContent()
        }
    }
}

private struct LibraryCard: View {
    let library: JellyfinLibrary

    var body: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.2))
                .frame(height: 100)
                .overlay {
                    Image(systemName: iconName)
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)
                }

            Text(library.name)
                .font(.headline)
                .lineLimit(1)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var iconName: String {
        switch library.collectionType {
        case "movies":
            return "film"
        case "tvshows":
            return "tv"
        case "music":
            return "music.note"
        default:
            return "folder"
        }
    }
}
