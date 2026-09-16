// HolidaySettingsScreen.swift — ← ui/screen/mine/HolidaySettingsScreen.kt
// 节假日与补班日设置页: 年份切换 / 数据源卡片(加载·失败·重试·刷新) /
// 三个灰显开关 / 灰显样式 chips / 节假日·补班日段列表(可编辑) / 已删除区(可恢复) / 添加自定义日期。
// 网络段+用户覆盖段合并逻辑在 HolidayRangeOps(纯函数, ← HolidayRange.kt)。

import SwiftUI

private enum HolidayUiState {
    case loading
    case failed
    case empty
    case loaded([HolidayEntry])
}

/// 弹窗编辑目标: isNew=true 添加模式; 网络段派生目标会预填 sourceKey ← EditingTarget
private struct EditingTarget: Identifiable {
    let range: HolidayRange
    let isNew: Bool
    var id: String { (isNew ? "new:" : "edit:") + range.id }
}

private let MIN_YEAR = 2005
private let MAX_YEAR = 2049

struct HolidaySettingsScreen: View {
    @Environment(\.localWakeUpColors) private var colors
    let onDismiss: () -> Void

    private let prefs = AppPrefs.shared

    @State private var year: Int = Calendar.gregorianCST.component(.year, from: Date())
    @State private var holidayGrey: Bool = AppPrefs.shared.isHolidayGreyHoliday()
    @State private var weekendGrey: Bool = AppPrefs.shared.isHolidayGreyWeekend()
    @State private var ignoreWorkday: Bool = AppPrefs.shared.isHolidayIgnoreWorkday()
    @State private var style: String = AppPrefs.shared.getHolidayStyle()
    @State private var state: HolidayUiState = .loading
    @State private var overrides: [HolidayRange] = AppPrefs.shared.getHolidayRanges()
    @State private var editing: EditingTarget? = nil
    @State private var loadTask: Task<Void, Never>? = nil

    private func reload() { overrides = prefs.getHolidayRanges() }

    /// 保存(新增或替换同 id)一段覆盖 ← saveRange
    private func saveRange(_ range: HolidayRange) {
        var next = overrides.filter { $0.id != range.id }
        next.append(range)
        prefs.setHolidayRanges(next)
        reload()
    }

    /**
     * 删除一段: 段 id 在 overrides 里 → 直接移除;
     * 是网络段(聚合生成、无对应覆盖) → 写 type=REMOVED + sourceKey 的覆盖挂接该网络段。← deleteRange
     */
    private func deleteRange(_ range: HolidayRange) {
        let known = overrides.contains { $0.id == range.id }
        var next = overrides.filter { $0.id != range.id }
        if !known {
            next.append(HolidayRange(
                id: HolidayRangeOps.newId(), name: range.name,
                startDate: range.startDate, endDate: range.endDate,
                type: HolidayRangeOps.REMOVED,
                sourceKey: networkKeyOf(range.type, range.startDate)
            ))
        }
        prefs.setHolidayRanges(next)
        reload()
    }

    /// 恢复默认: 移除该 id 的覆盖(含 REMOVED 型), 网络段随之回来 ← restoreRange
    private func restoreRange(_ range: HolidayRange) {
        prefs.setHolidayRanges(overrides.filter { $0.id != range.id })
        reload()
    }

