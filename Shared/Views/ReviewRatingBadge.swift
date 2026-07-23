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

extension BaseItemDto {
    /// Community (TMDb) rating to display on a cover badge, honoring the
    /// `useEpisodeRatings` setting.
    ///
    /// A TV episode carries its own per-episode `communityRating`, which reads
    /// as the *episode's* score — misleading on a cover that stands in for the
    /// whole series. The episode DTO does not carry the series' overall rating
    /// (detail views fetch the series separately for that), so unless the user
    /// opts into episode-level ratings we suppress the badge on episode cards.
    /// Series and movie cards always use their own (correct) rating.
    ///
    /// Returns `nil` when no badge should render.
    func coverReviewRating(useEpisodeRatings: Bool) -> Double? {
        if type == .episode && !useEpisodeRatings { return nil }
        guard let rating = communityRating, rating > 0 else { return nil }
        return rating
    }
}
