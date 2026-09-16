// WidgetEditScreen.swift — ← ui/screen/widget/WidgetEditScreen.kt
//   + WidgetEditSection.kt + WidgetEditScheduleSection.kt (三文件合一, 职责分区注释保留)。
// 逐 widget 编辑页: 选这个小组件呈现哪张课表。改绑定写 WidgetBindingStore 并触发
// WidgetCenter.reloadAllTimelines (← WidgetUpdater.notifyDataChanged), 桌面即时重绘。
//
// 平台差异(差异表#8): Android widgetId:Int → iOS kind:String (粒度 per-kind,
// 见 WidgetBindingStore.swift 头注); section 扩展点等价物见下方注释块。

import SwiftUI
import WidgetKit

// ← WidgetEditScope: 传给每个 section 的状态 + 选择回调 (tableId nil = 清绑定回默认)
//   issue#26: useAlias/onUseAliasChange — widget 场景 课程名显示 原名/别名 (全局一档);
//   默认参数兜底, 旧构造点(未传)不破编译。
struct WidgetEditScope {
    let kind: String
    let currentBinding: Int64?
    let availableTables: [TimeTableEntity]
    let onSelectTable: (Int64?) -> Void
    var useAlias: Bool = false
    var onUseAliasChange: (Bool) -> Void = { _ in }
}

// ← WidgetEditSection.kt 的协议扩展点在 SwiftUI 下不成立(existential View 不能做
//   ForEach 内容, Xcode14/Swift5.8)。等价扩展点 = 本文件直接加同级 section struct +
//   WidgetEditScreen.sections 里加一项 — 与 Android "新文件+列表加一项" 同构。
//   当前两节 (WidgetEditScheduleSection + WidgetEditAliasSection), 保持直连组合。

// ← WidgetEditViewModel.reload / setBinding / setUseAlias 的取数与落库序列:
//   availableTables = 有课的表 (← WidgetEditCore.filterAvailableTables, 保序)
//   currentBinding = WidgetBindingStore.get(kind); 选择回调写库 + WidgetCenter 通知。
//   useAlias = AppPrefs.isWidgetUseAlias; 切换回调写库(set 内已刷 timeline)。
func makeWidgetEditScope(kind: String, onSelect: @escaping (Int64?) -> Void,
                         onUseAliasChange: @escaping (Bool) -> Void = { _ in }) -> WidgetEditScope {
    let repo = WidgetLoader.makeRepo()
    let all = repo.map { (try? $0.getAllTables()) ?? [] } ?? []
    var available: [TimeTableEntity] = []
    for table in all {
        let count = ((try? repo?.getCourses(table.id)) ?? []).count
        if count > 0 {
            available.append(table)
        }
    }
    return WidgetEditScope(
        kind: kind,
        currentBinding: WidgetBindingStore.get(kind),
        availableTables: available,
        onSelectTable: onSelect,
        useAlias: AppPrefs.shared.isWidgetUseAlias(),
        onUseAliasChange: onUseAliasChange
    )
}

func applyWidgetBinding(kind: String, tableId: Int64?) {
    if let id = tableId {
        WidgetBindingStore.put(kind, tableId: id)
    } else {
        WidgetBindingStore.remove(kind)
    }
    WidgetCenter.shared.reloadAllTimelines()
}

struct WidgetEditScreen: View {
    @Environment(\.localWakeUpColors) private var colors
    let kind: String
    let onDismiss: () -> Void

    // ← state: currentBinding + availableTables (选完 reload, 选中态即时切换)
    @State private var scope: WidgetEditScope?

    // ← sections: 后续 per-widget 见本文件头注 (SwiftUI 扩展点等价物)
    var body: some View {
        VStack(spacing: 0) {
            SettingsTopBar(title: L10n.format("widget_edit_title"), onBack: onDismiss)
            ScrollView {
                LazyVStack(spacing: 16) {
                    if let s = scope {
                        WidgetEditScheduleSection(scope: s)
                        // ← sections 列表加一项的等价扩展点 (issue#26 别名节, 排课表节后)
                        WidgetEditAliasSection(scope: s)
                    }
                }
                .padding(.horizontal, 16)
                // ← Android WidgetEditScreen.kt L92 仅 horizontal 16, 无纵向 padding
            }
        }
        .background(colors.background)
        .onAppear {
            reloadScope()
        }
    }

