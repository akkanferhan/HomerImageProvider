import Foundation
import HomerFoundation

/// Tunables shared by every component inside ``HomerImageProviderManager``.
///
/// Conform a type to `HomerConfigurationProtocol` and pass it to
/// ``HomerImageProviderManager/configure(with:)`` to override the
/// defaults baked into ``HomerDefaultConfiguration``.
///
/// All conformers must be `Sendable` because the configuration is read
/// from the manager's `actor` isolation domain on every request.
public protocol HomerConfigurationProtocol: Sendable {
    /// Upper bound on the number of in-flight network downloads
    /// allowed by the loader's ``TaskQueue``. Default: `6`.
    var maxConcurrentTasks: Int { get }

    /// Memory-cache (`NSCache`) cost limit in megabytes. Default:
    /// `500` MB.
    var memoryCacheLimitMB: Int { get }

    /// Disk-cache size limit in megabytes; the cache prunes by
    /// least-recent access once exceeded. Default: `2000` MB.
    var diskCacheLimitMB: Int { get }

    /// Retry strategy applied when downloads come back with a `408`,
    /// `429`, or `503` status code.
    ///
    /// Backed by `HomerFoundation.HTTPRetryPolicy`, which parses the
    /// `Retry-After` header (delay-seconds and HTTP-date forms),
    /// applies exponential backoff with jitter, and clamps the
    /// computed delay to `[minDelay, maxDelay]`. Sharing the same
    /// instance with HomerNetwork's JSON client keeps backoff
    /// windows consistent when both layers hit the same upstream
    /// (typical when the image CDN is fronted by the same CloudFlare
    /// account as the API).
    var retryPolicy: HTTPRetryPolicy { get }
}

public extension HomerConfigurationProtocol {
    /// Default ``retryPolicy`` so that legacy conformers (which
    /// predate the property) keep compiling without explicitly
    /// providing a value.
    var retryPolicy: HTTPRetryPolicy { .default }
}

/// Built-in configuration used by ``HomerImageProviderManager`` when
/// no custom configuration is supplied.
///
/// ## Why these defaults
/// - `maxConcurrentTasks = 6`: balances HTTP/2 multiplexing throughput
///   against CloudFlare's per-IP burst protection. At `2` we measured
///   roughly 20 % `429` rate while scrolling fast collection views,
///   and visible cells lagged because image tasks queued up behind
///   off-screen work that hadn't been cancelled yet. `6` keeps the
///   queue draining at cell-reuse speed and `HTTPRetryPolicy`
///   transparently absorbs any residual `429` responses.
/// - `memoryCacheLimitMB = 500`: roomy enough to keep a long
///   collection-view scroll fully cached, falling back to disk only
///   on cold restart.
/// - `diskCacheLimitMB = 2000`: prevents the disk store from growing
///   unbounded across long sessions while still surviving multiple
///   feed reloads.
public struct HomerDefaultConfiguration: HomerConfigurationProtocol {
    public let maxConcurrentTasks: Int = 6
    public let memoryCacheLimitMB: Int = 500
    public let diskCacheLimitMB: Int = 2000
    public let retryPolicy: HTTPRetryPolicy = .default

    /// Creates a default configuration. All members are `let`, so
    /// override by conforming a custom type to ``HomerConfigurationProtocol``.
    public init() {}
}