    private func load(_ targetYear: Int, force: Bool = false) {
        loadTask?.cancel()
        loadTask = Task {
            state = .loading
            let entries: [HolidayEntry]
            if force {
                entries = await HolidayManager.refreshYearEntries(targetYear)
            } else {
                entries = await HolidayManager.getYearEntries(targetYear)
            }
            if Task.isCancelled { return }
            await MainActor.run {
                overrides = prefs.getHolidayRanges()
                if entries.isEmpty && HolidayManager.isYearFetchFailed(targetYear) {
                    state = .failed
                } else {
                    state = .loaded(entries)
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTopBar(title: L10n.format("holiday_page_title"), onBack: onDismiss)
            ScrollView {
                VStack(spacing: 16) {
                    yearSwitcher
                    dataSourceCard
                    togglesCard
                    styleCard

                    if case .loaded(let entries) = state {
                        segmentSections(entries)
                    }
                }
                .padding(16)
            }
        }
        .background(colors.background)
        .onAppear { load(year) }
        .onChange(of: year) { y in load(y) }
        .sheet(item: $editing) { t in
            HolidayRangeEditDialog(
                target: t.range,
                isNew: t.isNew,
                onDismiss: { editing = nil },
                onSave: { range in
                    saveRange(range)
                    editing = nil
                },
                onDelete: { range in
                    deleteRange(range)
                    editing = nil
                }
            )
            .sheetDetents([.medium, .large])
        }
    }

    // ← 年份切换行(ChevronLeft / 年份 / ChevronRight)
    private var yearSwitcher: some View {
        HStack {
            Button {
                if year > MIN_YEAR { year -= 1 }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(year > MIN_YEAR ? colors.onSurface : colors.onSurfaceVariant.opacity(0.4))
            }
            .buttonStyle(SleepyButtonStyle())
            .accessibilityLabel(L10n.format("holiday_year_prev"))
            .disabled(year <= MIN_YEAR)

            Spacer()
            Text(String(year))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(colors.onSurface)
            Spacer()

            Button {
                if year < MAX_YEAR { year += 1 }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(year < MAX_YEAR ? colors.onSurface : colors.onSurfaceVariant.opacity(0.4))
            }
            .buttonStyle(SleepyButtonStyle())
            .accessibilityLabel(L10n.format("holiday_year_next"))
            .disabled(year >= MAX_YEAR)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(colors.surfaceContainer)
        .cornerRadius(SleepyShapes.large)
    }

    // ← 数据源卡(用户 2026-09-04): 标题+URL 同行, 刷新=图标(语言无关, 不随文案伸缩)。
    //   Loading 态图标位转圈占位(行高稳定); Failed/Empty 提示行单独挂卡底(信息行不可省)。
    private var dataSourceCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(L10n.format("holiday_data_source"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(colors.onSurface)
                Text(L10n.format("holiday_source_label"))
                    .font(.system(size: 12))
                    .foregroundColor(colors.onSurfaceVariant)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if case .loading = state {
                    // 图标位转圈占位 — 行高稳定
                    ProgressView()
                        .tint(colors.primary)
                        .controlSize(.small)
                        .frame(width: 36, height: 36)
                } else {
                    // 刷新=图标(与 Android Icons.Outlined.Refresh 同位): failed/empty/loaded 均可点
                    Button {
                        load(year, force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 20))
                            .foregroundColor(colors.onSurfaceVariant)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(SleepyButtonStyle())
                    .accessibilityIdentifier("holiday_refresh")
                    .accessibilityLabel(L10n.format("holiday_data_refresh"))
                }
            }
            if case .failed = state {
                Text(L10n.format("holiday_data_failed"))
                    .font(.system(size: 12))
                    .foregroundColor(colors.error)
                    .padding(.bottom, 6)
            } else if case .empty = state {
                Text(L10n.format("holiday_data_empty"))
                    .font(.system(size: 12))
                    .foregroundColor(colors.onSurfaceVariant)
                    .padding(.bottom, 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.surfaceContainer)
        .cornerRadius(SleepyShapes.large)
    }

    // ← 三个灰显开关卡
    private var togglesCard: some View {
        VStack(spacing: 4) {
            SettingToggleRow(
                label: L10n.format("settings_holiday_holiday"),
                subtitle: L10n.format("settings_holiday_holiday_sub"),
                checked: holidayGrey
            ) {
                holidayGrey = $0
                prefs.setHolidayGreyHoliday($0)
            }
            divider
            SettingToggleRow(
                label: L10n.format("settings_holiday_weekend"),
                subtitle: L10n.format("settings_holiday_weekend_sub"),
                checked: weekendGrey
            ) {
                weekendGrey = $0
                prefs.setHolidayGreyWeekend($0)
            }
            divider
            SettingToggleRow(
                label: L10n.format("settings_holiday_workday"),
                subtitle: L10n.format("settings_holiday_workday_sub"),
                checked: ignoreWorkday
            ) {
                ignoreWorkday = $0
                prefs.setHolidayIgnoreWorkday($0)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(colors.surfaceContainer)
        .cornerRadius(SleepyShapes.large)
    }

    // ← 灰显样式卡: 标题行右贴 segmented tabs — 与通用设置页各平铺卡同款(用户 2026-09-04)
    private var styleCard: some View {
        SettingsFlatCard(
            title: L10n.format("settings_holiday_style"),
            options: [
                L10n.format("settings_holiday_style_grey"),
                L10n.format("settings_holiday_style_strikethrough")
            ],
            selectedIndex: Binding(
                get: { style == "strikethrough" ? 1 : 0 },
                set: { idx in
                    let next = idx == 1 ? "strikethrough" : "grey"
                    guard next != style else { return }
                    style = next
                    prefs.setHolidayStyle(next)
                }
            ),
            onSelect: { _ in }
        )
    }

    /// 覆盖变化时基于原始网络数据即时重合并, 不重新走网络 ← Loaded 分支
    @ViewBuilder
    private func segmentSections(_ entries: [HolidayEntry]) -> some View {
        let merged = HolidayRangeOps.mergeSegments(entries, overrides)
        let userRangeIds = Set(overrides.map { $0.id })
        let holidaySegments = merged.active.filter { $0.type == HolidayManager.TYPE_PUBLIC_HOLIDAY }
        let workdaySegments = merged.active.filter { $0.type == HolidayManager.TYPE_TRANSFER_WORKDAY }

        if !holidaySegments.isEmpty {
            SectionHeader(title: L10n.format("holiday_list_holidays"))
            HolidayRangeListCard(
                segments: holidaySegments,
                userRangeIds: userRangeIds,
                onEdit: { editing = resolveEditTarget($0, userRangeIds) }
            )
        }
        if !workdaySegments.isEmpty {
            SectionHeader(title: L10n.format("holiday_list_workdays"))
            HolidayRangeListCard(
                segments: workdaySegments,
                userRangeIds: userRangeIds,
                showWorkdayBadge: true,
                onEdit: { editing = resolveEditTarget($0, userRangeIds) }
            )
        }
        if !merged.removed.isEmpty {
            SectionHeader(title: L10n.format("holiday_removed_section"))
            HolidayRemovedCard(segments: merged.removed, onRestore: restoreRange)
        }

        Button {
            editing = EditingTarget(
                range: HolidayRange(
                    id: HolidayRangeOps.newId(),
                    name: "",
                    startDate: dateOf(year, 1, 1),
                    endDate: dateOf(year, 1, 1),
                    type: HolidayManager.TYPE_PUBLIC_HOLIDAY,
                    sourceKey: nil
                ),
                isNew: true
            )
        } label: {
            Text(L10n.format("holiday_add_entry"))
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(colors.onSecondaryContainer)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(colors.secondaryContainer)
                .cornerRadius(SleepyShapes.large)
        }
        .buttonStyle(SleepyButtonStyle())
        .accessibilityIdentifier("holiday_add_entry")
    }

    private var divider: some View {
        Rectangle()
            .fill(colors.outlineVariant.opacity(SleepyTheme.Alpha.hairline))
            .frame(height: 1)
    }
}

/// 网络段键: "holiday:<start>"/"workday:<start>", 与 HolidayRangeOps.mergeSegments 的命中规则一致
/// ← networkKeyOf
private func networkKeyOf(_ type: String, _ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "Asia/Shanghai")
    return "\(type == HolidayManager.TYPE_TRANSFER_WORKDAY ? "workday" : "holiday"):\(f.string(from: date))"
}

/// 行点击 → 弹窗编辑目标。网络段(聚合生成的 id 不在 overrides 里)复制一份并
/// 立即补上 sourceKey, 保存/删除时即按该键整段挂接替换/删除, 不产生重复行。← resolveEditTarget
private func resolveEditTarget(_ segment: HolidayRange, _ userRangeIds: Set<String>) -> EditingTarget {
    if userRangeIds.contains(segment.id) {
        return EditingTarget(range: segment, isNew: false)
    }
    return EditingTarget(
        range: HolidayRange(
            id: segment.id, name: segment.name,
            startDate: segment.startDate, endDate: segment.endDate,
            type: segment.type,
            sourceKey: networkKeyOf(segment.type, segment.startDate)
        ),
        isNew: false
    )
}

/// 段日期展示: 单日 M/d, 跨日 M/d – M/d ← segmentDateLabel
private func segmentDateLabel(_ seg: HolidayRange) -> String {
    if seg.startDate == seg.endDate {
        return DateUtils.shortDateSlash(seg.startDate)
    }
    return "\(DateUtils.shortDateSlash(seg.startDate)) – \(DateUtils.shortDateSlash(seg.endDate))"
}

private func dateOf(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d; c.hour = 12
    c.timeZone = TimeZone(identifier: "Asia/Shanghai")
    return Calendar(identifier: .gregorian).date(from: c) ?? Date()
}

// ← HolidayRangeListCard: 名称 + 自定义 badge(若是用户段) + 补班 badge(可选) + 起止日期; 行点击进入编辑
private struct HolidayRangeListCard: View {
    @Environment(\.localWakeUpColors) private var colors
    let segments: [HolidayRange]
    let userRangeIds: Set<String>
    var showWorkdayBadge: Bool = false
    let onEdit: (HolidayRange) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                Button {
                    onEdit(segment)
                } label: {
                    HStack(spacing: 0) {
                        Text(segment.name.isBlank ? DateUtils.shortDateSlash(segment.startDate) : segment.name)
                            .font(.system(size: 16))
                            .foregroundColor(colors.onSurface)
                        Spacer()
                        if userRangeIds.contains(segment.id) {
                            Text(L10n.format("holiday_custom_badge"))
                                .font(.system(size: 11, weight: .medium)) // ← Android labelSmall 11sp Medium
                                .foregroundColor(colors.onSurfaceVariant)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(colors.onSurfaceVariant.opacity(SleepyTheme.Alpha.tinted))
                                .cornerRadius(SleepyShapes.small)
                            Spacer().frame(width: 12)
                        }
                        if showWorkdayBadge {
                            Text(L10n.format("holiday_workday_badge"))
                                .font(.system(size: 11, weight: .medium)) // ← Android labelSmall 11sp Medium
                                .foregroundColor(colors.primary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(colors.primary.opacity(SleepyTheme.Alpha.tinted))
                                .cornerRadius(SleepyShapes.small)
                            Spacer().frame(width: 12)
                        }
                        Text(segmentDateLabel(segment))
                            .font(.system(size: 14))
                            .foregroundColor(colors.onSurfaceVariant)
                    }
                    .padding(.vertical, 10)
                }
                .buttonStyle(SleepyButtonStyle())
                // ← Android HorizontalDivider: outlineVariant @ hairline
                if index != segments.count - 1 {
                    Rectangle()
                        .fill(colors.outlineVariant.opacity(SleepyTheme.Alpha.hairline))
                        .frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(colors.surfaceContainer)
        .cornerRadius(SleepyShapes.large)
    }
}

// ← HolidayRemovedCard: 被用户删除的网络段, 行尾"恢复"移除覆盖使网络段回来
private struct HolidayRemovedCard: View {
    @Environment(\.localWakeUpColors) private var colors
    let segments: [HolidayRange]
    let onRestore: (HolidayRange) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                HStack {
                    Text(segment.name.isBlank ? DateUtils.shortDateSlash(segment.startDate) : segment.name)
                        .font(.system(size: 16))
                        .foregroundColor(colors.onSurfaceVariant)
                    Spacer()
                    Text(segmentDateLabel(segment))
                        .font(.system(size: 14))
                        .foregroundColor(colors.onSurfaceVariant)
                    Spacer().frame(width: 12)
                    // 恢复用 secondaryContainer 色块 — 与删除/刷新同风格, 禁悬空文字按钮
                    Button {
                        onRestore(segment)
                    } label: {
                        Text(L10n.format("holiday_restore"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(colors.onSecondaryContainer)
                            .padding(.horizontal, 14)
                            .frame(height: 48)
                            .background(colors.secondaryContainer)
                            .cornerRadius(SleepyShapes.large)
                    }
                    .buttonStyle(SleepyButtonStyle())
                }
                .padding(.vertical, 6)
                // ← Android HorizontalDivider: outlineVariant @ hairline
                if index != segments.count - 1 {
                    Rectangle()
                        .fill(colors.outlineVariant.opacity(SleepyTheme.Alpha.hairline))
                        .frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(colors.surfaceContainer)
        .cornerRadius(SleepyShapes.large)
    }
}

/**
 * 编辑/添加弹窗(起止日期范围段) ← HolidayRangeEditDialog。
 * target 为网络段时, 保存时补 sourceKey="holiday|workday:<首日>" 挂接替换该网络段。
 * 校验: start <= end, 否则禁用保存并提示 holiday_date_invalid。
 *
 * iOS 原生化:
 *   - 起止日期 → native DatePicker(.compact) 双字段, 点击展开滚轮
 *   - 名称 → TextField (SwiftUI 已是原生, 不变)
 *   - 类型 → Picker(.segmented) 二选一
 *   - 删除/取消/保存 → 自制色块按钮(与全 app 统一)
 */
private struct HolidayRangeEditDialog: View {
    @Environment(\.localWakeUpColors) private var colors
    let target: HolidayRange
    let isNew: Bool
    let onDismiss: () -> Void
    let onSave: (HolidayRange) -> Void
    let onDelete: (HolidayRange) -> Void

    @State private var name: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var type: String

    init(target: HolidayRange, isNew: Bool,
         onDismiss: @escaping () -> Void,
         onSave: @escaping (HolidayRange) -> Void,
         onDelete: @escaping (HolidayRange) -> Void) {
        self.target = target
        self.isNew = isNew
        self.onDismiss = onDismiss
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: target.name)
        _startDate = State(initialValue: target.startDate)
        _endDate = State(initialValue: target.endDate)
        _type = State(initialValue: target.type)
    }

    private var datesValid: Bool { endDate >= startDate }

    var body: some View {
        // ← Android AlertDialog text Column spacedBy(12)
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.format(isNew ? "holiday_add_title" : "holiday_edit_title"))
                .font(.system(size: 24)) // ← Android AlertDialog headlineSmall 24
                .foregroundColor(colors.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)

            // ← native iOS DatePicker(.compact): 点击展开滚轮, 系统级体验
            //   手动 HStack 替代 LabeledContent (iOS 16+), 保持 iOS 15.6 兼容
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L10n.format("holiday_name_label_date"))
                        .font(.system(size: 14))
                        .foregroundColor(colors.onSurfaceVariant)
                    Spacer()
                    DatePicker("", selection: $startDate, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }
                HStack {
                    Text(L10n.format("holiday_name_label_end"))
                        .font(.system(size: 14))
                        .foregroundColor(colors.onSurfaceVariant)
                    Spacer()
                    DatePicker("", selection: $endDate, in: startDate..., displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }
            }
            .padding(.vertical, 4)

            if !datesValid {
                Text(L10n.format("holiday_date_invalid"))
                    .font(.system(size: 12))
                    .foregroundColor(colors.error)
            }

            TextField(L10n.format("holiday_name_label"), text: $name)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(colors.surfaceContainer)
                .cornerRadius(SleepyTheme.fieldShape)

            // ← SegmentedSwitcher 全宽(与设置页 Tab 同款, 替代散排 chip) — Android 1.0.51
            SegmentedSwitcher(
                options: [(0, L10n.format("holiday_type_holiday")),
                          (1, L10n.format("holiday_type_workday"))],
                selected: type == HolidayManager.TYPE_PUBLIC_HOLIDAY ? 0 : 1,
                onSelect: { idx in
                    type = idx == 0 ? HolidayManager.TYPE_PUBLIC_HOLIDAY
                                    : HolidayManager.TYPE_TRANSFER_WORKDAY
                }
            )

            if !isNew {
                // 删除走 errorContainer 色块 — 纯色块禁描边规则。
                Button {
                    onDelete(target)
                } label: {
                    Text(L10n.format("holiday_delete_range"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colors.onErrorContainer)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(colors.errorContainer)
                        .cornerRadius(SleepyShapes.large)
                }
                .buttonStyle(SleepyButtonStyle())
            }

            HStack(spacing: 8) {
                Button(action: onDismiss) {
                    Text(L10n.format("cancel"))
                        .font(.system(size: 14, weight: .medium)) // ← Android TextButton labelLarge 14sp Medium
                        .foregroundColor(colors.onSurfaceVariant)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
                .buttonStyle(SleepyButtonStyle())
                Button {
                    onSave(HolidayRange(id: target.id,
                                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                        startDate: startDate, endDate: endDate,
                                        type: type, sourceKey: target.sourceKey))
                } label: {
                    Text(L10n.format("save"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(datesValid ? colors.onPrimary : colors.onPrimary.opacity(0.4))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(datesValid ? colors.primary : colors.primary.opacity(0.3))
                        .cornerRadius(SleepyShapes.medium)
                }
                .buttonStyle(SleepyButtonStyle())
                .disabled(!datesValid)
            }
        }
        .padding(20)
    }
}
