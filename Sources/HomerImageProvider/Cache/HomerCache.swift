import Foundation
import UIKit

/// In-memory `UIImage` cache backed by `NSCache`.
///
/// The cache is keyed by string and uses each image's approximate
/// in-memory footprint (`width * height * 4` bytes for RGBA) as the
/// `NSCache` cost. The total cost limit is configurable in megabytes
/// at construction time. Eviction is delegated to `NSCache`'s
/// memory-pressure heuristics — the cache will discard entries
/// automatically when the system reports memory pressure or the cost
/// limit is exceeded.
///
/// `NSCache` is documented as thread-safe and the wrapper exposes no
/// extra mutable state, so `MemoryCache` is `@unchecked Sendable`.
public final class MemoryCache: @unchecked Sendable {
    private let cache = NSCache<NSString, UIImage>()

    /// Creates a cache with the given total-cost limit in megabytes.
    /// The limit is converted to bytes internally to match
    /// `NSCache.totalCostLimit`'s units.
    /// - Parameter limitMB: Cost ceiling in megabytes. Defaults to
    ///   `50` MB.
    public init(limitMB: Int = 50) {
        cache.totalCostLimit = limitMB * Constants.bytesPerMegabyte
    }

    /// Inserts `image` for `key`, attributing an approximate
    /// `width * height * 4` (RGBA) byte cost so `NSCache` can evict
    /// proportionally under pressure.
    public func set(_ image: UIImage, forKey key: String) {
        let imageByteSize = Int(image.size.width * image.size.height * Constants.bytesPerPixelRGBA)
        cache.setObject(image, forKey: key as NSString, cost: imageByteSize)
    }

    /// Returns the image stored for `key`, or `nil` if the cache has
    /// no entry (or has evicted it).
    public func get(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    /// Removes the entry for `key` if present.
    public func remove(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
    }

    private enum Constants {
        static let bytesPerMegabyte = 1024 * 1024
        static let bytesPerPixelRGBA: CGFloat = 4
    }
}

/// Disk-backed `Data` cache living under the user's caches directory.
///
/// The store is structured as plain files inside a single directory
/// (`HomerImageProviderCache` by default), keyed by a percent-encoded
/// version of the supplied string. Writes trigger an opportunistic
/// cleanup that prunes least-recently-accessed files until the
/// on-disk footprint drops below 80 % of the configured limit.
///
/// `actor` isolation serialises reads and writes so the file system
/// state stays consistent without external locking.
public actor DiskCache {
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let limitBytes: Int64

    /// Creates a cache stored under `Library/Caches/<name>` with the
    /// given size cap.
    /// - Parameters:
    ///   - name: Subdirectory of the user's caches folder. Defaults to
    ///     `HomerImageProviderCache`.
    ///   - limitMB: Maximum on-disk size in megabytes. Defaults to
    ///     `250` MB.
    public init(name: String = "HomerImageProviderCache", limitMB: Int = 250) {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent(name)
        self.limitBytes = Int64(limitMB) * Int64(Constants.bytesPerMegabyte)

        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    /// Persists `data` for `key`. The write is preceded by an
    /// opportunistic cleanup pass that frees space if the total cache
    /// size has crept above the configured limit.
    public func set(_ data: Data, forKey key: String) {
        let fileURL = cacheDirectory.appendingPathComponent(filename(for: key))
        performCleanupIfNeeded()
        try? data.write(to: fileURL)
    }

    /// Returns the bytes stored for `key`, or `nil` if no file exists
    /// (or read failed).
    public func get(forKey key: String) -> Data? {
        let fileURL = cacheDirectory.appendingPathComponent(filename(for: key))
        return try? Data(contentsOf: fileURL)
    }

    /// Sanitises an arbitrary cache key into a filesystem-safe
    /// filename. Falls back to the raw key when percent-encoding
    /// returns `nil` (vanishingly rare — `addingPercentEncoding`
    /// returns `nil` only when the input contains malformed UTF-16
    /// surrogates).
    private func filename(for key: String) -> String {
        key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
    }

    /// Walks every file in the cache directory; if the total exceeds
    /// the configured ceiling, removes least-recently-accessed entries
    /// until the footprint drops below 80 % of the limit. The 80 %
    /// floor leaves headroom for the next batch of writes so the
    /// pruning pass doesn't fire on every single write.
    private func performCleanupIfNeeded() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey]
        ) else { return }

        var totalSize: Int64 = 0
        var fileInfos: [(url: URL, size: Int64, date: Date)] = []

        for fileURL in files {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey])
            let size = Int64(resourceValues?.fileSize ?? 0)
            let date = resourceValues?.contentAccessDate ?? Date.distantPast
            totalSize += size
            fileInfos.append((fileURL, size, date))
        }

        guard totalSize > limitBytes else { return }

        let sortedFiles = fileInfos.sorted { $0.date < $1.date }
        var currentSize = totalSize
        let floor = limitBytes * Int64(Constants.cleanupFloorPercent) / 100

        for file in sortedFiles {
            try? fileManager.removeItem(at: file.url)
            currentSize -= file.size
            if currentSize <= floor { break }
        }
    }

    private enum Constants {
        static let bytesPerMegabyte = 1024 * 1024
        /// Percentage of `limitBytes` we prune down to during cleanup.
        /// Anything below 100 leaves write headroom; `80` is the
        /// inflection point where pruning stays infrequent without
        /// allowing the cache to oscillate around the ceiling.
        static let cleanupFloorPercent = 80
    }
}
