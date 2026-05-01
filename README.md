# HomerImageProvider

Modern Swift 6 / iOS 18 image-loading library for the Homer suite. Async / await throughout, dual-layer caching, automatic downsampling, PhotoKit integration, and a Kingfisher-style `imageView.homer.setImage(...)` call site — built on top of `HomerFoundation` and `HomerUIKit` so it composes with the rest of the suite.

- **Swift tools:** 6.0 (`swiftLanguageModes: [.v6]`, strict concurrency)
- **Platforms:** iOS 18+
- **Dependencies:** `HomerFoundation` `0.5.0+`, `HomerUIKit` `0.8.0+`
- **Status:** `0.3.0` — public API documented with DocC, 0 warnings

## Installation

Swift Package Manager — add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/akkanferhan/HomerImageProvider.git", from: "0.3.0")
]
```

Then attach the product to a target:

```swift
.target(
    name: "MyApp",
    dependencies: ["HomerImageProvider"]
)
```

In code:

```swift
import HomerImageProvider
```

`HomerFoundation` and `HomerUIKit` are pulled in transitively — you don't need to declare them yourself.

## Quick start

### `UIImageView` extension (the common path)

```swift
import HomerImageProvider

// Remote URL with a static placeholder.
imageView.homer.setImage(
    with: .network(url),
    placeholder: .image(UIImage(named: "placeholder")!)
)

// Activity indicator placeholder (from HomerUIKit's UIActivityIndicatorView.make).
imageView.homer.setImage(
    with: .network(url),
    placeholder: .activityIndicator(style: .medium, color: .gray)
)

// Photos library asset (PHAsset.localIdentifier).
imageView.homer.setImage(with: .photos(localIdentifier: "LOCAL_ID"))

// Local file URL.
imageView.homer.setImage(with: .file(fileURL))
```

### Manual usage via the manager

```swift
Task {
    do {
        let image = try await HomerImageProviderManager.shared.loadImage(
            from: .network(url),
            targetSize: CGSize(width: 200, height: 200)
        )
        await MainActor.run { imageView.image = image }
    } catch {
        print("load failed: \(error)")
    }
}
```

## Modules

### Image source — `HomerImageSource`

```swift
public enum HomerImageSource: Sendable, Hashable {
    case network(URL)
    case photos(localIdentifier: String)
    case file(URL)
}
```

`Sendable` + `Hashable` so the source can travel across actor boundaries and be used as a cache key directly. The string form lives on `cacheKey`.

### Configuration — `HomerConfigurationProtocol` / `HomerDefaultConfiguration`

```swift
public protocol HomerConfigurationProtocol: Sendable {
    var maxConcurrentTasks: Int { get }     // default 6
    var memoryCacheLimitMB: Int { get }     // default 500 MB
    var diskCacheLimitMB: Int { get }       // default 2000 MB
    var retryPolicy: HTTPRetryPolicy { get } // .default
}
```

The retry policy comes from `HomerFoundation.HTTPRetryPolicy`. Sharing one instance with HomerNetwork's JSON client keeps backoff windows aligned when both hit the same upstream — typical when the image CDN sits behind the same CloudFlare account as the API.

```swift
struct CustomConfig: HomerConfigurationProtocol {
    let maxConcurrentTasks = 4
    let memoryCacheLimitMB = 200
    let diskCacheLimitMB = 1000
    let retryPolicy = HTTPRetryPolicy(maxAttempts: 5, baseDelay: 1.0)
}

