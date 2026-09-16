// ImportSheet.swift — ← ui/screen/imports/ImportSheet.kt (904 行)
// 导入课表弹窗: 教务直连 / 从文本导入(折叠) / 从文件导入 + 支持格式说明 +
// 预览对话框(三模式按钮) + 确认对话框(表名/开始日期/节次编辑器)。
//
// 平台映射: OpenDocument → fileImporter;Activity recreate → LocaleHelper 无关此处。

import SwiftUI
import UniformTypeIdentifiers

// --- shared types(← private enum/data class, sheet 自包含) ---

enum ImportApplyMode {
    case replaceCurrent
    case importAsNew
    case appendNonConflict
    /// 当前课表 + 导入数据合并, 创建新课表保存, 用户命名(v7.10.13)
    case appendAsNew
    /// 连冲突课一起追加进当前课表(红标: 会形成同格多层)(v7.10.13)
    case appendAll
}

struct CourseConflict {
    let incoming: CourseEntity
    let existing: CourseEntity
}

struct ImportPreview {
    let targetTableId: Int64
    let targetTableName: String
    let parseResult: ScheduleParser.ParseResult
    let existingCourses: [CourseEntity]
    let conflicts: [CourseConflict]
    /// issue#22: 同 groupId 多地点提示 — 不阻塞导入,只让用户心里有数
    var multiLocationWarnings: [String] = []

    var incomingCount: Int { parseResult.courses.count }
    var conflictCount: Int { conflicts.count }
    var cleanCount: Int { incomingCount - conflictCount }
}

// 外部打开 json → 主壳 pendingImportText(← MainActivity companion, iOS 为全局)
enum PendingImportText {
    static var value: String? = nil
}

/// 格式详情弹窗键(← Android ImportFormat, sheet(item:) 驱动)
enum ImportFormatKey: String, Identifiable, CaseIterable {
    case wakeupShare, wakeupJson, ics, csv, html, plain
    var id: String { rawValue }

    /// L10n key 前缀(wakeupShare → wakeup_share, 其余同 rawValue)
    var l10nKey: String {
        switch self {
        case .wakeupShare: return "wakeup_share"
        case .wakeupJson: return "wakeup_json"
        case .ics, .csv, .html, .plain: return rawValue
        }
    }

    /// 什么时候用(← format_*_when)
    var whenText: String { L10n.format("format_\(l10nKey)_when") }
    /// 识别要求条目(← string-array format_*_spec, 扁平化为 _0.._n)
    var specItems: [String] {
        var items: [String] = []
        var i = 0
        while L10n.has("format_\(l10nKey)_spec_\(i)") {
            items.append(L10n.format("format_\(l10nKey)_spec_\(i)"))
            i += 1
        }
        return items
    }
    /// 示例(← format_*_example)
    var exampleText: String { L10n.format("format_\(l10nKey)_example") }
}

struct ImportSheet: View {
    @Environment(\.localWakeUpColors) private var colors
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ScheduleViewModel
    let onJwImportRequested: () -> Void
    let onDismiss: () -> Void
    var onImported: () -> Void = {}
    var onOpenEditTable: (Int64) -> Void = { _ in }

    @State private var textExpanded = false
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var errorMsg: String? = nil
    @State private var preview: ImportPreview? = nil
    @State private var pendingMode: ImportApplyMode? = nil
    // ★ sheet 冲突修复配套: 预览快照(确认 sheet 期间 preview 已置 nil)
    @State private var confirmedPreview: ImportPreview? = nil
    @State private var confirmedTableName = ""
    @State private var confirmedStartDate = ""
    @State private var confirmedTimeJson = ""
    // ★ 2026-09-16 文件导入修复: showFilePicker 状态已随 .fileImporter 一起移除,
    //   改由 SystemDocumentPicker.present() 直驱 UIKit 选择器(见文件末尾 extension)。
    @State private var consumedPending = false
    @State private var detailFormat: ImportFormatKey? = nil

