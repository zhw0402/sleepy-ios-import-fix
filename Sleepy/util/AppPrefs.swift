// AppPrefs.swift — ← AppPrefs.kt
// Android: SharedPreferences + callbackFlow → iOS: UserDefaults + Combine CurrentValueSubject
// 进程内 @Published 同步给 UI,磁盘做持久化(与 Kotlin object 单例语义一致)。

import Foundation
import Combine
import WidgetKit

/// App 级别轻量设置 — 避免引入额外依赖。
final class AppPrefs {
    static let shared = AppPrefs()

    static let FILE = "sleepy_prefs"
    static let KEY_DARK = "dark_mode"
    static let KEY_REMINDER = "reminder_master"      // master toggle (default false)
    static let KEY_DAILY_ENABLED = "daily_reminder"   // daily sub-toggle (default true)
    static let KEY_DAILY_TIME = "daily_reminder_time" // "HH:mm" default "07:00"
    static let KEY_BEFORE_CLASS_ENABLED = "before_class_enabled"       // bool default false
    static let KEY_BEFORE_CLASS_MINUTES = "before_class_minutes"       // int default 10
    static let KEY_BEFORE_CLASS_BANNER = "before_class_banner"         // bool default true
    static let KEY_BEFORE_CLASS_FLUID = "before_class_fluid"            // bool default false
    static let KEY_BEFORE_CLASS_FLUID_FIELDS = "before_class_fluid_fields" // legacy multi-select
    static let KEY_BEFORE_CLASS_FLUID_PRIMARY = "before_class_fluid_primary" // name/time/room
    static let KEY_THEME = "theme_key"
    static let KEY_LANG = "language"
    static let KEY_DISPLAY_MODE = "display_mode" // "node" or "time"
    static let KEY_START_VIEW = "start_view" // "full" / "cards" — ← AppPrefs.KEY_START_VIEW Android; 启动默认视图（仅通用设置里设置；手动切换课表顶部视图不写入）
    static let KEY_GRID_SUB_INFO = "grid_sub_info" // "room" / "teacher" / "none" — 网格卡片副信息(周视图网格卡课程名下方那行;左栏已有节次,故此处不再显示节次/时间)
    static let KEY_CONFLICT_STYLE = "conflict_style" // "stack"/"fold"/"rail" — 冲突课程显示样式,默认 "rail"(← KEY_CONFLICT_STYLE v7.10.16s)
    static let KEY_CONFLICT_TOP_INSET = "conflict_top_inset" // Double dp — 旧共用收窄量 key: 仅作拆分迁移源,停写(用户 2026-09-04 拆分)
    static let KEY_CONFLICT_STACK_INSET = "conflict_stack_inset" // Double dp — 叠层偏移量(STACK 专有, 用户 2026-09-04 拆分: 两样式独立配置不共享)
    static let KEY_CONFLICT_RAIL_INSET = "conflict_rail_inset"   // Double dp — 右缘让宽(RAIL 专有, 同上)
    static let KEY_CONFLICT_FOLD_SIZE = "conflict_fold_size" // Double dp — 折角幅度(fold 样式): 折痕直角边长, 视觉符号与命中区共用; 默认 16dp
    static let KEY_CONFLICT_DEFAULT_TOP = "conflict_default_top" // JSON {"day:startNode:step": layerRepId} — 冲突簇默认置顶图层
    static let KEY_SHOW_DATE = "show_date"       // boolean
    static let KEY_VISIBLE_DAYS = "visible_days" // "1,2,3,4,5,6,7"
    static let KEY_VERT_PUNCT_REPLACE = "vert_punct_replace" // bool default false (方案B开关)
    static let KEY_WIDGET_COLORLESS = "widget_colorless" // bool default false
    static let KEY_COURSE_COLORLESS = "course_colorless" // bool default false (App 课程胶囊专用)
    static let KEY_WIDGET_SEPARATOR = "widget_separator" // bool default true (WeekView 纯文字课程间分隔线)
    static let KEY_HOLIDAY_GREY_HOLIDAY = "holiday_grey_holiday" // bool default true
    static let KEY_HOLIDAY_GREY_WEEKEND = "holiday_grey_weekend" // bool default true
    static let KEY_HOLIDAY_STYLE = "holiday_style"          // "grey" / "strikethrough" default "grey"
    static let KEY_HOLIDAY_IGNORE_WORKDAY = "holiday_ignore_workday" // bool default true
    static let KEY_HOLIDAY_OVERRIDES = "holiday_overrides"  // JSON, HolidayRangeOps 编解码
    static let KEY_THEME_MODE = "theme_mode"  // light/dark/system
    static let THEME_MODE_LIGHT = "light"
    static let THEME_MODE_DARK = "dark"
    static let THEME_MODE_SYSTEM = "system"
    // ★ v1.0.45 画面分组: 底栏样式(默认贴底 ← Android b0f8280)
    // (KEY_HIGH_REFRESH 已随 no-op 桩删除 — iOS 无公开刷率 API,2026-09-10 原生化审计)
    static let KEY_NAV_DOCK = "nav_dock"              // bool default false (false=贴底, true=悬浮药丸 ← Android b0f8280)
    // ★ issue#8 主页显示 pill 组: 网格/周视图缩放 + 圆角比例 + 周视图两栏 (← Android AppPrefs.kt 65-72)
    static let KEY_GRID_SCALE = "grid_scale"          // Float 0.7~1.3 default 1.0 — 网格整体缩放(字号/行高/间距/圆角联动)
    static let KEY_WEEK_SCALE = "week_scale"          // Float 0.7~1.3 default 1.0 — 周视图整体缩放
    static let KEY_GRID_CORNER_RATIO = "grid_corner_ratio" // Float 0.0~2.0 default 1.0 — 圆角比例(乘基准圆角)
    static let KEY_WEEK_TWO_COLUMN = "week_two_column" // bool default false — 周视图两栏
    static let KEY_WEEK_TWO_COLUMN_MODE = "week_two_column_mode" // "days"/"balance" default "days"
    static let KEY_WEEK_HIDE_EMPTY_DAYS = "week_hide_empty_days" // bool default false — 隐藏无课日
    static let KEY_WEEK_USE_ALIAS = "week_use_alias"  // bool default false — 周视图显示别名 (issue#26)
    static let KEY_GRID_USE_ALIAS = "grid_use_alias"  // bool default false — 网格视图显示别名 (issue#26)
    static let KEY_WIDGET_USE_ALIAS = "widget_use_alias"  // bool default false — widget 场景显示别名 (issue#26, 全局一档)
    static let GRID_SCALE_RANGE: ClosedRange<Double> = 0.7...1.3
    static let CORNER_RATIO_RANGE: ClosedRange<Double> = 0.0...2.0

