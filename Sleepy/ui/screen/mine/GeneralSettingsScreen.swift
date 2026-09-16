// GeneralSettingsScreen.swift — ← ui/screen/mine/GeneralSettingsScreen.kt
// 通用设置页(决策 D1 L1 ⑤): 课程显示 / 小组件 / 语言 三组。
// 显示项变更后即时刷新小组件;语言切换 → LocaleHelper.applyLanguage(无 Activity.recreate,
// 等价适配:iOS 由窗口重建语言环境)。
// 分组②③与各折叠卡抽为子视图 — SwiftUI ViewBuilder 单闭包 10 子视图上限。

import SwiftUI
import WidgetKit

struct GeneralSettingsScreen: View {
    @Environment(\.localWakeUpColors) private var colors
    // ★ v7.10.18 原生化: onBack → onDismiss(由 fullScreenCover / sheet 关闭)
    //   holiday 子页由本屏内 NavigationView + NavigationLink 承载, 不再走 AppRoot enum
    let onDismiss: () -> Void

    private let prefs = AppPrefs.shared

    @State private var expandedSections: Set<String> = []
    @State private var displayMode: String = AppPrefs.shared.getDisplayMode()
    @State private var gridSubInfo: String = AppPrefs.shared.getGridSubInfo()
    @State private var showDate: Bool = AppPrefs.shared.isShowDate()
    /// 启动默认视图 — ← AppPrefs.getStartView Android (默认 "full")。仅通用设置里设置,
    /// 手动切换课表顶部视图不写入(Android 注释硬规则, iOS 一致遵循)。
    @State private var startView: String = AppPrefs.shared.getStartView()
    @State private var visibleDays: Set<Int> = AppPrefs.shared.getVisibleDays()
    @State private var courseColorless: Bool = AppPrefs.shared.isCourseColorless()
    @State private var conflictStyle: String = AppPrefs.shared.getConflictStyle()
    @State private var conflictStackInset: Double = AppPrefs.shared.getConflictStackInset()
    @State private var conflictRailInset: Double = AppPrefs.shared.getConflictRailInset()
    @State private var conflictFoldSize: Double = AppPrefs.shared.getConflictFoldSize()
    // ★ issue#8 主页显示 pill 组(← Android GeneralSettingsScreen 189-330)
    @State private var weekUseAlias: Bool = AppPrefs.shared.isWeekUseAlias()
    @State private var gridUseAlias: Bool = AppPrefs.shared.isGridUseAlias()
    @State private var gridScale: Double = AppPrefs.shared.getGridScale()
    @State private var weekScale: Double = AppPrefs.shared.getWeekScale()
    @State private var gridCorner: Double = AppPrefs.shared.getGridCornerRatio()
    @State private var weekTwoColumn: Bool = AppPrefs.shared.isWeekTwoColumn()
    @State private var weekTwoColumnMode: String = AppPrefs.shared.getWeekTwoColumnMode()
    @State private var weekHideEmptyDays: Bool = AppPrefs.shared.isWeekHideEmptyDays()
    /// 底栏样式 — false=贴底(默认), true=悬浮药丸(与 Android v1.0.45 b0f8280 对齐)
    @State private var navFloating: Bool = AppPrefs.shared.isNavDocked()
    // ★ v7.10.18: HolidaySettings 在本屏内 sheet 弹出,无需走 root enum
    @State private var holidaySettingsItem: HolidaySettingsItem? = nil
    private struct HolidaySettingsItem: Identifiable { let id = UUID() }

    private func toggleSection(_ key: String) {
        if expandedSections.contains(key) { expandedSections.remove(key) }
        else { expandedSections.insert(key) }
    }

