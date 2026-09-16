// AppearanceScreen.swift — ← ui/screen/mine/AppearanceScreen.kt
// 外观页(决策 D2 合并页): 仅主题色彩组(SystemThemeCard + 2列预设网格 + 深浅色三态)。
// 选主题/模式后立即刷小组件(refreshWidgets 管线保留)。

import SwiftUI
import WidgetKit
import Combine

struct AppearanceScreen: View {
    @Environment(\.localWakeUpColors) private var colors
    let onDismiss: () -> Void
    var themeMode: String = AppPrefs.THEME_MODE_SYSTEM
    var onThemeModeChange: (String) -> Void = { _ in }
    // ← Android themeKeyFlow.collectAsState: 选色即时生效,经 AppRoot 回写 themeKey
    var onThemeKeyChange: () -> Void = {}

    @State private var currentKey: String
    // 自定义主题列表(编辑器保存/删除后重载)← Android customListVersion
    @State private var customThemes: [CustomTheme] = CustomThemeStore.getAll()
    @State private var showEditor = false
    @State private var editingTheme: CustomTheme?
    private let prefs = AppPrefs.shared

    init(onDismiss: @escaping () -> Void,
         themeMode: String = AppPrefs.THEME_MODE_SYSTEM,
         onThemeModeChange: @escaping (String) -> Void = { _ in },
         onThemeKeyChange: @escaping () -> Void = {}) {
        self.onDismiss = onDismiss
        self.themeMode = themeMode
        self.onThemeModeChange = onThemeModeChange
        self.onThemeKeyChange = onThemeKeyChange
        _currentKey = State(initialValue: AppPrefs.shared.getThemeKey())
    }

