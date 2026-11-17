import Foundation

/// 相册里的一张图，指向某条日记正文里的一个图片引用。
struct PhotoItem: Identifiable, Hashable {
    let entryID: String
    let entryTitle: String
    let dayKey: String
    let relativePath: String
    let url: URL
    var data: Data? = nil

    var id: String { "\(entryID)|\(relativePath)" }
}