    // ★ 显示项变更后立即刷小组件
    private func refreshWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    var body: some View {
        // ★ v7.10.18 原生化: NavigationView 内嵌 + NavigationLink 跳 HolidaySettings
        //   - iOS 16+: NavigationLink 推入栈,免费 swipe-back 手势
        //   - iOS 15: NavigationView stack 风格 + NavigationLink 正常工作,带原生 back 按钮
        //   - 6sp 空白: NavigationView 在此内嵌(非 root),子屏 navbar 是合法 UX 预期
        NavigationView {
                VStack(spacing: 0) {
                    SettingsTopBar(title: L10n.format("mine_general"), onBack: onDismiss)
                    ScrollView {
                        VStack(spacing: 16) {
                            // ── 分组① 课程显示 — 嵌套 Group(单个 builder 上限 10 子视图);
                            //    卡片顺序对齐 Android LazyColumn: 别名→pill→冲突→显示星期→启动页→统一底色 ──
                            Group {
                                Group {
                                    SectionHeader(title: L10n.format("appearance_section_display"))

                                    displayModeCard
                                    gridSubInfoCard
                                    pillCard
                                    conflictStyleCard
                                    visibleDaysCard
                                    startViewCard
                                    courseColorlessCard
                                }
                                Group {
                                    holidayEntryCard
                                }
                            }

                            MajorDivider()

                            // ── 分组② 画面(底栏样式) — ← Android v1.0.45 b0f8280;
                            //    高刷新率行已删:iOS 无公开刷率 API,系统自动调度,纯对齐开关=无效 placebo ──
                            DisplaySection(
                                navFloating: $navFloating,
                                onNavFloatingChange: { on in
                                    navFloating = on
                                    prefs.setNavDocked(on)
                                    // 单源真值:AppRoot 监听 prefs 后即刻重渲底栏
                                })

                            MajorDivider()

                            // ── 分组③ 小组件 ──
                            WidgetSection(expandedSections: $expandedSections,
                                          refreshWidgets: refreshWidgets)

                            MajorDivider()

                            // ── 分组④ 语言 ──
                            LanguageSection()
                        }
                        .padding(16)
                    }
                }
                .background(colors.background)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
    }

    // 课程时间显示: 节次 / 时间 — ← Android SettingsFlatCard(标题行右侧 tab)
    private var displayModeCard: some View {
        SettingsFlatCard(
            title: L10n.format("settings_display_mode"),
            options: [
                L10n.format("settings_display_node"),
                L10n.format("settings_display_time")
            ],
            selectedIndex: Binding(
                get: { displayMode == "time" ? 1 : 0 },
                set: { idx in
                    let v = idx == 1 ? "time" : "node"
                    guard v != displayMode else { return }
                    displayMode = v
                    prefs.setDisplayMode(v)
                    refreshWidgets()
                }
            ),
            onSelect: { _ in }
        )
    }

    // 网格卡片副信息: 教室 / 教师 / 无 — ← Android SettingsFlatCard
    private var gridSubInfoCard: some View {
        SettingsFlatCard(
            title: L10n.format("settings_grid_sub_info"),
            options: [
                L10n.format("settings_grid_sub_room"),
                L10n.format("settings_grid_sub_teacher"),
                L10n.format("settings_grid_sub_none")
            ],
            selectedIndex: Binding(
                get: {
                    switch gridSubInfo {
                    case "room": return 0
                    case "teacher": return 1
                    default: return 2
                    }
                },
                set: { idx in
                    let v = ["room", "teacher", "none"][idx]
                    guard v != gridSubInfo else { return }
                    gridSubInfo = v
                    prefs.setGridSubInfo(v)
                    refreshWidgets()
                }
            ),
            onSelect: { _ in }
        )
    }

    // 显示星期: 周一~周日多选(至少留 1 天)
    private var visibleDaysCard: some View {
        SettingsCard(title: L10n.format("settings_visible_days"),
                     expanded: expandedSections.contains("visibleDays"),
                     onToggle: { toggleSection("visibleDays") }) {
            Text(L10n.format("settings_visible_days_sub"))
                .font(.system(size: 12))
                .foregroundColor(colors.onSurfaceVariant)
                .padding(.bottom, 8)
            ForEach(1...7, id: \.self) { day in
                VisibleDayRow(day: day, visibleDays: $visibleDays, onChange: { n in
                    visibleDays = n
                    prefs.setVisibleDays(n)
                    refreshWidgets()
                })
                if day != 7 { SubDivider() }
            }
        }
    }

    // 启动默认视图: 周视图 / 卡片视图 — ← Android SettingsFlatCard
    // 仅影响下次进入课表页,不刷新小组件。
    private var startViewCard: some View {
        SettingsFlatCard(
            title: L10n.format("settings_start_view"),
            options: [
                L10n.format("settings_start_view_full"),
                L10n.format("settings_start_view_cards")
            ],
            selectedIndex: Binding(
                get: { startView == "cards" ? 1 : 0 },
                set: { idx in
                    let v = idx == 1 ? "cards" : "full"
                    guard v != startView else { return }
                    startView = v
                    prefs.setStartView(v)
                }
            ),
            onSelect: { _ in }
        )
    }

    // 课程胶囊统一底色: 标题行开关 — ← Android flat title-plus-switch row
    private var courseColorlessCard: some View {
        HStack {
            Text(L10n.format("settings_course_colorless"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(colors.onSurface)
            Spacer()
            Toggle("", isOn: Binding(
                get: { courseColorless },
                set: {
                    courseColorless = $0
                    prefs.setCourseColorless($0)
                }
            ))
            .toggleStyle(.switch)
            .tint(colors.primary)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(colors.surfaceContainer)
        .cornerRadius(SleepyShapes.large)
        .accessibilityLabel(Text(L10n.format("settings_course_colorless")))
    }

    // 冲突课程样式: 叠层 / 折角 / 竖轨(仅 App 内网格视图, 不涉及小组件, 无需 refreshWidgets)
    // 拖杆条件显示: 折角幅度=仅 fold; 叠层偏移量=仅 stack; 右缘让宽=仅 rail(用户 2026-09-04 拆分)
    private var conflictStyleCard: some View {
        SettingsCard(title: L10n.format("settings_conflict_style"),
                     expanded: expandedSections.contains("conflictStyle"),
                     onToggle: { toggleSection("conflictStyle") }) {
            DisplayModeOption(label: L10n.format("settings_conflict_stack"),
                              subtitle: L10n.format("settings_conflict_stack_sub"),
                              selected: conflictStyle == "stack") {
                conflictStyle = "stack"
                prefs.setConflictStyle("stack")
            }
            SubDivider()
            DisplayModeOption(label: L10n.format("settings_conflict_fold"),
                              subtitle: L10n.format("settings_conflict_fold_sub"),
                              selected: conflictStyle == "fold") {
                conflictStyle = "fold"
                prefs.setConflictStyle("fold")
            }
            SubDivider()
            DisplayModeOption(label: L10n.format("settings_conflict_rail"),
                              subtitle: L10n.format("settings_conflict_rail_sub"),
                              selected: conflictStyle == "rail") {
                conflictStyle = "rail"
                prefs.setConflictStyle("rail")
            }
            if conflictStyle == "fold" {
                SubDivider()
                ConflictSliderRow(label: L10n.format("settings_conflict_fold_size"),
                                  value: $conflictFoldSize,
                                  range: AppPrefs.CONFLICT_FOLD_SIZE_RANGE) {
                    prefs.setConflictFoldSize(conflictFoldSize)
                }
            }
            if conflictStyle == "stack" {
                SubDivider()
                ConflictSliderRow(label: L10n.format("settings_conflict_stack_inset"),
                                  value: $conflictStackInset,
                                  range: AppPrefs.CONFLICT_TOP_INSET_RANGE) {
                    prefs.setConflictStackInset(conflictStackInset)
                }
            }
            if conflictStyle == "rail" {
                SubDivider()
                ConflictSliderRow(label: L10n.format("settings_conflict_rail_inset"),
                                  value: $conflictRailInset,
                                  range: AppPrefs.CONFLICT_TOP_INSET_RANGE) {
                    prefs.setConflictRailInset(conflictRailInset)
                }
            }
        }
    }

    // ★ issue#8 主页显示 pill 组: 网格/周视图缩放 + 圆角比例 + 周视图两栏 + 隐藏无课日
    // + issue#26 课程别名两开关(自独立卡挪入, 行为零变化)
    // (← Android SettingsCard "settings_pill"; 滑杆 5% 吸附, 拖完落盘)
    private var pillCard: some View {
        SettingsCard(title: L10n.format("settings_pill"),
                     expanded: expandedSections.contains("gridScale"),
                     onToggle: { toggleSection("gridScale") }) {
            // 内容 14 条 — 拆两 Group(ViewBuilder 10 项上限);行间距对齐 Android(标签 bottom 8/8/4)
            Group {
                PillSliderRow(label: L10n.format("settings_pill_scale"),
                              value: $gridScale, range: AppPrefs.GRID_SCALE_RANGE) {
                    prefs.setGridScale(gridScale)
                }
                SubDivider()
                PillSliderRow(label: L10n.format("settings_pill_week_scale"),
                              value: $weekScale, range: AppPrefs.GRID_SCALE_RANGE) {
                    prefs.setWeekScale(weekScale)
                }
                SubDivider()
                PillSliderRow(label: L10n.format("settings_pill_corner"),
                              value: $gridCorner, range: AppPrefs.CORNER_RATIO_RANGE,
                              labelSpacing: 4) {
                    prefs.setGridCornerRatio(gridCorner)
                }
                SubDivider()
                SettingToggleRow(label: L10n.format("settings_week_two_column"),
                                 subtitle: "",
                                 checked: weekTwoColumn) {
                    weekTwoColumn = $0
                    prefs.setWeekTwoColumn($0)
                }
                // 分栏标准 — 两栏开启时才需要选
                if weekTwoColumn {
                    SubDivider()
                    DisplayModeOption(label: L10n.format("settings_week_two_column_days"),
                                      subtitle: "",
                                      selected: weekTwoColumnMode == "days") {
                        weekTwoColumnMode = "days"
                        prefs.setWeekTwoColumnMode("days")
                    }
                    SubDivider()
                    DisplayModeOption(label: L10n.format("settings_week_two_column_balance"),
                                      subtitle: "",
                                      selected: weekTwoColumnMode == "balance") {
                        weekTwoColumnMode = "balance"
                        prefs.setWeekTwoColumnMode("balance")
                    }
                }
                // 隐藏无课日 — 与两栏无关, 单栏/两栏都生效(单栏按安卓语义不分栏不过滤)
                SubDivider()
                SettingToggleRow(label: L10n.format("settings_week_hide_empty"),
                                 subtitle: "",
                                 checked: weekHideEmptyDays) {
                    weekHideEmptyDays = $0
                    prefs.setWeekHideEmptyDays($0)
                }
            }
            Group {
                // issue#26 课程别名: 周视图/网格场景 原名/别名 二选一, 关=原名 开=别名(自独立卡挪入, 行为零变化)
                SubDivider()
                SettingToggleRow(label: L10n.format("settings_week_alias"),
                                 subtitle: "",
                                 checked: weekUseAlias) {
                    weekUseAlias = $0
                    prefs.setWeekUseAlias($0)
                }
                SubDivider()
                SettingToggleRow(label: L10n.format("settings_grid_alias"),
                                 subtitle: "",
                                 checked: gridUseAlias) {
                    gridUseAlias = $0
                    prefs.setGridUseAlias($0)
                }
            }
            SubDivider()
            // 课表显示日期 — Android 此开关位于 pill 卡末尾, 无副标题
            SettingToggleRow(label: L10n.format("settings_show_date"),
                             subtitle: "",
                             checked: showDate) {
                showDate = $0
                prefs.setShowDate($0)
                refreshWidgets()
            }
        }
    }

    // ← 节假日课程灰显: 点击进入二级页 — ← Android GeneralSettingsScreen.kt: titleSmall 单行, 无副标题
    private var holidayEntryCard: some View {
        Button { holidaySettingsItem = HolidaySettingsItem() } label: {
            HStack {
                Text(L10n.format("settings_holiday_title"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(colors.onSurface)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 20))
                    .foregroundColor(colors.onSurfaceVariant)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.surfaceContainer)
            .cornerRadius(SleepyShapes.large)
        }
        .buttonStyle(SleepyButtonStyle())
        .accessibilityIdentifier("settings_holiday_entry")
        .sheet(item: $holidaySettingsItem) { _ in
            HolidaySettingsScreen(onDismiss: { holidaySettingsItem = nil })
        }
    }
}

// issue#8 pill 拖杆行: 左侧百分比标签, 5% 吸附, 拖完落盘 — ← Android (it*20).roundToInt()/20f
private struct PillSliderRow: View {
    @Environment(\.localWakeUpColors) private var colors
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// 标签与滑杆间距 — Android 三行 label bottomPadding 8/8/4(圆角行为 4)
    var labelSpacing: CGFloat = 8
    let onFinished: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: labelSpacing) {
            Text(label)
                .font(.system(size: 16))
                .foregroundColor(colors.onSurface)
            HStack(spacing: 8) {
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 14, weight: .medium)) // ← Android labelLarge 14
                    .foregroundColor(colors.primary)
                    .frame(minWidth: 52, alignment: .leading)
                Slider(value: $value, in: range, step: 0.05) { _ in
                    onFinished()
                }
                .tint(colors.primary)
            }
        }
    }
}

