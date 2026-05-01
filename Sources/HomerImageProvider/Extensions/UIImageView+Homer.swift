import HomerUIKit
import Photos
import UIKit

/// Wrapper used as the namespace for HomerImageProvider extensions on
/// `UIImageView` (and any other type that opts in via
/// ``HomerCompatible``). The wrapper avoids polluting the host type's
/// own surface — call sites read as `imageView.homer.setImage(...)`.
public struct HomerWrapper<Base> {
    /// The wrapped value the namespace operates on.
    public let base: Base
    /// Wraps `base` for HomerImageProvider extensions.
    public init(_ base: Base) {
        self.base = base
    }
}

/// Marker protocol for types that participate in the `homer.<...>`
/// namespace. The default implementation produces a fresh
/// ``HomerWrapper`` on each access; bound extensions live in
/// `HomerWrapper`-constrained extensions (see the `Base: UIImageView`
/// extension below).
public protocol HomerCompatible {
    associatedtype CompatibleType
    /// Entry point for `imageView.homer.setImage(...)`-style calls.
    var homer: HomerWrapper<CompatibleType> { get }
}

extension HomerCompatible {
    public var homer: HomerWrapper<Self> {
        HomerWrapper(self)
    }
}

extension UIImageView: HomerCompatible {}

// MARK: - Associated-object keys

nonisolated(unsafe) private var taskKey: UInt8 = 0
nonisolated(unsafe) private var photosRequestKey: UInt8 = 0
nonisolated(unsafe) private var photosRequestKindKey: UInt8 = 0
nonisolated(unsafe) private var loadSourceKey: UInt8 = 0
nonisolated(unsafe) private var loadTargetSizeKey: UInt8 = 0

private enum PhotosRequestKind: Int {
    case thumbnail
    case fullScreen
}

/// Reference wrapper used to stash a ``HomerImageSource`` (a
/// `Hashable` enum) in `objc_setAssociatedObject`, which only accepts
/// reference types.
private final class Box<T> {
    let value: T
    init(_ value: T) { self.value = value }
}

extension HomerWrapper where Base: UIImageView {