    var body: some View {
        let state = viewModel.state
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 标题
                Text(L10n.format("import_title"))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(colors.onSurface)
                    .padding(.bottom, 4)
                Text(L10n.format("import_preview_sub"))
                    .font(.system(size: 14))
                    .foregroundColor(colors.onSurfaceVariant)
                    .padding(.bottom, 16)

                // 行 1: 教务直连
                ImportMethodRow(id: "import_jw", icon: "qrcode", label: L10n.format("import_jw")) {
                    onDismiss()
                    onJwImportRequested()
                }

                // 行 2: 从文本导入(可折叠)
                ImportMethodRow(id: "import_text", icon: "doc.text",
                                label: L10n.format("import_paste"),
                                trailing: textExpanded ? "chevron.up" : "chevron.down") {
                    withAnimation { textExpanded.toggle() }
                }
                if textExpanded {
                    VStack(spacing: 8) {
                        MultilineFieldCompat(placeholder: L10n.format("import_paste_hint"), text: $inputText, minLines: 4, maxLines: 8)
                            .padding(12)
                            .frame(height: 160, alignment: .topLeading)
                            .background(colors.surfaceContainerHighest)   // ← fieldColors 容器色 surfaceContainerHighest
                            .cornerRadius(SleepyTheme.fieldShape)
                            // ← Android filled TextField, 无描边
                            .accessibilityIdentifier("import_paste_input")
                        Button {
                            isLoading = true
                            let p = ImportSheet.buildImportPreview(inputText, state) { msg in errorMsg = msg }
                            if p != nil { preview = p }
                            isLoading = false
                        } label: {
                            Text(isLoading ? L10n.format("import_parsing") : L10n.format("import_preview"))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(colors.onPrimary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(colors.primary)
                                .cornerRadius(SleepyShapes.large)
                        }
                        .buttonStyle(SleepyButtonStyle())
                        .accessibilityIdentifier("import_preview_btn")
                        .disabled(isLoading || inputText.isEmpty)
                    }
                    .padding(.leading, 56)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .padding(.trailing, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // 行 3: 从文件导入
                ImportMethodRow(id: "import_file", icon: "square.and.arrow.up", label: L10n.format("import_file")) {
                    presentFilePicker()
                }

                Spacer().frame(height: 20)

                // 支持的导入类型
                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.format("import_supported_formats"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(colors.onSurface)
                        .padding(.bottom, 8)
                    FormatRow(name: L10n.format("format_wakeup_share"), desc: L10n.format("format_wakeup_desc")) {
                        detailFormat = .wakeupShare
                    }
                    FormatRow(name: L10n.format("format_wakeup_json"), desc: L10n.format("format_json_desc")) {
                        detailFormat = .wakeupJson
                    }
                    FormatRow(name: L10n.format("format_ics"), desc: L10n.format("format_ics_desc")) {
                        detailFormat = .ics
                    }
                    FormatRow(name: L10n.format("format_csv"), desc: L10n.format("format_csv_desc")) {
                        detailFormat = .csv
                    }
                    FormatRow(name: L10n.format("format_html"), desc: L10n.format("format_html_desc")) {
                        detailFormat = .html
                    }
                    FormatRow(name: L10n.format("format_plain"), desc: L10n.format("format_plain_desc")) {
                        detailFormat = .plain
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colors.surfaceContainer)
                .cornerRadius(SleepyShapes.large)

                Spacer().frame(height: 24)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .background(colors.surface)
        // 外部打开 json: pendingImportText 自动触发 paste 路径(一次性消费)
        .onAppear {
            guard !consumedPending else { return }
            consumedPending = true
            // ★ 2026-09-16: 外部打开文件(file://)失败的原因由主壳带过来, 这里弹给用户
            if let failure = PendingImportFailure.value {
                PendingImportFailure.value = nil
                errorMsg = L10n.format("read_failed", failure)
                return
            }
            if let text = PendingImportText.value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                PendingImportText.value = nil
                isLoading = true
                let p = ImportSheet.buildImportPreview(text, state) { msg in errorMsg = msg }
                if p != nil { preview = p }
                isLoading = false
            }
        }
        // ★ 2026-09-16 文件导入修复: 原来的 .fileImporter 已移除 —— 它返回的是
        //   security-scoped URL, 授权失败/ iCloud 未下载 / 非 UTF-8 编码时统统只会
        //   报一句「读取失败」。现在改走 SystemDocumentPicker(asCopy: true) +
        //   TextFileReader(编码回退), 见 presentFilePicker() / consumePickedFile()。
        // 错误反馈通道(← SnackbarHost)
        .alert(L10n.format("import_title"), isPresented: Binding(
            get: { errorMsg != nil },
            set: { if !$0 { errorMsg = nil } }
        )) {
            Button(L10n.format("ok"), role: .cancel) {}
        } message: {
            Text(errorMsg ?? "")
        }
        // 预览对话框
        .sheet(item: Binding(
            get: { preview.map { PreviewBox(preview: $0) } },
            set: { if $0 == nil { preview = nil } }
        )) { box in
            ImportPreviewDialog(preview: box.preview,
                                onDismiss: { preview = nil }) { mode in
                let existingTable = state.currentTable
                confirmedStartDate = preview!.parseResult.startDate.isEmpty
                    ? (existingTable?.startDate ?? Self.todayISO())
                    : preview!.parseResult.startDate
                confirmedTableName = preview!.parseResult.tableName.isEmpty
                    ? (existingTable?.name ?? L10n.format("default_table_name"))
                    : preview!.parseResult.tableName
                // ★ timeJson 首选取解析收割值(ICS 作息/纯文本时间表行/WakeUp timeList),
                //   收割不到再用目标表现值 ← Android: parseResult.timeJson.ifBlank { ... }
                confirmedTimeJson = preview!.parseResult.timeJson.isEmpty
                    ? (existingTable?.timeJson ?? TimeTableUtils.DEFAULT_TIME_JSON)
                    : preview!.parseResult.timeJson
                // ★ iOS 16 sheet 冲突修复: 先关预览 sheet 再开确认 sheet —
                //   同一宿主上确认 sheet 会因预览未 dismiss 被丢弃。快照 preview
                //   进 confirmedPreview 持有, 延迟到预览 dismiss 完成后再置模式。
                // v7.10.13 追加模式: 追加到已存在的课表, 命名由目标课表自带, 不需要再问用户 —
                // 直接走 applyImportPreview, 跳过 ImportConfirmDialog(← Android LaunchedEffect)。
                if mode == .appendNonConflict || mode == .appendAll {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        guard let p = preview else { return }
                        isLoading = true
                        _ = ImportSheet.applyImportPreview(
                            preview: p, mode: mode,
                            confirmedStartDate: p.parseResult.startDate.isEmpty
                                ? (state.currentTable?.startDate ?? Self.todayISO())
                                : p.parseResult.startDate,
                            confirmedTableName: state.currentTable?.name ?? "",
                            confirmedTimeJson: TimeTableUtils.mergeMostComplete(
                                currentJson: state.currentTable?.timeJson ?? "",
                                incomingJson: p.parseResult.timeJson,
                                requiredNodeCount: p.parseResult.nodesPerDay),
                            onImported: onImported) { msg in errorMsg = msg }
                        preview = nil
                        pendingMode = nil
                        isLoading = false
                        onDismiss()
                    }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    confirmedPreview = preview
                    pendingMode = mode
                    preview = nil
                }
            }
            .sheetDetents([.large])
        }
        // 确认对话框(pendingMode 驱动; preview 已快照进 confirmedPreview)
        .sheet(isPresented: Binding(
            get: { pendingMode != nil },
            set: { if !$0 { pendingMode = nil } }
        )) {
            ImportConfirmDialog(
                startDate: confirmedStartDate,
                tableName: confirmedTableName,
                timeJson: confirmedTimeJson,
                // 仅"创建新课表"或"追加为新课表"需要命名; 覆盖课表不强制重命名
                showTableName: pendingMode == .importAsNew || pendingMode == .appendAsNew,
                onTableNameChange: { confirmedTableName = $0 },
                onStartDateChange: { confirmedStartDate = $0 },
                onTimeJsonChange: { confirmedTimeJson = $0 },
                onDismiss: { pendingMode = nil },
                onConfirm: {
                    guard let mode = pendingMode, let currentPreview = confirmedPreview else { return }
                    isLoading = true
                    let resultTableId = ImportSheet.applyImportPreview(
                        preview: currentPreview, mode: mode,
                        confirmedStartDate: confirmedStartDate,
                        confirmedTableName: confirmedTableName,
                        confirmedTimeJson: confirmedTimeJson,
                        onImported: onImported) { msg in errorMsg = msg }
                    confirmedPreview = nil
                    preview = nil
                    pendingMode = nil
                    isLoading = false
                    if let tid = resultTableId {
                        // ★ Android 行为: 导入成功 → 关导入框 → 打开新表编辑页
                        onDismiss()
                        onOpenEditTable(tid)
                    }
                })
                .sheetDetents([.large])
        }
        // 格式详情弹窗 ("支持格式"每行 ⓘ 点开)
        .sheet(item: $detailFormat) { fmt in
            FormatDetailDialog(format: fmt)
        }
    }

    private static func todayISO() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

// Identifiable 包装(sheet(item:) 需要)
private struct PreviewBox: Identifiable {
    let id = UUID()
    let preview: ImportPreview
}

// ← ImportMethodRow
private struct ImportMethodRow: View {
    @Environment(\.localWakeUpColors) private var colors
    let id: String
    let icon: String
    let label: String
    var trailing: String? = nil
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(colors.onPrimaryContainer)
                    .frame(width: 40, height: 40)
                    .background(colors.primaryContainer)
                    .cornerRadius(SleepyShapes.medium)
                Text(label)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(colors.onSurface)
                Spacer()
                if let trailing = trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 24))   // ← Android 无显式 size = 默认 24dp
                        .foregroundColor(colors.onSurfaceVariant)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(SleepyButtonStyle())
        .accessibilityIdentifier(id)
    }
}

