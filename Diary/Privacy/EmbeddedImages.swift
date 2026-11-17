import Foundation

/// Standard Markdown data URIs are sealed together with the body, never stored in a photo cache.
enum EmbeddedImages {
    enum Failure: LocalizedError {
        case unreadable(String), tooLarge, encryption
        var errorDescription: String? {
            switch self {
            case .unreadable(let path): return "图片无法读取，原日记未修改：\(path)"
            case .tooLarge: return "加密后的日记超过 90 MiB，请先缩小图片"
            case .encryption: return "日记加密失败，原文件已保留"
            }
        }
    }
    static func uri(_ data: Data, extension ext: String) throws -> String {
        guard data.count <= SyncFileStore.maximumFileSize / 2 else { throw Failure.tooLarge }
        let type: String
        switch ext.lowercased() {
        case "jpg", "jpeg": type = "jpeg"
        case "tif", "tiff": type = "tiff"
        case "svg": type = "svg+xml"
        case "png", "gif", "webp", "bmp", "heic", "heif", "avif": type = ext.lowercased()
        default: type = "png"
        }
        return "data:image/\(type);base64,\(data.base64EncodedString())"
    }
    static func bytes(_ path: String) -> Data? {
        guard path.hasPrefix("data:image/"), let comma = path.firstIndex(of: ","), path[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(path[path.index(after: comma)...]))
    }
    static func needsEmbedding(_ markdown: String) -> Bool {
        MarkdownText.imagePaths(markdown).contains { !$0.hasPrefix("data:image/") }
    }
    static func embed(_ markdown: String, read: (String) throws -> Data) throws -> String {
        let regex = try NSRegularExpression(pattern: "!\\[[^\\]]*\\]\\(([^)]+)\\)")
        var result = markdown
        for match in regex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)).reversed() {
            guard let range = Range(match.range(at: 1), in: result) else { continue }
            let path = String(result[range])
            if path.hasPrefix("data:image/") {
                guard bytes(path) != nil else { throw Failure.unreadable(path) }
            } else {
                let data = try read(path)
                result.replaceSubrange(range, with: try uri(data, extension: URL(fileURLWithPath: path).pathExtension))
            }
        }
        return result
    }
}
