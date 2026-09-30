import AVFoundation
import UniformTypeIdentifiers

/// Serves one multivariant playlist to AVPlayer from memory (#449).
///
/// AVPlayer only asks an `AVAssetResourceLoaderDelegate` for URLs it cannot
/// load itself, so the asset is created with a private scheme
/// (`sashimi-hls://`) and the playlist handed back here. Every URI inside the
/// playlist is absolute HTTP(S) (see
/// `HLSMultivariantPlaylist.primaryVariantPlaylistKeepingImageStreams`), so
/// media playlists, segments and trickplay tiles are fetched by AVPlayer
/// directly, exactly as before — this object only ever answers the one master
/// request.
///
/// `AVAssetResourceLoader` holds its delegate weakly: whoever creates the
/// asset must keep this object alive for as long as the asset is in use.
final class HLSPlaylistResourceLoader: NSObject, AVAssetResourceLoaderDelegate, Sendable {
    static let scheme = "sashimi-hls"

    /// The URL to create the `AVURLAsset` with. It names nothing on the
    /// server — every URI inside the playlist is absolute — so it carries no
    /// host or query (the real master's query holds the api_key). The
    /// `.m3u8` path keeps diagnostics reading as a playlist.
    let assetURL: URL
    private let playlist: Data
    private let queue = DispatchQueue(label: "com.mondominator.sashimi.hls-playlist-loader")

    init?(playlist: String) {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "playlist"
        components.path = "/\(UUID().uuidString)/master.m3u8"
        guard let assetURL = components.url else { return nil }
        self.assetURL = assetURL
        self.playlist = Data(playlist.utf8)
    }

    /// An asset that loads its master playlist from this object. The delegate
    /// is attached before anything can start loading the asset.
    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: assetURL)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard loadingRequest.request.url == assetURL else { return false }

        if let info = loadingRequest.contentInformationRequest {
            info.contentType = UTType.m3uPlaylist.identifier
            info.contentLength = Int64(playlist.count)
            info.isByteRangeAccessSupported = false
        }
        if let dataRequest = loadingRequest.dataRequest {
            dataRequest.respond(with: Self.slice(of: playlist, for: dataRequest))
        }
        loadingRequest.finishLoading()
        return true
    }

    /// The bytes a data request asks for, clamped to the playlist.
    static func slice(of data: Data, for dataRequest: AVAssetResourceLoadingDataRequest) -> Data {
        slice(
            of: data,
            offset: dataRequest.currentOffset,
            length: dataRequest.requestsAllDataToEndOfResource ? nil : dataRequest.requestedLength
        )
    }

    static func slice(of data: Data, offset: Int64, length: Int?) -> Data {
        let start = min(max(Int(offset), 0), data.count)
        let end = length.map { min(start + max($0, 0), data.count) } ?? data.count
        return data.subdata(in: start..<end)
    }
}
