import Foundation
import HomerFoundation
import Photos
import UIKit

/// Low-level transport for image bytes.
///
/// `ImageLoader` is `actor`-isolated and exposes two responsibilities:
///
/// - ``download(from:)`` — fetches image bytes over `URLSession`,
///   honouring `Retry-After` and `HTTPRetryPolicy` for transient
///   `408` / `429` / `503` responses.
/// - ``fetchFromPhotos(localIdentifier:targetSize:)`` — bridges
///   PhotoKit's continuation-based image API into async / await.
///
/// The loader intentionally has no awareness of caches or downsampling
/// — those concerns live in ``HomerImageProviderManager``.
public actor ImageLoader {
    private let session: URLSession
    private let retryPolicy: HTTPRetryPolicy

    /// Creates a loader with the given session and retry policy.
    /// - Parameters:
    ///   - session: The URLSession used for downloads. Defaults to
    ///     `URLSession.shared` so callers that don't need session
    ///     isolation can construct without ceremony.
    ///   - retryPolicy: The retry policy applied to `408` / `429` /
    ///     `503` responses. Sharing one policy with HomerNetwork's
    ///     JSON client keeps backoff windows aligned across
    ///     transports — see ``HomerConfigurationProtocol/retryPolicy``.
    public init(session: URLSession = .shared, retryPolicy: HTTPRetryPolicy = .default) {
        self.session = session
        self.retryPolicy = retryPolicy
    }

    /// Downloads the bytes at `url`, retrying transparently on
    /// transient HTTP failures.
    ///
    /// The loop consults ``HTTPRetryPolicy/shouldRetry(statusCode:attempt:)``
    /// after every non-2xx response. Retryable status codes (default
    /// `408`, `429`, `503`) trigger a sleep computed from the
    /// `Retry-After` header (when present) or exponential backoff with
    /// jitter; non-retryable failures throw an `NSError` carrying the
    /// status code so the manager can surface it through
    /// ``HomerImageDelivery/failed(_:)``.
    /// - Parameter url: The URL to fetch.
    /// - Returns: The raw response bytes on a 2xx response.
    /// - Throws: `NSError` with `Constants.errorDomain` for invalid
    ///   responses or non-retryable HTTP failures, or any
    ///   `URLSession`-thrown transport error.
    public func download(from url: URL) async throws -> Data {
        var attempt = 0
        while true {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(
                    domain: Constants.errorDomain,
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid response"]
                )
            }

            if (200...299).contains(httpResponse.statusCode) {
                return data
            }

            if retryPolicy.shouldRetry(statusCode: httpResponse.statusCode, attempt: attempt) {
                let header = httpResponse.value(forHTTPHeaderField: Constants.retryAfterHeader)
                let delay = retryPolicy.delay(forAttempt: attempt, retryAfterHeader: header)
                try await Task.sleep(nanoseconds: UInt64(delay * Double(NSEC_PER_SEC)))
                attempt += 1
                continue
            }

            throw NSError(
                domain: Constants.errorDomain,
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"]
            )
        }
    }

    /// Resolves a `PHAsset` for `localIdentifier` and asks PhotoKit
    /// for a high-quality `UIImage` at `targetSize`.
    ///
    /// The implementation prefers the asset map maintained by
    /// ``HomerPhotosImageService`` and falls back to a fresh
    /// `PHAsset.fetchAssets(withLocalIdentifiers:)` when the cache
    /// has been invalidated. PhotoKit is configured with
    /// `deliveryMode = .highQualityFormat` and `resizeMode = .fast`
    /// so degraded callbacks are skipped — only the final result
    /// resumes the continuation.
    /// - Parameters:
    ///   - localIdentifier: `PHAsset.localIdentifier` of the target
    ///     asset.
    ///   - targetSize: Requested point size. Pass `nil` to receive
    ///     `PHImageManagerMaximumSize`.
    /// - Returns: A `UIImage` produced by PhotoKit.
    /// - Throws: An `NSError` for asset-not-found / unknown delivery
    ///   states, or any `Error` propagated from
    ///   `PHImageErrorKey`.
    public func fetchFromPhotos(localIdentifier: String, targetSize: CGSize?) async throws -> UIImage {
        let asset: PHAsset
        if let cached = HomerPhotosImageService.shared.asset(for: localIdentifier) {
            asset = cached
        } else {
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
            guard let firstAsset = fetchResult.firstObject else {
                throw NSError(
                    domain: Constants.errorDomain,
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "PHAsset not found"]
                )
            }
            asset = firstAsset
        }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            PHCachingImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize ?? PHImageManagerMaximumSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                guard !didResume else { return }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                didResume = true
                if let image = image {
                    continuation.resume(returning: image)
                } else if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: Constants.errorDomain,
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Unknown PHAsset error"]
                    ))
                }
            }
        }
    }

    private enum Constants {
        static let errorDomain = "HomerImageProvider"
        static let retryAfterHeader = "Retry-After"
    }
}
