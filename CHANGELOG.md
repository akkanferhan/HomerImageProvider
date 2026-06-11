# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Stale PhotoKit deliveries no longer land on reused cells.** PhotoKit
  cancellation is asynchronous, so a result handler already in flight
  when ``cancelDownload()`` ran could still fire afterwards — assigning
  the *previous* source's image (and delivery events) to an image view
  that had since been re-bound by cell reuse. Symptom: brief wrong-photo
  flashes in grids during fast scrolling. Each request now captures a
  per-view load generation and drops its delivery when the view has
  moved on.

### Added

- **Test target** (`HomerImageProviderTests`) covering the pure logic
  units: `TaskQueue` (concurrency cap, LIFO resume order, cancellation
  slot release), `MemoryCache` (set/get/remove/overwrite semantics), and
  `HomerImageSource.cacheKey` (stability and collision resistance).
  `TaskQueue` gained internal `runningCount` / `waitingCount` hooks so
  the suite can synchronise deterministically instead of sleeping.
- **CI workflow** — GitHub Actions build + test on an iOS simulator,
  mirroring the HomerUIKit pipeline.

## [0.3.0] — 2026-05-01

### Fixed

- **iCloud-only assets no longer time out under
  `CloudPhotoLibraryErrorDomain Code 81`** (chained to
  `NSURLErrorDomain -1001`). The shared `PHImageRequestOptions` now
  installs an empty `progressHandler` block, which CloudKit reads as
  "this request is being actively observed" and promotes from the
  background / opportunistic queue to the interactive queue. Symptom
  previously seen on fast networks: ``HomerImageDelivery/degradedOnlyFinalFailed(degraded:error:)``
  fires repeatedly while the device is online but PhotoKit reports
  the underlying CloudKit transfer timed out. The handler body is
  intentionally empty — its presence is the priority signal;
  surfacing progress upward through ``HomerImageDelivery`` is
  reserved for a future revision so call sites can opt in to a
  progress bar.

## [0.2.0] — 2026-05-01

### Fixed

- **`HomerPhotosRepository.saveImage(with:)` now consults the cache
  before downloading.** The `0.1.0` save path called
  `imageLoader.download(from: url)` directly, which bypassed the disk
  and memory caches populated by ``HomerImageProviderManager/loadImage(from:targetSize:)``.
  Symptom: a detail screen would display an already-cached image
  successfully, but tapping "Save to Photos" on the same screen
  produced a network error when offline (or an unnecessary network
  hop when online). The save now routes through the new
  ``HomerImageProviderManager/originalData(for:)`` API so the same
  cache → in-flight dedupe → network fallback pipeline is honoured.

### Added

- **``HomerImageProviderManager/originalData(for:)``** — public,
  cache-first byte-fetch API. Resolves a ``HomerImageSource`` to its
  full-resolution encoded bytes through disk cache → in-flight
  dedupe → fresh download (with
  ``HomerConfigurationProtocol/retryPolicy`` honoured for transient
  HTTP failures). Use this anywhere a caller needs the raw bytes
  *after* a load has populated the cache: saving to the Photos
  library, uploading, hashing.
- **``HomerImageError/photosBytesUnavailable``** — thrown by
  ``originalData(for:)`` when called with a
  ``HomerImageSource/photos(localIdentifier:)`` source. PhotoKit
  assets do not have meaningful "raw bytes" in this API; pass the
  identifier through directly to the consuming call site instead.

### Changed

- **BREAKING (init only)**: ``HomerPhotosRepository/init(imageLoader:)``
  is removed. The repository now delegates byte-fetch to
  ``HomerImageProviderManager/originalData(for:)`` so the loader
  parameter is no longer meaningful — replace
  `HomerPhotosRepository(imageLoader: ImageLoader(...))` with
  `HomerPhotosRepository()`. To configure transport behaviour
  (`URLSession`, retry policy), conform a custom
  ``HomerConfigurationProtocol`` and pass it to
  ``HomerImageProviderManager/configure(with:)`` once at app launch.

## [0.1.0] — 2026-05-01

Initial public release. Modern Swift 6 / iOS 18 image-loading library
for the Homer suite, built on top of `HomerFoundation` and `HomerUIKit`.
Strict concurrency throughout, async / await everywhere, DocC-documented
public surface.

### Added

- **`HomerImageSource`** — `Sendable` + `Hashable` enum covering
  `network(URL)`, `photos(localIdentifier:)`, and `file(URL)` sources.
- **`HomerImageProviderManager`** — process-wide `actor` orchestrating
  the cache → variant-dedupe → download-dedupe → decode pipeline.
  In-flight original-byte downloads are coalesced under
  `HomerImageSource.cacheKey`, so two requests for the same URL with
  different `targetSize` values share one network hop and one
  disk-cache write. The download itself runs in a `Task.detached`
  worker so caller-side cancellation doesn't propagate into the
  URLSession stream — designed to avoid the `RST_STREAM` cascades
  that produced CloudFlare `429` chains during fast scrolls.