    private var currentTask: Task<Void, Never>? {
        get {
            objc_getAssociatedObject(base, &taskKey) as? Task<Void, Never>
        }
        nonmutating set {
            objc_setAssociatedObject(base, &taskKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    private var currentPhotosRequestID: PHImageRequestID {
        get {
            (objc_getAssociatedObject(base, &photosRequestKey) as? NSNumber)?.int32Value ?? PHInvalidImageRequestID
        }
        nonmutating set {
            objc_setAssociatedObject(base, &photosRequestKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    private var currentPhotosRequestKind: PhotosRequestKind? {
        get {
            guard let raw = (objc_getAssociatedObject(base, &photosRequestKindKey) as? NSNumber)?.intValue else { return nil }
            return PhotosRequestKind(rawValue: raw)
        }
        nonmutating set {
            let value = newValue.map { NSNumber(value: $0.rawValue) }
            objc_setAssociatedObject(base, &photosRequestKindKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// Source bound to the in-flight ``HomerImageProviderManager/loadImage(from:targetSize:)``
    /// call. ``cancelDownload()`` reads this so it can dispatch the
    /// correct cancellation sentinel back to the manager.
    private var currentLoadSource: HomerImageSource? {
        get {
            (objc_getAssociatedObject(base, &loadSourceKey) as? Box<HomerImageSource>)?.value
        }
        nonmutating set {
            let value = newValue.map { Box($0) }
            objc_setAssociatedObject(base, &loadSourceKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    private var currentLoadTargetSize: CGSize? {
        get {
            (objc_getAssociatedObject(base, &loadTargetSizeKey) as? NSValue)?.cgSizeValue
        }
        nonmutating set {
            let value = newValue.map { NSValue(cgSize: $0) }
            objc_setAssociatedObject(base, &loadTargetSizeKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// Legacy, `Result`-based completion API.
    ///
    /// Both ``HomerImageDelivery/degraded(_:)`` and
    /// ``HomerImageDelivery/final(_:)`` are mapped to `.success`,
    /// preserving the historical behaviour where Photos opportunistic
    /// delivery surfaced two consecutive successful callbacks.
    /// ``HomerImageDelivery/degradedOnlyFinalFailed(degraded:error:)``
    /// is silently swallowed because the degraded image was already
    /// reported as success. ``HomerImageDelivery/failed(_:)`` maps to
    /// `.failure`. New call sites should prefer the
    /// ``setImage(with:placeholder:targetSize:delivery:)`` overload.
    @MainActor
    public func setImage(with source: HomerImageSource,
                         placeholder: HomerPlaceholder? = nil,
                         targetSize: CGSize? = nil,
                         completion: (@MainActor (Result<UIImage, Error>) -> Void)? = nil) {
        let adapter: (@MainActor (HomerImageDelivery) -> Void)?
        if let completion {
            adapter = { delivery in
                switch delivery {
                case .degraded(let image), .final(let image):
                    completion(.success(image))
                case .degradedOnlyFinalFailed:
                    break
                case .failed(let error):
                    completion(.failure(error))
                }
            }
        } else {
            adapter = nil
        }
        setImage(with: source, placeholder: placeholder, targetSize: targetSize, delivery: adapter)
    }

    /// Modern delivery-event API.
    ///
    /// Reports each transition (``HomerImageDelivery``) so callers can
    /// distinguish a degraded preview from the final image, observe
    /// the "preview but no full quality" condition, and surface a
    /// consistent failure path across all source types.
    ///
    /// The image view assigns the image directly on the main thread
    /// before invoking the closure, so callers don't need to perform
    /// the assignment themselves; ``HomerPlaceholder`` activity
    /// indicators are removed automatically once delivery occurs.
    /// - Parameters:
    ///   - source: The ``HomerImageSource`` to load.
    ///   - placeholder: Optional placeholder shown until the first
    ///     image arrives.
    ///   - targetSize: Optional point size used to drive PhotoKit
    ///     thumbnail requests and ``ImageProcessor`` downsampling.
    ///     Pass `nil` to load the full-resolution image (or, for
    ///     `.photos`, to route through the full-screen
    ///     `PHImageManager.default()` path).
    ///   - delivery: Closure invoked on the main thread for every
    ///     delivery event. Pass `nil` if the image-view assignment
    ///     is the only behaviour you need.
    @MainActor
    public func setImage(with source: HomerImageSource,
                         placeholder: HomerPlaceholder? = nil,
                         targetSize: CGSize? = nil,
                         delivery: (@MainActor (HomerImageDelivery) -> Void)?) {
        cancelDownload()

        // `.photos` thumbnail (cell): `PHCachingImageManager` opportunistic
        // — fast, batched, prefetch-friendly.
        // `.photos` full-screen (detail, no targetSize): goes through
        // `PHImageManager.default()` so the request doesn't sit behind the
        // caching manager's cell-decode queue after a long scroll.
        if case .photos(let identifier) = source {
            if let placeholder = placeholder {
                applyPlaceholder(placeholder)
            }
            if let targetSize {
                startPhotosThumbnailRequest(localIdentifier: identifier, targetSize: targetSize, delivery: delivery)
            } else {
                startPhotosFullScreenRequest(localIdentifier: identifier, delivery: delivery)
            }
            return
        }

        if let cached = HomerImageProviderManager.shared.cachedImage(for: source, targetSize: targetSize) {
            base.image = cached
            // Cache hit — surface as instant success so cell-side
            // commit patterns ("save to DB once the image lands")
            // also fire on cold-restart disk-cache hits.
            delivery?(.final(cached))
            return
        }

        if let placeholder = placeholder {
            applyPlaceholder(placeholder)
        }
        currentLoadSource = source
        currentLoadTargetSize = targetSize
        startManagerTask(source: source, targetSize: targetSize, delivery: delivery)
    }

    /// Cancels the in-flight load (if any) for the receiving image
    /// view. Removes the placeholder, drops the manager-side
    /// dedupe-cancel sentinel, and cancels any outstanding PhotoKit
    /// request.
    @MainActor
    public func cancelDownload() {
        currentTask?.cancel()
        currentTask = nil

        // Manager-side cancel marker. The current implementation is a
        // no-op (see ``HomerImageProviderManager/cancelLoad(from:targetSize:)``)
        // — kept to clear the local source/size bookkeeping on cancel.
        if let source = currentLoadSource {
            let targetSize = currentLoadTargetSize
            Task {
                await HomerImageProviderManager.shared.cancelLoad(from: source, targetSize: targetSize)
            }
            currentLoadSource = nil
            currentLoadTargetSize = nil
        }

        if currentPhotosRequestID != PHInvalidImageRequestID {
            switch currentPhotosRequestKind {
            case .fullScreen:
                HomerPhotosImageService.shared.cancelFullScreen(currentPhotosRequestID)
            case .thumbnail, .none:
                HomerPhotosImageService.shared.cancelThumbnail(currentPhotosRequestID)
            }
            currentPhotosRequestID = PHInvalidImageRequestID
            currentPhotosRequestKind = nil
        }
        removePlaceholderViews()
    }

    @MainActor
    private func startPhotosThumbnailRequest(
        localIdentifier: String,
        targetSize: CGSize,
        delivery: (@MainActor (HomerImageDelivery) -> Void)?
    ) {
        currentPhotosRequestKind = .thumbnail
        let state = PhotosDeliveryState()
        currentPhotosRequestID = HomerPhotosImageService.shared.requestImage(
            for: localIdentifier,
            targetSize: targetSize
        ) { [weak base = self.base] image, isDegraded, error in
            // PhotoKit delivers the result handler on the main thread
            // for requests issued from the main thread; assigning
            // directly avoids an extra runloop iteration per cell.
            // The degraded thumbnail is set first, then overwritten
            // when the high-quality version arrives.
            // `assumeIsolated` is sound because the handler is
            // documented to run on the main queue when the request
            // was issued from it.
            MainActor.assumeIsolated {
                guard let base else { return }
                Self.dispatchPhotosDelivery(
                    image: image,
                    isDegraded: isDegraded,
                    error: error,
                    state: state,
                    base: base,
                    delivery: delivery
                )
            }
        }
    }

    @MainActor
    private func startPhotosFullScreenRequest(
        localIdentifier: String,
        delivery: (@MainActor (HomerImageDelivery) -> Void)?
    ) {
        let size = Self.fullScreenPhotosTargetSize
        currentPhotosRequestKind = .fullScreen
        let state = PhotosDeliveryState()
        currentPhotosRequestID = HomerPhotosImageService.shared.requestFullScreenImage(
            for: localIdentifier,
            targetSize: size
        ) { [weak base = self.base] image, isDegraded, error in
            MainActor.assumeIsolated {
                guard let base else { return }
                Self.dispatchPhotosDelivery(
                    image: image,
                    isDegraded: isDegraded,
                    error: error,
                    state: state,
                    base: base,
                    delivery: delivery
                )
            }
        }
    }

    /// Translates a PhotoKit opportunistic callback into a
    /// ``HomerImageDelivery`` event. If a degraded preview was
    /// previously delivered and the next callback returns `nil`, the
    /// dispatcher emits ``HomerImageDelivery/degradedOnlyFinalFailed(degraded:error:)``;
    /// when no preview was ever delivered the failure surfaces as
    /// ``HomerImageDelivery/failed(_:)``.
    @MainActor
    private static func dispatchPhotosDelivery(
        image: UIImage?,
        isDegraded: Bool,
        error: Error?,
        state: PhotosDeliveryState,
        base: UIImageView,
        delivery: (@MainActor (HomerImageDelivery) -> Void)?
    ) {
        if let image {
            base.subviews
                .filter { $0 is UIActivityIndicatorView }
                .forEach { $0.removeFromSuperview() }
            base.image = image
            if isDegraded {
                state.lastDegraded = image
                delivery?(.degraded(image))
            } else {
                delivery?(.final(image))
            }
            return
        }

        // image == nil: PhotoKit could not deliver. If a degraded
        // preview was seen earlier, surface the "final failed"
        // event; otherwise treat it as a generic failure.
        if let degraded = state.lastDegraded {
            delivery?(.degradedOnlyFinalFailed(
                degraded: degraded,
                error: error ?? HomerImageError.photosFinalQualityUnavailable
            ))
        } else {
            base.subviews
                .filter { $0 is UIActivityIndicatorView }
                .forEach { $0.removeFromSuperview() }
            delivery?(.failed(error ?? HomerImageError.photosImageUnavailable))
        }
    }

    @MainActor
    private func startManagerTask(
        source: HomerImageSource,
        targetSize: CGSize?,
        delivery: (@MainActor (HomerImageDelivery) -> Void)?
    ) {
        currentTask = Task {
            do {
                let image = try await HomerImageProviderManager.shared.loadImage(from: source, targetSize: targetSize)
                if !Task.isCancelled {
                    removePlaceholderViews()
                    base.image = image
                    currentLoadSource = nil
                    currentLoadTargetSize = nil
                    // Skip delivery on cancellation: the cell is
                    // already bound to a different source, and
                    // firing a commit for the stale source would
                    // mislead callers tracking "image landed".
                    delivery?(.final(image))
                }
            } catch {
                if !Task.isCancelled {
                    removePlaceholderViews()
                    currentLoadSource = nil
                    currentLoadTargetSize = nil
                    delivery?(.failed(error))
                }
            }
        }
    }

    @MainActor
    private func applyPlaceholder(_ placeholder: HomerPlaceholder) {
        switch placeholder {
        case .image(let image):
            base.image = image
        case .activityIndicator(let style, let color):
            base.image = nil
            // Uses HomerUIKit factories + AutoLayout helpers so the
            // boilerplate (translatesAutoresizingMaskIntoConstraints,
            // centerXAnchor / centerYAnchor activate, startAnimating)
            // collapses into two readable lines and stays in sync
            // with the rest of the suite's spinner conventions.
            let indicator = UIActivityIndicatorView.make(
                style: style,
                color: color ?? .systemGray
            )
            base.addSubview(indicator)
            indicator.centerInSuperview()
            indicator.startAnimating()
        }
    }

    @MainActor
    private func removePlaceholderViews() {
        base.subviews.filter { $0 is UIActivityIndicatorView }.forEach { $0.removeFromSuperview() }
    }

    /// Pixel-sized target for full-screen viewers. Asking PhotoKit for
    /// the screen size (rather than `PHImageManagerMaximumSize`) lets
    /// it serve rendered previews and avoids the iCloud Original
    /// download path that frequently times out
    /// (`PHPhotosErrorDomain` `3169`).
    @MainActor
    private static var fullScreenPhotosTargetSize: CGSize {
        let bounds = UIScreen.main.bounds.size
        let scale = UIScreen.main.scale
        return CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}

/// Holds the latest degraded preview across a PhotoKit opportunistic
/// delivery sequence.
///
/// Read and written exclusively from `MainActor.assumeIsolated`
/// blocks; the `@unchecked Sendable` mark is required because
/// PhotoKit's handler signature is itself `@Sendable`. The actual
/// thread-safety guarantee comes from the main-thread invariant the
/// handler is invoked under.
private final class PhotosDeliveryState: @unchecked Sendable {
    var lastDegraded: UIImage?
}
