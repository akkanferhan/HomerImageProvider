import Photos

/// Adapter that forwards `PHPhotoLibraryChangeObserver` callbacks
/// into `AsyncStream` element production.
///
/// Internal — exists because `NSObject` + `PHPhotoLibraryChangeObserver`
/// conformance cannot be expressed on an actor. The bridge stays
/// `final class` so the framework can call back into it via Objective-C
/// dispatch, and `@unchecked Sendable` is sound here because the only
/// stored reference is an immutable `@Sendable` closure.
final class PhotoLibraryChangeObserverBridge: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {

    private let onChange: @Sendable () -> Void

    /// Creates a bridge that calls `onChange` on every
    /// `PHPhotoLibraryChangeObserver.photoLibraryDidChange(_:)` invocation.
    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    /// PhotoKit invokes this whenever the user's library changes;
    /// the bridge ignores the `PHChange` payload and simply yields a
    /// "recompute" tick to the consuming stream.
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}
