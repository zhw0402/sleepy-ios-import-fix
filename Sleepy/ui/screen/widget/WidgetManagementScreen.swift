// WidgetManagementScreen.swift — ← ui/screen/widget/WidgetManagementScreen.kt
// 列出桌面上已放置的 Sleepy 小组件,点击行进入 WidgetEditScreen 选该组件呈现的课表。
// 空态文案引导去系统桌面添加(添加动作完全在 launcher,App 内无法代劳)。
//
// ★ 平台差异(差异表#8 附注): Android 用 AppWidgetManager.getAppWidgetIds 枚举 10 个
//   receiver 变体的已放置实例;iOS 等价物 = WidgetCenter.getCurrentConfigurations(),
//   返回的 WidgetInfo 只有 kind + family,无稳定实例 ID → 行键 = kind+family,
//   同 kind 的多实例显示为相同行(粒度上限即 per-kind,见 WidgetBindingStore.swift 头注)。

import SwiftUI
import WidgetKit

// ← PlacedWidgetItem — Android 1:1, 实例 ID 换成 kind(平台差异表#8)
struct PlacedWidgetItem: Identifiable {
    let kind: String
    let family: WidgetFamily
    let tableName: String?
    var id: String { kind + "|" + family.description }
    // ← variant.displayNameRes — kind → 既有 widget 标签键 (WidgetVariantInfo.kt 顺序)
    var displayName: String {
        switch kind {
        case "WeekGridWidgetV19": return L10n.format("widget_week_grid_label")
        case "TodayWidgetRV": return L10n.format("widget_today_label")
        case "WeekListWidgetRV": return L10n.format("widget_week_list_label")
        case "WeekViewWidgetRV": return L10n.format("widget_week_view_label")
        case "TwoDayWidgetRV": return L10n.format("widget_twoday_label")
        default: return kind
        }
    }
}

// ← WidgetManagementViewModel.reload 的取数序列(AppWidgetManager 枚举 + 绑定表名)。
//   async 形态 iOS 16+, 部署目标 15.6 → completion API + withCheckedContinuation。
private func loadPlacedWidgets() async -> [PlacedWidgetItem] {
    guard let repo = WidgetLoader.makeRepo() else {
        return []
    }
    let infos: [WidgetInfo] = await withCheckedContinuation { cont in
        WidgetCenter.shared.getCurrentConfigurations { result in
            cont.resume(returning: (try? result.get()) ?? [])
        }
    }
    return infos.map { info in
        PlacedWidgetItem(
            kind: info.kind,
            family: info.family,
            // ← tableName = 绑定表名,nil = 跟随默认(widget_edit_default_label)
            tableName: WidgetBindingStore.resolveBoundTable(info.kind, repo: repo)?.name
        )
    }
}

struct WidgetManagementScreen: View {
    @Environment(\.localWakeUpColors) private var colors
    let onDismiss: () -> Void

    // ← vm.state (WidgetManagementViewModel)
    @State private var items: [PlacedWidgetItem] = []
    // 点击行 → 编辑页(等价 Android onSelect(id) 导航)
    @State private var editTarget: PlacedWidgetItem? = nil

    var body: some View {
        VStack(spacing: 0) {
            SettingsTopBar(title: L10n.format("widget_manage_title"), onBack: onDismiss)
            if items.isEmpty {
                // ← 空态: bodyLarge 居中 + padding 24dp
                Text(L10n.format("widget_manage_empty"))
                    .font(.system(size: 16))
                    .foregroundColor(colors.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { item in
                            PlacedWidgetRow(item: item) { editTarget = item }
                        }
                    }
                    .padding(.horizontal, 16)
                    // ← Android WidgetManagementScreen.kt L97 仅 horizontal 16, 无纵向 padding
                }
            }
        }
        .background(colors.background)
        .task { items = await loadPlacedWidgets() }
        // ← onSelect(widgetId) 导航: fullScreenCover 叠放(manage → edit 两级)
        .fullScreenCover(item: $editTarget) { target in
            WidgetEditScreen(kind: target.kind, onDismiss: { editTarget = nil })
        }
    }
}

// ← PlacedWidgetRow: Card = surfaceContainer + large 圆角(项目既有映射), padding 12dp
private struct PlacedWidgetRow: View {
    @Environment(\.localWakeUpColors) private var colors
    let item: PlacedWidgetItem
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack {
                // ← Android PlacedWidgetRow L123 Column 无 verticalArrangement → 间距 0
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.displayName)
                        .font(.system(size: 16))
                        .foregroundColor(colors.onSurface)
                    // ← tableName ?: widget_edit_default_label
                    Text(item.tableName ?? L10n.format("widget_edit_default_label"))
                        .font(.system(size: 14))
                        .foregroundColor(colors.onSurfaceVariant)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.surfaceContainer)
            .cornerRadius(SleepyShapes.large)
        }
        .buttonStyle(SleepyButtonStyle())
        .accessibilityIdentifier("widget_manage_row_\(item.kind)")
    }
}
