import AppKit

extension NSAttributedString.Key {
    /// 图片在条目目录下的相对路径。存在这个属性，导出时就不会退化成 base64。
    static let diaryImagePath = NSAttributedString.Key("DiaryImagePath")
    /// 「最后编辑于」是界面附加在正文末尾的一行，不属于日记内容，写盘时必须跳过。
    static let diaryFooter = NSAttributedString.Key("DiaryFooter")
}

/// NSAttributedString ⇄ Markdown。
/// 只覆盖我们自己会写出的子集：粗体、斜体、下划线、删除线、图片。
enum MarkdownCodec {

    struct Style {
        var bold = false
        var italic = false
        var underline = false
        var strikethrough = false
    }

    static let baseFontSize: CGFloat = 15

    static var baseFont: NSFont {
        NSFont.systemFont(ofSize: baseFontSize)
    }

    static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = 8
        return style
    }

    static func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle()
        ]
    }

    static func attributes(for style: Style) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes()
        attributes[.font] = font(for: style)
        if style.underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    static func font(for style: Style) -> NSFont {
        var font = baseFont
        let manager = NSFontManager.shared
        if style.bold { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if style.italic { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    // MARK: - 编码

    static func encode(_ attributed: NSAttributedString) -> String {
        var lines: [String] = []
        var current = ""
        let fullRange = NSRange(location: 0, length: attributed.length)
        let source = attributed.string as NSString

        attributed.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            // 界面附加的尾部时间戳不写进 Markdown 文件
            if attributes[.diaryFooter] as? Bool == true { return }

            if let attachment = attributes[.attachment] as? NSTextAttachment {
                current += encodeAttachment(attachment, attributes: attributes)
                return
            }

            let segment = source.substring(with: range)
            let parts = segment.components(separatedBy: "\n")
            for (offset, part) in parts.enumerated() {
                if offset > 0 {
                    lines.append(current)
                    current = ""
                }
                current += encodeRun(part, attributes: attributes)
            }
        }

        lines.append(current)

        var result = lines.joined(separator: "\n")
        // 结尾多余的空白行没有意义
        while result.hasSuffix("\n\n") { result.removeLast() }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func encodeAttachment(
        _ attachment: NSTextAttachment,
        attributes: [NSAttributedString.Key: Any]
    ) -> String {
        if let relativePath = attributes[.diaryImagePath] as? String {
            return "![](\(relativePath))"
        }
        if let data = attachment.fileWrapper?.regularFileContents
            ?? attachment.contents {
            return "![](data:image/png;base64,\(data.base64EncodedString()))"
        }
        return ""
    }

    private static func encodeRun(
        _ text: String,
        attributes: [NSAttributedString.Key: Any]
    ) -> String {
        guard !text.isEmpty else { return "" }

        let font = attributes[.font] as? NSFont
        let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
        var style = Style()
        style.bold = traits.contains(.boldFontMask)
        style.italic = traits.contains(.italicFontMask)
        style.underline = (attributes[.underlineStyle] as? Int ?? 0) != 0
        style.strikethrough = (attributes[.strikethroughStyle] as? Int ?? 0) != 0

        let leading = String(text.prefix { $0 == " " })
        let trailing = String(text.reversed().prefix { $0 == " " }.reversed())
        let core = String(text.dropFirst(leading.count).dropLast(trailing.count))
        guard !core.isEmpty else { return text }

        var wrapped = escape(core)
        if style.italic {
            // 斜体统一用 `_`：这样和 `**` 相邻时不会拼出 *** 这种有歧义的写法
            wrapped = "_" + wrapped + "_"
        }
        if style.bold { wrapped = "**" + wrapped + "**" }
        if style.strikethrough { wrapped = "~~" + wrapped + "~~" }
        if style.underline { wrapped = "<u>" + wrapped + "</u>" }
        return leading + wrapped + trailing
    }

    private static let escapeTargets: Set<Character> = ["\\", "*", "_", "`", "[", "]", "<", ">", "~"]

    private static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count + 8)
        for character in text {
            if escapeTargets.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    // MARK: - 解码

    static func decode(_ markdown: String, entryDirectory: URL) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n", attributes: baseAttributes()))
            }
            let parser = InlineParser(text: line, entryDirectory: entryDirectory)
            result.append(parser.parse(style: Style(), until: nil))
        }

        if result.length == 0 {
            return NSAttributedString(string: "", attributes: baseAttributes())
        }
        return result
    }

    /// 追加在正文末尾的一行小字。跟着正文一起滚动，滚到底才看得到。
    static func footerAttributedString(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.paragraphSpacingBefore = 26
        paragraph.lineSpacing = 2

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraph,
            .diaryFooter: true
        ]
        // 末尾多一个空行，让时间戳和格式栏之间留点呼吸空间；同样带标记，不写进文件。
        return NSAttributedString(string: "\n" + text + "\n", attributes: attributes)
    }

    static func makeAttachment(path: String, entryDirectory: URL) -> NSAttributedString? {
        let url = entryDirectory.appendingPathComponent(path)
        guard let image = NSImage(contentsOf: url) else { return nil }
        return makeAttachment(image: image, path: path)
    }

    static func makeAttachment(image: NSImage, path: String?) -> NSAttributedString {
        // 先压到合理尺寸省内存，真正显示时再由 cell 按正文宽度缩放。
        let display = image.downscaled(maxWidth: 1000)
        let attachment = NSTextAttachment()
        // 只给 cell，不设 attachment.image：设了 image 会被内部 cell 顶掉，宽度就失控了。
        attachment.attachmentCell = FittingImageCell(image: display, maxWidth: 520)

        let string = NSMutableAttributedString(attachment: attachment)
        if let path {
            string.addAttribute(
                .diaryImagePath,
                value: path,
                range: NSRange(location: 0, length: string.length)
            )
        }
        return string
    }
}