// ← FormatRow(每行带 ⓘ 详情入口)
private struct FormatRow: View {
    @Environment(\.localWakeUpColors) private var colors
    let name: String
    let desc: String
    var onDetail: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("•")
                .font(.system(size: 12))
                .foregroundColor(colors.primary)
                .padding(.top, 2)
                .padding(.trailing, 8)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(colors.onSurface)
                .frame(width: 110, alignment: .leading)
            Text(desc)
                .font(.system(size: 12))
                .foregroundColor(colors.onSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)   // ← Android weight(1f)
            if let onDetail {
                Button(action: onDetail) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16))   // ← Android Info 16dp
                        .foregroundColor(colors.onSurfaceVariant)   // ← Android tint onSurfaceVariant
                        .padding(.top, 2)   // ← Android icon padding(top = 2.dp)
                }
                .buttonStyle(SleepyButtonStyle())
                .padding(.leading, 6)   // ← Android icon padding(start = 6.dp)
                .accessibilityLabel(L10n.format("format_detail_content_desc"))
            }
        }
        .padding(.vertical, 3)
    }
}

// ← FormatDetailDialog(格式详情弹窗: 什么时候用 + 识别要求 + 示例; 纯文本独有 AI Prompt)
//   iOS 原生化: List + Section 替代裸 VStack — 自动 inset/grouped 视觉, 系统原生分隔线
private struct FormatDetailDialog: View {
    @Environment(\.localWakeUpColors) private var colors
    @Environment(\.dismiss) private var dismiss
    let format: ImportFormatKey
    @State private var copiedPrompt = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text(format.whenText)
                        .font(.system(size: 14))
                        .foregroundColor(colors.onSurfaceVariant)
                        .listRowBackground(colors.surfaceContainer)
                }
                Section(L10n.format("format_help_spec")) {
                    ForEach(format.specItems, id: \.self) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .font(.system(size: 12))
                                .foregroundColor(colors.primary)
                                .padding(.top, 2)
                            Text(item)
                                .font(.system(size: 12)) // ← Android bodySmall 12
                                .foregroundColor(colors.onSurface)
                        }
                        .listRowBackground(colors.surfaceContainer)
                    }
                }
                Section(L10n.format("format_help_example")) {
                    Text(format.exampleText
                            .replacingOccurrences(of: "\\n", with: "\n")
                            .replacingOccurrences(of: "\\t", with: "\t"))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(colors.onSurface)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowBackground(colors.surfaceContainer)
                }
                if format == .plain {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.format("ai_prompt_title"))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(colors.onPrimaryContainer)
                            Text(L10n.format("ai_prompt_hint"))
                                .font(.system(size: 12))
                                .foregroundColor(colors.onPrimaryContainer)
                            Text(L10n.format("ai_prompt_text")
                                    .replacingOccurrences(of: "\\n", with: "\n")
                                    .replacingOccurrences(of: "\\t", with: "\t"))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(colors.onPrimaryContainer)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(colors.surfaceContainer)
                                .cornerRadius(SleepyShapes.medium)
                            Button {
                                UIPasteboard.general.string = L10n.format("ai_prompt_text")
                                    .replacingOccurrences(of: "\\n", with: "\n")
                                    .replacingOccurrences(of: "\\t", with: "\t")
                                copiedPrompt = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 16))   // ← Android ContentCopy 16dp
                                    Text(copiedPrompt ? L10n.format("copied") : L10n.format("copy_prompt"))
                                        .font(.system(size: 14, weight: .medium))   // ← labelLarge 14sp Medium
                                }
                                .foregroundColor(colors.onPrimaryContainer)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(colors.primaryContainer)
                                .cornerRadius(SleepyShapes.large)
                            }
                            .buttonStyle(SleepyButtonStyle())
                        }
                        .listRowBackground(colors.primaryContainer)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .background(colors.surface)
            .navigationTitle(L10n.format("format_detail_content_desc"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.format("cancel")) { dismiss() }
                        .foregroundColor(colors.primary)
                }
            }
        }
    }
}

