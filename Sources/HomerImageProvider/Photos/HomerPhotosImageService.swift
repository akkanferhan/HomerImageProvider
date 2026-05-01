import Foundation
import Photos
import UIKit

/// Thin wrapper around `PHCachingImageManager` for the local-photos
/// fast path.
///
/// `HomerImageProviderManager.loadImage(.photos:)` walks the regular
/// PhotoKit flow (`PHAsset.fetchAssets(withLocalIdentifiers:)`,
/// `PHImageManager.default()`, `deliveryMode = .highQualityFormat`),
/// which is correct but slow. This service bypasses all of that:
///
/// - registered assets are kept in an in-memory map keyed by
///   `localIdentifier`, so repeated requests skip the PhotoKit fetch;
/// - thumbnails are pre-decoded by `PHCachingImageManager`'s caching
///   pipeline;
/// - the request options use `.opportunistic` mode, so callers
///   receive a degraded preview instantly followed by the final
///   quality image.
public final class HomerPhotosImageService: @unchecked Sendable {

    /// Process-wide shared instance. The PhotoKit caching manager
    /// underneath is itself process-wide, so a singleton matches the
    /// underlying lifecycle.
    public static let shared = HomerPhotosImageService()

    private let cachingManager = PHCachingImageManager()
    private let lock = NSLock()
    private var assets: [String: PHAsset] = [:]

