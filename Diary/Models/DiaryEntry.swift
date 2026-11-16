import CryptoKit
import Foundation

struct EntryLocation: Hashable {
    var name: String
    var latitude: Double?
    var longitude: Double?
    /// country / province / city / district / street
    var level: String?
    /// 拆开的行政区，供「按省份 / 城市」筛选。放在最后并给默认值，老文件的写法不受影响。
    var province: String? = nil
    var city: String? = nil

    /// 老格式或手填条目里没有 province/city，就从名字里尽力推。
    static func deriveComponents(from name: String) -> (province: String?, city: String?) {
        let parts = name.split(separator: " ").map(String.init)
        var province: String?
        var city: String?
        for part in parts {
            if part.hasSuffix("省") || part.hasSuffix("自治区") || part.hasSuffix("特别行政区") {
                province = part
            } else if part.hasSuffix("市") || part.hasSuffix("州")
                        || part.hasSuffix("地区") || part.hasSuffix("盟") {
                city = part
            }
        }
        return (province, city)
    }

    /// 没有显式省份时，用城市名兜底分组，避免所有普通城市都归到「未分类」。
    var provinceForFilter: String? {
        province ?? city
    }
}

struct EntryWeather: Hashable {
    var text: String
    var temperature: Double?
    /// WMO 天气代码，用来还原图标；手填的条目没有。
    var code: Int?

    var symbol: String {
        guard let code else { return "cloud.sun" }
        return WeatherService.describe(code: code).symbol
    }
}

/// 一条日记。元数据全部来自文件 front matter，正文单独保存。
struct DiaryEntry: Identifiable, Hashable {
    var id: String
    var dayKey: String
    var sequence: Int
    var created: Date
    var updated: Date
    var title: String
    var mood: Mood?
    var tags: [String]
    var isPrivate: Bool
    var isDeleted: Bool
    var deletedAt: Date?
    var wordCount: Int
    var attachmentCount: Int
    var location: EntryLocation?
    var weather: EntryWeather?
    /// 已删除条目保留的正文预览；正常条目由正文实时计算。
    var excerpt: String
    var fileURL: URL
    var bodyMarkdown: String
    /// 手动插入的旧日记有半天补写期；普通条目为 nil。存在文件里，别的平台也能照着办。
    var editableUntil: Date? = nil
    /// 正文是否以密文保存（只有私密条目会）。
    var isEncrypted: Bool = false

    /// 普通条目只有当天可写；插入的旧日记在半天的补写期内可写，过期自动只读。
    func canEdit(at date: Date) -> Bool {
        guard !isDeleted else { return false }
        if let editableUntil {
            return date < editableUntil
        }
        return dayKey == DayKey.today()
    }

    var isWritable: Bool {
        canEdit(at: Date())
    }

    var day: Date? { DayKey.date(from: dayKey) }

    /// 文件名主干，例如 `2026-11-14-2`
    var stem: String { fileURL.deletingPathExtension().lastPathComponent }

    /// 图片目录，与文件同级、同名加 `.assets`
    var assetsDirectory: URL {
        fileURL.deletingPathExtension().appendingPathExtension("assets")
    }
}

// MARK: - 与文件互相转换

extension DiaryEntry {
    init?(document: EntryDocument, fileURL: URL, key: SymmetricKey? = nil) {
        let fm = document.frontMatter
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let parsedName = EntryFileName.parse(stem)

        guard let dayKey = fm.string("date") ?? parsedName?.dayKey,
              !dayKey.isEmpty else { return nil }

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileCreated = attributes?[.creationDate] as? Date
        let fileModified = attributes?[.modificationDate] as? Date

        self.id = fm.string("id") ?? stem
        self.dayKey = dayKey
        self.sequence = parsedName?.sequence ?? Int(fm.string("id")?.split(separator: "-").last ?? "") ?? 1
        self.created = ISO8601.date(fm.string("created")) ?? fileCreated ?? fileModified ?? Date()
        self.updated = ISO8601.date(fm.string("updated")) ?? fileModified ?? self.created
        self.title = fm.string("title") ?? ""
        self.mood = fm.string("mood").flatMap(Mood.init(rawValue:))
        self.tags = fm.list("tags") ?? []
        self.isPrivate = fm.bool("private") ?? false
        self.isDeleted = fm.bool("deleted") ?? false
        self.deletedAt = ISO8601.date(fm.string("deletedAt"))
        self.location = Self.location(from: fm)
        self.weather = Self.weather(from: fm)
        self.fileURL = fileURL
        self.editableUntil = ISO8601.date(fm.string("editable_until"))
        self.isEncrypted = fm.bool("encrypted") ?? false

        // 加密条目在锁定状态下读不出来，正文留空；元数据仍然可用。
        var plainBody = document.body
        if isEncrypted {
            if let key, let opened = PrivacyCrypto.open(document.body, key: key) {
                plainBody = opened
            } else {
                plainBody = ""
            }
        }
        self.bodyMarkdown = plainBody

        let storedExcerpt = fm.string("excerpt") ?? ""
        let computedExcerpt = MarkdownText.excerpt(plainBody)
        self.excerpt = storedExcerpt.isEmpty ? computedExcerpt : storedExcerpt

        // 有正文时以正文为准，手改过的文件也不会显示过期字数；
        // 墓碑没有正文，只能信 front matter 里保留的数字。
        let hasBody = !plainBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasBody {
            self.wordCount = WordCounter.count(MarkdownText.plain(plainBody))
            self.attachmentCount = MarkdownText.imageCount(plainBody)
        } else {
            self.wordCount = fm.int("words") ?? 0
            self.attachmentCount = fm.int("attachments") ?? 0
        }
    }