// ← ImportPreviewDialog
//   iOS 原生化: NavigationView + List(.insetGrouped) 替代裸 ScrollView → 系统原生导航栏 +
//   系统原生分隔线 + 系统原生 inset 分组, 安全区适配自动处理。底部按钮组保留纯色块(危险动作风格统一)
private struct ImportPreviewDialog: View {
    @Environment(\.localWakeUpColors) private var colors
    let preview: ImportPreview
    let onDismiss: () -> Void
    let onApply: (ImportApplyMode) -> Void

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            if preview.targetTableId == 0 {
                                Text(L10n.format("import_new_table_hint"))
                                    .font(.system(size: 12)) // ← Android bodySmall 12
                                    .foregroundColor(colors.primary)
                            } else {
                                Text(L10n.format("import_target_table", preview.targetTableName))
                                    .font(.system(size: 12)) // ← Android bodySmall 12
                                    .foregroundColor(colors.onSurfaceVariant)
                            }
                        }
                        .listRowBackground(colors.surfaceContainer)
                    }

                    Section {
                        HStack(spacing: 8) {
                            PreviewMetricCard(label: L10n.format("import_courses"),
                                              value: "\(preview.incomingCount)",
                                              bg: colors.primaryContainer, fg: colors.onPrimaryContainer)
                            if preview.targetTableId != 0 {
                                PreviewMetricCard(label: L10n.format("import_conflicts"),
                                                  value: "\(preview.conflictCount)",
                                                  bg: preview.conflictCount > 0 ? colors.errorContainer : colors.secondaryContainer,
                                                  fg: preview.conflictCount > 0 ? colors.onErrorContainer : colors.onSecondaryContainer)
                                PreviewMetricCard(label: L10n.format("import_appendable"),
                                                  value: "\(preview.cleanCount)",
                                                  bg: colors.tertiaryContainer, fg: colors.onTertiaryContainer)
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }

                    Section {
                        PreviewInfoRow(label: L10n.format("import_table_name"), value: preview.parseResult.tableName)
                            .listRowBackground(colors.surfaceContainer)
                        PreviewInfoRow(label: L10n.format("import_start_date"), value: preview.parseResult.startDate)
                            .listRowBackground(colors.surfaceContainer)
                        if preview.targetTableId != 0 {
                            PreviewInfoRow(label: L10n.format("import_suggestion"),
                                           value: preview.conflictCount == 0
                                               ? L10n.format("import_no_conflict")
                                               : L10n.format("import_conflict_count", preview.conflictCount))
                                .listRowBackground(colors.surfaceContainer)
                        }
                    }

                    // ← issue#22 同名课程多地点提示 (secondaryContainer 卡片, 不阻塞导入)
                    if !preview.multiLocationWarnings.isEmpty {
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.format("import_multi_location_warning"))
                                    .font(.system(size: 14, weight: .medium))   // ← titleSmall
                                    .foregroundColor(colors.onSecondaryContainer)
                                ForEach(preview.multiLocationWarnings.prefix(5), id: \.self) { warning in
                                    Text("• \(warning)")
                                        .font(.system(size: 12))   // ← bodySmall
                                        .foregroundColor(colors.onSecondaryContainer)
                                }
                                if preview.multiLocationWarnings.count > 5 {
                                    Text(L10n.format("more_unexpanded", preview.multiLocationWarnings.count - 5))
                                        .font(.system(size: 11, weight: .medium))   // ← labelSmall
                                        .foregroundColor(colors.onSecondaryContainer)
                                }
                            }
                            .listRowBackground(colors.secondaryContainer)
                        }
                    }

                    if !preview.conflicts.isEmpty {
                        Section(L10n.format("import_conflicts")) {
                            ForEach(preview.conflicts.prefix(3)) { conflict in
                                Text("• \(conflict.incoming.courseName) ↔ \(conflict.existing.courseName)（\(DateUtils.localizedDay(conflict.incoming.day)) \(conflict.incoming.nodeString(isShort: true))）")
                                    .font(.system(size: 12))
                                    .foregroundColor(colors.onSurfaceVariant)
                                    .listRowBackground(colors.surfaceContainer)
                            }
                            if preview.conflicts.count > 3 {
                                Text(L10n.format("import_conflict_more", preview.conflicts.count - 3))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(colors.onSurfaceVariant)
                                    .listRowBackground(colors.surfaceContainer)
                            }
                        }
                    }

                    if !preview.parseResult.droppedLines.isEmpty {
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.format("import_dropped_title", preview.parseResult.droppedLines.count))
                                    .font(.system(size: 14, weight: .medium))   // ← titleSmall 14sp Medium
                                    .foregroundColor(colors.onErrorContainer)
                                Text(L10n.format("import_dropped_hint"))
                                    .font(.system(size: 12))
                                    .foregroundColor(colors.onErrorContainer)
                                ForEach(preview.parseResult.droppedLines.prefix(3), id: \.self) { line in
                                    Text("• \(line)")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(colors.onErrorContainer)
                                }
                            }
                            .listRowBackground(colors.errorContainer)
                        }
                    }

                    // sleepy-v1 (§7.3): 表级提示(非行级) — T行钳制/节点抬升/chk不符/n=不符/二次表头
                    if !preview.parseResult.warnings.isEmpty {
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.format("import_warnings_title"))
                                    .font(.system(size: 14, weight: .medium))   // ← titleSmall
                                    .foregroundColor(colors.onSecondaryContainer)
                                ForEach(preview.parseResult.warnings.prefix(4), id: \.self) { line in
                                    Text("• \(line)")
                                        .font(.system(size: 12))
                                        .foregroundColor(colors.onSecondaryContainer)
                                }
                                if preview.parseResult.warnings.count > 4 {
                                    Text(L10n.format("import_conflict_more", preview.parseResult.warnings.count - 4))
                                        .font(.system(size: 11))
                                        .foregroundColor(colors.onSecondaryContainer)
                                }
                            }
                            .listRowBackground(colors.secondaryContainer)
                        }
                    }

                    // 留出底部按钮区空间
                    Section {
                        Color.clear.frame(height: 100)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.insetGrouped)
                .background(colors.surface)

                // 底部按钮组 - 浮动在 List 之上, 保留纯色块风格统一
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        if preview.targetTableId == 0 {
                            PrimaryDialogButton(L10n.format("import_as_new")) {
                                onApply(.importAsNew)
                            }
                        } else {
                            PrimaryDialogButton(L10n.format("import_append_only")) {
                                onApply(.appendNonConflict)
                            }
                            PrimaryDialogButton(L10n.format("import_as_new")) {
                                onApply(.importAsNew)
                            }
                        }
                    }
                    if preview.targetTableId != 0 {
                        HStack(spacing: 8) {
                            Button {
                                onApply(.appendAll)
                            } label: {
                                Text(L10n.format("import_append_conflict"))
                                    .font(.system(size: 14, weight: .medium))
                                    .lineLimit(1)   // ← Android maxLines = 1
                                    .foregroundColor(colors.onErrorContainer)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 40)
                                    .background(colors.errorContainer)
                                    .cornerRadius(SleepyShapes.medium)
                            }
                            .buttonStyle(SleepyButtonStyle())
                            PrimaryDialogButton(L10n.format("import_append_as_new")) {
                                onApply(.appendAsNew)
                            }
                        }
                        Button {
                            onApply(.replaceCurrent)
                        } label: {
                            Text(L10n.format("import_overwrite"))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(colors.onErrorContainer)
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                                .background(colors.errorContainer)
                                .cornerRadius(SleepyShapes.medium)
                        }
                        .buttonStyle(SleepyButtonStyle())
                    }
                    // ← Android TextButton: 纯文字 40dp, onSurfaceVariant
                    Button(action: onDismiss) {
                        Text(L10n.format("cancel"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(colors.onSurfaceVariant)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                    }
                    .buttonStyle(SleepyButtonStyle())
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .background(
                    LinearGradient(colors: [colors.surface.opacity(0), colors.surface],
                                   startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .bottom)
                )
            }
            .navigationTitle(L10n.format("import_preview_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.format("cancel")) { onDismiss() }
                        .foregroundColor(colors.primary)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("import_preview_title")
        }
    }
}