    /// 网格顺序不变量(d87eade3 + c1c166f9):预设 → 自定义 → 新建入口,加号永远在整网格
    /// 末尾且与自定义主题数量无关。抽成纯函数是为了让「顺序本身」被契约测试锁死
    /// (SleepyTests/CustomThemeTests.swift 的 CustomThemeGridTests),而不是只靠肉眼看 UI。
    static func gridCells(presets: [ThemePreset], customs: [CustomTheme]) -> [ThemeGridCell] {
        presets.map { ThemeGridCell.preset($0) }
            + customs.map { ThemeGridCell.custom($0) }
            + [ThemeGridCell.newTheme]
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTopBar(title: L10n.format("mine_appearance"), onBack: onDismiss)
            ScrollView {
                VStack(spacing: 12) {
                    // ── 分组① 主题色彩 ──
                    SectionHeader(title: L10n.format("appearance_section_theme"))

                    SystemThemeCard(selected: currentKey == ThemePresets.KEY_SYSTEM) {
                        prefs.setThemeKey(ThemePresets.KEY_SYSTEM)
                        currentKey = ThemePresets.KEY_SYSTEM
                        onThemeKeyChange()
                        refreshWidgets()
                    }

                    // 2 列网格:5 套预设 → 各自定义卡 → 新建入口(加号)
                    // ★ 顺序不变量(d87eade3 + c1c166f9):预设 → 自定义 → 加号,加号永远
                    //   排在整网格末尾,与自定义主题数量无关;自定义卡与预设卡同尺寸同构。
                    let cells: [ThemeGridCell] = Self.gridCells(presets: ThemePresets.all, customs: customThemes)
                    VStack(spacing: 12) {
                        ForEach(Array(cells.chunked(into: 2).enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 12) {
                                ForEach(row) { cell in
                                    ThemeGridCellView(
                                        cell: cell,
                                        currentKey: currentKey,
                                        onSelect: selectThemeKey,
                                        onEdit: openEditor
                                    )
                                }
                                // 奇数行补空位:用等弹性占位而非 Spacer,保证单卡也严格半宽
                                // (与 Android Box(Modifier.weight(1f)) 等价)
                                if row.count == 1 {
                                    Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                                }
                            }
                        }
                    }

                    // 外观模式: 浅色/深色/跟随系统 三态分段
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.format("theme_appearance"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(colors.onSurface)
                        let modes: [(String, String)] = [
                            (AppPrefs.THEME_MODE_SYSTEM, L10n.format("theme_mode_system")),
                            (AppPrefs.THEME_MODE_LIGHT, L10n.format("theme_mode_light")),
                            (AppPrefs.THEME_MODE_DARK, L10n.format("theme_mode_dark"))
                        ]
                        HStack(spacing: 3) {
                            ForEach(modes, id: \.0) { mode, label in
                                let sel = mode == themeMode
                                Button {
                                    guard mode != themeMode else { return }
                                    prefs.setThemeMode(mode)
                                    onThemeModeChange(mode)
                                    refreshWidgets()
                                } label: {
                                    Text(label)
                                        .font(.system(size: 14, weight: sel ? .semibold : .medium))
                                        .foregroundColor(sel ? colors.onPrimary : colors.onSurfaceVariant)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(sel ? colors.primary : colors.surfaceContainer)
                                        .cornerRadius(SleepyShapes.medium)
                                }
                                .buttonStyle(SleepyButtonStyle())
                                .accessibilityIdentifier("theme_mode_\(mode)")
                            }
                        }
                        .padding(3)
                        .background(colors.surfaceContainer)
                        .cornerRadius(SleepyShapes.medium)
                    }
                }
                .padding(16)
            }
        }
        .background(colors.background)
        // 自定义主题编辑器 ← Android 全屏 overlay;iOS 用 sheet 承载,
        // 这样编辑器内部的 .interactiveDismissDisabled(dirty) 才真正挡住下滑手势。
        .sheet(isPresented: $showEditor, onDismiss: { editingTheme = nil }) {
            CustomThemeEditorScreen(
                editing: editingTheme,
                nextThemeNumber: customThemes.count + 1,
                onBack: { showEditor = false },
                onSaved: saveTheme,
                onDeleted: deleteTheme
            )
            // sheet 内容不保证继承宿主 environment,显式把当前主题色带进去
            .environment(\.localWakeUpColors, colors)
        }
    }

    // ★ 选主题/模式后立即刷小组件(← WidgetUpdater.notifyDataChanged)
    private func refreshWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func selectThemeKey(_ key: String) {
        prefs.setThemeKey(key)
        currentKey = key
        onThemeKeyChange()
        refreshWidgets()
    }

    private func openEditor(_ theme: CustomTheme?) {
        editingTheme = theme
        showEditor = true
    }

    /// 编辑器保存 → 落库 + 重排网格;若改的正是当前应用主题,顺带刷小组件
    private func saveTheme(_ saved: CustomTheme) {
        CustomThemeStore.save(saved)
        customThemes = CustomThemeStore.getAll()
        showEditor = false
        editingTheme = nil
        if currentKey == ThemePresets.CUSTOM_KEY_PREFIX + saved.id {
            onThemeKeyChange()
            refreshWidgets()
        }
    }

    /// 编辑器删除 → 落库;删的正是当前应用主题则写回 default(与 unknown-key 回落语义一致)
    private func deleteTheme(_ id: String) {
        CustomThemeStore.delete(id)
        customThemes = CustomThemeStore.getAll()
        showEditor = false
        editingTheme = nil
        if currentKey == ThemePresets.CUSTOM_KEY_PREFIX + id {
            selectThemeKey(ThemePresets.KEY_DEFAULT)
        }
    }
}

// ← ThemeGridCell(预设卡 / 自定义卡 / 新建卡 混排单元)
enum ThemeGridCell: Identifiable {
    case preset(ThemePreset)
    case custom(CustomTheme)
    case newTheme

    var id: String {
        switch self {
        case .preset(let p): return "preset:" + p.key
        case .custom(let t): return "custom:" + t.id
        case .newTheme: return "new-theme"
        }
    }
}

/// 网格单元分发 — 三种卡都撑满半宽,保证同尺寸
private struct ThemeGridCellView: View {
    let cell: ThemeGridCell
    let currentKey: String
    let onSelect: (String) -> Void
    let onEdit: (CustomTheme?) -> Void

    var body: some View {
        switch cell {
        case .preset(let preset):
            PresetThemeCard(preset: preset, selected: currentKey == preset.key) {
                onSelect(preset.key)
            }
        case .custom(let theme):
            CustomThemeCard(theme: theme, selected: currentKey == ThemePresets.CUSTOM_KEY_PREFIX + theme.id) {
                onSelect(ThemePresets.CUSTOM_KEY_PREFIX + theme.id)
            } onEdit: {
                onEdit(theme)
            }
        case .newTheme:
            NewThemeEntry { onEdit(nil) }
        }
    }
}

