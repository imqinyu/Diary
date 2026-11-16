import Foundation

/// 一条日记文件的完整内容：YAML front matter + Markdown 正文。
struct EntryDocument {
    var frontMatter: FrontMatter
    var body: String

    static func read(from url: URL) throws -> EntryDocument {
        let text = try String(contentsOf: url, encoding: .utf8)
        return decode(text)
    }

    static func decode(_ text: String) -> EntryDocument {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---") else {
            return EntryDocument(frontMatter: FrontMatter(), body: normalized)
        }

        var lines = normalized.components(separatedBy: "\n")
        lines.removeFirst() // 首行 `---`

        var frontMatterLines: [String] = []
        var bodyLines: [String] = []
        var insideBody = false

        for line in lines {
            if !insideBody, line.trimmingCharacters(in: .whitespaces) == "---" {
                insideBody = true
                continue
            }
            if insideBody {
                bodyLines.append(line)
            } else {
                frontMatterLines.append(line)
            }
        }

        var body = bodyLines.joined(separator: "\n")
        while body.hasPrefix("\n") { body.removeFirst() }
        // 结尾的空行没有语义，读回来时统一去掉，保证「写出-读回」稳定
        while body.hasSuffix("\n") { body.removeLast() }
        return EntryDocument(frontMatter: FrontMatter.parse(frontMatterLines), body: body)
    }

    func encode() -> String {
        let yaml = frontMatter.serialized()
        let body = self.body.hasSuffix("\n") ? self.body : self.body + "\n"
        return "---\n\(yaml)\n---\n\n\(body)"
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encode().write(to: url, atomically: true, encoding: .utf8)
    }
}