extension CourseConflict: Identifiable {
    var id: String { "\(incoming.id)-\(existing.id)" }
}

private struct PrimaryDialogButton: View {
    @Environment(\.localWakeUpColors) private var colors
    let title: String
    let action: () -> Void

    init(_ title: String, _ action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(colors.onPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(colors.primary)
                .cornerRadius(SleepyShapes.medium)
        }
        .buttonStyle(SleepyButtonStyle())
    }
}

// ← PreviewMetricCard
private struct PreviewMetricCard: View {
    let label: String
    let value: String
    let bg: Color
    let fg: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))   // ← labelSmall 11sp Medium
                .foregroundColor(fg.opacity(SleepyTheme.Alpha.highContent))
            Text(value)
                .font(.system(size: 22, weight: .bold))   // ← titleLarge 22sp Bold
                .foregroundColor(fg)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg)
        .cornerRadius(SleepyShapes.large)
    }
}

// ← PreviewInfoRow
private struct PreviewInfoRow: View {
    @Environment(\.localWakeUpColors) private var colors
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .medium))   // ← labelSmall 11sp Medium
                .foregroundColor(colors.onSurfaceVariant)
            Text(value)
                .font(.system(size: 14))
                .foregroundColor(colors.onSurface)
                .accessibilityIdentifier("import_info_\(label)")
        }
    }
}

