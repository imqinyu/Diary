import AppKit
import CryptoKit
import Foundation

@main struct PrivateImageChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DiaryPrivateImageChecks-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(["DiaryDataRootPath": root.path], forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        let suite = "PrivateImageChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let privacy = PrivacyManager(defaults: defaults, auditLog: PrivacyAuditLog(fileURL: root.appendingPathComponent("audit.json")))
        precondition(privacy.setPassword("private-image-password"))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<4 { for x in 0..<4 { bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y) } }
        let png = bitmap.representation(using: .png, properties: [:])!
        let uri = try EmbeddedImages.uri(png, extension: "png")
        let day = "2020-01-02"
        let file = root.appendingPathComponent("entries/2020/01/02/\(day)-1.md")
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var matter = FrontMatter()
        for (key, value) in ["id": "\(day)-1", "date": day, "created": "2020-01-02T12:00:00Z", "updated": "2020-01-02T12:00:00Z", "private": "false", "title": "Old photo"] { matter.set(key, .scalar(value)) }
        let local = "assets/\(day)-1/photo.png"
        let asset = file.deletingLastPathComponent().appendingPathComponent(local)
        try fm.createDirectory(at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: asset)
        try EntryDocument(frontMatter: matter, body: "Old text\n![](\(local))").write(to: file)
        let store = DiaryStore(privacy: privacy)
        let old = store.entries.first!
        precondition(!old.isWritable)
        store.updatePrivacy(entryID: old.id, isPrivate: true)
        let hidden = store.entries.first!
        precondition(hidden.isPrivate && hidden.isEncrypted && !hidden.isWritable)
        precondition(hidden.created == old.created && hidden.updated == old.updated && hidden.isBackfilled == old.isBackfilled)
        precondition(hidden.attachmentCount == 1 && hidden.bodyMarkdown.contains(uri))
        precondition(!fm.fileExists(atPath: asset.path))
        let encrypted = try EntryDocument.read(from: file)
        precondition(!encrypted.body.contains("Old text") && !encrypted.body.contains(uri))
        precondition(PrivacyCrypto.open(encrypted.body, key: privacy.encryptionKey!) == hidden.bodyMarkdown)
        let roundTrip = MarkdownCodec.encode(MarkdownCodec.decode(hidden.bodyMarkdown, entryDirectory: file.deletingLastPathComponent()))
        precondition(roundTrip.contains(uri))
        let photo = store.photos().first!
        precondition(photo.data == png)
        let thumbnail = await ThumbnailCache.shared.thumbnail(for: photo.url, data: photo.data, maxPixel: 100)
        precondition(thumbnail != nil)
        privacy.lock(); store.reload()
        precondition(store.visibleEntries.isEmpty && store.photos().isEmpty)
        let unlocked = await privacy.tryUnlock("private-image-password")
        precondition(unlocked); store.reload()
        store.updatePrivacy(entryID: old.id, isPrivate: false)
        precondition(!store.entries.first!.isPrivate && !store.entries.first!.isWritable)
        precondition(store.photos().first!.data == png)

        // Existing encrypted Markdown with plaintext assets is migrated after unlocking.
        try png.write(to: asset)
        var legacy = matter
        legacy.set("private", .scalar("true")); legacy.set("encrypted", .scalar("true"))
        legacy.set("encryption_salt", privacy.encryptionSalt.map { .scalar($0) })
        try EntryDocument(frontMatter: legacy, body: PrivacyCrypto.seal("Old text\n![](\(local))", key: privacy.encryptionKey!)!).write(to: file)
        store.reload()
        let migrationPassed = store.encryptPlaintextPrivateEntries()
        if !migrationPassed { FileHandle.standardError.write(Data("Migration failed: \(store.errorMessage ?? "unknown")\n".utf8)) }
        precondition(migrationPassed)
        let migratedPrivate = store.entries.first!
        precondition(migratedPrivate.bodyMarkdown.contains(uri) && !fm.fileExists(atPath: asset.path))
        let stable = try Data(contentsOf: file)
        precondition(store.encryptPlaintextPrivateEntries())
        let stableReload = try Data(contentsOf: file)
        precondition(stableReload == stable)
        precondition(store.changePrivacyPassword(current: "private-image-password", new: "new-private-password"))
        privacy.lock(); let nextUnlocked = await privacy.tryUnlock("new-private-password")
        precondition(nextUnlocked); store.reload()
        precondition(store.entries.first!.bodyMarkdown.contains(uri))

        // Failures before the directory swap preserve every original byte and the old password.
        let badBody = "![](assets/\(day)-1/missing.png)"
        var bad = store.entries.first!
        bad.bodyMarkdown = badBody
        try bad.makeDocument(encryptionKey: privacy.encryptionKey, encryptionSalt: privacy.encryptionSalt).write(to: file)
        store.reload(); let beforeFailure = try Data(contentsOf: file)
        precondition(!store.changePrivacyPassword(current: "new-private-password", new: "bad-change-password"))
        precondition(privacy.verify("new-private-password") && !privacy.verify("bad-change-password"))
        let failedReload = try Data(contentsOf: file)
        precondition(failedReload == beforeFailure)
        let today = store.createTodayEntry()!
        store.updatePrivacy(entryID: today.id, isPrivate: true)
        let image = NSImage(data: png)!
        let imported = store.importImage(image, for: today.id)!
        precondition(imported.hasPrefix("data:image/png;base64,"))
        precondition(!fm.fileExists(atPath: today.assetsDirectory.path))

        let salt = "00112233445566778899aabbccddeeff"
        let password = "cross-platform-private-photo"
        let markdown = "Cross-platform photo\n![](\(uri))"
        let key = PrivacyCrypto.key(from: password, salt: salt)!
        let fixture: [String: String] = ["salt": salt, "password": password, "plaintext": markdown,
                                       "ciphertext": PrivacyCrypto.seal(markdown, key: key)!, "png": png.base64EncodedString()]
        try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys]).write(to: URL(fileURLWithPath: "/tmp/diary-private-image-fixture.json"))
        let androidFixture = URL(fileURLWithPath: "/tmp/diary-android-private-image-fixture.json")
        if fm.fileExists(atPath: androidFixture.path) {
            let android = try JSONSerialization.jsonObject(with: Data(contentsOf: androidFixture)) as! [String: String]
            let androidKey = PrivacyCrypto.key(from: android["password"]!, salt: android["salt"]!)!
            precondition(PrivacyCrypto.open(android["ciphertext"]!, key: androidKey) == android["plaintext"]!)
            let androidPath = MarkdownText.imagePaths(android["plaintext"]!).first!
            precondition(EmbeddedImages.bytes(androidPath)?.base64EncodedString() == android["png"]!)
        }
        print("PASS: sealed diary hide/unhide, encrypted inline images, migration, image editor round trip, album thumbnails, password rotation, rollback and direct private image import")
    }
}
