import UIKit

/// A single delivery event emitted during the lifecycle of a
/// `setImage(with:placeholder:targetSize:delivery:)` request.
///
/// The type abstracts PhotoKit's "opportunistic" delivery model so that
/// callers can answer the three questions they actually care about
/// — *do I have an image to display, did the final-quality version
/// arrive, and did anything fail?* — without leaking framework
/// specifics into the call site.
///
/// ## Per-source behaviour
/// - **Network / File**: emits exactly one of ``final(_:)`` or
///   ``failed(_:)``. ``degraded(_:)`` and ``degradedOnlyFinalFailed(degraded:error:)``
///   are never produced.
/// - **Photos**: opportunistic delivery may emit ``degraded(_:)`` first
///   (low-resolution preview) followed by ``final(_:)``. If the final
///   quality cannot be produced after a degraded preview was delivered,
///   ``degradedOnlyFinalFailed(degraded:error:)`` is emitted — the
///   `UIImageView` still has a visible image, but the caller can
///   surface a "full quality unavailable" state to the user.
///
/// `@MainActor` isolation is intentional: every delivery callback is
/// dispatched on the main thread because the UI mutations that follow
/// must be main-thread isolated.
@MainActor
public enum HomerImageDelivery {

    /// First (low-resolution) delivery in PhotoKit's opportunistic
    /// stream. Never produced by network or file sources.
    case degraded(UIImage)

    /// Final, full-quality image delivered. After this event, no
    /// further deliveries are produced for the request.
    case `final`(UIImage)

    /// Photos-specific terminal event: a degraded preview was
    /// delivered but PhotoKit could not produce the full-quality
    /// image. The image view continues to show the degraded preview,
    /// and the caller can present a "full-resolution unavailable"
    /// notice. Never produced by network or file sources.
    case degradedOnlyFinalFailed(degraded: UIImage, error: Error)

    /// No image could be produced. Triggered by a network / file
    /// transport error, an asset-not-found Photos lookup, or a
    /// Photos opportunistic delivery whose first callback already
    /// returned `nil`.
    case failed(Error)
}
