import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct EditorImageChecks {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiaryImageChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(["DiaryDataRootPath": root.path], forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        let suite = "DiaryImageChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let privacy = PrivacyManager(defaults: defaults, auditLog: PrivacyAuditLog(fileURL: root.appendingPathComponent("audit.json")))
        let store = DiaryStore(privacy: privacy)
        let entry = store.createTodayEntry()!
        let image = testImage(width: 120, height: 80)
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!

        // 附件在真实、坐标翻转的 NSTextView 中绘制，顶部红色不能变到底部。
        try checkOrientation(image: image)
        try checkOrientation(image: testImage(width: 1400, height: 800))

        let controller = RichTextController()
        var imported = 0
        var changed = 0
        let editor = RichTextEditor(
            initialText: NSAttributedString(string: "before after", attributes: MarkdownCodec.baseAttributes()),
            isEditable: true,
            controller: controller,
            footerText: nil,
            onPasteImage: { image in
                guard let path = store.importImage(image, for: entry.id) else { return nil }
                imported += 1
                return MarkdownCodec.makeAttachment(image: image, path: path)
            },
            onChange: { attributed in
                changed += 1
                store.saveBody(entryID: entry.id, markdown: MarkdownCodec.encode(attributed))
            }
        )
        let hosting = NSHostingView(rootView: editor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        settle(hosting)
        let textView = controller.textView as! DiaryTextView
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        clipboard.declareTypes([.png], owner: nil)
        clipboard.setData(png, forType: .png)
        textView.setSelectedRange(NSRange(location: 7, length: 5))
        precondition(textView.pasteImages(from: clipboard))
        precondition(imported == 1 && changed > 0)
        let markdown = MarkdownCodec.encode(textView.attributedString())
        let path = MarkdownText.imagePaths(markdown).first!
        precondition(markdown.hasPrefix("before ![](") && !markdown.contains("base64"))
        let asset = store.assetURL(relativePath: path, for: entry)
        precondition(FileManager.default.fileExists(atPath: asset.path))
        precondition(store.entry(with: entry.id)?.attachmentCount == 1)
        let saved = try EntryDocument.read(from: entry.fileURL)
        precondition(saved.body == markdown)
        let reopened = MarkdownCodec.decode(saved.body, entryDirectory: entry.fileURL.deletingLastPathComponent())
        precondition(MarkdownCodec.encode(reopened) == markdown)
        precondition(store.photos().count == 1)

        let undo = textView.undoManager!
        precondition(undo.canUndo)
        undo.undo()
        precondition(MarkdownCodec.encode(textView.attributedString()) == "before after")
        undo.redo()
        precondition(MarkdownCodec.encode(textView.attributedString()) == markdown)

        // TIFF 截图和从访达复制的多个图片文件，都应落盘为独立图片。
        clipboard.declareTypes([.tiff], owner: nil)
        clipboard.setData(image.tiffRepresentation!, forType: .tiff)
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        precondition(textView.pasteImages(from: clipboard))
        let first = root.appendingPathComponent("first.png")
        let second = root.appendingPathComponent("second.png")
        try png.write(to: first)
        try png.write(to: second)
        clipboard.clearContents()
        clipboard.writeObjects([first as NSURL, second as NSURL])
        precondition(textView.pasteImages(from: clipboard))
        precondition(imported == 4)
        precondition(MarkdownText.imagePaths(MarkdownCodec.encode(textView.attributedString())).count == 4)

        clipboard.declareTypes([.string], owner: nil)
        clipboard.setString("normal text", forType: .string)
        precondition(!textView.pasteImages(from: clipboard))
        precondition(textView.readSelection(from: clipboard, type: .string))
        precondition(textView.string.contains("normal text"))

        clipboard.declareTypes([.png], owner: nil)
        clipboard.setData(png, forType: .png)
        textView.isEditable = false
        let beforeReadOnly = textView.attributedString()
        precondition(!textView.pasteImages(from: clipboard))
        precondition(imported == 4 && textView.attributedString() == beforeReadOnly)
        textView.isEditable = true
        textView.importPastedImage = { _ in nil }
        precondition(textView.pasteImages(from: clipboard))
        precondition(textView.attributedString() == beforeReadOnly)

        window.contentView = nil
        print("PASS: upright attachments, PNG/TIFF/file clipboard images, insertion, persistence, reopen, album indexing, undo/redo, text paste, and read-only protection")
    }

    @MainActor
    static func testImage(width: Int, height: Int) -> NSImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let pixels = bitmap.bitmapData!
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bitmap.bytesPerRow + x * 4
                pixels[offset] = y < height / 2 ? 255 : 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = y < height / 2 ? 0 : 255
                pixels[offset + 3] = 255
            }
        }
        return NSImage(data: bitmap.representation(using: .png, properties: [:])!)!
    }

    @MainActor
    static func checkOrientation(image: NSImage) throws {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.drawsBackground = true
        view.backgroundColor = .white
        view.textStorage?.setAttributedString(MarkdownCodec.makeAttachment(image: image, path: "test.png"))
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var redRows: [Int] = []
        var blueRows: [Int] = []
        let x = min(bitmap.pixelsWide - 1, Int(min(image.size.width, 520) / 2))
        for y in 0..<bitmap.pixelsHigh {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if color.redComponent > 0.8 && color.blueComponent < 0.2 { redRows.append(y) }
            if color.blueComponent > 0.8 && color.redComponent < 0.2 { blueRows.append(y) }
        }
        precondition(!redRows.isEmpty && !blueRows.isEmpty)
        precondition(redRows.reduce(0, +) / redRows.count < blueRows.reduce(0, +) / blueRows.count, "Image is upside down in the editor")
    }

    @MainActor
    static func settle(_ view: NSView) {
        for _ in 0..<10 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }
}
