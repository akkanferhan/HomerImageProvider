import Foundation
import UIKit

/// Process-wide image provider that orchestrates caching, deduplication,
/// downloading, and downsampling for every ``HomerImageSource``.
///
/// `HomerImageProviderManager` is an `actor`, so concurrent
/// ``loadImage(from:targetSize:)`` calls coming from arbitrary
/// `Task`s synchronise through its isolation domain. The cache and
/// transport components it owns (``MemoryCache``, ``DiskCache``,
/// ``ImageLoader``, ``TaskQueue``) are reconstructed via
/// ``configure(with:)`` when a custom configuration is supplied.
///
/// ## Pipeline
/// 1. **Memory cache** lookup keyed by `(source, targetSize)`. Hit
///    returns synchronously through ``cachedImage(for:targetSize:)``.
/// 2. **In-flight variant** dedupe — if another caller is already
///    producing the same `(source, targetSize)` variant, the second
///    request awaits the same `Task<UIImage>`.
/// 3. **Detached worker**: the work runs in a `Task.detached`
///    deliberately, so caller-side cancellation does not propagate
///    into the URLSession download. Caller-side cancel cascades
///    triggered hundreds of `RST_STREAM`s on CloudFlare-fronted
///    upstreams during fast scrolls, which produced `429`s back —
///    detaching the worker keeps the in-flight stream count stable.
/// 4. **Network branch** dedupes the original-byte download under
///    ``HomerImageSource/cacheKey`` so that two requests for the
///    same URL with different `targetSize` values share one network
///    hop and one disk-cache write.
/// 5. **Decode** + **downsample** via ``ImageProcessor`` when a
///    `targetSize` was supplied; full-resolution decode otherwise.
/// 6. **Memory-cache write** by variant key, ready for the next
///    cell to hit synchronously.
public actor HomerImageProviderManager {

    /// Process-wide shared instance. Production call sites usually
    /// reach for this rather than constructing a manager themselves;
    /// the `init` is kept private to keep the singleton honest.
    public static let shared = HomerImageProviderManager()

    nonisolated(unsafe) private var memoryCache: MemoryCache
    private var diskCache: DiskCache
    private var loader: ImageLoader
    private var networkQueue: TaskQueue

    /// Per-source in-flight original-byte downloads, keyed by
    /// ``HomerImageSource/cacheKey``. Concurrent calls for the same
    /// URL with different `targetSize` values share one network hop
    /// and one disk-cache write; each variant performs its own
    /// downsample on the shared bytes.
    private var activeDownloads: [String: Task<Data, Error>] = [:]

    /// Per-variant in-flight processing tasks, keyed by
    /// `processedKey(source:targetSize:)`. Concurrent calls for the
    /// same `(source, targetSize)` pair share one downsample.
    private var activeTasks: [String: Task<UIImage, Error>] = [:]

    private init() {
        let defaultConfig = HomerDefaultConfiguration()
        self.memoryCache = MemoryCache(limitMB: defaultConfig.memoryCacheLimitMB)
        self.diskCache = DiskCache(limitMB: defaultConfig.diskCacheLimitMB)
        self.loader = ImageLoader(retryPolicy: defaultConfig.retryPolicy)
        self.networkQueue = TaskQueue(maxConcurrentTasks: defaultConfig.maxConcurrentTasks)
    }

    /// Replaces the cache, loader, and queue with fresh instances
    /// built from `config`. In-flight tasks tied to the previous
    /// instances are not cancelled — they continue to completion
    /// against their original components and the next request picks
    /// up the new ones.
    public func configure(with config: HomerConfigurationProtocol) {
        self.memoryCache = MemoryCache(limitMB: config.memoryCacheLimitMB)
        self.diskCache = DiskCache(limitMB: config.diskCacheLimitMB)
        self.loader = ImageLoader(retryPolicy: config.retryPolicy)
        self.networkQueue = TaskQueue(maxConcurrentTasks: config.maxConcurrentTasks)
    }

    /// Synchronous in-memory cache lookup. Returns the cached image
    /// when present, `nil` otherwise.
    ///
    /// Safe to call from any context — ``MemoryCache`` is backed by
    /// thread-safe `NSCache` and the manager exposes the read as
    /// `nonisolated`.
    public nonisolated func cachedImage(for source: HomerImageSource, targetSize: CGSize? = nil) -> UIImage? {
        return memoryCache.get(forKey: Self.processedKey(source: source, targetSize: targetSize))
    }

    /// Kept for source compatibility; **now a no-op**.
    ///
    /// The previous behaviour cancelled the underlying `URLSession`
    /// data task. On CloudFlare-fronted hosts that triggered a
    /// cascade of `RST_STREAM` packets during fast scrolls, which
    /// produced `429` responses on the *next* attempt and caused
    /// cells to render blank. The current behaviour leaves the
    /// download running to completion in the detached worker; the
    /// cell-side `Task` is still cancelled, but the bytes land in
    /// memory + disk cache so a subsequent ``cachedImage(for:targetSize:)``
    /// hit is instant. Net effect: stable in-flight stream count, no
    /// cancel / restart pattern, no `429` chains.
    public func cancelLoad(from source: HomerImageSource, targetSize: CGSize? = nil) {
        // Intentional no-op — see doc comment above.
    }

    /// Returns the original (full-resolution) bytes for `source`,
    /// honouring the same cache → in-flight dedupe → network-fetch
    /// pipeline as ``loadImage(from:targetSize:)``.
    ///
    /// Use this when a caller needs the raw bytes (saving to the
    /// Photos library, uploading, hashing) **after** a load has
    /// already populated the cache. ``loadImage(from:targetSize:)``
    /// decodes / downsamples for display and only the network branch
    /// writes the encoded bytes to disk; a hand-rolled
    /// `URLSession.data(from: url)` in a save handler therefore
    /// bypasses the cache and re-hits the network even when the
    /// detail screen displayed an already-cached image moments ago.
    ///
    /// - Parameter source: The image's origin.
    ///   - ``HomerImageSource/network(_:)`` resolves through disk
    ///     cache → in-flight dedupe → fresh download (with
    ///     ``HomerConfigurationProtocol/retryPolicy`` honoured).
    ///   - ``HomerImageSource/file(_:)`` reads bytes from the file
    ///     system.
    ///   - ``HomerImageSource/photos(localIdentifier:)`` throws
    ///     ``HomerImageError/photosBytesUnavailable`` because
    ///     PhotoKit assets do not have meaningful "raw bytes" in
    ///     this API — keep the identifier and pass it through
    ///     directly to the consuming call site.
    /// - Returns: The full-resolution encoded bytes (JPEG / PNG /
    ///   HEIC / …, depending on the source).
    /// - Throws: ``HomerImageError/photosBytesUnavailable`` for
    ///   `.photos` sources, or any error propagated from the disk
    ///   read or network download.
    public func originalData(for source: HomerImageSource) async throws -> Data {
        switch source {
        case .network(let url):
            return try await fetchOriginalNetworkData(url: url, sourceKey: source.cacheKey)
        case .file(let url):
            return try Data(contentsOf: url)
        case .photos:
            throw HomerImageError.photosBytesUnavailable
        }
    }

    /// Loads an image, applying the full cache → dedupe → fetch →
    /// decode pipeline.
    ///
    /// - Parameters:
    ///   - source: The image's origin.
    ///   - targetSize: Optional point size used for downsampling.
    ///     Pass `nil` to load the full-resolution image.
    /// - Returns: A decoded `UIImage`, sized either to `targetSize`
    ///   or the original dimensions.
    /// - Throws: Any error produced by the loader, the disk cache,
    ///   or PhotoKit; an `NSError` (`HomerImageProvider` domain) if
    ///   decoding fails or the manager has been deallocated by the
    ///   time the detached worker runs.
    public func loadImage(from source: HomerImageSource, targetSize: CGSize? = nil) async throws -> UIImage {
        let sourceKey = source.cacheKey
        let processedKey = Self.processedKey(source: source, targetSize: targetSize)

        // 1. Variant memory hit.
        if let cachedImage = memoryCache.get(forKey: processedKey) {
            return cachedImage
        }

        // 2. Coalesce concurrent variant requests.
        if let existingTask = activeTasks[processedKey] {
            return try await existingTask.value
        }

        // 3. Detached worker keeps caller-side cancel from racing the
        // network hop. `activeTasks` is cleared from inside the task
        // (`markVariantCompleted`) so the dedupe entry survives a
        // caller cancellation.
        let memoryCache = self.memoryCache
        let loader = self.loader

        let task = Task<UIImage, Error>.detached { [weak self] in
            defer {
                Task { [weak self] in
                    await self?.markVariantCompleted(processedKey: processedKey)
                }
            }

            let image: UIImage

            switch source {
            case .network(let url):
                // Disk holds **original bytes only**, keyed by
                // `sourceKey`. Any `targetSize` variant for the same
                // URL hits here and downsamples in memory without
                // re-fetching. Earlier versions keyed disk by variant
                // and re-downloaded for every new size.
                guard let strongSelf = self else {
                    throw NSError(
                        domain: Constants.errorDomain,
                        code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"]
                    )
                }
                let originalData = try await strongSelf.fetchOriginalNetworkData(url: url, sourceKey: sourceKey)

                if let targetSize, let downsampled = await ImageProcessor.downsample(data: originalData, to: targetSize) {
                    image = downsampled
                } else if let original = UIImage(data: originalData) {
                    image = original
                } else {
                    throw NSError(
                        domain: Constants.errorDomain,
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to decode image"]
                    )
                }

            case .photos(let id):
                image = try await loader.fetchFromPhotos(localIdentifier: id, targetSize: targetSize)

            case .file(let url):
                let data = try Data(contentsOf: url)
                if let targetSize, let downsampled = await ImageProcessor.downsample(data: data, to: targetSize) {
                    image = downsampled
                } else if let original = UIImage(data: data) {
                    image = original
                } else {
                    throw NSError(
                        domain: Constants.errorDomain,
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to decode image"]
                    )
                }
            }

            memoryCache.set(image, forKey: processedKey)
            return image
        }
        activeTasks[processedKey] = task

        return try await task.value
    }

    /// Returns the original (full-resolution) bytes for a `.network`
    /// source, applying:
    /// 1. disk cache lookup (keyed by `sourceKey`),
    /// 2. concurrent in-flight download dedupe,
    /// 3. fresh network fetch + disk-cache write.
    private func fetchOriginalNetworkData(url: URL, sourceKey: String) async throws -> Data {
        if let cached = await diskCache.get(forKey: sourceKey) {
            return cached
        }

        if let existing = activeDownloads[sourceKey] {
            return try await existing.value
        }

        let diskCache = self.diskCache
        let loader = self.loader
        let networkQueue = self.networkQueue

        let task = Task<Data, Error>.detached { [weak self] in
            defer {
                Task { [weak self] in
                    await self?.markDownloadCompleted(sourceKey: sourceKey)
                }
            }
            let data = try await networkQueue.execute {
                try await loader.download(from: url)
            }
            await diskCache.set(data, forKey: sourceKey)
            return data
        }
        activeDownloads[sourceKey] = task

        return try await task.value
    }

    /// Drops the variant task from the registry. Always invoked from
    /// inside the task itself, so caller-side cancellation does not
    /// race the dedupe map.
    private func markVariantCompleted(processedKey: String) {
        activeTasks[processedKey] = nil
    }

    /// Drops the original-byte download task from the registry.
    private func markDownloadCompleted(sourceKey: String) {
        activeDownloads[sourceKey] = nil
    }

    /// Builds the memory / processing cache key from a
    /// `(source, targetSize)` pair. When `targetSize == nil`, the
    /// key reduces to `sourceKey` — the full-resolution variant
    /// caches identical bytes under the same name as the disk
    /// original.
    private static func processedKey(source: HomerImageSource, targetSize: CGSize?) -> String {
        source.cacheKey + (targetSize.map { "_\($0.width)x\($0.height)" } ?? "")
    }

    private enum Constants {
        static let errorDomain = "HomerImageProvider"
    }
}