    // ← vm.reload(): 选完/切完重读 scope, 选中态即时切换 — 两个回调同走"写库 + 重读"管线
    private func reloadScope() {
        scope = makeWidgetEditScope(
            kind: kind,
            onSelect: { tableId in
                applyWidgetBinding(kind: kind, tableId: tableId)
                reloadScope()
            },
            onUseAliasChange: { v in
                // ← vm.setUseAlias: 写 AppPrefs(内部已 WidgetCenter 全量刷) + reload
                AppPrefs.shared.setWidgetUseAlias(v)
                reloadScope()
            }
        )
    }
}

// ← WidgetEditScheduleSection: "呈现的课表" 分区。
//   选中态 = primaryContainer 色块 + Check 图标 (ui-blocks-no-border-rule, 无描边)。
//   空表已被过滤 — 永不给用户绑到会渲染"请先创建课表"的表。
private struct WidgetEditScheduleSection: View {
    @Environment(\.localWakeUpColors) private var colors
    let scope: WidgetEditScope

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.format("widget_edit_section_schedule"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(colors.onSurface)
            Spacer().frame(height: 8)
            // ← Surface(shape 16dp, surfaceContainer): 纵向 padding 4dp + 行列
            VStack(spacing: 0) {
                sectionRow(
                    label: L10n.format("widget_edit_default_label"),
                    selected: scope.currentBinding == nil
                ) {
                    scope.onSelectTable(nil)
                }
                ForEach(scope.availableTables) { table in
                    sectionRow(
                        label: table.name,
                        selected: scope.currentBinding == table.id
                    ) {
                        scope.onSelectTable(table.id)
                    }
                }
            }
            .padding(.vertical, 4)
            .background(colors.surfaceContainer)
            .cornerRadius(16)
        }
    }

    // ← DefaultRow / TableRow (仅差 Spacer 8dp, 合一): bodyLarge 16 + Check primary
    private func sectionRow(label: String, selected: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack {
                Text(label)
                    .font(.system(size: 16))
                    .foregroundColor(colors.onSurface)
                Spacer()
                if selected {
                    Spacer().frame(width: 8)
                    Image(systemName: "checkmark")
                        // ← Android Check 无 size 修饰符 = 默认 24dp (ScheduleSection L91/L121, AliasSection L91)
                        .font(.system(size: 24))
                        .foregroundColor(colors.primary)
                        .accessibilityLabel(L10n.format("selected"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(selected ? colors.primaryContainer : colors.surfaceContainer)
        }
        .buttonStyle(SleepyButtonStyle())
    }
}

// ← WidgetEditAliasSection (issue#26): "课程名显示" 分区 — 原名/别名 全局一档,
//   所有小组件共享同一开关(渲染器无 widgetId, 读 AppPrefs — 与 colorless/separator 同先例)。
//   选中态 = primaryContainer 色块 + Check 图标 (ui-blocks-no-border-rule, 无描边),
//   与 WidgetEditScheduleSection.sectionRow 同模式。
private struct WidgetEditAliasSection: View {
    @Environment(\.localWakeUpColors) private var colors
    let scope: WidgetEditScope

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.format("widget_edit_section_alias"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(colors.onSurface)
            Spacer().frame(height: 8)
            // ← Surface(shape 16dp, surfaceContainer): 纵向 padding 4dp + 两行 optionRow
            VStack(spacing: 0) {
                optionRow(
                    label: L10n.format("settings_name_original"),
                    selected: !scope.useAlias
                ) {
                    scope.onUseAliasChange(false)
                }
                optionRow(
                    label: L10n.format("settings_name_alias"),
                    selected: scope.useAlias
                ) {
                    scope.onUseAliasChange(true)
                }
            }
            .padding(.vertical, 4)
            .background(colors.surfaceContainer)
            .cornerRadius(16)
        }
    }

    // ← OptionRow: bodyLarge 16 + Check 24 primary, 选中 primaryContainer 底, padding 16×14
    private func optionRow(label: String, selected: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack {
                Text(label)
                    .font(.system(size: 16))
                    .foregroundColor(colors.onSurface)
                Spacer()
                if selected {
                    Spacer().frame(width: 8)
                    Image(systemName: "checkmark")
                        .font(.system(size: 24))
                        .foregroundColor(colors.primary)
                        .accessibilityLabel(L10n.format("selected"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(selected ? colors.primaryContainer : colors.surfaceContainer)
        }
        .buttonStyle(SleepyButtonStyle())
    }
}
