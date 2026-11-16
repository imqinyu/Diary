import Foundation

/// front matter 里能表达的值。只支持 YAML 的一个小子集，
/// 目标是「人能读、能手改、写回去不丢信息」。
enum YAMLValue {
    case scalar(String)
    case list([String])
    case map([(String, String)])
    /// 解析不了的结构原样保留，避免手写内容被抹掉。
    case raw(String)
}

/// 有序的 front matter。顺序固定 = diff 好看。
struct FrontMatter {
    var items: [(key: String, value: YAMLValue)] = []

    func value(_ key: String) -> YAMLValue? {
        items.first { $0.key == key }?.value
    }

    func string(_ key: String) -> String? {
        if case .scalar(let text)? = value(key) { return text }
        return nil
    }

    func int(_ key: String) -> Int? {
        string(key).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    func double(_ key: String) -> Double? {
        string(key).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    func bool(_ key: String) -> Bool? {
        guard let text = string(key)?.lowercased() else { return nil }
        if text == "true" { return true }
        if text == "false" { return false }
        return nil
    }

    func list(_ key: String) -> [String]? {
        if case .list(let values)? = value(key) { return values }
        return nil
    }

    func map(_ key: String) -> [String: String] {
        guard case .map(let pairs)? = value(key) else { return [:] }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    mutating func set(_ key: String, _ newValue: YAMLValue?) {
        if let index = items.firstIndex(where: { $0.key == key }) {
            if let newValue {
                items[index].value = newValue
            } else {
                items.remove(at: index)
            }
        } else if let newValue {
            items.append((key: key, value: newValue))
        }
    }

    // MARK: - 序列化

    func serialized() -> String {
        items
            .map { "\(Self.quoteIfNeeded($0.key)): \(Self.render($0.value))" }
            .joined(separator: "\n")
    }

    private static func render(_ value: YAMLValue) -> String {
        switch value {
        case .scalar(let text):
            return quoteIfNeeded(text)
        case .list(let values):
            return "[" + values.map { quoteIfNeeded($0, inFlow: true) }.joined(separator: ", ") + "]"
        case .map(let pairs):
            let rendered = pairs.map { pair in
                "\(quoteIfNeeded(pair.0, inFlow: true)): \(quoteIfNeeded(pair.1, inFlow: true))"
            }
            return "{" + rendered.joined(separator: ", ") + "}"
        case .raw(let text):
            return text
        }
    }

    /// 只在真的会破坏 YAML 时才加引号，这样 `created: 2026-11-14T21:03:10+08:00`
    /// 这种值在文件里保持可读。
    private static let leadingIndicators: Set<Character> = [
        "-", "?", ":", ",", "[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`"
    ]

    static func quoteIfNeeded(_ text: String, inFlow: Bool = false) -> String {
        if text.isEmpty { return "\"\"" }

        let needsQuote: Bool
        if text.first == " " || text.last == " " || text.first == "\n" {
            needsQuote = true
        } else if let first = text.first, leadingIndicators.contains(first) {
            needsQuote = true
        } else if text.contains("\n") || text.contains("\t") || text.contains("\"") {
            needsQuote = true
        } else if text.contains(": ") || text.contains(" #") {
            needsQuote = true
        } else if inFlow, text.contains(where: { ",[]{}".contains($0) }) {
            needsQuote = true
        } else {
            needsQuote = false
        }

        guard needsQuote else { return text }
        var escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        escaped = "\"\(escaped)\""
        return escaped
    }

    static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        var inner = String(text.dropFirst().dropLast())
        inner = inner.replacingOccurrences(of: "\\n", with: "\n")
        inner = inner.replacingOccurrences(of: "\\\"", with: "\"")
        inner = inner.replacingOccurrences(of: "\\\\", with: "\\")
        return inner
    }

    // MARK: - 解析

    static func parse(_ lines: [String]) -> FrontMatter {
        var frontMatter = FrontMatter()
        var index = 0

        while index < lines.count {
            let line = lines[index]
            index += 1

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // 顶格之外的缩进行属于上一个键，这里单独处理不了就跳过。
            guard !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }

            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            if rest.isEmpty {
                // 可能是块状映射（下一层缩进）
                var pairs: [(String, String)] = []
                while index < lines.count {
                    let sub = lines[index]
                    let subTrimmed = sub.trimmingCharacters(in: .whitespaces)
                    if subTrimmed.isEmpty { index += 1; continue }
                    guard sub.hasPrefix(" ") || sub.hasPrefix("\t") else { break }
                    if let subColon = subTrimmed.firstIndex(of: ":") {
                        let subKey = String(subTrimmed[subTrimmed.startIndex..<subColon]).trimmingCharacters(in: .whitespaces)
                        let subValue = String(subTrimmed[subTrimmed.index(after: subColon)...]).trimmingCharacters(in: .whitespaces)
                        pairs.append((subKey, unquote(subValue)))
                    } else {
                        pairs.append((subTrimmed, ""))
                    }
                    index += 1
                }
                frontMatter.set(key, pairs.isEmpty ? .scalar("") : .map(pairs))
            } else if rest.hasPrefix("["), rest.hasSuffix("]") {
                let inner = String(rest.dropFirst().dropLast())
                frontMatter.set(key, .list(splitFlow(inner).map { unquote($0) }))
            } else if rest.hasPrefix("{"), rest.hasSuffix("}") {
                let inner = String(rest.dropFirst().dropLast())
                var pairs: [(String, String)] = []
                for part in splitFlow(inner) {
                    if let colon = part.firstIndex(of: ":") {
                        let subKey = String(part[part.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                        let subValue = String(part[part.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                        pairs.append((subKey, unquote(subValue)))
                    }
                }
                frontMatter.set(key, pairs.isEmpty ? .scalar("") : .map(pairs))
            } else {
                frontMatter.set(key, .scalar(unquote(rest)))
            }
        }

        return frontMatter
    }

    /// 按逗号切分，跳过引号内的逗号。
    private static func splitFlow(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var insideQuote = false
        for character in text {
            if character == "\"" {
                insideQuote.toggle()
                current.append(character)
                continue
            }
            if character == ",", !insideQuote {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(character)
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { parts.append(tail) }
        return parts.filter { !$0.isEmpty }
    }
}
