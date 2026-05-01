import Foundation

/// Typed error surface produced by the
/// ``HomerImageProvider/setImage(with:placeholder:targetSize:delivery:)``
/// delivery flow.
///
/// `HomerImageError` collects PhotoKit anomalies (`PHPhotosErrorDomain`)
/// and library-internal cases (asset-map miss, opportunistic delivery
/// returning `nil`) under a single type so callers can pattern-match
/// on a closed set of values rather than chasing untyped `NSError`s.
///
/// `Equatable` is synthesized — cases have no associated values, so the
/// default member-wise comparison is correct and zero-maintenance when
/// new cases are added.
public enum HomerImageError: Error, Equatable {

    /// The `localIdentifier` supplied to a
    /// ``HomerImageSource/photos(localIdentifier:)`` source could not be
    /// resolved by PhotoKit. Either the asset was deleted from the
    /// user's library or the identifier was never registered with
    /// ``HomerPhotosImageService/register(assets:)``.
    case photosAssetNotFound

    /// PhotoKit returned a `nil` image with neither a degraded preview
    /// nor a usable error in the result `info` dictionary. Treated as
    /// a generic delivery failure that callers cannot recover from
    /// without retrying.
    case photosImageUnavailable

    /// A degraded preview was delivered but PhotoKit could not produce
    /// the final, full-quality version. The most common cause is the
    /// iCloud original failing to download (`PHPhotosErrorDomain` `3169`)
    /// — the user sees the low-resolution thumbnail and the caller is
    /// notified that no upgrade is coming.
    case photosFinalQualityUnavailable
}