// 冲突拖杆行: 左侧量值标签(dp), 右侧 Slider — ← Android Slider 拖完落盘
private struct ConflictSliderRow: View {
    @Environment(\.localWakeUpColors) private var colors
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onFinished: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 16))
                .foregroundColor(colors.onSurface)
            HStack(spacing: 8) {
                Text("\(Int(value.rounded()))dp")
                    .font(.system(size: 14, weight: .medium)) // ← Android labelLarge 14
                    .foregroundColor(colors.primary)
                    .frame(minWidth: 52, alignment: .leading)
                Slider(value: $value, in: range) { _ in
                    onFinished()
                }
                .tint(colors.primary)
            }
        }
    }
}

// 单行星期开关(抽行: 类型推断上限)
private struct VisibleDayRow: View {
    @Environment(\.localWakeUpColors) private var colors
    let day: Int
    @Binding var visibleDays: Set<Int>
    let onChange: (Set<Int>) -> Void

    var body: some View {
        let checked = visibleDays.contains(day)
        HStack {
            Text(DateUtils.localizedDay(day))
                .font(.system(size: 16))
                .foregroundColor(colors.onSurface)
            Spacer()
            Toggle("", isOn: Binding(
                get: { checked },
                set: { on in
                    let n = on ? visibleDays.union([day]) : visibleDays.subtracting([day])
                    guard !n.isEmpty else { return }
                    onChange(n)
                }
            ))
            .toggleStyle(.switch)
            .tint(colors.primary)
            .labelsHidden()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(DateUtils.localizedDay(day)))
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

// ← 分组② 小组件
private struct WidgetSection: View {
    @Environment(\.localWakeUpColors) private var colors
    @Binding var expandedSections: Set<String>
    let refreshWidgets: () -> Void

    // ← onOpenWidgetManagement: 跳二级页列出已放置的小组件
    @State private var showManage = false

    @State private var widgetColorless: Bool = AppPrefs.shared.isWidgetColorless()
    @State private var widgetSeparator: Bool = AppPrefs.shared.isWidgetSeparator()
    @State private var vertPunct: Bool = AppPrefs.shared.isVertPunctReplace()
    private let prefs = AppPrefs.shared

    private func toggleSection(_ key: String) {
        if expandedSections.contains(key) { expandedSections.remove(key) }
        else { expandedSections.insert(key) }
    }

    var body: some View {
        VStack(spacing: 16) {
            SectionHeader(title: L10n.format("appearance_section_widget"))
            SettingsCard(title: L10n.format("settings_widget"),
                         expanded: expandedSections.contains("widget"),
                         onToggle: { toggleSection("widget") }) {
                SettingToggleRow(label: L10n.format("settings_widget_colorless"),
                                 subtitle: L10n.format("settings_widget_colorless_sub"),
                                 checked: widgetColorless) {
                    widgetColorless = $0
                    prefs.setWidgetColorless($0)
                    refreshWidgets()
                }
                SubDivider()
                SettingToggleRow(label: L10n.format("settings_widget_separator"),
                                 subtitle: L10n.format("settings_widget_separator_sub"),
                                 checked: widgetSeparator) {
                    widgetSeparator = $0
                    prefs.setWidgetSeparator($0)
                    refreshWidgets()
                }
                SubDivider()
                SettingToggleRow(label: L10n.format("settings_vert_punct"),
                                 subtitle: L10n.format("settings_vert_punct_sub"),
                                 checked: vertPunct) {
                    vertPunct = $0
                    prefs.setVertPunctReplace($0)
                    refreshWidgets()
                }
            }

            // 管理桌面小组件: 跳二级页列出已放置的小组件(模板: 节假日课程灰显入口行)
            // ← GeneralSettingsScreen.kt item{ Row{...} }: titleSmall + ChevronRight 20dp
            Button { showManage = true } label: {
                HStack {
                    Text(L10n.format("widget_manage_entry"))
                        .font(.system(size: 14, weight: .medium)) // ← Android titleSmall 14sp Medium
                        .foregroundColor(colors.onSurface)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 20))
                        .foregroundColor(colors.onSurfaceVariant)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colors.surfaceContainer)
                .cornerRadius(SleepyShapes.large)
            }
            .buttonStyle(SleepyButtonStyle())
            .accessibilityIdentifier("settings_widget_manage_entry")
        }
        .fullScreenCover(isPresented: $showManage) {
            WidgetManagementScreen(onDismiss: { showManage = false })
        }
    }
}

