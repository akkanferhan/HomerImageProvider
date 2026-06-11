import Foundation
import Testing
@testable import HomerImageProvider

@Suite("HomerImageSource")
struct HomerImageSourceTests {

    // MARK: - cacheKey stability

    @Test("network source uses the absolute URL string as its cache key")
    func networkCacheKey() throws {
        let url = try #require(URL(string: "https://cdn.example.com/images/42.png?w=100"))
        let source = HomerImageSource.network(url)
        #expect(source.cacheKey == "https://cdn.example.com/images/42.png?w=100")
    }

    @Test("photos source prefixes the local identifier with phasset://")
    func photosCacheKey() {
        let source = HomerImageSource.photos(localIdentifier: "ABC-123/L0/001")
        #expect(source.cacheKey == "phasset://ABC-123/L0/001")
    }

    @Test("file source uses the percent-decoded file system path")
    func fileCacheKey() {
        let url = URL(fileURLWithPath: "/tmp/some image.png")
        let source = HomerImageSource.file(url)
        #expect(source.cacheKey == "/tmp/some image.png")
    }

    // MARK: - Collision resistance

    @Test("photos and file sources with lookalike values produce distinct keys")
    func photosAndFileKeysDoNotCollide() {
        let photos = HomerImageSource.photos(localIdentifier: "/tmp/some image.png")
        let file = HomerImageSource.file(URL(fileURLWithPath: "/tmp/some image.png"))
        #expect(photos.cacheKey != file.cacheKey)
    }

    // MARK: - Hashable

    @Test("equal sources are interchangeable as dictionary keys")
    func hashableSemantics() throws {
        let url = try #require(URL(string: "https://cdn.example.com/a.png"))
        var dictionary: [HomerImageSource: Int] = [:]
        dictionary[.network(url)] = 1
        dictionary[.network(url)] = 2
        dictionary[.photos(localIdentifier: "id-1")] = 3

        #expect(dictionary.count == 2)
        #expect(dictionary[.network(url)] == 2)
    }
}
