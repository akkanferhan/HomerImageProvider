import Foundation
import ImageIO
import UIKit

/// Memory-efficient image downsampling utilities.
///
/// `ImageProcessor` resizes encoded image bytes (typically JPEG or
/// PNG) into a `UIImage` of a target point size by going through
/// `CGImageSource`'s thumbnail API. The pipeline never decodes the
/// full-resolution image into memory — `kCGImageSourceShouldCache` is
/// disabled and the source is asked to produce a thumbnail at the
/// pixel size required for display, which is dramatically lower than
/// loading + resizing in two passes.
public enum ImageProcessor {

    /// Downsamples encoded image bytes to the supplied point size.
    ///
    /// The function reads `UIScreen.main.scale` from the main actor
    /// once (so callers don't need to be `@MainActor`-isolated) and
    /// then runs the rest of the work in a `nonisolated` helper —
    /// downsampling is CPU-bound and benefits from staying off the
    /// main actor when called from background tasks.
    ///
    /// - Parameters:
    ///   - data: Encoded image bytes (JPEG, PNG, HEIC, …).
    ///   - pointSize: Display size in points; the function multiplies
    ///     by the screen scale internally to derive the target pixel
    ///     dimension passed to `kCGImageSourceThumbnailMaxPixelSize`.
    ///   - scale: Optional override for the screen scale. Pass a
    ///     specific value when you know the target context (e.g.
    ///     `2.0` for `@2x` mocks); leave `nil` to read
    ///     `UIScreen.main.scale` on the main actor.
    /// - Returns: A `UIImage` whose largest dimension matches
    ///   `max(pointSize.width, pointSize.height) * scale` pixels, or
    ///   `nil` if `data` could not be decoded by `CGImageSource`.
    public static func downsample(
        data: Data,
        to pointSize: CGSize,
        scale: CGFloat? = nil
    ) async -> UIImage? {
        let resolvedScale: CGFloat
        if let scale {
            resolvedScale = scale
        } else {
            resolvedScale = await MainActor.run { UIScreen.main.scale }
        }
        return Self.downsampleNonisolated(data: data, to: pointSize, scale: resolvedScale)
    }

    /// CPU-bound downsampling kernel. Stays `nonisolated` so it can
    /// run on whichever executor the calling task happens to be on.
    private static func downsampleNonisolated(data: Data, to pointSize: CGSize, scale: CGFloat) -> UIImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, imageSourceOptions) else { return nil }

        let maxDimensionInPixels = max(pointSize.width, pointSize.height) * scale
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimensionInPixels
        ] as CFDictionary

        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions) else { return nil }
        return UIImage(cgImage: downsampledImage)
    }
}