// ← 分组③ 语言
private struct LanguageSection: View {
    @Environment(\.localWakeUpColors) private var colors
    @State private var language: String = AppPrefs.shared.getLanguage()

    private let languages: [(String, String)] = [
        ("zh-CN", "简体中文"),
        ("zh-TW", "繁體中文"),
        ("en", "English"),
        ("ja", "日本語"),
        ("es", "Español")
    ]

    var body: some View {
        VStack(spacing: 16) {
            SectionHeader(title: L10n.format("settings_language"))
            VStack(spacing: 4) {
                ForEach(languages, id: \.0) { code, label in
                    let selected = language == code
                    Button {
                        language = code
                        AppPrefs.shared.setLanguage(code)
                        // Activity.recreate() → applyLanguage(重设 bundle + AppleLanguages)
                        LocaleHelper.applyLanguage(code)
                    } label: {
                        HStack {
                            Text(label)
                                .font(.system(size: 16))
                                .foregroundColor(selected ? colors.primary : colors.onSurface)
                            Spacer()
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 20))
                                    .foregroundColor(colors.primary)
                            }
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 4)
                    }
                    .buttonStyle(SleepyButtonStyle())
                    if code != languages.last!.0 { SubDivider() }
                }
            }
            .padding(16)
            .background(colors.surfaceContainer)
            .cornerRadius(SleepyShapes.large)
        }
    }
}

