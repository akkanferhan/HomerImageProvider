import Foundation
import Photos

/// The origin of an image that ``HomerImageProviderManager`` can resolve.
///
/// Three transports are supported, picked at the call site:
///
/// - ``network(_:)`` for an `https://` (or `http://`) URL.
/// - ``photos(localIdentifier:)`` for an asset that lives in the user's
///   Photos library, addressed by `PHAsset.localIdentifier`.
/// - ``file(_:)`` for a local file URL.
///
/// `HomerImageSource` is `Sendable` and `Hashable`, so it can travel
/// across actor boundaries and be used as a cache key directly. The
/// stable string form lives on ``cacheKey``.
public enum HomerImageSource: Sendable, Hashable {
    /// A remote image fetched over HTTP / HTTPS.
    case network(URL)
    /// An asset in the user's Photos library, identified by
    /// `PHAsset.localIdentifier`.
    case photos(localIdentifier: String)
    /// An image read from a local file URL.
    case file(URL)

    /// Stable string identifier used as the cache key for this source.
    ///
    /// - Network: the absolute URL string.
    /// - Photos: `phasset://<localIdentifier>` (the prefix prevents
    ///   collisions with file paths that happen to look identical).
    /// - File: the percent-decoded file system path.
    public var cacheKey: String {
        switch self {
        case .network(let url):
            return url.absoluteString
        case .photos(let id):
            return "phasset://\(id)"
        case .file(let url):
            return url.path(percentEncoded: false)
        }
    }
}
