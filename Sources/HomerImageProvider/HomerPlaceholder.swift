import UIKit

/// Placeholder content displayed while an image request is in flight.
///
/// Pass one of these cases to
/// ``UIImageView/setImage(with:placeholder:targetSize:delivery:)`` to
/// fill the receiver until the network or PhotoKit delivery completes.
/// Picking the right placeholder is purely a UX choice:
///
/// - ``image(_:)`` — replaces the receiver's `image` directly. Good
///   for static "no photo yet" art that should never disappear from
///   layout (the constraints stay stable because the image view's
///   intrinsic size doesn't change).
/// - ``activityIndicator(style:color:)`` — clears `image` and centres
///   a spinning `UIActivityIndicatorView` over the receiver, removed
///   automatically when the real image arrives. Good for cells that
///   start blank and need an in-place loading hint.
public enum HomerPlaceholder {
    /// A pre-loaded image displayed while the real image is fetched.
    case image(UIImage)

    /// A `UIActivityIndicatorView` overlaid on the receiver. The
    /// indicator is centered, started immediately, and removed when
    /// the real image is delivered or when ``UIImageView/cancelDownload()``
    /// is invoked.
    /// - Parameters:
    ///   - style: Indicator style. Defaults to `.medium`.
    ///   - color: Indicator tint. `nil` keeps the system default
    ///     (which adapts to light / dark mode).
    case activityIndicator(style: UIActivityIndicatorView.Style = .medium, color: UIColor? = nil)
}