- **`HomerConfigurationProtocol`** + **`HomerDefaultConfiguration`** —
  injectable settings for cache sizes, concurrency limit, and
  `HTTPRetryPolicy`. Defaults: `maxConcurrentTasks = 6`,
  `memoryCacheLimitMB = 500`, `diskCacheLimitMB = 2000`,
  `retryPolicy = .default`.
- **`MemoryCache`** — `NSCache`-backed, thread-safe, RGBA-cost-attributed.
- **`DiskCache`** — `actor`-isolated file store under
  `Library/Caches/HomerImageProviderCache`. Writes trigger an
  opportunistic cleanup pass that prunes least-recently-accessed
  entries until the footprint drops below 80 % of the configured
  limit.
- **`TaskQueue`** — LIFO-ordered, concurrency-capped queue. Critical
  for scroll-driven image grids — popping the most recently enqueued
  continuation first means a freshly scrolled-into-view cell jumps
  the queue ahead of off-screen requests still trailing behind it.
- **`ImageProcessor.downsample(data:to:scale:)`** — memory-efficient
  downsampling via `CGImageSourceCreateThumbnailAtIndex`. Reads
  `UIScreen.main.scale` on the main actor once and runs the actual
  decode `nonisolated`.
- **`ImageLoader`** — `URLSession`-backed download with
  `HomerFoundation.HTTPRetryPolicy` integration (`Retry-After`
  parsing, exponential backoff with jitter, `[minDelay, maxDelay]`
  clamp). Plus `fetchFromPhotos(localIdentifier:targetSize:)` for the
  high-quality PhotoKit path.
- **`HomerPhotosImageService`** — `PHCachingImageManager` wrapper with
  an in-memory `localIdentifier → PHAsset` map. Provides
  thumbnail-grid (caching manager, opportunistic) and full-screen
  (`PHImageManager.default()`, latency-isolated) paths plus prefetch
  controls (`startCaching` / `stopCaching` / `stopCachingAll`).
- **`HomerPhotosRepository`** + **`HomerPhotosRepositoryProtocol`** —
  permission flow, asset enumeration, library-change `AsyncStream<Void>`,
  and image saves through `PHAssetCreationRequest`. The change stream
  registers a private `PHPhotoLibraryChangeObserver` bridge that the
  stream's `onTermination` handler unregisters automatically.
- **`HomerImageDelivery`** — `@MainActor` enum modelling each
  delivery transition (`degraded`, `final`, `degradedOnlyFinalFailed`,
  `failed`) so call sites can distinguish a degraded preview from the
  final image and observe the iCloud-original-failed condition.
- **`HomerImageError`** — typed PhotoKit-anomaly cases
  (`photosAssetNotFound`, `photosImageUnavailable`,
  `photosFinalQualityUnavailable`) that the framework cannot always
  express through `PHImageErrorKey` alone.
- **`UIImageView.homer.setImage(...)`** — Kingfisher-style binding API
  with placeholder support, automatic cancellation on rebind,
  PhotoKit thumbnail / full-screen routing, and modern delivery-event
  callbacks. The activity-indicator placeholder uses HomerUIKit's
  `UIActivityIndicatorView.make(style:color:hidesWhenStopped:)`
  factory and `UIView.centerInSuperview()` helper.

### Cross-package integration

- Depends on **`HomerFoundation 0.5.0+`** for `HTTPRetryPolicy` (the
  retry policy underlying `ImageLoader.download(from:)`) and
  `Reachability` (available to consumers if they want to gate loads
  on connectivity).
- Depends on **`HomerUIKit 0.8.0+`** for the activity-indicator
  factory and AutoLayout helpers used by the placeholder path —
  removes hand-rolled `translatesAutoresizingMaskIntoConstraints` +
  `centerXAnchor` / `centerYAnchor` boilerplate from `UIImageView+Homer`.

### Known limitations

- No test target. The library has been validated against production
  scroll-grid + detail-screen workloads in the Homer apps; a
  `HomerImageProviderTests` target with mock `URLSession` + PhotoKit
  fixtures is planned for a follow-up release.
- `HomerImageProviderManager.cancelLoad(from:targetSize:)` is a
  documented no-op kept for source compatibility — the cell-side
  `Task` cancels, but the manager-side download is allowed to run to
  completion so the bytes land in cache. Cancelling the URLSession
  data task during fast scrolls produced `RST_STREAM` cascades and
  CloudFlare `429` chains.

[Unreleased]: https://github.com/akkanferhan/HomerImageProvider/compare/0.3.0...HEAD
[0.3.0]: https://github.com/akkanferhan/HomerImageProvider/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/akkanferhan/HomerImageProvider/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/akkanferhan/HomerImageProvider/releases/tag/0.1.0
