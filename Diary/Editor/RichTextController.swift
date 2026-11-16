import AppKit

/// 连接 SwiftUI 工具栏和底层 NSTextView 的桥。
@MainActor
final class RichTextController {
    weak var textView: NSTextView?

    var baseFont: NSFont { MarkdownCodec.baseFont }

    func focus() {
        guard let textView else { return }
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
    }

    func toggleBold() {
        toggleFontTrait(.boldFontMask)
    }

    func toggleItalic() {
        toggleFontTrait(.italicFontMask)
    }

    func toggleUnderline() {
        toggleLineAttribute(.underlineStyle)
    }

    func toggleStrikethrough() {
        toggleLineAttribute(.strikethroughStyle)
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard let textView, let storage = textView.textStorage else { return }
        let manager = NSFontManager.shared
        let range = textView.selectedRange()

        if range.length == 0 {
            var attributes = textView.typingAttributes
            let current = (attributes[.font] as? NSFont) ?? baseFont
            let hasTrait = manager.traits(of: current).contains(trait)
            attributes[.font] = hasTrait
                ? manager.convert(current, toNotHaveTrait: trait)
                : manager.convert(current, toHaveTrait: trait)
            textView.typingAttributes = attributes
            return
        }

        var allHaveTrait = true
        storage.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
            let font = (value as? NSFont) ?? self.baseFont
            if !manager.traits(of: font).contains(trait) {
                allHaveTrait = false
                stop.pointee = true
            }
        }

        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
            let font = (value as? NSFont) ?? self.baseFont
            let newFont = allHaveTrait
                ? manager.convert(font, toNotHaveTrait: trait)
                : manager.convert(font, toHaveTrait: trait)
            storage.addAttribute(.font, value: newFont, range: subRange)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    private func toggleLineAttribute(_ key: NSAttributedString.Key) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()

        if range.length == 0 {
            var attributes = textView.typingAttributes
            let current = (attributes[key] as? Int) ?? 0
            attributes[key] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            textView.typingAttributes = attributes
            return
        }

        var allSet = true
        storage.enumerateAttribute(key, in: range, options: []) { value, _, stop in
            if (value as? Int ?? 0) == 0 {
                allSet = false
                stop.pointee = true
            }
        }

        storage.beginEditing()
        storage.addAttribute(
            key,
            value: allSet ? 0 : NSUnderlineStyle.single.rawValue,
            range: range
        )
        storage.endEditing()
        textView.didChangeText()
    }

    /// 在当前光标处插入一张已经复制进 assets 目录的图片。
    func insertImage(_ image: NSImage, relativePath: String) {
        guard let textView else { return }
        let string = MarkdownCodec.makeAttachment(image: image, path: relativePath)
        textView.insertText(string, replacementRange: textView.selectedRange())
    }
}