// ← SystemThemeCard
private struct SystemThemeCard: View {
    @Environment(\.localWakeUpColors) private var colors
    let selected: Bool
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: 28))
                    .foregroundColor(colors.onPrimaryContainer)
                    .frame(width: 56, height: 56)
                    .background(colors.primaryContainer)
                    .cornerRadius(SleepyShapes.large)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.format("theme_system"))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(colors.onSurface)
                    Text(L10n.format("theme_system_desc"))
                        .font(.system(size: 12))
                        .foregroundColor(colors.onSurfaceVariant)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 24))
                        .foregroundColor(colors.primary)
                }
            }
            .padding(16)
            .background(selected ? colors.primaryContainer : colors.surfaceContainer)
            .cornerRadius(SleepyShapes.large)
        }
        .buttonStyle(SleepyButtonStyle())
        .accessibilityIdentifier("theme_system_card")
    }
}

// ← PresetThemeCard
private struct PresetThemeCard: View {
    @Environment(\.localWakeUpColors) private var colors
    let preset: ThemePreset
    let selected: Bool
    let onClick: () -> Void

    var body: some View {
        // 背景亮度决定展示 light 还是 dark 预览
        let scheme = CourseColorUtil.luminance(colors.background) < 0.5 ? preset.dark : preset.light
        Button(action: onClick) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ColorSwatch(color: scheme.primary)
                    ColorSwatch(color: scheme.secondary)
                    ColorSwatch(color: scheme.tertiary)
                }
                HStack {
                    Text(L10n.format(preset.nameKey))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colors.onSurface)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 20))
                            .foregroundColor(colors.primary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? colors.primaryContainer : colors.surfaceContainer)
            .cornerRadius(SleepyShapes.large)
        }
        .buttonStyle(SleepyButtonStyle())
        .accessibilityIdentifier("theme_preset_\(preset.key)")
    }
}

// ← ColorSwatch
private struct ColorSwatch: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: SleepyShapes.small)
            .fill(color)
            .frame(width: 28, height: 28)
    }
}

/// 自定义主题卡 — 与 PresetThemeCard 完全同构(三色板 + 名称 + 选中对勾,大小一模一样)。
/// edit 图标在色板行右端:色块包裹(可点性可见)+ 与 3 色块同行,不撑高卡片。
private struct CustomThemeCard: View {
    @Environment(\.localWakeUpColors) private var colors
    let theme: CustomTheme
    let selected: Bool
    let onClick: () -> Void
    let onEdit: () -> Void

    var body: some View {
        // 卡片色板预览按当前深浅模式派生(与 PresetThemeCard 的探针逻辑一致)
        let isDark = CourseColorUtil.luminance(colors.background) < 0.5
        let scheme = CustomSchemeDeriver.derive(theme: theme, isDark: isDark)
        Button(action: onClick) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ColorSwatch(color: scheme.primary)
                    ColorSwatch(color: scheme.secondary)
                    ColorSwatch(color: scheme.tertiary)
                    Spacer(minLength: 0)
                    // edit 色块:surfaceContainerHighest 与卡片底色拉开层级;24 嵌 28 行不撑高
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.system(size: 16))
                            .foregroundColor(colors.onSurfaceVariant)
                            .frame(width: 24, height: 24)
                            .background(colors.surfaceContainerHighest)
                            .cornerRadius(SleepyShapes.small)
                    }
                    .buttonStyle(SleepyButtonStyle())
                    .accessibilityIdentifier("theme_custom_edit_\(theme.id)")
                    .accessibilityLabel(L10n.format("theme_custom_edit"))
                }
                HStack {
                    Text(theme.name.isEmpty ? L10n.format("theme_new") : theme.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colors.onSurface)
                        .lineLimit(1)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 20))
                            .foregroundColor(colors.primary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? colors.primaryContainer : colors.surfaceContainer)
            .cornerRadius(SleepyShapes.large)
        }
        .buttonStyle(SleepyButtonStyle())
        .accessibilityIdentifier("theme_custom_\(theme.id)")
    }
}

/// 「新建主题」入口 — 裸虚线圆圈 + 加号,无卡片无背景无文字(2026-09-11 用户定稿)
private struct NewThemeEntry: View {
    @Environment(\.localWakeUpColors) private var colors
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            DashedCircleWithPlus(size: 40)
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .contentShape(Rectangle())
        }
        .buttonStyle(SleepyButtonStyle())
        .accessibilityIdentifier("theme_new_entry")
        .accessibilityLabel(L10n.format("theme_new"))
    }
}

/// 虚线圆圈 + 中心加号 — onSurface 描边自动适配深浅
private struct DashedCircleWithPlus: View {
    @Environment(\.localWakeUpColors) private var colors
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    colors.onSurface,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
            Image(systemName: "plus")
                .font(.system(size: size / 2))
                .foregroundColor(colors.onSurface)
        }
        .frame(width: size, height: size)
    }
}