// ← ImportConfirmDialog
private struct ImportConfirmDialog: View {
    @Environment(\.localWakeUpColors) private var colors
    @State var startDate: String
    @State var tableName: String
    @State var timeJson: String
    var showTableName: Bool = true
    let onTableNameChange: (String) -> Void
    let onStartDateChange: (String) -> Void
    let onTimeJsonChange: (String) -> Void
    let onDismiss: () -> Void
    let onConfirm: () -> Void

    @State private var rows: [TimeTableUtils.TimeSlotRow] = []
    @State private var rowsLoaded = false
    @State private var localError: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.format("import_confirm_title"))
                    .font(.system(size: 24))   // ← M3 AlertDialog title = headlineSmall 24sp 常规
                    .foregroundColor(colors.onSurface)
                Text(L10n.format("import_confirm_body"))
                    .font(.system(size: 14))
                    .foregroundColor(colors.onSurfaceVariant)

                if showTableName {
                    TextField(L10n.format("import_table_name"), text: $tableName)
                        .frame(maxWidth: .infinity)   // ← Android fillMaxWidth()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(colors.surfaceContainerHighest)   // ← fieldColors 容器色 surfaceContainerHighest
                        .cornerRadius(SleepyTheme.fieldShape)
                        .onChange(of: tableName) { onTableNameChange($0) }
                }

                DatePickerField(value: startDate, onValueChange: { newValue in
                    startDate = newValue
                    onStartDateChange(newValue)
                }, label: L10n.format("import_week_start"), isError: localError != nil,
                   fillsWidth: true)

                if let localError = localError {
                    Text(localError)
                        .font(.system(size: 12))
                        .foregroundColor(colors.error)
                }

                TimeSlotEditor(rows: rows, onRowsChange: { newRows in
                    rows = newRows
                    onTimeJsonChange(TimeTableUtils.buildTimeJsonFromRows(newRows))
                })
            }
            .padding(20)
        }
        .background(colors.surface)
        .onAppear {
            guard !rowsLoaded else { return }
            rowsLoaded = true
            rows = TimeTableUtils.parseTimeSlotRows(timeJson)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                // ← Android TextButton 默认色 = primary, labelLarge 14sp Medium, 高 40dp
                Button(action: onDismiss) {
                    Text(L10n.format("back"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colors.primary)
                        .frame(height: 40)
                }
                .buttonStyle(SleepyButtonStyle())
                Spacer()
                Button(action: validateAndConfirm) {
                    Text(L10n.format("import_confirm"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colors.primary)
                        .frame(height: 40)
                }
                .buttonStyle(SleepyButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(colors.surface)
        }
    }

    // ← confirmButton 内校验链: 空日期/格式/空时间/非法时间
    private func validateAndConfirm() {
        if startDate.trimmingCharacters(in: .whitespaces).isEmpty {
            localError = L10n.format("import_start_date_required")
            return
        }
        let dateRegex = "^\\d{4}-\\d{2}-\\d{2}$"
        if startDate.range(of: dateRegex, options: .regularExpression) == nil {
            localError = L10n.format("start_date_format")
            return
        }
        let emptyRows = rows.filter { $0.start.isEmpty || $0.end.isEmpty }
        if let first = emptyRows.first {
            localError = L10n.format("slot_time_required", first.node)
            return
        }
        let timeRegex = "^\\d{2}:\\d{2}$"
        let invalidRows = rows.filter {
            $0.start.range(of: timeRegex, options: .regularExpression) == nil ||
            $0.end.range(of: timeRegex, options: .regularExpression) == nil ||
            $0.start >= $0.end
        }
        if let first = invalidRows.first {
            localError = L10n.format("slot_time_invalid", first.node)
            return
        }
        localError = nil
        onTimeJsonChange(TimeTableUtils.buildTimeJsonFromRows(rows))
        onConfirm()
    }
}

// ==================== 业务逻辑(buildImportPreview / applyImportPreview / conflict) ====================

extension ImportSheet {

    // ← buildImportPreview
    static func buildImportPreview(
        _ text: String,
        _ state: ScheduleState,
        onError: (String) -> Void
    ) -> ImportPreview? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onError(L10n.format("import_content_empty"))
            return nil
        }
        // selectedTableId 缺失时也能导入 — tableId=0, apply 时按 ImportAsNew 自动建表
        let tableId = state.selectedTableId ?? 0
        let repo = ScheduleRepository(AppDatabase.getShared())
        switch ScheduleParser.parse(text, defaultTableId: tableId) {
        case .success(let parseResult):
            let existingTable = tableId == 0 ? nil : try? repo.getTable(tableId)
            let existingCourses = tableId == 0 ? [] : ((try? repo.getCourses(tableId)) ?? [])
            let conflicts: [CourseConflict] = tableId == 0 ? [] : parseResult.courses.compactMap { incoming in
                existingCourses.first { Self.coursesConflict(incoming, $0) }
                    .map { CourseConflict(incoming: incoming, existing: $0) }
            }
            // ← issue#22: 同 groupId 多地点提示 — 不阻塞导入, 让用户心里有数
            var multiLocWarnings: [String] = []
            let roomGroups = Dictionary(grouping: parseResult.courses) { $0.groupId }
            for (gid, cs) in roomGroups {
                if gid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                let distinctRooms = Set(cs.map { $0.room.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty })
                if distinctRooms.count >= 2 {
                    multiLocWarnings.append(L10n.format(
                        "import_multi_location_warning_detail", cs.first?.courseName ?? "", distinctRooms.count))
                }
            }
            return ImportPreview(
                targetTableId: tableId,
                targetTableName: existingTable?.name ?? L10n.format("manage_current_table"),
                parseResult: parseResult,
                existingCourses: existingCourses,
                conflicts: conflicts,
                multiLocationWarnings: multiLocWarnings)
        case .failure(let e):
            onError(L10n.format("import_failed", e.localizedDescription))
            return nil
        }
    }

    // ← applyImportPreview: 三模式落地
    @discardableResult
    static func applyImportPreview(
        preview: ImportPreview,
        mode: ImportApplyMode,
        confirmedStartDate: String,
        confirmedTableName: String,
        confirmedTimeJson: String,
        onImported: () -> Void,
        onError: (String) -> Void
    ) -> Int64? {
        let repo = ScheduleRepository(AppDatabase.getShared())
        switch mode {
        case .replaceCurrent:
            if let existing = try? repo.getTable(preview.targetTableId) {
                var copy = existing
                copy.name = confirmedTableName.trimmingCharacters(in: .whitespaces).isEmpty
                    ? preview.parseResult.tableName
                    : confirmedTableName.trimmingCharacters(in: .whitespaces)
                copy.startDate = confirmedStartDate
                copy.timeJson = confirmedTimeJson
                copy.nodesPerDay = preview.parseResult.nodesPerDay > 0 ? preview.parseResult.nodesPerDay : existing.nodesPerDay
                try? repo.updateTable(copy)
            }
            // sleepy-v1 (§3.4 契约一): 解析端权威 groupId → 绕过 assignGroupIds 再分配
            if preview.parseResult.groupIdsAuthoritative {
                try? repo.replaceCoursesKeepingGroups(preview.targetTableId, preview.parseResult.courses)
            } else {
                try? repo.replaceCourses(preview.targetTableId, preview.parseResult.courses)
            }
            onImported()
            return preview.targetTableId
        case .importAsNew:
            let base = try? repo.getTable(preview.targetTableId)
            let existingNames = ((try? repo.getAllTables()) ?? []).map { $0.name }
            var newTable = TimeTableEntity(
                name: uniqueImportedTableName(confirmedTableName, existingNames),
                startDate: confirmedStartDate,
                maxWeek: preview.parseResult.maxWeek > 0 ? preview.parseResult.maxWeek : (base?.maxWeek ?? 20),
                nodesPerDay: preview.parseResult.nodesPerDay > 0 ? preview.parseResult.nodesPerDay : base?.nodesPerDay ?? 12,
                timeJson: confirmedTimeJson,
                isDefault: false)
            newTable.color = base?.color ?? "#FF6750A4"
            let newTableId = (try? repo.insertTable(newTable)) ?? 0
            var courses = preview.parseResult.courses
            for i in courses.indices {
                courses[i].id = 0
                courses[i].tableId = newTableId
            }
            // sleepy-v1: groupId 权威时保留分区(ImportAsNew 全量落新课表, 等价 replace 语义)
            if preview.parseResult.groupIdsAuthoritative {
                _ = try? repo.insertCoursesKeepingGroups(courses)
            } else {
                _ = try? repo.insertCourses(courses)
            }
            try? repo.setDefault(newTableId)
            onImported()
            return newTableId
        case .appendNonConflict:
            let cleanCourses = preview.parseResult.courses.filter { incoming in
                !preview.existingCourses.contains { Self.coursesConflict(incoming, $0) }
            }
            // v7.10.16x 三层闸门改相对判定(用户 2026-09-10 报"预览 8 门全不冲突,
            // 仅追加不冲突却 toast 全部冲突"): 旧绝对判定连坐原表已有超层天上的无辜候选。
            // 与 AppendAsNew(v7.10.16j)同规: 只剔**让某天新超 2 层**的候选(因它而恶化才拦)。
            let baseExceeding = ConflictLayoutEngine.daysExceedingTwoLanes(preview.existingCourses)
            let survivors = cleanCourses.filter { cand in
                ConflictLayoutEngine.daysExceedingTwoLanes(preview.existingCourses + [cand]) == baseExceeding
            }
            if survivors.isEmpty {
                onError(L10n.format("import_all_conflict"))
                return nil
            }
            var courses = survivors
            for i in courses.indices {
                courses[i].id = 0
                courses[i].tableId = preview.targetTableId
            }
            if preview.parseResult.groupIdsAuthoritative {
                _ = try? repo.insertCoursesKeepingGroups(courses)
            } else {
                _ = try? repo.insertCourses(courses)
            }
            onImported()
            return preview.targetTableId
        case .appendAsNew:
            // v7.10.13: 并集追加为新课表 — 老表全部课程 + 导入课程(闸门不拦), 用户命名
            let base = try? repo.getTable(preview.targetTableId)
            let existingNames = ((try? repo.getAllTables()) ?? []).map { $0.name }
            var newTable = TimeTableEntity(
                name: uniqueImportedTableName(confirmedTableName, existingNames),
                startDate: confirmedStartDate,
                maxWeek: preview.parseResult.maxWeek > 0 ? preview.parseResult.maxWeek : (base?.maxWeek ?? 20),
                nodesPerDay: preview.parseResult.nodesPerDay > 0 ? preview.parseResult.nodesPerDay : base?.nodesPerDay ?? 12,
                timeJson: confirmedTimeJson,
                isDefault: false)
            newTable.color = base?.color ?? "#FF6750A4"
            let newTableId = (try? repo.insertTable(newTable)) ?? 0
            var courses = preview.existingCourses + preview.parseResult.courses
            for i in courses.indices {
                courses[i].id = 0
                courses[i].tableId = newTableId
            }
            if preview.parseResult.groupIdsAuthoritative {
                _ = try? repo.insertCoursesKeepingGroups(courses)
            } else {
                _ = try? repo.insertCourses(courses)
            }
            onImported()
            return newTableId
        case .appendAll:
            // v7.10.13: 连冲突课一起追加进当前课表(危险: 会形成同格多层)
            var courses = preview.parseResult.courses
            for i in courses.indices {
                courses[i].id = 0
                courses[i].tableId = preview.targetTableId
            }
            if preview.parseResult.groupIdsAuthoritative {
                _ = try? repo.insertCoursesKeepingGroups(courses)
            } else {
                _ = try? repo.insertCourses(courses)
            }
            onImported()
            return preview.targetTableId
        }
    }

    // ← coursesConflict: 同日 + 周次区间重叠 + 节次区间重叠
    static func coursesConflict(_ a: CourseEntity, _ b: CourseEntity) -> Bool {
        if a.day != b.day { return false }
        if a.endWeek < b.startWeek || b.endWeek < a.startWeek { return false }
        let aStart = a.startNode
        let aEnd = a.startNode + a.step - 1
        let bStart = b.startNode
        let bEnd = b.startNode + b.step - 1
        return aStart <= bEnd && bStart <= aEnd
    }

    // ← uniqueImportedTableName
    static func uniqueImportedTableName(_ base: String, _ existingNames: [String]) -> String {
        let def = L10n.format("default_table_name")
        let effective = base.isEmpty ? def : base
        if !existingNames.contains(effective) {
            return effective.isEmpty ? "\(def)1" : effective
        }
        var index = 2
        while existingNames.contains("\(effective)\(index)") ||
              existingNames.contains("\(effective)(\(index))") {
            index += 1
        }
        return "\(effective)\(index)"
    }
}

