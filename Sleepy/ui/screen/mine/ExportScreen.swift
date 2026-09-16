// ExportScreen.swift — ← ui/screen/mine/ExportScreen.kt
// 导出课表页: WakeUp JSON / WakeUp 分享文本 / ICS 日历 / Sleepy 原生格式(.sleepy 文件)。
// 平台映射: MediaStore Downloads + ACTION_SEND → ShareLink/UIActivityViewController +
// 写临时文件(tmp)经 UIActivityViewController 分享(等价适配:iOS 沙箱无公共 Downloads)。

import SwiftUI
import UIKit

struct ExportScreen: View {
    @Environment(\.localWakeUpColors) private var colors
    @ObservedObject var viewModel: ScheduleViewModel
    let onDismiss: () -> Void

    @State private var shareSheet: ShareItem? = nil
    @State private var snackMessage: String? = nil
    // ← 导出目标课表 — 本地选择, 不污染主页 selectedTableId/widget 默认表。
    //   默认跟随当前课表; 用户切过一次后(pin)固定, 除非主页切到 pin 掉的表之外又变了。
    @State private var exportTableId: Int64? = nil
    // 选中表的课程: 当前表直接用 state.courses(已观察), 其他表选中时本地加载一次
    @State private var loadedCourses: [CourseEntity]? = nil
    @State private var showTablePicker = false