await HomerImageProviderManager.shared.configure(with: CustomConfig())
```

### Manager — `HomerImageProviderManager`

`actor`-isolated process-wide image provider. The pipeline is:

1. **Memory cache** lookup (`(source, targetSize)`-keyed).
2. **In-flight variant dedupe** — concurrent calls for the same `(source, targetSize)` share one downsample.
3. **Detached worker**: caller-side cancellation does not propagate into the URLSession download. Cancel-cascade was producing CloudFlare 429 chains during fast scrolls; detaching the worker keeps the in-flight stream count stable.
4. **Network branch** dedupes the original-byte download keyed by `cacheKey` so two requests for the same URL with different `targetSize` values share one network hop and one disk-cache write.
5. **Decode** + **downsample** (when `targetSize` was supplied) via `ImageProcessor` (memory-efficient `CGImageSource` thumbnail API).
6. **Memory-cache write** by variant key for the next cell.

### Caches — `MemoryCache` / `DiskCache`

- `MemoryCache` — `NSCache`-backed, RGBA-cost-attributed.
- `DiskCache` — `actor`-isolated, files under `Library/Caches/HomerImageProviderCache`. Writes trigger an opportunistic cleanup that prunes least-recently-accessed entries until the on-disk footprint drops below 80 % of the limit.

### LIFO concurrency limit — `TaskQueue`

```swift
public actor TaskQueue {
    public func enqueue() async
    public func dequeue() async
    public func execute<T>(operation: @escaping @Sendable () async throws -> T) async throws -> T
}
```

LIFO matters for scroll-driven grids: the user always wants the cells they're looking at right now to load before the off-screen cells they scrolled past two seconds ago.

### Downsampling — `ImageProcessor`

```swift
let image = await ImageProcessor.downsample(data: bytes, to: CGSize(width: 200, height: 200))
```

Reads `UIScreen.main.scale` from the main actor once and runs the actual `CGImageSourceCreateThumbnailAtIndex` work `nonisolated`, so callers in a background `Task` don't pay a main-actor hop.

### Loader — `ImageLoader`

```swift
public actor ImageLoader {
    public func download(from url: URL) async throws -> Data
    public func fetchFromPhotos(localIdentifier: String, targetSize: CGSize?) async throws -> UIImage
}
```

The download loop honours `Retry-After` headers and `HTTPRetryPolicy` exponential backoff for transient `408` / `429` / `503` responses. PhotoKit fetches use `deliveryMode = .highQualityFormat` and ignore degraded callbacks (the manager-level Photos path goes through `HomerPhotosImageService` instead, which provides opportunistic delivery).

### Photos integration — `HomerPhotosImageService` / `HomerPhotosRepository`

- `HomerPhotosImageService` — `PHCachingImageManager` wrapper with an in-memory `localIdentifier → PHAsset` map, `.opportunistic` delivery, and dedicated thumbnail / full-screen request paths.
- `HomerPhotosRepository` — high-level read / write API: permission flow, asset enumeration, change observation (`AsyncStream<Void>` driven by `PHPhotoLibraryChangeObserver`), and image saves via `PHAssetCreationRequest`.

### Errors — `HomerImageError`

```swift
public enum HomerImageError: Error, Equatable {
    case photosAssetNotFound
    case photosImageUnavailable
    case photosFinalQualityUnavailable
}
```

Surfaces PhotoKit-specific failure modes that the framework can't always express through `PHImageErrorKey` alone.

### Delivery events — `HomerImageDelivery`

```swift
@MainActor
public enum HomerImageDelivery {
    case degraded(UIImage)
    case `final`(UIImage)
    case degradedOnlyFinalFailed(degraded: UIImage, error: Error)
    case failed(Error)
}
```

The modern `setImage(with:placeholder:targetSize:delivery:)` overload reports each transition so call sites can distinguish a degraded preview from the final image and observe the "preview but no full quality" condition that PhotoKit's iCloud-original download path occasionally produces (`PHPhotosErrorDomain` `3169`).

## UICollectionView / UITableView guidance

### Target size and downsampling

When you call `imageView.homer.setImage` without a `targetSize`, the library passes through `imageView.bounds.size` (or `PHImageManagerMaximumSize` for full-screen Photos) and downsamples accordingly. This keeps memory pressure proportional to display footprint instead of source resolution.

### Cell reuse

`setImage` cancels the previous in-flight binding on the receiving image view automatically — both the `Task` driving the manager call and any outstanding `PHImageRequestID`. The wrong image will not flash into a recycled cell.

The manager-side download itself keeps running in the detached worker even when the cell-side `Task` is cancelled: the bytes land in cache so the next time the same cell scrolls back into view, the synchronous `cachedImage(for:targetSize:)` lookup hits instantly. This is intentional — cancelling the `URLSession` data task during fast scrolls produced `RST_STREAM` cascades and CloudFlare `429` chains.

### Prefetching

For `UICollectionViewDataSourcePrefetching`:

```swift
func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
    for indexPath in indexPaths {
        let url = urls[indexPath.item]
        Task {
            // Cache-only load — the discarded result still warms the disk + memory caches.
            _ = try? await HomerImageProviderManager.shared.loadImage(from: .network(url))
        }
    }
}
```

For PhotoKit-backed grids, prefer `HomerPhotosImageService.shared.startCaching(for:targetSize:)`.

## Cross-package composition

| What | Where it comes from |
|---|---|
| `HTTPRetryPolicy` | `HomerFoundation` (single source of truth for retry behaviour across the suite) |
| `UIActivityIndicatorView.make(...)` | `HomerUIKit` — used by the activity-indicator placeholder |
| `centerInSuperview()` | `HomerUIKit` — used to centre the placeholder spinner |
| `Reachability` | Available from `HomerFoundation` if you want to gate loads on connectivity (not built in here) |

## License

[MIT](LICENSE) © 2026 Ferhan Akkan
