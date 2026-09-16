// WeekViewWidgetView.swift — ← WeekViewWidget.kt + WidgetBitmapRenderers.renderWeekView
// 本周课表(周视图) widget — 复刻 DaySummaryCell (CourseTableView.kt L559-L642)。
// 列卡片同 WeekList;课程列表: 纯文本无胶囊背景, take(5), onSurfaceVariant 色,
// today 列 onPrimaryContainer@0.82alpha, 课程间分隔线(可选开关)。

import SwiftUI
import WidgetKit

struct WeekViewWidgetEntry: TimelineEntry {
    let date: Date
    let data: WeekData
}

struct WeekViewWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WeekViewWidgetEntry {
        WidgetArchiveLog.append(kind: "WeekViewWidgetRV", family: context.family.description, result: "success")
        return WeekViewWidgetEntry(date: Date(), data: WeekListWidgetLoader.loadDataSync(kind: "WeekViewWidgetRV"))
    }

    func getSnapshot(in context: Context, completion: @escaping (WeekViewWidgetEntry) -> Void) {
        WidgetArchiveLog.append(kind: "WeekViewWidgetRV", family: context.family.description, result: "success")
        completion(WeekViewWidgetEntry(date: Date(), data: WeekListWidgetLoader.loadDataSync(kind: "WeekViewWidgetRV")))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WeekViewWidgetEntry>) -> Void) {
        let entry = WeekViewWidgetEntry(date: Date(), data: WeekListWidgetLoader.loadDataSync(kind: "WeekViewWidgetRV"))
        let refresh = Date().addingTimeInterval(6 * 3600)
        WidgetArchiveLog.append(kind: "WeekViewWidgetRV", family: context.family.description, result: "success")
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }
}

// MARK: - View ← renderWeekView

struct WeekViewWidgetEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.colorScheme) private var widgetColorScheme
    let entry: WeekViewWidgetEntry

    var body: some View {
        let data = entry.data
        let isDark = effectiveWidgetIsDark(themeMode: data.themeMode, snapshotIsDark: data.isDark, envScheme: widgetColorScheme)
        let s = resolveWidgetScheme(themeKey: data.themeKey, isDark: isDark)
        let showSeparator = AppPrefs.shared.isWidgetSeparator()
        let todayDow = DateUtils.todayDayOfWeek(today: Date())
        // SMALL 紧凑档 ← renderWeekViewCompact: 复用 Regular 渲染器, 数据侧换列(列少每列自然变宽)
        let days = widgetFamily == .systemSmall
            ? Self.compactDays(data: data, todayDow: todayDow)
            : shownDays(data)
        // issue#26: widget 全局一档别名开关
        let useAlias = AppPrefs.shared.isWidgetUseAlias()

        Group {
            if !data.hasTable || days.isEmpty {
                Text(L10n.format("widget_create_schedule"))
                    .font(.system(size: 15))
                    .foregroundColor(s.onSurface)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(spacing: 0) {
                    // ★ 学期外: 顶部全宽状态行(只画一次, 同 renderWeekList)
                    if data.semesterStatus != .inRange {
                        Text(data.semesterStatus == .beforeStart
                             ? L10n.format("semester_not_started")
                             : L10n.format("semester_ended"))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(s.onSurfaceVariant)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 4)
                    }
                    HStack(alignment: .top, spacing: 4) {
                        ForEach(days, id: \.dayOfWeek) { day in
                            WeekViewDayColumn(day: day, scheme: s, isToday: day.dayOfWeek == todayDow,
                                              showSeparator: showSeparator, useAlias: useAlias)
                        }
                    }
                }
            }
        }
        .padding(6)
        .background(s.bg)
        .widgetURL(URL(string: "sleepy://open"))
    }
}

private struct WeekViewDayColumn: View {
    let day: DayData
    let scheme: WidgetScheme
    let isToday: Bool
    let showSeparator: Bool
    /// issue#26: widget 场景别名 — 课名展示名
    let useAlias: Bool