// MARK: - 行内解析

private final class InlineParser {
    private let characters: [Character]
    private var index = 0
    private let entryDirectory: URL

    init(text: String, entryDirectory: URL) {
        self.characters = Array(text)
        self.entryDirectory = entryDirectory
    }

    /// 解析 `[index, end)`，遇到 end 停止。
    func parse(style: MarkdownCodec.Style, until end: Int?) -> NSAttributedString {
        let limit = end ?? characters.count
        let output = NSMutableAttributedString()
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            output.append(NSAttributedString(
                string: buffer,
                attributes: MarkdownCodec.attributes(for: style)
            ))
            buffer = ""
        }

        while index < limit {
            let character = characters[index]

            if character == "\\", index + 1 < limit {
                buffer.append(characters[index + 1])
                index += 2
                continue
            }

            if character == "!", index + 1 < limit, characters[index + 1] == "[" {
                if let image = parseImage(until: limit) {
                    flush()
                    output.append(image)
                    continue
                }
            }

            if character == "*", index + 1 < limit, characters[index + 1] == "*" {
                if let close = find("**", from: index + 2, before: limit) {
                    flush()
                    index += 2
                    var nested = style
                    nested.bold = true
                    output.append(parse(style: nested, until: close))
                    index = close + 2
                    continue
                }
            }

            if character == "*" {
                if let close = find("*", from: index + 1, before: limit) {
                    flush()
                    index += 1
                    var nested = style
                    nested.italic = true
                    output.append(parse(style: nested, until: close))
                    index = close + 1
                    continue
                }
            }

            if character == "_" {
                if let close = find("_", from: index + 1, before: limit) {
                    flush()
                    index += 1
                    var nested = style
                    nested.italic = true
                    output.append(parse(style: nested, until: close))
                    index = close + 1
                    continue
                }
            }

            if character == "~", index + 1 < limit, characters[index + 1] == "~" {
                if let close = find("~~", from: index + 2, before: limit) {
                    flush()
                    index += 2
                    var nested = style
                    nested.strikethrough = true
                    output.append(parse(style: nested, until: close))
                    index = close + 2
                    continue
                }
            }

            if character == "<", hasPrefix("<u>", at: index, limit: limit) {
                if let close = find("</u>", from: index + 3, before: limit) {
                    flush()
                    index += 3
                    var nested = style
                    nested.underline = true
                    output.append(parse(style: nested, until: close))
                    index = close + 4
                    continue
                }
            }

            buffer.append(character)
            index += 1
        }

