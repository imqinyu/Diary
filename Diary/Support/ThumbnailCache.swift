import AppKit

/// 相册缩略图。用 ImageIO 生成缩略图，避免把大图整张解码进内存。
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private var cache: [String: CGImage] = [:]

    func thumbnail(for url: URL, maxPixel: CGFloat) async -> CGImage? {
        let key = "\(url.path)|\(Int(maxPixel))"
        if let cached = cache[key] { return cached }
        let pixel = Int(maxPixel)
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            Self.makeThumbnail(url: url, maxPixel: pixel)
        }.value
        if let image { cache[key] = image }
        return image
    }

    func forget(url: URL) {
        cache = cache.filter { !$0.key.hasPrefix(url.path) }
    }

    nonisolated private static func makeThumbnail(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
