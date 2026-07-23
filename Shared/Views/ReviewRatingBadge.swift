import SwiftUI

/// Community (TMDb) review-rating chip shown on cover art (bottom-left corner).
/// Mirrors `QualityBadge`'s dark translucent slate styling but pairs the TMDb
/// logo with the `communityRating` formatted to one decimal (e.g. "8.0").
///
/// Sizing is parameterized so the 10-ft tvOS grid can render larger than the
/// compact iOS grid while keeping identical styling. Driven by
/// `BaseItemDto.communityRating` and gated on the `showReviewRatings` setting.
struct ReviewRatingBadge: View {
    let rating: Double
    var fontSize: CGFloat = 12
    var logoHeight: CGFloat = 12
    var spacing: CGFloat = 4
    var horizontalPadding: CGFloat = 6
    var verticalPadding: CGFloat = 3
    var cornerRadius: CGFloat = 6

    var body: some View {
        HStack(spacing: spacing) {
            Image("TMDBLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: logoHeight)
            Text(String(format: "%.1f", rating))
                .font(.system(size: fontSize, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(Color.black.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}