    var body: some View {
        let s = scheme
        VStack(alignment: .center, spacing: 0) {
            // 星期标题
            Text(weekDayLabels[day.dayOfWeek])
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(isToday ? s.onPrimaryContainer : s.onSurface)
                .padding(.top, 1)   // 安卓标题基线 colTop+12 (字形顶≈+4)
                .padding(.bottom, 11) // chip 顶 colTop+26

            if !day.courses.isEmpty {
                // 课程数量 chip
                Text("\(day.courses.count) 门")
                    .font(.system(size: 9))
                    .foregroundColor(s.onSurfaceVariant)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(s.surfaceVariant)
                    .cornerRadius(50)
                    .padding(.bottom, 4)  // 4dp gap (DaySummaryCell L624)

                // 课程 mini-list — 最多2行换行 + 课程间分隔线(可选), take(5)
                VStack(spacing: 3) {  // 3dp (原2dp太紧, 对齐胶囊版)
                    ForEach(Array(day.courses.prefix(5).enumerated()), id: \.element.id) { idx, course in
                        // today → onPrimaryContainer@0.82alpha, 其他 → onSurfaceVariant
                        Text(CourseDisplayUtil.displayName(course, useAlias))
                            .font(.system(size: 9))
                            .foregroundColor(isToday
                                ? s.onPrimaryContainer.opacity(0.82)
                                : s.onSurfaceVariant)
                            .multilineTextAlignment(.leading) // 安卓 Paint 默认 LEFT, 画在 x+textPad
                            .lineLimit(2)   // wrapMax2Lines → 最多2行,超出截断 (安卓只截断不缩字)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4) // textPad 4dp
                        // 课程间分隔: 开关ON→1dp@40%线; OFF→纯3dp留白(由 VStack spacing 提供)
                        if showSeparator && idx < min(day.courses.count, 5) - 1 {
                            Rectangle()
                                .fill(s.onSurfaceVariant.opacity(0.4))
                                .frame(height: 1)
                                .padding(.horizontal, 4)
                                .padding(.vertical, -1.5) // 安卓: 间距 courseGap/2(1.5) + 线1 + 1.5
                        }
                    }
                }
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(isToday ? s.primaryContainer : s.surfaceContainer)
        .cornerRadius(14)
    }
}

struct WeekViewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WeekViewWidgetRV", provider: WeekViewWidgetProvider()) { entry in
            WeekViewWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(L10n.format("widget_week_view_label"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// ← weekViewCompactColumns: SMALL 紧凑档选列(纯函数)。
// 池 = 有课日(空则全周), 今天不在池必补入; 按 |dow−today| 排序取 maxColumns, 输出升序。
// tie-break 按池内原序(Kotlin sortedBy 稳定排序语义)。
extension WeekViewWidgetEntryView {
    static func weekViewCompactColumns(days: [DayData], todayDow: Int, maxColumns: Int = 3) -> [Int] {
        var pool = days.filter { !$0.courses.isEmpty }.map { $0.dayOfWeek }
        if pool.isEmpty { pool = days.map { $0.dayOfWeek } }
        if !pool.contains(todayDow) { pool.append(todayDow) }
        let ranked = pool.enumerated().sorted { a, b in
            let da = abs(a.element - todayDow), db = abs(b.element - todayDow)
            return da != db ? da < db : a.offset < b.offset
        }
        return ranked.prefix(maxColumns).map { $0.element }.sorted()
    }

    // ← renderWeekViewCompact 数据侧换列: 先按 visibleDays 收窄可选池(空集回退全周防御), 再选 compact 列
    static func compactDays(data: WeekData, todayDow: Int) -> [DayData] {
        let compactDows = weekViewCompactColumns(days: shownDays(data), todayDow: todayDow)
        return data.days
            .filter { compactDows.contains($0.dayOfWeek) }
            .sorted { $0.dayOfWeek < $1.dayOfWeek }
    }
}