// Optional.map 语义链(嵌套 optional 展平用)
extension Optional {
    func `let`<R>(_ transform: (Wrapped) -> R) -> R? {
        map(transform) ?? nil
    }
}

// ==================== ★ 2026-09-16 文件导入修复 ====================
//
// 替换掉原来挂在 body 上的 SwiftUI .fileImporter。原因:
//   ① .fileImporter 回调给的是 security-scoped URL, 需要 startAccessingSecurityScopedResource()
//      成功才读得到; 一旦失败, 代码仍继续读 → 所有文件统一报「读取失败」。
//   ② iCloud 云盘未下载的占位文件直接 String(contentsOf:) 必失败。
//   ③ 只按 .utf8 解码, 中文教务/Excel 导出的 GBK 文件必失败。
// 现在: SystemDocumentPicker(asCopy:true) 由系统先把文件复制进沙箱 →
//      TextFileReader 多编码回退 → 失败时给出能照着做的中文提示。
//
// 注: 这段必须在与本 struct 同一文件内(@State 为 private → 跨文件不可见), 故不另开文件。

// 文件打开失败原因(file:// 外部打开路径专用; 与 PendingImportText 对称)
enum PendingImportFailure {
    static var value: String? = nil
}

extension ImportSheet {

    /// 弹出系统文件选择器(UIKit 直驱; 不受 SwiftUI sheet 嵌套影响)
    func presentFilePicker() {
        SystemDocumentPicker.present { outcome in
            switch outcome {
            case .picked(let url):
                consumePickedFile(url)
            case .cancelled:
                break
            case .failed(let error):
                let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                errorMsg = L10n.format("read_failed", detail)
            }
        }
    }

    /// 读取 + 解析选中的文件。读取层的报错已可直接展示给用户。
    func consumePickedFile(_ url: URL) {
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        isLoading = true

        let text: String
        do {
            text = try TextFileReader.read(url: url)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMsg = L10n.format("read_failed", "\(name) — \(detail)")
            isLoading = false
            return
        }

        guard let parsed = ImportSheet.buildImportPreview(text, viewModel.state, onError: { msg in
            // 解析失败: 把文件名一起带上, 便于用户回报是哪个文件
            errorMsg = "\(msg)(文件: \(name))"
        }) else {
            isLoading = false
            return
        }

        // ★ 选择器仍在 dismiss 动画里: 同一 runloop 立刻 present 预览 sheet 会被丢弃
        //   (与文件内既有「先关预览再开确认」的 0.45s 延迟同一个坑)。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            preview = parsed
            isLoading = false
        }
    }
}
