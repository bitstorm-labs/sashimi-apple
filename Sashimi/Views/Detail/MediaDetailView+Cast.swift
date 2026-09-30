import SwiftUI

extension MediaDetailView {
    // MARK: - Cast
    func castSection(_ people: [PersonInfo]) -> some View {
        let cast = PersonInfo.sortedForDisplay(people)

        return VStack(alignment: .leading, spacing: 16) {
            Text("Cast & Crew")
                .font(.headline)
                .foregroundStyle(SashimiTheme.textPrimary)
                .padding(.horizontal, 60)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(cast) { person in
                        CastCard(person: person, serverID: serverID) {
                            showingPersonDetail = person
                        }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 20)
            }
            .focusSection()
        }
    }
}
