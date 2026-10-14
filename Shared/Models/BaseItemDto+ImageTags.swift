import Foundation

/// Jellyfin image tags: an opaque hash that changes whenever the image behind
/// `/Items/{id}/Images/{type}` changes. Image URLs carry it as `?tag=` so the
/// URL — and therefore Nuke's disk/memory cache key — changes with the
/// picture. Without it a re-fetched (e.g. higher-resolution) server image is
/// never seen by a device that already cached the old one.
extension BaseItemDto {
    /// The tag for image `imageType` of item `itemId`, as known to this item.
    ///
    /// `itemId` may be this item itself or one of its parents (an episode
    /// shows the series backdrop/thumb/logo/poster), so the lookup is keyed
    /// on which item the URL actually points at: own images come from
    /// `ImageTags` / `BackdropImageTags`, parent images from the `Parent…` /
    /// `Series…` tag fields. Returns nil when the tag is unknown — the URL is
    /// then built without one, exactly as before.
    func imageTag(for imageType: String, itemId: String) -> String? {
        if itemId == id {
            if imageType == "Backdrop" { return backdropImageTags?.first }
            return imageTags?[imageType]
        }
        switch imageType {
        case "Backdrop":
            guard isParent(itemId, declared: parentBackdropItemId) else { return nil }
            return parentBackdropImageTags?.first
        case "Thumb":
            if isParent(itemId, declared: parentThumbItemId), let parentThumbImageTag {
                return parentThumbImageTag
            }
            return itemId == seriesId ? seriesThumbImageTag : nil
        case "Logo":
            guard isParent(itemId, declared: parentLogoItemId) else { return nil }
            return parentLogoImageTag
        case "Primary":
            return itemId == seriesId ? seriesPrimaryImageTag : nil
        default:
            return nil
        }
    }

    /// Whether `itemId` is the parent a `Parent…ImageTag` field describes.
    /// Jellyfin names that parent in `Parent…ItemId`; older responses that
    /// omit it describe the series.
    private func isParent(_ itemId: String, declared: String?) -> Bool {
        if let declared { return itemId == declared }
        return itemId == seriesId
    }
}
