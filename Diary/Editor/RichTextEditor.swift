import AppKit
import SwiftUI

/// 用 NSTextView 承载富文本。SwiftUI 在 macOS 15 的 TextEditor 还不支持富文本，
/// 而且我们需要完全控制附件（图片）怎么落到磁盘上。
struct RichTextEditor: NSViewRepresentable {
    let initialText: NSAttributedString
    var isEditable: Bool
    var controller: RichTextController
    /// 追加在正文末尾、跟着正文一起滚动的一行小字。
    var footerText: String?
    var onPasteImage: ((NSImage) -> NSAttributedString?)? = nil
    var onChange: (NSAttributedString) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = DiaryTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? DiaryTextView else {
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.isRichText = true
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = MarkdownCodec.baseAttributes()
        textView.textStorage?.setAttributedString(initialText)
        textView.importPastedImage = onPasteImage

        context.coordinator.applyFooter(in: textView, text: footerText)
        controller.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? DiaryTextView else { return }
        textView.importPastedImage = onPasteImage
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        if context.coordinator.lastFooterText != footerText {
            context.coordinator.applyFooter(in: textView, text: footerText)
        }
        controller.textView = textView
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var lastFooterText: String?

        init(_ parent: RichTextEditor) {
            self.parent = parent
        }

        // MARK: - 尾部时间戳

        private func footerRange(in textView: NSTextView) -> NSRange? {
            guard let storage = textView.textStorage else { return nil }
            var result: NSRange?
            storage.enumerateAttribute(
                .diaryFooter,
                in: NSRange(location: 0, length: storage.length),
                options: []
            ) { value, range, _ in
                if value as? Bool == true { result = range }
            }
            return result
        }

        /// 规范化尾部时间戳：只有末尾那一段标准文本带 .diaryFooter 标记，
        /// 用户输入的任何字符都不带标记，编码时才能被完整保留。
        func applyFooter(in textView: NSTextView, text: String?) {
            lastFooterText = text
            guard let storage = textView.textStorage else { return }
            guard let text else {
                if let range = footerRange(in: textView) {
                    textView.undoManager?.disableUndoRegistration()
                    storage.deleteCharacters(in: range)
                    textView.undoManager?.enableUndoRegistration()
                }
                return
            }

            let standard = MarkdownCodec.footerAttributedString(text).string
            let whole = NSRange(location: 0, length: storage.length)

            // 先把所有旧标记清掉，用户打进时间戳行里的字也会因此变回正文
            storage.removeAttribute(.diaryFooter, range: whole)

            let current = storage.string as NSString
            if current.hasSuffix(standard) {
                let footer = NSRange(location: current.length - (standard as NSString).length,
                                     length: (standard as NSString).length)
                storage.addAttribute(.diaryFooter, value: true, range: footer)
                return
            }

            // 时间戳被改动或删掉了：把残留的旧文本换成新的，再追加回去
            let marker = "\n最后编辑于 "
            let old = current.range(of: marker, options: .backwards)
            let replacement = MarkdownCodec.footerAttributedString(text)
            textView.undoManager?.disableUndoRegistration()
            if old.location != NSNotFound {
                let tail = NSRange(location: old.location, length: current.length - old.location)
                storage.replaceCharacters(in: tail, with: replacement)
            } else {
                storage.append(replacement)
            }
            textView.undoManager?.enableUndoRegistration()
        }

        // MARK: - 光标与输入

        /// 不让光标停进时间戳段落。输入本身一律放行，否则空文档会打不了字。
        func textView(
            _ textView: NSTextView,
            willChangeSelectionFromCharacterRange oldRange: NSRange,
            toCharacterRange newRange: NSRange
        ) -> NSRange {
            guard let footer = footerRange(in: textView),
                  newRange.location > footer.location else { return newRange }
            return NSRange(location: footer.location, length: 0)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // 光标紧挨着时间戳时，新输入的字不能继承时间戳的样式和标记
            if textView.typingAttributes[.diaryFooter] as? Bool == true {
                textView.typingAttributes = MarkdownCodec.baseAttributes()
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            applyFooter(in: textView, text: parent.footerText)
            parent.onChange(textView.attributedString())
        }
    }
}