        flush()
        return output
    }

    private func hasPrefix(_ text: String, at position: Int, limit: Int) -> Bool {
        let charactersOfText = Array(text)
        guard position + charactersOfText.count <= limit else { return false }
        for offset in 0..<charactersOfText.count where characters[position + offset] != charactersOfText[offset] {
            return false
        }
        return true
    }

    private func find(_ marker: String, from start: Int, before limit: Int) -> Int? {
        let charactersOfMarker = Array(marker)
        guard !charactersOfMarker.isEmpty else { return nil }
        var position = start
        while position + charactersOfMarker.count <= limit {
            if charactersOfMarker.enumerated().allSatisfy({ characters[position + $0.offset] == $0.element }) {
                return position
            }
            position += 1
        }
        return nil
    }

    /// `![alt](path)`
    private func parseImage(until limit: Int) -> NSAttributedString? {
        var cursor = index + 2
        guard let altEnd = find("]", from: cursor, before: limit) else { return nil }
        cursor = altEnd + 1
        guard cursor < limit, characters[cursor] == "(" else { return nil }
        guard let pathEnd = find(")", from: cursor + 1, before: limit) else { return nil }

        let path = String(characters[(cursor + 1)..<pathEnd])
        guard !path.isEmpty else { return nil }

        index = pathEnd + 1

        if path.hasPrefix("data:") {
            if let base64 = path.split(separator: ",").last,
               let data = Data(base64Encoded: String(base64)),
               let image = NSImage(data: data) {
                return MarkdownCodec.makeAttachment(image: image, path: nil)
            }
            return nil
        }

        return MarkdownCodec.makeAttachment(path: path, entryDirectory: entryDirectory)
    }
}

/// 图片附件按正文可用宽度等比缩放，窗口变窄时不会把文字挤出边界。
final class FittingImageCell: NSTextAttachmentCell {
    private var sourceImage = NSImage()
    private var maxWidth: CGFloat = 520

    convenience init(image: NSImage, maxWidth: CGFloat) {
        self.init()
        self.sourceImage = image
        self.maxWidth = maxWidth
        self.image = image
    }

    override func cellSize() -> NSSize {
        fittedSize(availableWidth: maxWidth)
    }

    override func cellFrame(
        for textContainer: NSTextContainer,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        NSRect(origin: .zero, size: fittedSize(availableWidth: lineFrag.width))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        sourceImage.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: nil)
    }

    override func draw(
        withFrame cellFrame: NSRect,
        in controlView: NSView?,
        characterIndex charIndex: Int,
        layoutManager: NSLayoutManager
    ) {
        sourceImage.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: nil)
    }

    private func fittedSize(availableWidth: CGFloat) -> NSSize {
        let size = sourceImage.size
        guard size.width > 0, size.height > 0 else { return .zero }
        let usable = min(maxWidth, max(availableWidth, 120))
        let target = min(size.width, usable)
        let ratio = target / size.width
        return NSSize(width: target, height: (size.height * ratio).rounded())
    }
}

extension NSImage {
    func downscaled(maxWidth: CGFloat) -> NSImage {
        let original = size
        guard original.width > maxWidth, original.width > 0, original.height > 0 else { return self }
        let ratio = maxWidth / original.width
        let target = NSSize(width: maxWidth, height: (original.height * ratio).rounded())
        let image = NSImage(size: target)
        image.lockFocus()
        draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        image.unlockFocus()
        return image
    }
}
