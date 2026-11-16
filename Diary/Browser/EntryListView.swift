import SwiftUI

struct DaySection: Identifiable {
    var id: String { dayKey }
    let dayKey: String
    let entries: [DiaryEntry]
}

struct EntryListView: View {
    let entries: [DiaryEntry]
    @Binding var selection: String?

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "还没有日记",
                    systemImage: "book.closed",
                    description: Text("点左上角的笔，写下第一页。")
                )
            } else {
                List(selection: $selection) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.entries) { entry in
                                EntryRow(entry: entry)
                                    .tag(entry.id)
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Text(DayKey.display(section.dayKey))
                                Text(DayKey.weekday(section.dayKey))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var sections: [DaySection] {
        var result: [DaySection] = []
        var currentDay: String?
        var bucket: [DiaryEntry] = []

        for entry in entries {
            if entry.dayKey != currentDay {
                if let currentDay {
                    result.append(DaySection(dayKey: currentDay, entries: bucket))
                }
                currentDay = entry.dayKey
                bucket = []
            }
            bucket.append(entry)
        }
        if let currentDay {
            result.append(DaySection(dayKey: currentDay, entries: bucket))
        }
        return result
    }
}

// MARK: - 行

struct EntryRow: View {
    let entry: DiaryEntry

    @Environment(DiaryStore.self) private var store
    @Environment(PrivacyManager.self) private var privacy

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.mood?.symbolName ?? "text.alignleft")
                .font(.system(size: 13))
                .foregroundStyle(entry.mood?.tint ?? Color.secondary)
                .frame(width: 18, height: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    // 隐私标记只在解锁后出现，锁着时不给旁人任何暗示
                    if entry.isPrivate, privacy.isUnlocked {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    Text(Self.timeFormatter.string(from: entry.created))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if !entry.excerpt.isEmpty {
                    Text(entry.excerpt)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if entry.attachmentCount > 0 || !entry.tags.isEmpty || entry.location != nil {
                    HStack(spacing: 8) {
                        if entry.attachmentCount > 0 {
                            Label(attachmentCountText, systemImage: "photo")
                        }
                        if let location = entry.location {
                            Label(location.name, systemImage: "location")
                                .lineLimit(1)
                        }
                        ForEach(entry.tags, id: \.self) { tag in
                            Text("#\(tag)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .labelStyle(.titleAndIcon)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(entry.isDeleted ? 0.55 : 1)
    }

    private var title: String {
        store.displayTitle(for: entry)
    }

    private var attachmentCountText: String {
        "\(entry.attachmentCount)"
    }
}
