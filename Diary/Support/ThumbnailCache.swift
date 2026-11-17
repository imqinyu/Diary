import AppKit
import CryptoKit

/// 相册缩略图。用 ImageIO 生成缩略图，避免把大图整张解码进内存。
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    private var generation = 0

    func thumbnail(for url: URL, data: Data? = nil, maxPixel: CGFloat) async -> CGImage? {
        let requestedGeneration = generation
        let identity = await Task.detached(priority: .userInitiated) {
            data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? url.path
        }.value
        guard requestedGeneration == generation, !Task.isCancelled else { return nil }
        let key = "\(identity)|\(Int(maxPixel))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let pixel = Int(maxPixel)
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            Self.makeThumbnail(url: url, data: data, maxPixel: pixel)
        }.value
        guard requestedGeneration == generation, !Task.isCancelled else { return nil }
        if let image { cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height) }
        return image
    }

    func forget(url: URL) {
        generation += 1
        cache.removeAllObjects()
    }

    func clear() { generation += 1; cache.removeAllObjects() }

    nonisolated private static func makeThumbnail(url: URL, data: Data?, maxPixel: Int) -> CGImage? {
        let source = data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) } ?? CGImageSourceCreateWithURL(url as CFURL, nil)
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
