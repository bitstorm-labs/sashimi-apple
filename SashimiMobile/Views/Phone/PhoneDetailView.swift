import SwiftUI

struct PhoneDetailView: View {
    let item: BaseItemDto
    var libraryName: String?

    var body: some View {
        Text(item.name)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MobileColors.background)
    }
}