    private static func location(from fm: FrontMatter) -> EntryLocation? {
        let map = fm.map("location")
        guard let name = map["name"], !name.isEmpty else { return nil }
        var location = EntryLocation(
            name: name,
            latitude: map["lat"].flatMap(Double.init),
            longitude: map["lon"].flatMap(Double.init),
            level: map["level"],
            province: map["province"],
            city: map["city"]
        )
        // 老文件没拆过行政区，从地名里推一次，内存里就能按省份/城市筛选。
        if location.province == nil && location.city == nil {
            let derived = EntryLocation.deriveComponents(from: name)
            location.province = derived.province
            location.city = derived.city
        }
        return location
    }

    private static func weather(from fm: FrontMatter) -> EntryWeather? {
        let map = fm.map("weather")
        guard let text = map["text"], !text.isEmpty else { return nil }
        return EntryWeather(
            text: text,
            temperature: map["temp"].flatMap(Double.init),
            code: map["code"].flatMap(Int.init)
        )
    }

    /// 生成写盘用的 front matter，键顺序固定，方便人读和 diff。
    /// 私密条目在拿到密钥时把正文加密；没有密钥说明当前是锁定态，不该走到这里。
    func makeDocument(encryptionKey: SymmetricKey? = nil) -> EntryDocument {
        var fm = FrontMatter()
        fm.set("schema", .scalar("1"))
        fm.set("id", .scalar(id))
        fm.set("date", .scalar(dayKey))
        fm.set("created", .scalar(ISO8601.string(created)))
        fm.set("updated", .scalar(ISO8601.string(updated)))
        fm.set("title", .scalar(title))
        fm.set("mood", mood.map { .scalar($0.rawValue) })
        fm.set("tags", tags.isEmpty ? nil : .list(tags))
        if let location {
            var pairs: [(String, String)] = [("name", location.name)]
            if let province = location.province { pairs.append(("province", province)) }
            if let city = location.city { pairs.append(("city", city)) }
            if let lat = location.latitude { pairs.append(("lat", Self.number(lat))) }
            if let lon = location.longitude { pairs.append(("lon", Self.number(lon))) }
            if let level = location.level { pairs.append(("level", level)) }
            fm.set("location", .map(pairs))
        } else {
            fm.set("location", nil)
        }
        if let weather {
            var pairs: [(String, String)] = [("text", weather.text)]
            if let temp = weather.temperature { pairs.append(("temp", Self.number(temp))) }
            if let code = weather.code { pairs.append(("code", String(code))) }
            fm.set("weather", .map(pairs))
        } else {
            fm.set("weather", nil)
        }
        fm.set("private", .scalar(isPrivate ? "true" : "false"))
        fm.set("deleted", .scalar(isDeleted ? "true" : "false"))
        fm.set("deletedAt", deletedAt.map { .scalar(ISO8601.string($0)) })
        fm.set("editable_until", editableUntil.map { .scalar(ISO8601.string($0)) })
        fm.set("words", .scalar(String(wordCount)))
        fm.set("attachments", .scalar(String(attachmentCount)))
        // 已删除条目没有正文，靠这个字段保留列表里的预览。
        // 私密条目一律不写预览，否则等于把正文片段留在明文里。
        fm.set("excerpt", (isDeleted && !isPrivate) ? .scalar(excerpt) : nil)

        let shouldEncrypt = isPrivate && !isDeleted && encryptionKey != nil
        fm.set("encrypted", .scalar(shouldEncrypt ? "true" : "false"))

        let body: String
        if isDeleted {
            body = ""
        } else if shouldEncrypt, let encryptionKey {
            // 加密失败就退回明文，宁可丢隐私也不能丢内容
            body = PrivacyCrypto.seal(bodyMarkdown, key: encryptionKey) ?? bodyMarkdown
        } else {
            body = bodyMarkdown
        }

        return EntryDocument(frontMatter: fm, body: body)
    }

    private static func number(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e9 {
            return String(Int(value))
        }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