    var body: some View {
        let state = viewModel.state
        // ← Android: effectiveId = exportTableId ?: state.selectedTableId
        let effectiveId = exportTableId ?? state.selectedTableId
        let table = state.tables.first { $0.id == effectiveId } ?? state.currentTable
        let courses = loadedCourses ?? state.courses

        VStack(spacing: 0) {
            SettingsTopBar(title: L10n.format("export_title"), onBack: onDismiss)
            if let table = table {
                ScrollView {
                    VStack(spacing: 12) {
                        // 顶部信息卡 — 点击拉出课表选择(默认当前课表; 选后 pin, 不污染主页默认表)
                        Button {
                            showTablePicker = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(table.name)
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(colors.onPrimaryContainer)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 24)) // ← Android 默认 Icon 24dp(ExpandMore 无 size 修饰)
                                        .foregroundColor(colors.onPrimaryContainer)
                                        // ← Android contentDescription = export_pick_table
                                        .accessibilityLabel(L10n.format("export_pick_table"))
                                }
                                Text("\(L10n.format("export_course_count", courses.count)) · \(L10n.format("export_start_date", table.startDate))")
                                    .font(.system(size: 14))
                                    .foregroundColor(colors.onPrimaryContainer)
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(colors.primaryContainer)
                            .cornerRadius(SleepyShapes.large)
                        }
                        .buttonStyle(SleepyButtonStyle())
                        .accessibilityIdentifier("export_table_card")

                        // 格式选项
                        VStack(spacing: 0) {
                            ExportItem(icon: "curlybraces",
                                       title: L10n.format("export_json_title"),
                                       subtitle: L10n.format("export_json_subtitle"),
                                       id: "export_json_row") {
                                exportFile(table: table, courses: courses,
                                           ext: "json", mime: "application/json",
                                           content: ScheduleExporter.exportWakeUpJson(table, courses))
                            }
                            RowDivider()
                            ExportItem(icon: "square.and.arrow.up",
                                       title: L10n.format("export_share_title"),
                                       subtitle: L10n.format("export_share_subtitle"),
                                       id: "export_share_row") {
                                // ← shareText: 直接分享文本
                                shareSheet = ShareItem(text: ScheduleExporter.exportWakeUpShareText(table, courses),
                                                       subject: table.name, url: nil)
                                snackMessage = L10n.format("export_copied_hint")
                            }
                            RowDivider()
                            ExportItem(icon: "calendar",
                                       title: L10n.format("export_ics_title"),
                                       subtitle: L10n.format("export_ics_subtitle"),
                                       id: "export_ics_row") {
                                exportFile(table: table, courses: courses,
                                           ext: "ics", mime: "text/calendar",
                                           content: ScheduleExporter.exportIcs(table, courses))
                            }
                            // ← Android 第 4 行: Sleepy 原生格式 — 文件形态(末尾 z|chk=crc32 尾注),
                            //   .sleepy 文件经系统分享; 图标 Star → SF "star"(与 ShareScheduleSheet 同映射)
                            RowDivider()
                            ExportItem(icon: "star",
                                       title: L10n.format("export_native_title"),
                                       subtitle: L10n.format("export_native_subtitle"),
                                       id: "export_native_row") {
                                // MIME 用 text/plain 规避 ImportReceiverActivity MIME 收窄问题(调查报告 P3)
                                exportFile(table: table, courses: courses,
                                           ext: "sleepy", mime: "text/plain",
                                           content: SleepyNativeExporter.exportFile(
                                               tableName: table.name, startDate: table.startDate,
                                               maxWeek: table.maxWeek, nodesPerDay: table.nodesPerDay,
                                               timeJson: table.timeJson, courses: courses))
                            }
                        }
                        .background(colors.surfaceContainer)
                        .cornerRadius(SleepyShapes.large)
                    }
                    .padding(16)
                }
            } else {
                Text(L10n.format("export_no_table"))
                    .font(.system(size: 16)) // ← Android 默认 bodyLarge 16(未显式指定 style)
                    .foregroundColor(colors.onSurfaceVariant)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(colors.background)
        // ← snackbar 等价
        .overlay(alignment: .bottom) {
            if let msg = snackMessage {
                Text(msg)
                    .font(.system(size: 14)) // ← Android Snackbar bodyMedium 14
                    .accessibilityIdentifier("export_snackbar")
                    .foregroundColor(colors.onSurface)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(colors.surfaceContainerHighest)
                    .cornerRadius(8)
                    .padding(.bottom, 12)
                    .task(id: msg) {
                        // snackbar 2s(← Android LENGTH_SHORT)。UI 测试态延到 6s:
                        // 批量跑套件时模拟器负载高, 单次 XCUITest 快照可能 >2s,
                        // 负载尖峰会错过 snackbar 存活窗口造成批量 flake(单跑全绿)。
                        let life: Double = ProcessInfo.processInfo.arguments
                            .contains("-SLEEPY_UI_TEST_SEED") ? 6 : 2
                        try? await Task.sleep(nanoseconds: UInt64(life * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        withAnimation { snackMessage = nil }
                    }
            }
        }
        .sheet(item: $shareSheet) { item in
            ShareSheet(text: item.text, subject: item.subject, url: item.url)
        }
        .onAppear { reloadPinnedCourses(viewModel.state) }
        .onChange(of: exportTableId) { _ in reloadPinnedCourses(viewModel.state) }
        // ← 导出目标课表选择弹层 — 行样式对齐 ScheduleScreen TableSwitcherSheet(用户定版视觉)
        .sheet(isPresented: $showTablePicker) {
            ExportTablePickerSheet(
                tables: state.tables,
                selectedTableId: effectiveId,
                mainSelectedId: state.selectedTableId,
                onSelect: { id in
                    exportTableId = id
                    showTablePicker = false
                },
                onDismiss: { showTablePicker = false })
        }
    }

    // 选中表的课程: 当前表直接用 state.courses(已观察), 其他表选中时本地加载一次
    private func reloadPinnedCourses(_ state: ScheduleState) {
        let effectiveId = exportTableId ?? state.selectedTableId
        if let tid = effectiveId, tid != state.selectedTableId {
            loadedCourses = try? ScheduleRepository(AppDatabase.getShared()).getCourses(tid)
        } else {
            loadedCourses = nil
        }
    }

    // ← exportAndShare: 写临时文件 + 分享
    private func exportFile(table: TimeTableEntity, courses: [CourseEntity],
                            ext: String, mime: String, content: String) {
        let fileName = "sleepy_\(table.name)_\(Self.stamp()).\(ext)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try content.data(using: .utf8)?.write(to: url)
            shareSheet = ShareItem(text: nil, subject: table.name, url: url)
            snackMessage = L10n.format("export_saved_to", fileName)
        } catch {
            snackMessage = L10n.format("export_failed")
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}

// ← 导出目标课表选择弹层(AlertDialog) — 行样式对齐 ScheduleScreen TableSwitcherSheet(用户定版视觉):
// 选中行 primaryContainer + 对勾; 主页当前表挂 export_current_table_badge; 上限 360 高滚动。
private struct ExportTablePickerSheet: View {
    @Environment(\.localWakeUpColors) private var colors
    let tables: [TimeTableEntity]
    let selectedTableId: Int64?
    let mainSelectedId: Int64?
    let onSelect: (Int64) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(L10n.format("export_pick_table"))
                .font(.system(size: 24)) // ← Android AlertDialog 默认标题 headlineSmall 24 Regular
                .foregroundColor(colors.onSurface)
                .padding(.top, 16)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(tables) { table in
                        let isSelected = table.id == selectedTableId
                        Button {
                            onSelect(table.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 0) { // ← Android Column 默认 spacing 0
                                    Text(table.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(isSelected ? colors.onPrimaryContainer : colors.onSurface)
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if table.id == mainSelectedId {
                                        Text(L10n.format("export_current_table_badge"))
                                            .font(.system(size: 11))
                                            .foregroundColor(isSelected ? colors.onPrimaryContainer : colors.onSurfaceVariant)
                                    }
                                }
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 18)) // ← Android Modifier.size(18.dp)
                                        .foregroundColor(colors.primary)
                                }
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 8)
                            .background(isSelected ? colors.primaryContainer : colors.surfaceContainer)
                            .cornerRadius(SleepyShapes.small)
                        }
                        .buttonStyle(SleepyButtonStyle())
                        .accessibilityIdentifier("export_table_row_\(table.id)")
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(maxHeight: 360)
        }
        .padding(.bottom, 16)
        .sheetDetents([.medium])
    }
}

