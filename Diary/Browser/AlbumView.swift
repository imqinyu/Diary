import AppKit
import SwiftUI

private struct AlbumSection: Identifiable {
    var id: String { dayKey }
    let dayKey: String
    let photos: [PhotoItem]
}

/// 单独一个窗口，集中看所有日记里的图片。
struct AlbumView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(PrivacyManager.self) private var privacy
    @State private var photos: [PhotoItem] = []
    @State private var preview: PhotoItem?
    @State private var filter = EntryFilter()

    var body: some View {
        Group {
            if photos.isEmpty {
                ContentUnavailableView(
                    "还没有图片",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("在日记里插入图片后，会集中出现在这里。")
                )
            } else {
                // 自己算列数并用 .flexible() 均分，比 .adaptive 更容易让格子严格对齐
                GeometryReader { proxy in
                    let horizontalPadding: CGFloat = 18
                    let spacing: CGFloat = 10
                    let available = max(proxy.size.width - horizontalPadding * 2, 200)
                    let columnCount = max(2, Int((available + spacing) / 150))
                    let columns = Array(
                        repeating: GridItem(.flexible(), spacing: spacing),
                        count: columnCount
                    )

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                            ForEach(sections) { section in
                                Section {
                                    LazyVGrid(columns: columns, spacing: spacing) {
                                        ForEach(section.photos) { photo in
                                            PhotoCell(photo: photo)
                                                .onTapGesture { preview = photo }
                                        }
                                    }
                                    .padding(.horizontal, horizontalPadding)
                                } header: {
                                    header(for: section)
                                }
                            }
                        }
                        .padding(.vertical, 16)
                    }
                }
            }
        }
        // 空状态也填满窗口，让顶部筛选栏和内容区使用完整的可用高度。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("相册")
        .safeAreaInset(edge: .top, spacing: 0) {
            filterBar
        }
        .task { refresh() }
        .onChange(of: filter) { _, _ in refresh() }
        .onChange(of: store.entries) { _, _ in refresh() }
        .onChange(of: privacy.isUnlocked) { _, _ in refresh() }
        .sheet(item: $preview) { photo in
            PhotoPreviewSheet(photo: photo)
                .environment(store)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Text(verbatim: "\(photos.count) 张图片")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - 筛选栏

    private var filterBar: some View {
        HStack(spacing: 12) {
            Menu {
                Button("全部时间") { filter.time = .all }
                Divider()
                ForEach(availableYears, id: \.self) { year in
                    Menu {
                        Button("全年") { filter.time = .year(year) }
                        Divider()
                        ForEach(1...12, id: \.self) { month in
                            Button {
                                filter.time = .month(year: year, month: month)
                            } label: {
                                Text(verbatim: "\(month) 月")
                            }
                        }
                    } label: {
                        Text(verbatim: "\(year) 年")
                    }
                }
            } label: {
                Label(timeLabel, systemImage: "calendar")
            }
            .menuIndicator(.hidden)
            .fixedSize()

            Menu {
                Button("不限心情") { filter.mood = nil }
                Divider()
                ForEach(Mood.allCases) { mood in
                    Button {
                        filter.mood = mood
                    } label: {
                        Label(mood.displayName, systemImage: mood.symbolName)
                    }
                }
            } label: {
                Label(filter.mood?.displayName ?? "不限心情",
                      systemImage: filter.mood?.symbolName ?? "face.smiling")
            }
            .menuIndicator(.hidden)
            .fixedSize()

            if filter.isActive {
                Button("清除筛选") { filter = EntryFilter() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var timeLabel: String {
        filter.time == .all ? "全部时间" : (filter.time.title ?? "全部时间")
    }

    private var availableYears: [Int] {
        var years = Set(store.visibleEntries.compactMap { Int($0.dayKey.prefix(4)) })
        years.insert(Calendar.current.component(.year, from: Date()))
        return years.sorted(by: >)
    }

    private func refresh() {
        let matching = store.visibleEntries.filter { filter.matches($0) }
        photos = store.photos(in: matching)
    }

    private var sections: [AlbumSection] {
        var result: [AlbumSection] = []
        var currentDay: String?
        var bucket: [PhotoItem] = []

        for photo in photos {
            if photo.dayKey != currentDay {
                if let currentDay {
                    result.append(AlbumSection(dayKey: currentDay, photos: bucket))
                }
                currentDay = photo.dayKey
                bucket = []
            }
            bucket.append(photo)
        }
        if let currentDay {
            result.append(AlbumSection(dayKey: currentDay, photos: bucket))
        }
        return result
    }

    private func header(for section: AlbumSection) -> some View {
        HStack(spacing: 6) {
            Text(DayKey.display(section.dayKey))
                .font(.subheadline.weight(.semibold))
            Text(DayKey.weekday(section.dayKey))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(verbatim: "\(section.photos.count) 张")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - 格子

private struct PhotoCell: View {
    let photo: PhotoItem
    @State private var image: CGImage?

    var body: some View {
        // 宽度由网格列决定、高度固定；图片只放在 overlay 里，不参与尺寸计算，
        // 否则 scaledToFill 会按原图比例把格子撑变形。
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 132)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.secondary.opacity(0.1)
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .task(id: photo.url) {
                image = await ThumbnailCache.shared.thumbnail(for: photo.url, maxPixel: 480)
            }
    }
}

// MARK: - 大图

private struct PhotoPreviewSheet: View {
    let photo: PhotoItem

    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(photo.entryTitle)
                        .font(.headline)
                    Text("\(DayKey.display(photo.dayKey)) \(DayKey.weekday(photo.dayKey))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            if let image = NSImage(contentsOf: photo.url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
            } else {
                ContentUnavailableView("图片打不开", systemImage: "exclamationmark.triangle")
                    .frame(maxHeight: .infinity)
            }

            Divider()

            HStack {
                Spacer()
                Button("在日记中打开") {
                    store.requestedEntryID = photo.entryID
                    dismiss()
                    dismissWindow(id: "album")
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 640, minHeight: 500)
    }
}