// ── 分组② 画面: 底栏样式 ──
private struct DisplaySection: View {
    @Environment(\.localWakeUpColors) private var colors
    @Binding var navFloating: Bool
    let onNavFloatingChange: (Bool) -> Void

    var body: some View {
        VStack(spacing: 16) {
            SectionHeader(title: L10n.format("settings_section_display"))
            // ← Android SettingsFlatCard(padding h16/v14, Column spacedBy(4), 标题 titleSmall 14sp SemiBold)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.format("settings_nav_style"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(colors.onSurface)
                Picker("", selection: Binding(
                    get: { navFloating },
                    set: { onNavFloatingChange($0) }
                )) {
                    // 标签顺序: 贴底(默认) → 悬浮;Picker 用 Bool tag 配 (false, true)
                    // (← Android GeneralSettingsScreen.kt selectedKey = if (navDock) 1 else 0:
                    //  选项索引 0=docked, 1=floating;navDock=true 即悬浮药丸)
                    Text(L10n.format("settings_nav_style_docked")).tag(false)
                    Text(L10n.format("settings_nav_style_floating")).tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings_nav_style")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.surfaceContainer)
            .cornerRadius(SleepyShapes.large)
        }
    }
}

// 分隔线(卡内细线 / 组间粗线 — ← HorizontalDivider outlineVariant@hairline)
private struct SubDivider: View {
    @Environment(\.localWakeUpColors) private var colors
    var body: some View {
        Rectangle()
            .fill(colors.outlineVariant.opacity(SleepyTheme.Alpha.hairline))
            .frame(height: 1)
    }
}

private struct MajorDivider: View {
    @Environment(\.localWakeUpColors) private var colors
    var body: some View {
        Rectangle()
            .fill(colors.outlineVariant.opacity(SleepyTheme.Alpha.hairline))
            .frame(height: 1)
    }
}
