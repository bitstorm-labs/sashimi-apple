import XCTest
@testable import Sashimi

final class JellyfinClientTests: XCTestCase {

    // MARK: - URL Building Tests

    func testImageURLConstruction() async {
        let client = JellyfinClient.shared
        await client.configure(serverURL: URL(string: "http://localhost:8096")!)

        let imageURL = await client.imageURL(itemId: "test-item-123", imageType: "Primary", maxWidth: 400)

        XCTAssertNotNil(imageURL)
        XCTAssertEqual(imageURL?.host, "localhost")
        XCTAssertEqual(imageURL?.port, 8096)
        XCTAssertTrue(imageURL?.path.contains("test-item-123") ?? false)
        XCTAssertTrue(imageURL?.path.contains("Primary") ?? false)
    }

    func testBuildURLWithPath() async {
        let client = JellyfinClient.shared
        await client.configure(serverURL: URL(string: "https://jellyfin.example.com:443")!)

        let url = await client.buildURL(path: "/Users/Test")

        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "jellyfin.example.com")
        XCTAssertEqual(url?.path, "/Users/Test")
    }

    func testPlaybackURLConstruction() async {
        let client = JellyfinClient.shared
        await client.configure(serverURL: URL(string: "http://192.168.1.100:8096")!, accessToken: "test-token")

        let playbackURL = await client.getPlaybackURL(
            itemId: "video-123",
            mediaSourceId: "source-456",
            container: "mp4"
        )

        XCTAssertNotNil(playbackURL)
        XCTAssertTrue(playbackURL?.absoluteString.contains("video-123") ?? false)
        XCTAssertTrue(playbackURL?.absoluteString.contains("source-456") ?? false)
    }

    func testHLSStreamURLConstruction() async {
        let client = JellyfinClient.shared
        await client.configure(serverURL: URL(string: "http://localhost:8096")!, accessToken: "test-token")

        let hlsURL = await client.getHLSStreamURL(
            itemId: "movie-789",
            mediaSourceId: "source-123",
            subtitleStreamIndex: 1
        )

        XCTAssertNotNil(hlsURL)
        XCTAssertTrue(hlsURL?.absoluteString.contains("master.m3u8") ?? false)
        XCTAssertTrue(hlsURL?.absoluteString.contains("movie-789") ?? false)
    }

    // MARK: - Response Parsing Tests

    func testAuthenticationResultDecoding() throws {
        let json = """
        {
            "AccessToken": "test-access-token-12345",
            "ServerId": "server-456",
            "User": {
                "Id": "user-123",
                "Name": "TestUser"
            }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let result = try decoder.decode(AuthenticationResult.self, from: json)

        XCTAssertEqual(result.accessToken, "test-access-token-12345")
        XCTAssertEqual(result.serverId, "server-456")
        XCTAssertEqual(result.user.id, "user-123")
        XCTAssertEqual(result.user.name, "TestUser")
    }

    func testPlaybackInfoResponseDecoding() throws {
        let json = """
        {
            "MediaSources": [
                {
                    "Id": "source-1",
                    "Container": "mkv",
                    "SupportsDirectPlay": true,
                    "SupportsTranscoding": true,
                    "MediaStreams": [
                        {
                            "Type": "Video",
                            "Index": 0,
                            "Codec": "h264",
                            "Width": 1920,
                            "Height": 1080
                        },
                        {
                            "Type": "Audio",
                            "Index": 1,
                            "Codec": "aac",
                            "Language": "eng",
                            "DisplayTitle": "English AAC"
                        }
                    ]
                }
            ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let response = try decoder.decode(PlaybackInfoResponse.self, from: json)

        guard let mediaSources = response.mediaSources else {
            XCTFail("mediaSources should not be nil")
            return
        }

        XCTAssertEqual(mediaSources.count, 1)

        let source = mediaSources[0]
        XCTAssertEqual(source.id, "source-1")
        XCTAssertEqual(source.container, "mkv")
        XCTAssertTrue(source.supportsDirectPlay ?? false)
        XCTAssertEqual(source.mediaStreams?.count, 2)

        let videoStream = source.mediaStreams?.first { $0.type == "Video" }
        XCTAssertNotNil(videoStream)
        XCTAssertEqual(videoStream?.codec, "h264")
        XCTAssertEqual(videoStream?.width, 1920)
        XCTAssertEqual(videoStream?.height, 1080)

        let audioStream = source.mediaStreams?.first { $0.type == "Audio" }
        XCTAssertNotNil(audioStream)
        XCTAssertEqual(audioStream?.language, "eng")
    }

    func testItemsResponseDecoding() throws {
        let json = """
        {
            "Items": [
                {
                    "Id": "item-1",
                    "Name": "Movie 1",
                    "Type": "Movie"
                },
                {
                    "Id": "item-2",
                    "Name": "Movie 2",
                    "Type": "Movie"
                }
            ],
            "TotalRecordCount": 100
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let response = try decoder.decode(ItemsResponse.self, from: json)

        XCTAssertEqual(response.items.count, 2)
        XCTAssertEqual(response.totalRecordCount, 100)
        XCTAssertEqual(response.items[0].name, "Movie 1")
        XCTAssertEqual(response.items[1].name, "Movie 2")
    }

    func testLibraryViewsDecoding() throws {
        let json = """
        {
            "Items": [
                {
                    "Id": "lib-1",
                    "Name": "Movies",
                    "CollectionType": "movies"
                },
                {
                    "Id": "lib-2",
                    "Name": "TV Shows",
                    "CollectionType": "tvshows"
                }
            ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let response = try decoder.decode(LibraryViewsResponse.self, from: json)

        XCTAssertEqual(response.items.count, 2)
        XCTAssertEqual(response.items[0].id, "lib-1")
        XCTAssertEqual(response.items[0].name, "Movies")
        XCTAssertEqual(response.items[0].collectionType, "movies")
    }

    // MARK: - Media Segment Type Tests

    func testMediaSegmentTypeRawValues() {
        XCTAssertEqual(MediaSegmentType.intro.rawValue, "Introduction")
        XCTAssertEqual(MediaSegmentType.outro.rawValue, "Credits")
        XCTAssertEqual(MediaSegmentType.preview.rawValue, "Preview")
        XCTAssertEqual(MediaSegmentType.recap.rawValue, "Recap")
    }

    func testMediaSegmentTypeDisplayNames() {
        XCTAssertEqual(MediaSegmentType.intro.displayName, "Intro")
        XCTAssertEqual(MediaSegmentType.outro.displayName, "Credits")
        XCTAssertEqual(MediaSegmentType.preview.displayName, "Preview")
        XCTAssertEqual(MediaSegmentType.recap.displayName, "Recap")
        XCTAssertEqual(MediaSegmentType.unknown.displayName, "Segment")
    }

    // MARK: - Intro Skipper Segment Tests

    func testIntroSkipperSegmentDecoding() throws {
        let json = """
        {
            "Start": 0.0,
            "End": 90.5
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let segment = try decoder.decode(IntroSkipperSegment.self, from: json)

        XCTAssertEqual(segment.start, 0.0, accuracy: 0.001)
        XCTAssertEqual(segment.end, 90.5, accuracy: 0.001)
    }

    // MARK: - Virtual Folder Tests

    func testVirtualFolderDecoding() throws {
        let json = """
        [
            {
                "Name": "Movies",
                "CollectionType": "movies",
                "ItemId": "folder-1"
            },
            {
                "Name": "TV Shows",
                "CollectionType": "tvshows",
                "ItemId": "folder-2"
            }
        ]
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let folders = try decoder.decode([VirtualFolderInfo].self, from: json)

        XCTAssertEqual(folders.count, 2)
        XCTAssertEqual(folders[0].name, "Movies")
        XCTAssertEqual(folders[1].name, "TV Shows")
    }

    // MARK: - Chapter Tests

    func testChapterDecoding() throws {
        let json = """
        {
            "StartPositionTicks": 0,
            "Name": "Chapter 1"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let chapter = try decoder.decode(ChapterInfo.self, from: json)

        XCTAssertEqual(chapter.startPositionTicks, 0)
        XCTAssertEqual(chapter.name, "Chapter 1")
    }

    func testChapterStartSeconds() {
        let chapter = ChapterInfo(startPositionTicks: 36_000_000_000, name: "Test Chapter", imageTag: nil)
        XCTAssertEqual(chapter.startSeconds, 3600, accuracy: 0.001) // 1 hour
    }

    // MARK: - Media Source Helper Tests

    func testMediaSourceVideoResolution() throws {
        let json = """
        {
            "Id": "source-1",
            "MediaStreams": [
                {
                    "Type": "Video",
                    "Index": 0,
                    "Codec": "h264",
                    "Width": 3840,
                    "Height": 2160
                }
            ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let source = try decoder.decode(MediaSourceInfo.self, from: json)

        XCTAssertEqual(source.videoResolution, "4K")
        XCTAssertEqual(source.videoCodec, "h264")
    }

    func testMediaSource1080pResolution() throws {
        let json = """
        {
            "Id": "source-1",
            "MediaStreams": [
                {
                    "Type": "Video",
                    "Index": 0,
                    "Height": 1080
                }
            ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let source = try decoder.decode(MediaSourceInfo.self, from: json)

        XCTAssertEqual(source.videoResolution, "1080p")
    }
}
