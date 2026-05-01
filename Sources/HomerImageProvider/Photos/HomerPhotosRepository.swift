import Photos
import Foundation
import UIKit

/// High-level interface for read / write operations against the
/// user's Photos library.
///
/// `HomerPhotosRepositoryProtocol` is the protocol HomerImageProvider
/// callers depend on for permission flows, asset enumeration,
/// change observation, and image saves. The default conformer is
/// ``HomerPhotosRepository``, which talks to PhotoKit directly; tests
/// or apps that want offline / replay behaviour can supply their own
/// implementation.
public protocol HomerPhotosRepositoryProtocol: Sendable {
    /// Reports the current `PHAuthorizationStatus` for the
    /// `.readWrite` access level.
    func checkPermissionStatus() async -> PHAuthorizationStatus

    /// Triggers PhotoKit's authorization prompt (no-op when the user
    /// has already responded) and returns the resulting status.
    func requestPermission() async -> PHAuthorizationStatus

    /// Enumerates `.image` assets, sorted by creation date.
    /// - Parameters:
    ///   - limit: Optional cap on the number of assets returned. Pass
    ///     `nil` for "no limit".
    ///   - ascending: Sort direction. `false` (the default in
    ///     ``HomerPhotosRepository``) yields newest-first ordering.
    func fetchAllAssets(limit: Int?, ascending: Bool) async -> [PHAsset]

    /// Yields a `Void` element every time the user's library
    /// changes — new photo, deletion, edit, or limited-access scope
    /// adjustment. The stream automatically deregisters its
    /// underlying `PHPhotoLibraryChangeObserver` when the consuming
    /// `Task` is cancelled.
    ///
    /// The API does **not** diff the change set; consumers are
    /// expected to use the event as a "recompute snapshot" trigger
    /// and re-fetch whatever they care about.
    func photoLibraryChanges() -> AsyncStream<Void>

    /// Persists `data` as a new asset in the user's library after
    /// requesting `.readWrite` permission.
    /// - Returns: The `localIdentifier` of the created asset, or
    ///   `nil` if the placeholder request did not produce one.
    /// - Throws: An `NSError` when the user denies permission or
    ///   `PHPhotoLibrary.performChanges` fails.
    @discardableResult
    func saveImageData(_ data: Data) async throws -> String?

    /// Convenience that downloads or reads `source` and saves the
    /// resulting bytes via ``saveImageData(_:)``.
    /// - Returns: The created asset's `localIdentifier`, or — for a
    ///   ``HomerImageSource/photos(localIdentifier:)`` source — the
    ///   identifier passed in (since no save is needed).
    @discardableResult
    func saveImage(with source: HomerImageSource) async throws -> String?
}

/// Default ``HomerPhotosRepositoryProtocol`` implementation backed by
/// PhotoKit and ``HomerImageProviderManager``.
///
/// Operates as an `actor` so writes through `PHPhotoLibrary.performChanges`
/// are serialised — concurrent saves would otherwise compete for the
/// shared change-block transaction.
public actor HomerPhotosRepository: HomerPhotosRepositoryProtocol {

    /// Creates a repository. ``saveImage(with:)`` now delegates the
    /// byte-fetch to ``HomerImageProviderManager/originalData(for:)``
    /// so the manager's disk cache and in-flight dedupe are honoured
    /// — passing a custom ``ImageLoader`` is no longer meaningful and
    /// the parameter has been removed (`0.1.0` `init(imageLoader:)`
    /// is gone).
    public init() {}

    public func checkPermissionStatus() async -> PHAuthorizationStatus {
        return PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    public func requestPermission() async -> PHAuthorizationStatus {
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    public nonisolated func photoLibraryChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let observer = PhotoLibraryChangeObserverBridge {
                continuation.yield()
            }
            PHPhotoLibrary.shared().register(observer)
            continuation.onTermination = { _ in
                // The closure observer strong-retains the bridge.
                // `PHPhotoLibrary` keeps observers as weak references,
                // so the bridge must outlive the stream — we hold
                // the strong reference for the stream's lifetime
                // and release it via `unregisterChangeObserver` when
                // the stream terminates.
                PHPhotoLibrary.shared().unregisterChangeObserver(observer)
            }
        }
    }

    public func fetchAllAssets(limit: Int? = nil, ascending: Bool = false) async -> [PHAsset] {
        let options = PHFetchOptions()
        if let limit = limit {
            options.fetchLimit = limit
        }
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: ascending)]

        let fetchResult = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    @discardableResult
    public func saveImageData(_ data: Data) async throws -> String? {
        let status = await requestPermission()
        guard status == .authorized || status == .limited else {
            throw NSError(
                domain: "HomerPhotosRepository",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Gallery permission denied"]
            )
        }

        var localIdentifier: String?

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
            localIdentifier = request.placeholderForCreatedAsset?.localIdentifier
        }

        return localIdentifier
    }

    @discardableResult
    public func saveImage(with source: HomerImageSource) async throws -> String? {
        switch source {
        case .network, .file:
            // Route through HomerImageProviderManager.originalData(for:)
            // so disk cache + in-flight dedupe are consulted before
            // the network. A detail screen that just displayed the
            // image has already populated the disk cache; the save
            // path now picks those bytes up instead of issuing a
            // fresh URLSession hop that would fail when offline.
            let data = try await HomerImageProviderManager.shared.originalData(for: source)
            return try await saveImageData(data)
        case .photos(let identifier):
            return identifier
        }
    }
}
