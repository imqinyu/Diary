import SwiftUI

/// 手动补一篇以前的日记。选的那一天会在列表里按正常规则归档、编号。
struct InsertEntrySheet: View {
    let onInsert: (Date) -> Void
    let onCancel: () -> Void

    @State private var selectedDate: Date

    init(onInsert: @escaping (Date) -> Void, onCancel: @escaping () -> Void) {
        self.onInsert = onInsert
        self.onCancel = onCancel
        _selectedDate = State(
            initialValue: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("补写以前的日记")
                    .font(.headline)
                Text("选一个过去的日期，会像正常条目一样归档到那天、自动编号。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DatePicker(
                "日期与时间",
                selection: $selectedDate,
                in: ...Date(),
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.graphical)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                Text("插入后有半天时间可以补写，到点自动变成只读，和别的旧日记一样。补写期写在文件里，别的平台也能识别。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { onCancel() }
                Button("插入") { onInsert(selectedDate) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
