import Foundation

// MARK: - 日期键工具

enum DayKey {
    /// `yyyy-MM-dd`，按本机时区。
    static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.timeZone = .current
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.timeZone = .current
        f.dateFormat = "EEEE"
        return f
    }()

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.timeZone = .current
        f.dateFormat = "M月d日"
        return f
    }()

    static func string(from date: Date) -> String {
        keyFormatter.string(from: date)
    }

    static func today() -> String {
        string(from: Date())
    }

    static func date(from key: String) -> Date? {
        keyFormatter.date(from: key)
    }

    /// `2026年11月14日`
    static func display(_ key: String) -> String {
        guard let date = date(from: key) else { return key }
        return displayFormatter.string(from: date)
    }

    /// `星期六`
    static func weekday(_ key: String) -> String {
        guard let date = date(from: key) else { return "" }
        return weekdayFormatter.string(from: date)
    }

    /// `11月14日`
    static func short(_ key: String) -> String {
        guard let date = date(from: key) else { return key }
        return shortFormatter.string(from: date)
    }
}

// MARK: - ISO8601

enum ISO8601 {
    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    static func string(_ date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return formatter.date(from: string)
    }
}

// MARK: - 文件名解析

/// `2026-11-14-2` → (dayKey: "2026-11-14", sequence: 2)
enum EntryFileName {
    static func parse(_ stem: String) -> (dayKey: String, sequence: Int)? {
        let parts = stem.split(separator: "-")
        guard parts.count == 4,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              Int(parts[0]) != nil, Int(parts[1]) != nil, Int(parts[2]) != nil,
              let seq = Int(parts[3]) else { return nil }
        return ("\(parts[0])-\(parts[1])-\(parts[2])", seq)
    }

    static func stem(dayKey: String, sequence: Int) -> String {
        "\(dayKey)-\(sequence)"
    }
}

// MARK: - 字数

enum WordCounter {
    /// 中日韩字符按字计，拉丁文按词计，标点与空白不计。
    static func count(_ text: String) -> Int {
        var total = 0
        var inLatinWord = false
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                total += 1
                inLatinWord = false
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) || isPunctuation(scalar) {
                inLatinWord = false
            } else {
                if !inLatinWord { total += 1 }
                inLatinWord = true
            }
        }
        return total
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x3040...0x30FF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.punctuationCharacters.contains(scalar)
    }
}

// MARK: - 纯文本提取

enum MarkdownText {
    /// 去掉 Markdown 标记，用于列表里的正文预览。
    static func plain(_ markdown: String) -> String {
        var text = markdown
        text = text.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]+\\)", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "!\\[[^\\]]*\\]\\[[^\\]]*\\]", with: "", options: .regularExpression)
        for token in ["**", "~~", "<u>", "</u>", "*", "_"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        text = text.replacingOccurrences(of: "\\", with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func excerpt(_ markdown: String, limit: Int = 120) -> String {
        let plain = plain(markdown).replacingOccurrences(of: "\n", with: " ")
        let collapsed = plain.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    static func imageCount(_ markdown: String) -> Int {
        imagePaths(markdown).count
    }

    /// 抽出正文里引用的图片路径（保持出现顺序）。
    static func imagePaths(_ markdown: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "!\\[[^\\]]*\\]\\(([^)]+)\\)") else { return [] }
        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        return regex.matches(in: markdown, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let pathRange = Range(match.range(at: 1), in: markdown) else { return nil }
            return String(markdown[pathRange])
        }
    }
}