    /// Shared `PHImageRequestOptions` reused across `startCachingImages`
    /// and `requestImage` calls. PhotoKit is documented to recognise
    /// the same thumbnail cache entry only when the caching call and
    /// the request call use options with identical fields, so reusing
    /// one instance keeps the cache hit rate high.
    ///
    /// `resizeMode` is intentionally left at PhotoKit's default —
    /// `.fast` can cause low-quality versions to stick when the
    /// requested size isn't already cached.
    ///
    /// ## Why the empty `progressHandler`
    /// CloudKit prioritises iCloud-photo download requests differently
    /// based on whether anyone is observing progress. Without a
    /// `progressHandler`, requests for iCloud-only assets are tagged
    /// as background / opportunistic and queued behind interactive
    /// traffic — even on fast connections, these requests frequently
    /// time out with `CloudPhotoLibraryErrorDomain Code 81` chained to
    /// `NSURLErrorDomain -1001`. Setting the handler — even with an
    /// empty body — promotes the request to "interactive" priority
    /// and dramatically reduces the timeout rate. The handler body
    /// stays empty because progress is not currently surfaced upward;
    /// a future revision can expose it through ``HomerImageDelivery``
    /// if call sites want to render a progress bar.
    private let sharedOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.progressHandler = { _, _, _, _ in }
        return options
    }()

    private init() {}

    /// Stores the supplied `PHAsset` array in the internal map,
    /// keyed by `localIdentifier`. Subsequent ``requestImage(for:targetSize:contentMode:handler:)``
    /// and ``startCaching(for:targetSize:contentMode:)`` calls read
    /// from this map directly instead of hitting PhotoKit again.
    ///
    /// Replaces the existing map atomically — the typical caller is
    /// "fetched assets, here is the new snapshot" rather than an
    /// incremental builder.
    public func register(assets: [PHAsset]) {
        var map: [String: PHAsset] = [:]
        map.reserveCapacity(assets.count)
        for asset in assets {
            map[asset.localIdentifier] = asset
        }
        lock.lock()
        self.assets = map
        lock.unlock()
    }

    /// Returns the cached `PHAsset` for `localIdentifier`, or `nil`
    /// when none has been registered.
    public func asset(for localIdentifier: String) -> PHAsset? {
        lock.lock()
        defer { lock.unlock() }
        return assets[localIdentifier]
    }

    /// Cell / grid thumbnail path. Goes through `PHCachingImageManager`
    /// using the shared `.opportunistic` options so the handler is
    /// invoked twice — first with a fast degraded preview, then with
    /// the full-quality result.
    ///
    /// The handler signature is `(image, isDegraded, error)`. When
    /// `image == nil`, `error` carries the cause (either the
    /// `PHImageErrorKey` value from the result `info` dictionary, or
    /// ``HomerImageError/photosAssetNotFound`` when `localIdentifier`
    /// has never been registered).
    /// - Returns: The PhotoKit request identifier so callers can
    ///   pass it to ``cancelThumbnail(_:)`` if the surrounding cell
    ///   gets reused before the request completes.
    @discardableResult
    public func requestImage(
        for localIdentifier: String,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill,
        handler: @escaping @Sendable (UIImage?, Bool, Error?) -> Void
    ) -> PHImageRequestID {
        guard let asset = resolveAsset(for: localIdentifier) else {
            handler(nil, false, HomerImageError.photosAssetNotFound)
            return PHInvalidImageRequestID
        }
        return cachingManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: contentMode,
            options: sharedOptions
        ) { image, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let error = info?[PHImageErrorKey] as? Error
            handler(image, isDegraded, error)
        }
    }

    /// Full-screen viewer (detail) path. Goes through
    /// `PHImageManager.default()` instead of the caching manager so
    /// the request doesn't sit behind the cell-decode queue that
    /// `requestImage(...)` is filling. The first callback delivers a
    /// degraded preview (a local thumbnail, no network); subsequent
    /// callbacks deliver the full-resolution image. Network access is
    /// enabled, so iCloud-only assets can fetch a preview.
    ///
    /// The handler signature mirrors ``requestImage(for:targetSize:contentMode:handler:)``.
    /// When the final quality cannot be produced, the handler is
    /// invoked with `image == nil` and `error` (when present, taken
    /// from `PHImageErrorKey`).
    @discardableResult
    public func requestFullScreenImage(
        for localIdentifier: String,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFit,
        handler: @escaping @Sendable (UIImage?, Bool, Error?) -> Void
    ) -> PHImageRequestID {
        guard let asset = resolveAsset(for: localIdentifier) else {
            handler(nil, false, HomerImageError.photosAssetNotFound)
            return PHInvalidImageRequestID
        }
        return PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: contentMode,
            options: sharedOptions
        ) { image, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let error = info?[PHImageErrorKey] as? Error
            handler(image, isDegraded, error)
        }
    }

    /// Cancels a request previously issued by
    /// ``requestImage(for:targetSize:contentMode:handler:)``.
    /// No-op when `requestID` is `PHInvalidImageRequestID`.
    public func cancelThumbnail(_ requestID: PHImageRequestID) {
        guard requestID != PHInvalidImageRequestID else { return }
        cachingManager.cancelImageRequest(requestID)
    }

    /// Cancels a request previously issued by
    /// ``requestFullScreenImage(for:targetSize:contentMode:handler:)``.
    /// No-op when `requestID` is `PHInvalidImageRequestID`.
    public func cancelFullScreen(_ requestID: PHImageRequestID) {
        guard requestID != PHInvalidImageRequestID else { return }
        PHImageManager.default().cancelImageRequest(requestID)
    }

    /// Resolves an asset from the local map, falling back to a fresh
    /// PhotoKit fetch when the identifier hasn't been registered.
    /// This guards detail screens against a long scroll having
    /// rotated the registered set without having seen the asset
    /// the user just tapped on.
    private func resolveAsset(for localIdentifier: String) -> PHAsset? {
        if let cached = asset(for: localIdentifier) {
            return cached
        }
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        return fetchResult.firstObject
    }

    /// Prefetch entry point. Tells PhotoKit to pre-decode thumbnails
    /// for the supplied identifiers in the background. Pair with
    /// `UICollectionViewDataSourcePrefetching` for visible-soon
    /// hints during fast scrolls.
    public func startCaching(
        for localIdentifiers: [String],
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill
    ) {
        let toCache = localIdentifiers.compactMap { asset(for: $0) }
        guard !toCache.isEmpty else { return }
        cachingManager.startCachingImages(
            for: toCache,
            targetSize: targetSize,
            contentMode: contentMode,
            options: sharedOptions
        )
    }

    /// Tells PhotoKit it can release the pre-decoded thumbnails for
    /// the supplied identifiers. Mirror this with the same parameters
    /// you used in the matching ``startCaching(for:targetSize:contentMode:)``
    /// call so PhotoKit can locate the cached entry.
    public func stopCaching(
        for localIdentifiers: [String],
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill
    ) {
        let toStop = localIdentifiers.compactMap { asset(for: $0) }
        guard !toStop.isEmpty else { return }
        cachingManager.stopCachingImages(
            for: toStop,
            targetSize: targetSize,
            contentMode: contentMode,
            options: sharedOptions
        )
    }

    /// Releases every pre-decoded thumbnail held by the caching
    /// manager. Useful when the surrounding feature unloads (e.g.
    /// the photos browser is dismissed).
    public func stopCachingAll() {
        cachingManager.stopCachingImagesForAllAssets()
    }
}
