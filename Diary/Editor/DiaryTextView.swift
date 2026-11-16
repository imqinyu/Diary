import AppKit

/// 截图、复制的图片和图片文件都走日记的图片存储流程，文本仍由 AppKit 粘贴。
final class DiaryTextView: NSTextView {
    var importPastedImage: ((NSImage) -> NSAttributedString?)?

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.png, .tiff, .fileURL] + super.readablePasteboardTypes
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        if !pasteImages(from: .general) { super.paste(sender) }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        guard isEditable else { return }
        if !pasteImages(from: .general) { super.pasteAsPlainText(sender) }
    }

    @discardableResult
    func pasteImages(from pasteboard: NSPasteboard) -> Bool {
        guard isEditable, let importPastedImage else { return false }

        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: NSImage.imageTypes
        ]) as? [URL] ?? []
        let images: [NSImage]
        if !urls.isEmpty {
            images = urls.compactMap { NSImage(contentsOf: $0) }
        } else {
            images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] ?? []
        }
        guard !images.isEmpty else { return false }

        let range = selectedRange()
        let inserted = NSMutableAttributedString()
        for image in images {
            guard let attachment = importPastedImage(image) else { continue }
            if inserted.length > 0 {
                inserted.append(NSAttributedString(string: "\n", attributes: MarkdownCodec.baseAttributes()))
            }
            inserted.append(attachment)
        }
        if inserted.length > 0 {
            insertText(inserted, replacementRange: range)
        }
        // 导入失败时不回退到 AppKit 的内嵌附件，错误由存储层显示。
        return true
    }
}