    /// 主题色 key 的进程内 Flow — ← themeKeyFlow(callbackFlow+distinctUntilChanged)
    /// 订阅即收当前值,变更推送新值,去重。
    private let themeKeySubject = CurrentValueSubject<String, Never>(ThemePresets.KEY_DEFAULT)
    lazy private(set) var themeKeyPublisher: AnyPublisher<String, Never> = themeKeySubject.eraseToAnyPublisher()

    /// 单测注入用:默认 UserDefaults.standard。测试用 suiteName 隔离。
    private let d: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.d = defaults
    }

    private func sp() -> UserDefaults { d }

    /// HolidayManager 磁盘缓存与业务 prefs 共用同一存储(← PREFS_NAME 同文件语义)
    var sharedBackedStore: UserDefaults { d }

    /// 实际是否深色:dark→true, light→false, system→isSystemDark。isSystemDark 由调用方传入。 ← isDarkMode
    func isDarkMode(isSystemDark: Bool = false) -> Bool {
        // 向后兼容:旧 boolean KEY_DARK 在无新三态时生效
        if sp().object(forKey: Self.KEY_THEME_MODE) == nil {
            if let legacy = sp().object(forKey: Self.KEY_DARK) as? Bool {
                return legacy
            }
        }
        switch getThemeMode() {
        case Self.THEME_MODE_DARK: return true
        case Self.THEME_MODE_LIGHT: return false
        default: return isSystemDark
        }
    }

    /// 主题模式:light / dark / system。默认 system。 ← getThemeMode/setThemeMode
    func getThemeMode() -> String {
        sp().string(forKey: Self.KEY_THEME_MODE) ?? Self.THEME_MODE_SYSTEM
    }

    func setThemeMode(_ mode: String) {
        precondition(mode == Self.THEME_MODE_LIGHT || mode == Self.THEME_MODE_DARK || mode == Self.THEME_MODE_SYSTEM)
        sp().set(mode, forKey: Self.KEY_THEME_MODE)
    }

    // ===== 画面 =====

    /// 底栏样式 — false=贴底(默认), true=悬浮药丸(← Android v1.0.45 AppPrefs.KEY_NAV_DOCK 一字对齐)。
    /// API 名沿用 isNavDocked()/setNavDocked(_:) 以保留调用方,但语义已校正:
    /// 传入 true 意味着"是悬浮药丸"(写入 KEY_NAV_DOCK=true),返回 true 同义。
    /// 关键修复(2026-09-08): 早期实现方向反转 → 新装用户看不到悬浮形态。
    func isNavDocked() -> Bool {
        // 反向兼容: 旧版本以「false=悬浮」存值。新版本「true=悬浮」,
        // 因此首读时一旦读到旧值 false 还要再判一次是否从未写入过。
        guard sp().object(forKey: Self.KEY_NAV_DOCK) != nil else { return false }
        return sp().bool(forKey: Self.KEY_NAV_DOCK)
    }

    func setNavDocked(_ floating: Bool) {
        sp().set(floating, forKey: Self.KEY_NAV_DOCK)
    }

    // ===== 主题色 =====

    func getThemeKey() -> String {
        sp().string(forKey: Self.KEY_THEME) ?? ThemePresets.KEY_DEFAULT
    }

    func setThemeKey(_ key: String) {
        sp().set(key, forKey: Self.KEY_THEME)
        themeKeySubject.send(key)
    }

    // ===== 提醒 =====

    /// Master toggle — default false
    func isReminderEnabled() -> Bool { sp().bool(forKey: Self.KEY_REMINDER) }
    func setReminderEnabled(_ v: Bool) { sp().set(v, forKey: Self.KEY_REMINDER) }

    /// Daily reminder sub-toggle — default true (only active when master on)
    func isDailyReminderEnabled() -> Bool {
        sp().object(forKey: Self.KEY_DAILY_ENABLED) as? Bool ?? true
    }
    func setDailyReminderEnabled(_ v: Bool) { sp().set(v, forKey: Self.KEY_DAILY_ENABLED) }

    /// Daily reminder time "HH:mm" — default "07:00"
    func getDailyReminderTime() -> String { sp().string(forKey: Self.KEY_DAILY_TIME) ?? "07:00" }
    func setDailyReminderTime(_ time: String) { sp().set(time, forKey: Self.KEY_DAILY_TIME) }

    /// Before-class reminder sub-toggle — default false
    func isBeforeClassEnabled() -> Bool { sp().bool(forKey: Self.KEY_BEFORE_CLASS_ENABLED) }
    func setBeforeClassEnabled(_ v: Bool) { sp().set(v, forKey: Self.KEY_BEFORE_CLASS_ENABLED) }

    /// Minutes before class to notify — default 10
    func getBeforeClassMinutes() -> Int {
        sp().object(forKey: Self.KEY_BEFORE_CLASS_MINUTES) as? Int ?? 10
    }
    func setBeforeClassMinutes(_ minutes: Int) { sp().set(minutes, forKey: Self.KEY_BEFORE_CLASS_MINUTES) }

    func isBeforeClassBannerEnabled() -> Bool {
        sp().object(forKey: Self.KEY_BEFORE_CLASS_BANNER) as? Bool ?? true
    }
    func setBeforeClassBannerEnabled(_ v: Bool) { sp().set(v, forKey: Self.KEY_BEFORE_CLASS_BANNER) }

    func isBeforeClassFluidEnabled() -> Bool { sp().bool(forKey: Self.KEY_BEFORE_CLASS_FLUID) }
    func setBeforeClassFluidEnabled(_ v: Bool) { sp().set(v, forKey: Self.KEY_BEFORE_CLASS_FLUID) }

    /// legacy multi-select 读取(死写路径已删 — setBeforeClassFluidFields 全库零调用,读取仅通知组件用旧数据)
    func getBeforeClassFluidFields() -> Set<String> {
        let raw = sp().string(forKey: Self.KEY_BEFORE_CLASS_FLUID_FIELDS) ?? "name,time,room,teacher"
        return Set(raw.split(separator: ",").filter { !$0.isEmpty }.map(String.init))
    }

    func getBeforeClassFluidPrimary() -> String {
        sp().string(forKey: Self.KEY_BEFORE_CLASS_FLUID_PRIMARY) ?? "room"
    }

    func setBeforeClassFluidPrimary(_ value: String) {
        precondition(value == "name" || value == "time" || value == "room")
        // ★ 只写 PRIMARY;不再覆盖 FIELDS(多选字段集),否则用户配置的多字段组合被冲掉。
        sp().set(value, forKey: Self.KEY_BEFORE_CLASS_FLUID_PRIMARY)
    }

    // ===== 语言 =====

    /// 首启无保存值 → 从 AppleLanguages 推断(等价 Android 首启跟随系统;
    /// 用户在 App 内切过语言后 KEY_LANG 固定, AppPrefs 为唯一事实来源 ← wrapDefault)。
    /// 读 UserDefaults "AppleLanguages"(launch args/系统设置同源), 非 Locale.preferredLanguages。
    func getLanguage() -> String {
        if let saved = sp().string(forKey: Self.KEY_LANG) { return saved }
        let preferred = sp().stringArray(forKey: "AppleLanguages")?.first
            ?? Locale.preferredLanguages.first ?? "zh-CN"
        if preferred.hasPrefix("zh") {
            return preferred.contains("Hant") || preferred.contains("TW")
                || preferred.contains("HK") || preferred.contains("MO") ? "zh-TW" : "zh-CN"
        }
        if preferred.hasPrefix("en") { return "en" }
        if preferred.hasPrefix("ja") { return "ja" }
        if preferred.hasPrefix("es") { return "es" }
        return "zh-CN"
    }
    func setLanguage(_ lang: String) { sp().set(lang, forKey: Self.KEY_LANG) }

    // ===== 显示模式:节次 / 时间 =====

    func getDisplayMode() -> String { sp().string(forKey: Self.KEY_DISPLAY_MODE) ?? "node" }
    func setDisplayMode(_ mode: String) { sp().set(mode, forKey: Self.KEY_DISPLAY_MODE) }

    /// 启动默认视图 — ← AppPrefs.getStartView Android (默认 "full")。仅通用设置里设置,
    /// 手动切换课表顶部视图不写入(Android 注释硬规则, iOS 一致遵循)。
    func getStartView() -> String { sp().string(forKey: Self.KEY_START_VIEW) ?? "full" }
    func setStartView(_ mode: String) {
        precondition(mode == "full" || mode == "cards")
        sp().set(mode, forKey: Self.KEY_START_VIEW)
    }

    // ===== 网格卡片副信息:教室 / 教师 / 无 =====

    func getGridSubInfo() -> String { sp().string(forKey: Self.KEY_GRID_SUB_INFO) ?? "room" }

    func setGridSubInfo(_ value: String) {
        precondition(value == "room" || value == "teacher" || value == "none")
        sp().set(value, forKey: Self.KEY_GRID_SUB_INFO)
    }

    // ===== 冲突课程显示样式：叠层 / 折角 / 竖轨(← v7.10.16s) =====

    /// 滑杆量程/默认值(← CONFLICT_TOP_INSET_RANGE / CONFLICT_FOLD_SIZE_RANGE)
    static let CONFLICT_TOP_INSET_RANGE: ClosedRange<Double> = 4...20
    static let CONFLICT_TOP_INSET_DEFAULT: Double = 7
    static let CONFLICT_FOLD_SIZE_RANGE: ClosedRange<Double> = 8...28
    static let CONFLICT_FOLD_SIZE_DEFAULT: Double = 16

    func getConflictStyle() -> String { sp().string(forKey: Self.KEY_CONFLICT_STYLE) ?? "rail" }

    func setConflictStyle(_ value: String) {
        precondition(value == "stack" || value == "fold" || value == "rail")
        sp().set(value, forKey: Self.KEY_CONFLICT_STYLE)
    }

    // ===== 冲突顶卡收窄量(用户 2026-09-04 拆分: 叠层/竖轨独立配置不共享) =====
    // 首次读取时从旧共用 key 迁移一次(旧值复制到两新 key), 旧 key 停写保留仅作迁移源。

    func getConflictStackInset() -> Double {
        if sp().object(forKey: Self.KEY_CONFLICT_STACK_INSET) == nil {
            sp().set(sp().double(forKey: Self.KEY_CONFLICT_TOP_INSET) == 0
                ? Self.CONFLICT_TOP_INSET_DEFAULT
                : sp().double(forKey: Self.KEY_CONFLICT_TOP_INSET),
                forKey: Self.KEY_CONFLICT_STACK_INSET)
        }
        let v = sp().double(forKey: Self.KEY_CONFLICT_STACK_INSET)
        return v == 0 ? Self.CONFLICT_TOP_INSET_DEFAULT : v
    }

    func setConflictStackInset(_ value: Double) {
        precondition(Self.CONFLICT_TOP_INSET_RANGE.contains(value))
        sp().set(value, forKey: Self.KEY_CONFLICT_STACK_INSET)
    }

    func getConflictRailInset() -> Double {
        if sp().object(forKey: Self.KEY_CONFLICT_RAIL_INSET) == nil {
            sp().set(sp().double(forKey: Self.KEY_CONFLICT_TOP_INSET) == 0
                ? Self.CONFLICT_TOP_INSET_DEFAULT
                : sp().double(forKey: Self.KEY_CONFLICT_TOP_INSET),
                forKey: Self.KEY_CONFLICT_RAIL_INSET)
        }
        let v = sp().double(forKey: Self.KEY_CONFLICT_RAIL_INSET)
        return v == 0 ? Self.CONFLICT_TOP_INSET_DEFAULT : v
    }

    func setConflictRailInset(_ value: Double) {
        precondition(Self.CONFLICT_TOP_INSET_RANGE.contains(value))
        sp().set(value, forKey: Self.KEY_CONFLICT_RAIL_INSET)
    }

    // ===== 冲突折角幅度(fold 样式专有) — 折痕直角边长,视觉/命中区同一真值 =====

    func getConflictFoldSize() -> Double {
        let v = sp().double(forKey: Self.KEY_CONFLICT_FOLD_SIZE)
        return v == 0 ? Self.CONFLICT_FOLD_SIZE_DEFAULT : v
    }

    func setConflictFoldSize(_ value: Double) {
        precondition(Self.CONFLICT_FOLD_SIZE_RANGE.contains(value))
        sp().set(value, forKey: Self.KEY_CONFLICT_FOLD_SIZE)
    }

    // ===== issue#8 主页显示 pill 组(← Android AppPrefs.kt get/set + changeBus) =====
    // iOS 无 changeBus:渲染层在 body 内直读(靠设置页关闭触发父级重建重算),与冲突滑杆同模式。

    func getGridScale() -> Double {
        let v = sp().double(forKey: Self.KEY_GRID_SCALE)
        return v == 0 ? 1.0 : v
    }

    func setGridScale(_ value: Double) {
        precondition(Self.GRID_SCALE_RANGE.contains(value))
        sp().set(value, forKey: Self.KEY_GRID_SCALE)
    }

    func getWeekScale() -> Double {
        let v = sp().double(forKey: Self.KEY_WEEK_SCALE)
        return v == 0 ? 1.0 : v
    }

    func setWeekScale(_ value: Double) {
        precondition(Self.GRID_SCALE_RANGE.contains(value))
        sp().set(value, forKey: Self.KEY_WEEK_SCALE)
    }

    func getGridCornerRatio() -> Double {
        let v = sp().double(forKey: Self.KEY_GRID_CORNER_RATIO)
        return v == 0 ? 1.0 : v
    }

    func setGridCornerRatio(_ value: Double) {
        precondition(Self.CORNER_RATIO_RANGE.contains(value))
        sp().set(value, forKey: Self.KEY_GRID_CORNER_RATIO)
    }

    func isWeekTwoColumn() -> Bool { sp().bool(forKey: Self.KEY_WEEK_TWO_COLUMN) }
    func setWeekTwoColumn(_ v: Bool) { sp().set(v, forKey: Self.KEY_WEEK_TWO_COLUMN) }

    func getWeekTwoColumnMode() -> String {
        sp().string(forKey: Self.KEY_WEEK_TWO_COLUMN_MODE) ?? "days"
    }
    func setWeekTwoColumnMode(_ v: String) { sp().set(v, forKey: Self.KEY_WEEK_TWO_COLUMN_MODE) }

    func isWeekHideEmptyDays() -> Bool { sp().bool(forKey: Self.KEY_WEEK_HIDE_EMPTY_DAYS) }
    func setWeekHideEmptyDays(_ v: Bool) { sp().set(v, forKey: Self.KEY_WEEK_HIDE_EMPTY_DAYS) }

    func isWeekUseAlias() -> Bool { sp().bool(forKey: Self.KEY_WEEK_USE_ALIAS) }
    func setWeekUseAlias(_ v: Bool) { sp().set(v, forKey: Self.KEY_WEEK_USE_ALIAS) }

    func isGridUseAlias() -> Bool { sp().bool(forKey: Self.KEY_GRID_USE_ALIAS) }
    func setGridUseAlias(_ v: Bool) { sp().set(v, forKey: Self.KEY_GRID_USE_ALIAS) }

    // issue#26: widget 场景 课程名显示 原名/别名 — 全局一档(所有小组件共享, 渲染器无
    // widgetId, 与 colorless/separator 同先例)。写入后全量刷 timeline
    // (← Android WidgetUpdater.notifyDataChanged, 桌面即时重绘)。
    func isWidgetUseAlias() -> Bool { sp().bool(forKey: Self.KEY_WIDGET_USE_ALIAS) }
    func setWidgetUseAlias(_ v: Bool) {
        sp().set(v, forKey: Self.KEY_WIDGET_USE_ALIAS)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // ===== 冲突簇默认置顶图层 =====
    // JSON Map<clusterKey, layerRepId>;内存真相源(@Published)保瞬时更新 —
    // 点击 → set 同帧刷 UI(用户 2026-09-02:「勾选的那一瞬间课表就应该完成置顶更新」),
    // UserDefaults 落盘异步不驱动 UI(← StateFlow 瞬时通道, v7.10.2)。

    /// 冲突默认置顶内存真相源(实例级 — AppPrefs 单例,与 Kotlin object 对齐)
    private let conflictDefaultTopSubject = ConflictDefaultTopStore.shared

    func getConflictDefaultTop() -> [String: Int64] {
        conflictDefaultTopSubject.map
    }

    func setConflictDefaultTop(_ map: [String: Int64]) {
        conflictDefaultTopSubject.map = map
        // ← encodeDefaultTopMap: JSONEncoder 过 Dictionary[String: Int64]
        if let data = try? JSONEncoder().encode(map) {
            sp().set(data, forKey: Self.KEY_CONFLICT_DEFAULT_TOP)
        } else {
            sp().removeObject(forKey: Self.KEY_CONFLICT_DEFAULT_TOP)
        }
    }

    /// 修改单个 clusterKey;传 nil = 删除该键(回退系统默认)。
    func putConflictDefaultTop(_ clusterKey: String, _ layerRepId: Int64?) {
        var current = getConflictDefaultTop()
        if let id = layerRepId { current[clusterKey] = id } else { current.removeValue(forKey: clusterKey) }
        setConflictDefaultTop(current)
    }

    /// 冷启动加载磁盘值进内存真相源 — 幂等(磁盘值与内存一致时不发射)。
    func primeConflictDefaultTop() {
        guard let data = sp().data(forKey: Self.KEY_CONFLICT_DEFAULT_TOP),
              let disk = try? JSONDecoder().decode([String: Int64].self, from: data) else { return }
        conflictDefaultTopSubject.prime(disk)
    }

    /// SwiftUI 订阅入口(GridConflictLayer @ObservedObject 用)
    static var sharedConflictDefaultTopStore: ConflictDefaultTopStore { ConflictDefaultTopStore.shared }

    // ===== 网格显示日期 =====

    func isShowDate() -> Bool { sp().bool(forKey: Self.KEY_SHOW_DATE) }
    func setShowDate(_ v: Bool) { sp().set(v, forKey: Self.KEY_SHOW_DATE) }

    // ===== 可见天 =====

    func getVisibleDays() -> Set<Int> {
        let raw = sp().string(forKey: Self.KEY_VISIBLE_DAYS) ?? "1,2,3,4,5,6,7"
        // ← mapNotNull { it.trim().toIntOrNull() }:非数字段丢弃
        return Set(raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }

    func setVisibleDays(_ days: Set<Int>) {
        let joined = days.sorted().map(String.init).joined(separator: ",")
        sp().set(joined, forKey: Self.KEY_VISIBLE_DAYS)
    }

    // ===== 竖排标点优化(方案B: 标点替换为 Unicode Vertical Forms) — 默认 false =====

    func isVertPunctReplace() -> Bool { sp().bool(forKey: Self.KEY_VERT_PUNCT_REPLACE) }
    func setVertPunctReplace(_ v: Bool) { sp().set(v, forKey: Self.KEY_VERT_PUNCT_REPLACE) }

    // ===== 小组件无色模式 — 默认 false =====

    func isWidgetColorless() -> Bool { sp().bool(forKey: Self.KEY_WIDGET_COLORLESS) }
    func setWidgetColorless(_ v: Bool) { sp().set(v, forKey: Self.KEY_WIDGET_COLORLESS) }

    // ===== App 课程胶囊无色模式 — 默认 false =====

    func isCourseColorless() -> Bool { sp().bool(forKey: Self.KEY_COURSE_COLORLESS) }
    func setCourseColorless(_ v: Bool) { sp().set(v, forKey: Self.KEY_COURSE_COLORLESS) }

    // ===== WeekView 纯文字组件:课程间分隔线 — 默认 true =====

    func isWidgetSeparator() -> Bool {
        sp().object(forKey: Self.KEY_WIDGET_SEPARATOR) as? Bool ?? true
    }
    func setWidgetSeparator(_ v: Bool) { sp().set(v, forKey: Self.KEY_WIDGET_SEPARATOR) }

    // ===== 节假日灰显 =====

    /// 法定节假日灰显开关 — 默认 true ← isHolidayGreyHoliday
    func isHolidayGreyHoliday() -> Bool {
        sp().object(forKey: Self.KEY_HOLIDAY_GREY_HOLIDAY) as? Bool ?? true
    }
    func setHolidayGreyHoliday(_ v: Bool) { sp().set(v, forKey: Self.KEY_HOLIDAY_GREY_HOLIDAY) }

    /// 周末灰显开关 — 默认 true ← isHolidayGreyWeekend
    func isHolidayGreyWeekend() -> Bool {
        sp().object(forKey: Self.KEY_HOLIDAY_GREY_WEEKEND) as? Bool ?? true
    }
    func setHolidayGreyWeekend(_ v: Bool) { sp().set(v, forKey: Self.KEY_HOLIDAY_GREY_WEEKEND) }

    /// 灰显样式 — 默认 "grey" ← getHolidayStyle/setHolidayStyle
    func getHolidayStyle() -> String {
        sp().string(forKey: Self.KEY_HOLIDAY_STYLE) ?? "grey"
    }
    func setHolidayStyle(_ style: String) {
        precondition(style == "grey" || style == "strikethrough")
        sp().set(style, forKey: Self.KEY_HOLIDAY_STYLE)
    }

    /// 忽略补班日 — 默认 true ← isHolidayIgnoreWorkday
    func isHolidayIgnoreWorkday() -> Bool {
        sp().object(forKey: Self.KEY_HOLIDAY_IGNORE_WORKDAY) as? Bool ?? true
    }
    func setHolidayIgnoreWorkday(_ v: Bool) { sp().set(v, forKey: Self.KEY_HOLIDAY_IGNORE_WORKDAY) }

    /// 用户范围化覆盖段: 编辑/新增/删除节日段 ← getHolidayRanges/setHolidayRanges
    func getHolidayRanges() -> [HolidayRange] {
        HolidayRangeOps.decodeOverrides(sp().string(forKey: Self.KEY_HOLIDAY_OVERRIDES) ?? "[]")
    }
    func setHolidayRanges(_ ranges: [HolidayRange]) {
        sp().set(HolidayRangeOps.encodeOverrides(ranges), forKey: Self.KEY_HOLIDAY_OVERRIDES)
    }
}

/// 冲突默认置顶内存真相源(← MutableStateFlow) — @Published 供 SwiftUI 同帧刷 UI
final class ConflictDefaultTopStore: ObservableObject {
    static let shared = ConflictDefaultTopStore()
    @Published var map: [String: Int64] = [:]

    /// 幂等加载: 磁盘值与内存一致时不发射
    func prime(_ disk: [String: Int64]) {
        if map != disk { map = disk }
    }
}
