import XCTest
@testable import Sashimi

/// Image URLs carry Jellyfin's image `tag` so a picture replaced on the server
/// gets a new URL — and so a new image-cache key — instead of the stale copy.
final class ImageTagURLTests: XCTestCase {
    private let server = URL(string: "http://jf.local:8096")!

    /// An episode as the server returns it: own tags plus its series' tags.
    private func decodedEpisode() throws -> BaseItemDto {
        let json = """
        {
          "Id": "ep1", "Name": "Pilot", "Type": "Episode",
          "SeriesId": "series1", "SeasonId": "season1",
          "ImageTags": { "Primary": "epPrimaryTag" },
          "BackdropImageTags": [],
          "ParentBackdropItemId": "series1",
          "ParentBackdropImageTags": ["seriesBackdropTag", "secondBackdrop"],
          "ParentThumbItemId": "series1",
          "ParentThumbImageTag": "seriesThumbTag",
          "ParentLogoItemId": "series1",
          "ParentLogoImageTag": "seriesLogoTag",
          "SeriesPrimaryImageTag": "seriesPrimaryTag"
        }
        """
        return try JSONDecoder().decode(BaseItemDto.self, from: Data(json.utf8))
    }

    private func tagQuery(_ url: URL?) -> String? {
        guard let url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "tag" }?.value
    }

    // MARK: - URL builder

    func testSyncImageURLIncludesTagWhenGiven() {
        let url = JellyfinClient.shared.syncImageURL(
            itemId: "ep1", imageType: "Primary", maxWidth: 400, tag: "abc123", serverURL: server
        )
        XCTAssertEqual(url?.path, "/Items/ep1/Images/Primary")
        XCTAssertEqual(tagQuery(url), "abc123")
        XCTAssertTrue(url?.query?.contains("maxWidth=400") ?? false)
    }

    func testSyncImageURLOmitsTagWhenNil() {
        let url = JellyfinClient.shared.syncImageURL(
            itemId: "ep1", imageType: "Primary", maxWidth: 400, serverURL: server
        )
        XCTAssertNotNil(url)
        XCTAssertFalse(url?.query?.contains("tag") ?? true)
    }

    func testActorImageURLIncludesTag() async {
        let client = JellyfinClient.shared
        await client.configure(serverURL: server)
        let url = await client.imageURL(itemId: "x", imageType: "Backdrop", maxWidth: 1280, tag: "bk")
        XCTAssertEqual(tagQuery(url), "bk")
    }

    func testPersonImageURLIncludesTag() {
        let url = JellyfinClient.shared.personImageURL(personId: "p1", maxWidth: 200, tag: "face", serverURL: server)
        XCTAssertEqual(tagQuery(url), "face")
    }

    // MARK: - Item → tag mapping

    func testEpisodeOwnImagesUseItsImageTags() throws {
        let episode = try decodedEpisode()
        XCTAssertEqual(episode.imageTag(for: "Primary", itemId: "ep1"), "epPrimaryTag")
        // The episode has no Thumb or backdrop of its own.
        XCTAssertNil(episode.imageTag(for: "Thumb", itemId: "ep1"))
        XCTAssertNil(episode.imageTag(for: "Backdrop", itemId: "ep1"))
    }

    func testEpisodeSeriesImagesUseParentTags() throws {
        let episode = try decodedEpisode()
        XCTAssertEqual(episode.imageTag(for: "Backdrop", itemId: "series1"), "seriesBackdropTag")
        XCTAssertEqual(episode.imageTag(for: "Thumb", itemId: "series1"), "seriesThumbTag")
        XCTAssertEqual(episode.imageTag(for: "Logo", itemId: "series1"), "seriesLogoTag")
        XCTAssertEqual(episode.imageTag(for: "Primary", itemId: "series1"), "seriesPrimaryTag")
        // Nothing describes the season's images, so no tag is guessed.
        XCTAssertNil(episode.imageTag(for: "Primary", itemId: "season1"))
    }

    func testOwnBackdropUsesFirstBackdropTag() {
        let movie = BaseItemDto(
            id: "m1", name: "Movie", type: .movie,
            seriesName: nil, seriesId: nil, seasonId: nil, parentId: nil,
            indexNumber: nil, parentIndexNumber: nil, overview: nil,
            runTimeTicks: nil, userData: nil, imageTags: ["Primary": "poster"],
            backdropImageTags: ["bd0", "bd1"], parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, libraryName: nil, productionYear: nil,
            communityRating: nil, officialRating: nil, genres: nil,
            taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil,
            localTrailerCount: nil, mediaStreams: nil
        )
        XCTAssertEqual(movie.imageTag(for: "Backdrop", itemId: "m1"), "bd0")
        XCTAssertEqual(movie.imageTag(for: "Primary", itemId: "m1"), "poster")
    }

    /// The up-next card's production URL builder: the episode still carries
    /// the episode's Primary tag, the series fallbacks carry the parent tags.
    func testUpNextURLsCarryTheTagOfEachRequestedImage() throws {
        let episode = try decodedEpisode()
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: "serverURL")
        defaults.set(server.absoluteString, forKey: "serverURL")
        defer { defaults.set(saved, forKey: "serverURL") }

        let thumbs = EpisodeUpNextScreen.serverImageURLs(for: episode, role: .thumbnail, serverID: nil)
        XCTAssertEqual(thumbs.map(\.path), [
            "/Items/ep1/Images/Primary", "/Items/series1/Images/Thumb", "/Items/series1/Images/Backdrop"
        ])
        XCTAssertEqual(thumbs.map(tagQuery), ["epPrimaryTag", "seriesThumbTag", "seriesBackdropTag"])
    }

    // MARK: - One-time cache reset

    private func freshDefaults() -> UserDefaults {
        let name = "ImageCacheResetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testCacheResetRunsOnceThenNeverAgain() {
        let defaults = freshDefaults()
        var clears = 0
        XCTAssertTrue(ImageCacheReset.runIfNeeded(defaults: defaults) { clears += 1 })
        XCTAssertFalse(ImageCacheReset.runIfNeeded(defaults: defaults) { clears += 1 })
        XCTAssertFalse(ImageCacheReset.runIfNeeded(defaults: defaults) { clears += 1 })
        XCTAssertEqual(clears, 1)
        XCTAssertEqual(defaults.integer(forKey: ImageCacheReset.defaultsKey), ImageCacheReset.currentVersion)
    }

    func testCacheResetSkipsWhenAlreadyAtCurrentVersion() {
        let defaults = freshDefaults()
        defaults.set(ImageCacheReset.currentVersion, forKey: ImageCacheReset.defaultsKey)
        var clears = 0
        ImageCacheReset.runIfNeeded(defaults: defaults) { clears += 1 }
        XCTAssertEqual(clears, 0)
    }
}
