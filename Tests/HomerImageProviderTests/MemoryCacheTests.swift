import Testing
import UIKit
@testable import HomerImageProvider

@Suite("MemoryCache")
struct MemoryCacheTests {

    @Test("get returns the image previously stored for the key")
    func setThenGet() {
        let cache = MemoryCache()
        let image = makeImage(side: 4)

        cache.set(image, forKey: "a")

        #expect(cache.get(forKey: "a") === image)
    }

    @Test("get returns nil for a key that was never stored")
    func missingKeyReturnsNil() {
        let cache = MemoryCache()
        #expect(cache.get(forKey: "absent") == nil)
    }

    @Test("set overwrites an existing entry for the same key")
    func overwrite() {
        let cache = MemoryCache()
        let first = makeImage(side: 4)
        let second = makeImage(side: 8)

        cache.set(first, forKey: "a")
        cache.set(second, forKey: "a")

        #expect(cache.get(forKey: "a") === second)
    }

    @Test("remove deletes the entry for the key and leaves others intact")
    func removeIsScopedToKey() {
        let cache = MemoryCache()
        let kept = makeImage(side: 4)
        cache.set(makeImage(side: 4), forKey: "doomed")
        cache.set(kept, forKey: "kept")

        cache.remove(forKey: "doomed")

        #expect(cache.get(forKey: "doomed") == nil)
        #expect(cache.get(forKey: "kept") === kept)
    }

    @Test("remove on an absent key is a no-op")
    func removeAbsentKeyDoesNotCrash() {
        let cache = MemoryCache()
        cache.remove(forKey: "absent")
    }
}

// MARK: - Helpers

/// Renders a solid square so each test stores a distinct, real
/// `UIImage` instance with a non-zero cost.
private func makeImage(side: CGFloat) -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
        UIColor.systemRed.setFill()
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    }
}