// 分享载荷(Identifiable for sheet(item:))
private struct ShareItem: Identifiable {
    let id = UUID()
    let text: String?
    let subject: String
    let url: URL?
}

// UIActivityViewController 包装(← Intent.createChooser)
private struct ShareSheet: UIViewControllerRepresentable {
    let text: String?
    let subject: String
    let url: URL?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        var items: [Any] = []
        if let text = text { items.append(text) }
        if let url = url { items.append(url) }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.setValue(subject, forKey: "subject")
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// ← ExportItem
private struct ExportItem: View {
    @Environment(\.localWakeUpColors) private var colors
    let icon: String
    let title: String
    let subtitle: String
    var id: String? = nil
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 24)) // ← Android 默认 Icon 24dp
                    .foregroundColor(colors.onPrimaryContainer)
                    .frame(width: 44, height: 44)
                    .background(colors.primaryContainer)
                    .cornerRadius(SleepyShapes.medium)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colors.onSurface)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(colors.onSurfaceVariant)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .buttonStyle(SleepyButtonStyle())
        .modifier(OptionalIdentifier(id: id))
    }
}

// 可选 identifier(不破坏无 id 调用点)
private struct OptionalIdentifier: ViewModifier {
    let id: String?
    func body(content: Content) -> some View {
        if let id = id {
            content.accessibilityIdentifier(id)
        } else {
            content
        }
    }
}

private struct RowDivider: View {
    @Environment(\.localWakeUpColors) private var colors
    var body: some View {
        Rectangle()
            .fill(colors.outlineVariant.opacity(SleepyTheme.Alpha.hairline))
            .frame(height: 0.5)
            .padding(.horizontal, 16)
    }
}
