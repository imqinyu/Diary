import SwiftUI

/// 详情页里的标签行：读的时候是胶囊，当天条目可以增删。
struct TagRow: View {
    let entry: DiaryEntry
    let isEditable: Bool

    @Environment(DiaryStore.self) private var store
    @State private var isPickerPresented = false

    private var currentTags: [String] {
        store.entry(with: entry.id)?.tags ?? entry.tags
    }

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(currentTags, id: \.self) { tag in
                chip(tag)
            }
            if isEditable {
                addButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ tag: String) -> some View {
        HStack(spacing: 5) {
            Text("#\(tag)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if isEditable {
                Button {
                    store.updateTags(entryID: entry.id, tags: currentTags.filter { $0 != tag })
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("移除标签")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, isEditable ? 6 : 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.11)))
    }

    private var addButton: some View {
        Button {
            isPickerPresented = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    Capsule().strokeBorder(
                        Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                    )
                )
        }
        .buttonStyle(.plain)
        .help("添加标签")
        .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
            TagPickerPopover(entryID: entry.id, currentTags: currentTags)
        }
    }
}

private struct TagPickerPopover: View {
    let entryID: String
    let currentTags: [String]

    @Environment(DiaryStore.self) private var store
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private var suggestions: [String] {
        store.allTags.filter { !currentTags.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("新标签，回车添加", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit {
                    add(draft)
                    draft = ""
                }

            if !suggestions.isEmpty {
                Divider()
                Text("已有标签")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(suggestions, id: \.self) { tag in
                            Button {
                                add(tag)
                            } label: {
                                HStack(spacing: 6) {
                                    Text("#\(tag)")
                                        .font(.callout)
                                    Spacer(minLength: 4)
                                    Image(systemName: "plus")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 3)
                                .padding(.horizontal, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 170)
            }
        }
        .padding(12)
        .frame(width: 220)
        .onAppear { isFocused = true }
    }

    private func add(_ raw: String) {
        let normalized = DiaryStore.normalizeTags([raw])
        guard let tag = normalized.first else { return }
        guard !currentTags.contains(tag) else { return }
        store.updateTags(entryID: entryID, tags: currentTags + [tag])
    }
}
