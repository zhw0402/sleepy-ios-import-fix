// AddCourseScreen.swift — ← ui/screen/edit/AddCourseScreen.kt (1857 行, 逐段翻译, GPL-3.0)
// 新建/编辑课程: 基本信息(名/别名 issue#26)+周次范围+多时段 block(标准节次 / 非常规节次 issue#23 /
// 非常规时间覆盖 + 时长反推)+校验(空名/天数/正数/时间格式/时段重叠)+保存(编辑=行级 diff, 新建=共享
// groupId)+删除组。HSV 调色盘(SV 面板+色相条)。边缘槽位暂存串接(pendingEdgeInserts/Edits)。

import SwiftUI

enum MeetingInputMode: Hashable { case byNode, byClock }

// ← MeetingBlockDraft(SnapshotStateList → @Published 手动管理)
struct MeetingBlockDraft: Identifiable {
    let id: Int
    var days: Set<Int>
    var mode: MeetingInputMode
    var startNode: Int
    var step: Int
    var startTime: String
    var endTime: String
    var startWeek: Int
    var endWeek: Int
    var weekType: Int
    /// issue#22: 老师/地点/备注/颜色下沉到每时段独立编辑 — 同名同周次不同地点不再相互覆盖
    var room: String = ""
    var teacher: String = ""
    var note: String = ""
    var color: String = ""
    var colorMode: Int = CourseColorMode.GROUP
    /// issue#23 逐卡: 绑定边缘槽位 (0/-1/N+1…); true 时位置=selectedEdgeNode, step 锁 1
    var isIrregularNode: Bool = false
    var selectedEdgeNode: Int = 0
    /// issue#23 逐卡: 本卡覆盖起止时间 (与落库 ownTime 同值, §5 契约); 旧 ByClock 并入此开关
    var isIrregularTime: Bool = false
    /// issue#23 §2.4 B 规则: 持续时长(分钟)文本 — 改起止重算, 改时长反推结束
    var durationText: String = ""
    var clamped: Bool = false

    /// §3.3 契约: 本卡生效起止 = 覆盖值 / 槽位默认 / 标准节次时间, 单一出口
    func effectiveRange(timeJson: String) -> (String, String)? {
        TimeTableUtils.effectiveCourseTime(
            isIrregularTime: isIrregularTime,
            startTime: startTime,
            endTime: endTime,
            startNode: isIrregularNode ? selectedEdgeNode : startNode,
            step: isIrregularNode ? 1 : step,
            timeJson: timeJson)
    }
}

/// issue#23 逐卡: 「新建槽位」暂存 — 保存课程成功后串接写回课表 timeJson
struct PendingEdgeInsert {
    let edgeClass: TimeTableUtils.EdgeClass
    let node: Int
    let start: String
    let end: String
    let ownerBlockId: Int
}

/// issue#23 逐卡: 已有槽位默认时间编辑暂存
struct EdgeSlotEdit {
    let node: Int
    let start: String
    let end: String
}

/// issue#23 逐卡: 「新建槽位」确认弹层的目标 — 哪张卡片选择了哪个候选
struct NewSlotTarget: Identifiable {
    let id = UUID()
    let blockIndex: Int
    let candidate: TimeTableUtils.EdgeCandidate
}

/// issue#23 逐卡: 已有槽位默认时间编辑弹层的目标
struct SlotEditTarget: Identifiable {
    let id = UUID()
    let node: Int
    let start: String
    let end: String
}

struct ValidationIssue {
    let blockId: Int?
    let message: String
}

struct AddCourseScreen: View {
    @Environment(\.localWakeUpColors) private var colors
    @ObservedObject var viewModel: ScheduleViewModel
    let onDismiss: () -> Void
    let onSaved: () -> Void
    var editingCourse: CourseEntity? = nil

    @State private var loadedForId: Int64 = -1
    @State private var courseName = ""
    /// issue#26: 课程别名(可选) — 空串 = 处处显示原名; 组级属性, 编辑页保存时整组覆盖
    @State private var courseAlias = ""
    @State private var startWeek = 1
    @State private var endWeek = 16
    @State private var nextBlockId = 2
    @State private var validationIssues: [ValidationIssue] = []
    @State private var meetingBlocks: [MeetingBlockDraft] = []
    @State private var showDeleteConfirm = false
    // 改组色弹层状态(issue#22 spec §6.2 恢复): 编辑模式才有组色源, 新建模式无组
    @State private var showGroupColorPicker = false
    // 组色源色值: 同组 colorMode=GROUP 中 id 最小行的 color — UI 显示 + 改组色弹层初值
    @State private var groupSourceColorHex = ""
    // 改组色两段式: 调色盘选中 → 暂存 → 确认对话框(spec §6.3)→ 落库
    @State private var pendingGroupColorHex: String? = nil
    @State private var showConflictConfirm = false
    @State private var pendingConflictDetails: [String] = []
    @State private var groupLoaded = false
    // issue#23 逐卡: 边缘槽位暂存 + 三个弹层目标
    @State private var pendingEdgeInserts: [PendingEdgeInsert] = []
    @State private var pendingEdgeEdits: [EdgeSlotEdit] = []
    @State private var edgePickTargetIndex: Int? = nil
    @State private var newSlotTarget: NewSlotTarget? = nil
    @State private var slotEditTarget: SlotEditTarget? = nil

    private var canSave: Bool { !courseName.trimmingCharacters(in: .whitespaces).isEmpty && !meetingBlocks.isEmpty }

    // ← Android conflict AlertDialog 正文: "• " 前缀行, 最多 6 条, 多余折叠提示
    private var conflictDetailMessage: String {
        var lines = pendingConflictDetails.prefix(6).map { "• \($0)" }
        if pendingConflictDetails.count > 6 {
            lines.append(L10n.format("more_unexpanded", pendingConflictDetails.count - 6))
        }
        return lines.joined(separator: "\n")
    }

    /// issue#9/issue#23: 生效时间表 = 课表 timeJson + 本次会话暂存的新建槽位 + 槽位时间编辑。
    /// 候选集合/槽位时间展示/校验/落库全部以它为唯一依据。
    private var effectiveTimeJson: String {
        let base = viewModel.state.currentTable?.timeJson ?? TimeTableUtils.DEFAULT_TIME_JSON
        var json = base
        for insert in pendingEdgeInserts {
            json = TimeTableUtils.insertEdgeNode(timeJson: json, edgeClass: insert.edgeClass,
                                                 start: insert.start, end: insert.end)
        }
        for edit in pendingEdgeEdits {
            json = TimeTableUtils.updateEdgeNodeTimes(timeJson: json, node: edit.node,
                                                      start: edit.start, end: edit.end)
        }
        return json
    }

    var body: some View {
        let state = viewModel.state
        let currentTable = state.currentTable

        VStack(spacing: 0) {
            SettingsTopBar(title: L10n.format(editingCourse != nil ? "edit_course" : "create_course"),
                           onBack: onDismiss)
            ScrollView {
                VStack(spacing: 14) {
                    Spacer().frame(height: 2)

                    if !validationIssues.isEmpty {
                        ValidationCard(issues: validationIssues)
                    }

                    basicInfoCard
                    weekRangeCard

                    // 上课时段标题
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.format("meeting_slots"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(colors.onSurface)
                        Text(L10n.format("meeting_slots_sub"))
                            .font(.system(size: 12))
                            .foregroundColor(colors.onSurfaceVariant)
                    }
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(Array(meetingBlocks.enumerated()), id: \.element.id) { index, _ in
                        MeetingBlockEditor(
                            title: L10n.format("slot_n", index + 1),
                            block: bindingForBlock(at: index),
                            maxStd: TimeTableUtils.maxStandardNode(effectiveTimeJson),
                            timeJson: effectiveTimeJson,
                            canRemove: meetingBlocks.count > 1,
                            issues: validationIssues.filter { $0.blockId == meetingBlocks[index].id }.map { $0.message },
                            groupSourceColorHex: groupSourceColorHex,
                            onChangeGroupColor: { showGroupColorPicker = true },
                            onRemove: { meetingBlocks.remove(at: index) },
                            onPickEdge: { edgePickTargetIndex = index },
                            onEditSlot: { node, s, e in slotEditTarget = SlotEditTarget(node: node, start: s, end: e) },
                            onDeselectEdge: { released in deselectEdge(from: index, released: released) })
                    }

                    // 新增时段按钮 (← Android: LazyColumn 独立 item, spacing 14)
                    Button {
                        meetingBlocks.append(MeetingBlockDraft(
                            id: nextBlockId, days: [2], mode: .byNode,
                            startNode: 3, step: 2, startTime: "10:00", endTime: "11:40",
                            startWeek: min(startWeek, endWeek), endWeek: max(startWeek, endWeek), weekType: 0))
                        nextBlockId += 1
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 24))
                            Text(L10n.format("add_slot"))
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colors.onSecondaryContainer)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(colors.secondaryContainer)
                        .cornerRadius(SleepyShapes.large)
                    }
                    .buttonStyle(SleepyButtonStyle())
                    .accessibilityIdentifier("course_add_slot")

                    // 保存
                    Button(action: { save(state: state) }) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 24))
                            Text(L10n.format(editingCourse != nil ? "save_course" : "create_course_btn"))
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colors.onPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(colors.primary)
                        .cornerRadius(SleepyShapes.large)
                    }
                    .buttonStyle(SleepyButtonStyle())
                    .disabled(!canSave)
                    .accessibilityIdentifier("course_save")

                    // 删除(编辑模式)
                    if editingCourse != nil {
                        Button(action: { showDeleteConfirm = true }) {
                            HStack(spacing: 8) {
                                Image(systemName: "trash")
                                    .font(.system(size: 24))
                                Text(L10n.format("delete_course"))
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(colors.onErrorContainer)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(colors.errorContainer)
                            .cornerRadius(SleepyShapes.large)
                        }
                        .buttonStyle(SleepyButtonStyle())
                        .accessibilityIdentifier("course_delete")
                    }

                    Spacer().frame(height: 32)
                }
                .padding(.horizontal, 16)
            }
        }
        .background(colors.background)
        .onAppear { loadIfNeeded(state: state) }
        // 改组色弹层(issue#22 spec §6.2/§6.3 恢复): 调色盘 + 全组影响确认。
        // 编辑模式才弹(新建模式无 groupId, showGroupColorPicker 永远不会置 true)
        .sheet(isPresented: $showGroupColorPicker) {
            NativeColorPicker(initialHex: groupSourceColorHex.isEmpty ? "#FF6750A4" : groupSourceColorHex) { hex in
                showGroupColorPicker = false
                pendingGroupColorHex = hex
            }
        }
        .alert(L10n.format("group_color_confirm_title"), isPresented: Binding(
            get: { pendingGroupColorHex != nil },
            set: { if !$0 { pendingGroupColorHex = nil } }
        )) {
            Button(L10n.format("action_confirm")) { confirmGroupColor() }
            Button(L10n.format("cancel"), role: .cancel) { pendingGroupColorHex = nil }
        } message: {
            if let hex = pendingGroupColorHex {
                Text(hex + "\n" + L10n.format("group_color_confirm_msg"))
            } else {
                Text(L10n.format("group_color_confirm_msg"))
            }
        }
        .alert(L10n.format("confirm_delete"), isPresented: $showDeleteConfirm) {
            Button(L10n.format("delete"), role: .destructive) {
                showDeleteConfirm = false
                if let eg = editingCourse, let tid = state.selectedTableId {
                    try? ScheduleRepository(AppDatabase.getShared()).deleteCourseGroup(tid, eg.groupId)
                }
                onSaved()
            }
            Button(L10n.format("cancel"), role: .cancel) {}
        } message: {
            Text(L10n.format("delete_course_confirm", editingCourse?.courseName ?? ""))
        }
        .alert(L10n.format("conflict_detail_title"), isPresented: $showConflictConfirm) {
            Button(L10n.format("conflict_detail_save_anyway")) {
                showConflictConfirm = false
                save(state: state, forceAfterConflict: true)
            }
            Button(L10n.format("conflict_detail_go_back"), role: .cancel) {
                showConflictConfirm = false
            }
        } message: {
            Text(conflictDetailMessage)
        }
        // ── issue#23 逐卡: 候选弹层 / 新建槽位弹窗 / 槽位默认时间编辑弹窗 ──
        .sheet(item: $edgePickTarget) { _ in
            EdgeCandidatePickerDialog(
                candidates: TimeTableUtils.edgeCandidates(effectiveTimeJson),
                onPickExisting: { node in
                    if let i = edgePickTargetIndex, meetingBlocks.indices.contains(i) {
                        meetingBlocks[i].isIrregularNode = true
                        meetingBlocks[i].selectedEdgeNode = node
                    }
                    edgePickTarget = nil
                },
                onPickNew: { candidate in
                    edgePickTarget = nil
                    newSlotTarget = NewSlotTarget(blockIndex: edgePickTargetIndex ?? 0, candidate: candidate)
                },
                onDismiss: { edgePickTarget = nil })
        }
        .sheet(item: $newSlotTarget) { target in
            NewEdgeSlotDialog(candidate: target.candidate,
                onConfirm: { start, end in
                    let c = target.candidate
                    pendingEdgeInserts.append(PendingEdgeInsert(
                        edgeClass: c.edgeClass, node: c.node, start: start, end: end,
                        ownerBlockId: meetingBlocks.indices.contains(target.blockIndex)
                            ? meetingBlocks[target.blockIndex].id : 0))
                    if meetingBlocks.indices.contains(target.blockIndex) {
                        meetingBlocks[target.blockIndex].isIrregularNode = true
                        meetingBlocks[target.blockIndex].selectedEdgeNode = c.node
                    }
                    newSlotTarget = nil
                },
                onDismiss: { newSlotTarget = nil })
        }
        .sheet(item: $slotEditTarget) { target in
            SlotEditDialog(node: target.node, initialStart: target.start, initialEnd: target.end,
                onConfirm: { s, e in
                    // 同节点旧编辑项覆盖 (最新一次编辑为准)
                    pendingEdgeEdits.removeAll { $0.node == target.node }
                    pendingEdgeEdits.append(EdgeSlotEdit(node: target.node, start: s, end: e))
                    slotEditTarget = nil
                },
                onDismiss: { slotEditTarget = nil })
        }
    }

    // 候选弹层目标需要 Identifiable 包装(sheet(item:))
    private struct EdgePickTarget: Identifiable { let id = UUID() }
    @State private var edgePickTarget: EdgePickTarget? = nil

    /// §2.3 槽位复用: 关闭非常规节次时, 无他卡引用的 owned 暂存槽位回收
    private func deselectEdge(from index: Int, released: Int) {
        guard meetingBlocks.indices.contains(index) else { return }
        let blockId = meetingBlocks[index].id
        pendingEdgeInserts.removeAll { ins in
            ins.ownerBlockId == blockId && ins.node == released &&
                !meetingBlocks.contains { o in
                    o.id != blockId && o.isIrregularNode && o.selectedEdgeNode == released
                }
        }
    }

    // ← 基本信息
    private var basicInfoCard: some View {
        CardSection(title: L10n.format("course_basic_info"),
                    subtitle: L10n.format("course_basic_info_sub")) {
            VStack(spacing: 12) {
                FieldTextField(text: $courseName, label: L10n.format("course_name_required"))
                // issue#26: 别名输入(可选) — 空 = 原名; 语义是"展示名", 不参与身份/匹配
                FieldTextField(text: $courseAlias, label: L10n.format("course_alias"))
                // issue#22: teacher/room/note/color 已下沉到每个 MeetingBlockDraft(同名多地点独立编辑)
            }
        }
    }

    // ← 周次范围
    private var weekRangeCard: some View {
        CardSection(title: L10n.format("week_range"),
                    subtitle: L10n.format("week_range_sub")) {
            HStack(spacing: 12) {
                NumberStepperField(label: L10n.format("start_week"), value: $startWeek, minV: 1, maxV: 30)
                    .frame(maxWidth: .infinity)
                NumberStepperField(label: L10n.format("end_week"), value: $endWeek, minV: 1, maxV: 30)
                    .frame(maxWidth: .infinity)
            }
            // ← Android 周次卡内「显式应用」按钮 (无图标, regularHeight 48, 卡内 spacing 12)
            Button {
                for index in meetingBlocks.indices {
                    meetingBlocks[index].startWeek = min(startWeek, endWeek)
                    meetingBlocks[index].endWeek = max(startWeek, endWeek)
                }
            } label: {
                Text(L10n.format("apply_to_all_slots"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(colors.onSecondaryContainer)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(colors.secondaryContainer)
                    .cornerRadius(SleepyShapes.large)
            }
            .buttonStyle(SleepyButtonStyle())
            .accessibilityIdentifier("course_apply_to_all_slots")
        }
    }

    private func bindingForBlock(at index: Int) -> Binding<MeetingBlockDraft> {
        Binding(
            get: { meetingBlocks[index] },
            set: { meetingBlocks[index] = $0 })
    }

    // ← remember(editingCourse?.id) 初始状态 + 编辑模式查同 groupId 回填多 block
    private func loadIfNeeded(state: ScheduleState) {
        let key = editingCourse?.id ?? 0
        guard loadedForId != key else { return }
        loadedForId = key
        groupLoaded = false
        courseName = editingCourse?.courseName ?? ""
        courseAlias = editingCourse?.alias ?? ""
        startWeek = editingCourse?.startWeek ?? 1
        endWeek = editingCourse?.endWeek ?? 16
        nextBlockId = 2
        validationIssues = []
        pendingEdgeInserts = []
        pendingEdgeEdits = []
        meetingBlocks = [Self.initialMeetingBlock(editingCourse)]

        // LaunchedEffect(editingCourse?.groupId): 查同 groupId 分组回填
        if let eg = editingCourse, !eg.groupId.isEmpty, let tid = state.selectedTableId {
            let repo = ScheduleRepository(AppDatabase.getShared())
            if let groupCourses = try? repo.getGroupCourses(tid, eg.groupId), !groupCourses.isEmpty {
                // 组色源: 同组 colorMode=GROUP 中 id 最小行的 color (CourseColorUtil 单点)
                groupSourceColorHex = CourseColorUtil.groupSourceColorHex(groupCourses)
                // 按完整时段特征分组; issue#22: room/teacher 进分组 key
                let slots = Dictionary(grouping: groupCourses) {
                    "\($0.ownTime)-\($0.startNode)-\($0.step)-\($0.startTime)-\($0.endTime)-\($0.startWeek)-\($0.endWeek)-\($0.type)-\($0.room)-\($0.teacher)"
                }
                // issue#23 §4.3: startNode 落在边缘槽位 → 点亮该卡「非常规节次」;
                // ownTime=true → 点亮「非常规时间」并预填课程起止 (旧 ByClock 并入此开关)
                let edgeNodes = Set(TimeTableUtils.parseTimeSlotRows(
                    state.currentTable?.timeJson ?? TimeTableUtils.DEFAULT_TIME_JSON
                ).filter { $0.edgeClass != nil }.map { $0.node })
                var blocks: [MeetingBlockDraft] = []
                var bid = 1
                for (_, courses) in slots {
                    let first = courses[0]
                    let isEdge = edgeNodes.contains(first.startNode)
                    var b = MeetingBlockDraft(
                        id: bid,
                        days: Set(courses.map { $0.day }),
                        mode: first.ownTime ? .byClock : .byNode,
                        startNode: first.startNode,
                        step: first.step,
                        startTime: first.startTime.isEmpty ? "08:00" : first.startTime,
                        endTime: first.endTime.isEmpty ? "09:40" : first.endTime,
                        startWeek: first.startWeek, endWeek: first.endWeek,
                        weekType: first.type,
                        room: first.room, teacher: first.teacher,
                        note: first.note, color: first.color,
                        colorMode: first.colorMode,
                        isIrregularNode: isEdge,
                        selectedEdgeNode: isEdge ? first.startNode : 0,
                        isIrregularTime: first.ownTime)
                    // §2.4: 覆盖时间的卡补派生时长文本
                    if b.isIrregularTime {
                        b.durationText = String(Self.minutesBetween(b.startTime, b.endTime) ?? 0)
                        if Int(b.durationText) == 0 { b.durationText = "" }
                    }
                    blocks.append(b)
                    bid += 1
                }
                meetingBlocks = blocks
            }
        }
        groupLoaded = true
    }

    // ← 保存: 校验 → 冲突报告 → 编辑行级 diff / 新建共享 groupId + 槽位暂存写回
    /// 改组色确认落库: 只写组色源(GROUP 行 color), 刷新编辑回填的组色源显示
    private func confirmGroupColor() {
        guard let hex = pendingGroupColorHex else { return }
        pendingGroupColorHex = nil
        guard let eg = editingCourse, !eg.groupId.isEmpty, let tid = viewModel.state.selectedTableId else { return }
        let repo = ScheduleRepository(AppDatabase.getShared())
        try? repo.setGroupSourceColor(tid, eg.groupId, hex)
        if let fresh = try? repo.getGroupCourses(tid, eg.groupId), !fresh.isEmpty {
            groupSourceColorHex = CourseColorUtil.groupSourceColorHex(fresh)
        }
    }

    private func save(state: ScheduleState, forceAfterConflict: Bool = false) {
        let timeJson = effectiveTimeJson
        let issues = Self.validateCourseDraft(courseName: courseName, blocks: meetingBlocks,
                                              startWeek: startWeek, endWeek: endWeek,
                                              timeJson: timeJson)
        validationIssues = issues
        guard issues.isEmpty else { return }

        let draftTableId = state.selectedTableId ?? 0
        // issue#22: color/teacher/room/note 从 block 取(每时段独立); issue#26: alias 组级
        let drafts = meetingBlocks.flatMap { block in
            block.days.sorted().map { day in
                Self.buildCourseEntity(
                    tableId: draftTableId, groupId: "",
                    courseName: courseName.trimmingCharacters(in: .whitespaces),
                    day: day, block: block,
                    alias: courseAlias.trimmingCharacters(in: .whitespaces))
            }
        }

        let repo = ScheduleRepository(AppDatabase.getShared())
        // 冲突检测(新建 / 编辑同一 groupId 的草稿都不算 — 用 groupId 排除被编辑的自己)
        if !forceAfterConflict, draftTableId != 0, let table = state.currentTable {
            let stored = ((try? repo.getCourses(draftTableId)) ?? [])
                .filter { editingCourse?.groupId != $0.groupId }
                .map { Self.conflictLite($0.normalizeNode(timeJson: table.timeJson)) }
            let draftLites = drafts.map(Self.conflictLite)
            let dayNames = (1...7).map { DateUtils.localizedDay($0) }
            let details = ConflictDetailReporter.draftConflictDetails(
                drafts: draftLites, stored: stored, dayNames: dayNames,
                timeJson: table.timeJson)
                .map { ConflictDetailReporter.formatDetail($0, template: L10n.format("conflict_detail_line")) }
            if !details.isEmpty {
                pendingConflictDetails = details
                showConflictConfirm = true
                return
            }
        }

        // 没表就自动建一张
        let tableId = state.selectedTableId ?? viewModel.createEmptyTable()
        var fixedDrafts = drafts
        for i in fixedDrafts.indices { fixedDrafts[i].tableId = tableId }
        if let eg = editingCourse {
            // 编辑: 行级 diff/patch 替换整组覆盖 — issue#22 同名多地点
            let gid = eg.groupId
            for i in fixedDrafts.indices { fixedDrafts[i].groupId = gid }
            let existing = ((try? repo.getCourses(tableId)) ?? []).filter { $0.groupId == gid }
            let diff = RowKeyDiffer.diff(fixedDrafts, existing)
            try? repo.applyDiff(tableId, diff)
        } else {
            // 新建: 所有草稿共享同一个 groupId
            let gid = UUID().uuidString
            for i in fixedDrafts.indices { fixedDrafts[i].groupId = gid }
            _ = try? repo.insertCourses(fixedDrafts)
        }
        // issue#23: 新建槽位 / 槽位时间编辑先在编辑页暂存, 课程落库成功后再写回课表 timeJson。
        // 顺序串接保证一次添加多个槽位时编号连续且方向元数据不丢失。
        // v7.10.16v 撤回: 课程行 + timeJson 写回是一个动作 — beginBatch 让快照
        // 固定在动作前, 撤回一次整步回退(否则第二写覆盖快照, 只回退一半)。
        if !pendingEdgeInserts.isEmpty || !pendingEdgeEdits.isEmpty {
            let repo2 = ScheduleRepository(AppDatabase.getShared())
            let base = ((try? repo2.getTable(tableId))?.timeJson) ?? TimeTableUtils.DEFAULT_TIME_JSON
            UndoManager.shared.beginBatch()
            defer { UndoManager.shared.endBatch() }
            var updated = base
            for insert in pendingEdgeInserts {
                updated = TimeTableUtils.insertEdgeNode(timeJson: updated, edgeClass: insert.edgeClass,
                                                        start: insert.start, end: insert.end)
            }
            for edit in pendingEdgeEdits {
                updated = TimeTableUtils.updateEdgeNodeTimes(timeJson: updated, node: edit.node,
                                                             start: edit.start, end: edit.end)
            }
            if let table = try? repo2.getTable(tableId), updated != table.timeJson {
                var copy = table
                copy.timeJson = updated
                try? repo2.updateTable(copy)
            }
        }
        onSaved()
    }

    // ← initialMeetingBlock
    static func initialMeetingBlock(_ course: CourseEntity?) -> MeetingBlockDraft {
        guard let course = course else {
            return MeetingBlockDraft(id: 1, days: [1], mode: .byNode, startNode: 1, step: 2,
                                     startTime: "08:00", endTime: "09:40",
                                     startWeek: 1, endWeek: 16, weekType: 0)
        }
        return MeetingBlockDraft(id: 1, days: [course.day],
                                 mode: course.ownTime ? .byClock : .byNode,
                                 startNode: course.startNode, step: course.step,
                                 startTime: course.startTime.isEmpty ? "08:00" : course.startTime,
                                 endTime: course.endTime.isEmpty ? "09:40" : course.endTime,
                                 startWeek: course.startWeek, endWeek: course.endWeek,
                                 weekType: course.type,
                                 room: course.room, teacher: course.teacher,
                                 note: course.note, color: course.color,
                                 colorMode: course.colorMode,
                                 isIrregularTime: course.ownTime)
    }

    // ← buildCourseEntity (issue#26 alias 参数)
    static func buildCourseEntity(tableId: Int64, groupId: String, courseName: String,
                                  day: Int, block: MeetingBlockDraft,
                                  alias: String = "") -> CourseEntity {
        // issue#22: color/colorMode 从 block 取;AUTO 模式 color 留空(渲染时按 hash 取)
        let finalColor: String
        switch block.colorMode {
        case CourseColorMode.CUSTOM:
            finalColor = block.color.isEmpty ? "#FF6750A4" : block.color
        case CourseColorMode.AUTO:
            finalColor = ""
        default:
            finalColor = block.color.isEmpty ? "#FF6750A4" : block.color
        }
        // issue#23 逐卡: 边缘槽位卡 → startNode=槽位号, step 锁 1;
        // 覆盖时间卡 → ownTime=isIrregularTime 且起止为覆盖值 (§5 同值契约)
        let ownTime = block.isIrregularTime
        return CourseEntity(
            groupId: groupId, tableId: tableId, courseName: courseName,
            teacher: block.teacher.trimmingCharacters(in: .whitespaces),
            room: block.room.trimmingCharacters(in: .whitespaces),
            note: block.note.trimmingCharacters(in: .whitespaces),
            day: day,
            startNode: block.isIrregularNode ? block.selectedEdgeNode : block.startNode,
            step: block.isIrregularNode ? 1 : block.step,
            startWeek: min(block.startWeek, block.endWeek),
            endWeek: max(block.startWeek, block.endWeek), type: block.weekType,
            color: finalColor, colorMode: block.colorMode,
            isIrregularNode: block.isIrregularNode,
            isIrregularTime: block.isIrregularTime,
            ownTime: ownTime,
            startTime: ownTime ? block.startTime.trimmingCharacters(in: .whitespaces) : "",
            endTime: ownTime ? block.endTime.trimmingCharacters(in: .whitespaces) : "",
            alias: alias.trimmingCharacters(in: .whitespaces))
    }

    // ← validateCourseDraft (issue#23: 生效时间表唯一依据; 非常规卡独立校验)
    static func validateCourseDraft(courseName: String, blocks: [MeetingBlockDraft],
                                    startWeek: Int, endWeek: Int,
                                    timeJson: String) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if courseName.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(ValidationIssue(blockId: nil, message: L10n.format("course_name_empty")))
        }
        if startWeek <= 0 || endWeek <= 0 {
            issues.append(ValidationIssue(blockId: nil, message: L10n.format("week_must_be_positive")))
        }
        let rows = TimeTableUtils.parseTimeSlotRows(timeJson)
        let maxStd = TimeTableUtils.maxStandardNode(timeJson)

        for (index, block) in blocks.enumerated() {
            if block.days.isEmpty {
                issues.append(ValidationIssue(blockId: block.id, message: L10n.format("slot_at_least_one_day", index + 1)))
            }
            if block.startWeek <= 0 || block.endWeek <= 0 || block.startWeek > block.endWeek {
                issues.append(ValidationIssue(blockId: block.id,
                                              message: L10n.format("slot_week_order", index + 1)))
            }
            // issue#23 逐卡: 非常规节次卡 → 槽位必须真实存在于生效时间表;
            // 标准卡 → 1..maxStd 越界拒绝。时间格式/顺序只对勾了「非常规时间」的卡检查。
            if block.isIrregularNode {
                let row = rows.first { $0.node == block.selectedEdgeNode && $0.edgeClass != nil }
                if row == nil {
                    issues.append(ValidationIssue(blockId: block.id,
                                                  message: L10n.format("irregular_node_required", index + 1)))
                }
            } else if block.mode == .byNode {
                if block.startNode < 1 {
                    issues.append(ValidationIssue(blockId: block.id, message: L10n.format("slot_start_node_positive", index + 1)))
                }
                if block.step <= 0 {
                    issues.append(ValidationIssue(blockId: block.id, message: L10n.format("slot_step_positive", index + 1)))
                }
                // issue#9: startNode+step-1 越过标准 1..maxStd 段上界时拒绝保存(边缘槽位不受此限)
                let endNode = block.startNode + block.step - 1
                if endNode > maxStd {
                    issues.append(ValidationIssue(
                        blockId: block.id,
                        message: L10n.format("slot_step_exceeds_max", index + 1, block.startNode, endNode, maxStd)))
                }
            }
            if block.isIrregularTime {
                guard let start = parseHm(block.startTime), let end = parseHm(block.endTime) else {
                    issues.append(ValidationIssue(blockId: block.id, message: L10n.format("irregular_time_format")))
                    continue
                }
                if start >= end {
                    issues.append(ValidationIssue(blockId: block.id, message: L10n.format("irregular_time_order")))
                }
            }
        }
        // 时段重叠检测
        for i in blocks.indices {
            for j in (i + 1)..<blocks.count {
                let first = blocks[i], second = blocks[j]
                let overlapDays = first.days.intersection(second.days)
                if overlapDays.isEmpty { continue }
                guard let firstRange = blockRangeMinutes(first, timeJson),
                      let secondRange = blockRangeMinutes(second, timeJson) else { continue }
                if firstRange.0 < secondRange.1 && secondRange.0 < firstRange.1 {
                    if !weekRangesOverlap(first.startWeek, first.endWeek, first.weekType,
                                          second.startWeek, second.endWeek, second.weekType) { continue }
                    let dayText = overlapDays.sorted().map { DateUtils.localizedDay($0) }.joined(separator: " / ")
                    issues.append(ValidationIssue(blockId: second.id,
                                                  message: L10n.format("slot_time_overlap", i + 1, j + 1, dayText)))
                }
            }
        }
        return issues
    }

    /// ← weekRangesOverlap(周次区间 + 单双周相交判定; Android private fun 同名)
    static func weekRangesOverlap(_ s1: Int, _ e1: Int, _ t1: Int, _ s2: Int, _ e2: Int, _ t2: Int) -> Bool {
        if s1 > e2 || s2 > e1 { return false }
        // 同 type 或有一方每周 → 区间交即重叠; 单 vs 双 无交
        if t1 == t2 || t1 == 0 || t2 == 0 { return true }
        if (t1 == 1 && t2 == 2) || (t1 == 2 && t2 == 1) { return false }
        return true  // type 3(按周次) 保守当重叠
    }

    static func maxNode(for table: TimeTableEntity?) -> Int {
        let nodes = TimeTableUtils.parseNodes(table?.timeJson ?? TimeTableUtils.DEFAULT_TIME_JSON)
        return nodes.map(\.node).max() ?? table?.nodesPerDay ?? 12
    }

    private static func conflictLite(_ course: CourseEntity) -> CourseEntityLite {
        CourseEntityLite(courseName: course.courseName, day: course.day,
                         startNode: course.startNode, step: course.step,
                         startWeek: course.startWeek, endWeek: course.endWeek,
                         type: course.type,
                         ownTime: course.ownTime, startTime: course.startTime,
                         endTime: course.endTime, isIrregularTime: course.isIrregularTime)
    }

    // ← blockRangeMinutes (§3.3 契约的分钟化: 本卡生效起止 → [startMin, endMin))
    static func blockRangeMinutes(_ block: MeetingBlockDraft, _ timeJson: String) -> (Int, Int)? {
        guard let range = block.effectiveRange(timeJson: timeJson) else { return nil }
        guard let start = parseHm(range.0), let end = parseHm(range.1) else { return nil }
        return (start, end)
    }

    /// §2.4 B 规则: 起止时间差(分钟), 解析失败返回 nil
    static func minutesBetween(_ start: String, _ end: String) -> Int? {
        guard let s = parseHm(start), let e = parseHm(end) else { return nil }
        return e - s
    }

    // ← parseHm("HH:mm" → 当日分钟数)
    static func parseHm(_ value: String) -> Int? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}

// ← ValidationCard
private struct ValidationCard: View {
    @Environment(\.localWakeUpColors) private var colors
    let issues: [ValidationIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.format("fix_issues_first"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(colors.onErrorContainer)
            ForEach(issues.prefix(4)) { issue in
                Text("• \(issue.message)")
                    .font(.system(size: 12))
                    .foregroundColor(colors.onErrorContainer)
            }
            if issues.count > 4 {
                Text(L10n.format("more_unexpanded", issues.count - 4))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(colors.onErrorContainer)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.errorContainer)
        .cornerRadius(SleepyShapes.large)
    }
}

extension ValidationIssue: Identifiable {
    var id: String { "\(blockId ?? -1)-\(message)" }
}

// ← CardSection(带副标题)
private struct CardSection<Content: View>: View {
    @Environment(\.localWakeUpColors) private var colors
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(colors.onSurface)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(colors.onSurfaceVariant)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.surfaceContainer)
        .cornerRadius(SleepyShapes.extraLarge)
    }
}

/// issue#23 逐卡: 标签 + 副标题 + Toggle 的标准行 — 卡内两个非常规开关共用
private struct SwitchRow: View {
    @Environment(\.localWakeUpColors) private var colors
    let label: String
    let sub: String
    @Binding var checked: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundColor(colors.onSurface)
                Text(sub)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(colors.onSurfaceVariant)
            }
            Spacer()
            Toggle("", isOn: $checked)
                .labelsHidden()
        }
    }
}

// ← MeetingBlockEditor (issue#23 逐卡: 卡内两个独立开关 — 非常规节次 / 非常规时间)
private struct MeetingBlockEditor: View {
    @Environment(\.localWakeUpColors) private var colors
    let title: String
    @Binding var block: MeetingBlockDraft
    let maxStd: Int
    let timeJson: String
    let canRemove: Bool
    let issues: [String]
    let groupSourceColorHex: String
    let onChangeGroupColor: () -> Void
    let onRemove: () -> Void
    let onPickEdge: () -> Void
    let onEditSlot: (_ node: Int, _ start: String, _ end: String) -> Void
    let onDeselectEdge: (_ releasedNode: Int) -> Void

    private var candidates: [TimeTableUtils.EdgeCandidate] {
        TimeTableUtils.edgeCandidates(timeJson)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // issue#9 延伸: 输入超界被夹紧时, 卡顶提示 (← Android clamped hint 在卡首)
            if block.clamped {
                Text(L10n.format(
                    "slot_step_clamped_hint",
                    block.startNode,
                    block.startNode + block.step - 1,
                    maxStd))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(colors.onErrorContainer)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(colors.onSurface)
                    Text(block.days.isEmpty
                         ? L10n.format("select_at_least_one_day")
                         : L10n.format("selected_days",
                                       block.days.sorted().map { DateUtils.localizedDay($0) }.joined(separator: " / ")))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(colors.onSurfaceVariant)
                }
                Spacer()
                if canRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 24))
                            .foregroundColor(colors.onSurfaceVariant)
                    }
                    .buttonStyle(SleepyButtonStyle())
                }
            }

            MultiDayPicker(selectedDays: block.days) { day in
                if block.days.contains(day) { block.days.remove(day) } else { block.days.insert(day) }
            }

            // issue#23 逐卡: 非常规节次 / 非常规时间 — 收进同一折叠栏 (2026-09-09 折叠栏改版)
            IrregularOptionsSection(
                block: $block,
                timeJson: timeJson,
                initiallyExpanded: block.isIrregularNode || block.isIrregularTime,
                onPickEdge: onPickEdge,
                onEditSlot: onEditSlot,
                onDeselectEdge: onDeselectEdge)

            if !block.isIrregularNode && block.mode == .byNode {
                // 标准卡: startNode/step, 1..maxStd
                HStack(spacing: 12) {
                    NumberStepperField(label: L10n.format("start_node"), value: Binding(
                        get: { block.startNode }, set: {
                            block.startNode = $0
                            let stepCap = Swift.max(1, maxStd - block.startNode + 1)
                            if block.step > stepCap {
                                block.step = stepCap
                                block.clamped = true
                            }
                        }), minV: 1, maxV: maxStd,
                        onClamp: { block.clamped = true })
                        .frame(maxWidth: .infinity)
                    // startNode 上调 → step 上限同步收紧, 避免越界
                    NumberStepperField(label: L10n.format("step_count"), value: Binding(
                        get: { block.step }, set: { block.step = $0 }),
                        minV: 1, maxV: Swift.max(1, maxStd - block.startNode + 1),
                        onClamp: { block.clamped = true })
                        .frame(maxWidth: .infinity)
                }
            }

            HStack(spacing: 12) {
                NumberStepperField(label: L10n.format("slot_week_range") + " " + L10n.format("start_week"), value: $block.startWeek, minV: 1, maxV: 30)
                    .frame(maxWidth: .infinity)
                NumberStepperField(label: L10n.format("slot_week_range") + " " + L10n.format("end_week"), value: $block.endWeek, minV: 1, maxV: 30)
                    .frame(maxWidth: .infinity)
            }
            SegmentedSwitcher(options: [
                (0, L10n.format("week_every")),
                (1, L10n.format("week_odd")),
                (2, L10n.format("week_even")),
                (3, L10n.format("week_custom"))
            ], selected: block.weekType) { block.weekType = $0 }

            // issue#22: 老师/地点/备注下沉到每时段独立编辑
            // (嵌套 Group — ViewBuilder 单 builder 10 子视图上限)
            Group {
                FieldTextField(text: $block.teacher, label: L10n.format("course_teacher"))
                FieldTextField(text: $block.room, label: L10n.format("course_room"))
                MultilineFieldCompat(placeholder: L10n.format("course_note"), text: $block.note, minLines: 2, maxLines: 4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(colors.surfaceContainerHighest)   // ← fieldColors 容器色 surfaceContainerHighest
                    .cornerRadius(SleepyTheme.fieldShape)
                    // ← Android filled TextField, 无描边
                ColorSection(block: $block, groupSourceColorHex: groupSourceColorHex,
                             onChangeGroupColor: onChangeGroupColor)
            }

            // 尾部 if 合并进 Group, 防外层 builder 超 10 子视图
            Group {
                if !issues.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(issues, id: \.self) { issue in
                            Text(issue)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(colors.error)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 有 issue 或输入被夹紧时整卡变 errorContainer, 无描边
        .background(issues.isEmpty && !block.clamped ? colors.surfaceContainerHigh : colors.errorContainer)
        .cornerRadius(SleepyShapes.large)
    }
}

// ← IrregularOptionsSection (2026-09-09 折叠栏改版): 「非常规节次」「非常规时间」两个开关
// 绑到一起收进可展开区块, 默认折叠; 编辑已启用任一非常规项的卡时自动展开 (initiallyExpanded)。
// Android: Column clip medium + bg surfaceContainerHighest, 栏头 padding h12 v10 spacedBy 10,
// 展开内容 padding start/end/bottom 12 spacedBy 12, chevron 20dp 随展开旋转 180°。
private struct IrregularOptionsSection: View {
    @Environment(\.localWakeUpColors) private var colors
    @Binding var block: MeetingBlockDraft
    let timeJson: String
    let initiallyExpanded: Bool
    let onPickEdge: () -> Void
    let onEditSlot: (_ node: Int, _ start: String, _ end: String) -> Void
    let onDeselectEdge: (_ releasedNode: Int) -> Void
    @State private var expanded: Bool

    private var candidates: [TimeTableUtils.EdgeCandidate] {
        TimeTableUtils.edgeCandidates(timeJson)
    }

    // ← irregularOptionsExpanded 由构造参数派生 (isIrregularNode || isIrregularTime)
    init(block: Binding<MeetingBlockDraft>, timeJson: String, initiallyExpanded: Bool,
         onPickEdge: @escaping () -> Void,
         onEditSlot: @escaping (_ node: Int, _ start: String, _ end: String) -> Void,
         onDeselectEdge: @escaping (_ releasedNode: Int) -> Void) {
        _block = block
        self.timeJson = timeJson
        self.initiallyExpanded = initiallyExpanded
        self.onPickEdge = onPickEdge
        self.onEditSlot = onEditSlot
        self.onDeselectEdge = onDeselectEdge
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 栏头: 标题 + 摘要 + chevron, 整行可点
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.format("irregular_options_section"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(colors.onSurface)
                        Text(headerSub)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(colors.onSurfaceVariant)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 20))
                        .foregroundColor(colors.onSurfaceVariant)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(SleepyButtonStyle())

            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    // 开关一 — 非常规节次 (§4 逐卡开关设计, 行为原样保留)
                    SwitchRow(label: L10n.format("irregular_node_switch"),
                              sub: L10n.format("irregular_node_switch_sub"),
                              checked: Binding(
                                get: { block.isIrregularNode },
                                set: { on in
                                    if on {
                                        block.isIrregularNode = true
                                        onPickEdge()
                                    } else {
                                        let released = block.selectedEdgeNode
                                        block.isIrregularNode = false
                                        block.selectedEdgeNode = 0
                                        onDeselectEdge(released)
                                    }
                                    block.clamped = false
                                }))

                    if block.isIrregularNode {
                        // 非常规节次卡: 槽位摘要 + 已有槽位默认时间编辑入口
                        let selected = candidates.first { $0.node == block.selectedEdgeNode }
                        HStack(spacing: 10) {
                            Text(selected.flatMap { s in s.exists
                                    ? L10n.format("edge_node_range", s.node, s.start, s.end)
                                    : nil }
                                 ?? L10n.format("edge_node_label", block.selectedEdgeNode))
                                .font(.system(size: 14))
                                .foregroundColor(colors.onSurface)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let s = selected, s.exists {
                                Button {
                                    onEditSlot(s.node, s.start, s.end)
                                } label: {
                                    Image(systemName: "square.and.pencil")
                                        .font(.system(size: 24))
                                        .foregroundColor(colors.onSurfaceVariant)
                                }
                                .buttonStyle(SleepyButtonStyle())
                                .accessibilityLabel(L10n.format("irregular_slot_edit_title"))
                            }
                        }
                    }

                    // 开关二 — 非常规时间 (吞并旧 ByClock 模式, 行为原样保留)
                    SwitchRow(label: L10n.format("irregular_time_switch"),
                              sub: L10n.format("irregular_time_switch_sub"),
                              checked: Binding(
                                get: { block.isIrregularTime },
                                set: { on in
                                    if on {
                                        block.isIrregularTime = true
                                        block.mode = .byClock
                                        if block.startTime.isEmpty || block.endTime.isEmpty {
                                            // 首次开启: 预填本卡生效时间 (槽位默认 / 标准节次时间), §4 B 规则
                                            if let r = block.effectiveRange(timeJson: timeJson) {
                                                block.startTime = r.0
                                                block.endTime = r.1
                                            }
                                        }
                                        if block.durationText.isEmpty {
                                            let d = AddCourseScreen.minutesBetween(block.startTime, block.endTime) ?? 0
                                            block.durationText = d > 0 ? String(d) : ""
                                        }
                                    } else {
                                        // 关闭覆盖时间 → 回落槽位默认 / 标准节次时间
                                        block.isIrregularTime = false
                                        block.mode = .byNode
                                        block.startTime = ""
                                        block.endTime = ""
                                        block.durationText = ""
                                    }
                                }))

                    if block.isIrregularTime {
                        // §2.4 B 规则: 起止/时长三输入 — 改起止重算时长, 改时长反推结束
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                TimePickerField(value: block.startTime, onValueChange: { v in
                                    block.startTime = v
                                    let d = AddCourseScreen.minutesBetween(block.startTime, block.endTime) ?? 0
                                    block.durationText = d > 0 ? String(d) : ""
                                }, label: L10n.format("start_time"))
                                .frame(maxWidth: .infinity)
                                TimePickerField(value: block.endTime, onValueChange: { v in
                                    block.endTime = v
                                    let d = AddCourseScreen.minutesBetween(block.startTime, block.endTime) ?? 0
                                    block.durationText = d > 0 ? String(d) : ""
                                }, label: L10n.format("end_time"))
                                .frame(maxWidth: .infinity)
                            }
                            NumberStepperField(label: L10n.format("irregular_duration_label"),
                                               value: Binding(
                                                get: { Int(block.durationText) ?? 0 },
                                                set: { mins in
                                                    guard mins > 0 else { return }
                                                    block.durationText = String(mins)
                                                    if let s = AddCourseScreen.parseHm(block.startTime) {
                                                        let end = s + mins
                                                        if end < 24 * 60 {
                                                            block.endTime = String(format: "%02d:%02d", end / 60, end % 60)
                                                        }
                                                        // 跨午夜 → 回退清空交由校验报错
                                                        let diff = AddCourseScreen.minutesBetween(block.startTime, block.endTime) ?? -1
                                                        if diff != mins || end >= 24 * 60 {
                                                            block.endTime = ""
                                                            block.durationText = ""
                                                        }
                                                    }
                                                }),
                                               minV: 1, maxV: 24 * 60)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.surfaceContainerHighest)
        .cornerRadius(SleepyShapes.medium)
    }

    // ← irregularOptionsSummary: 折叠态摘要 — 收起但已启用选项时, 栏头露出启用了什么
    private var headerSub: String {
        if expanded { return L10n.format("irregular_options_section_sub") }
        var parts: [String] = []
        if block.isIrregularNode {
            // 与 Android 一致: 未选槽位时 edgeNodeLabel 为空串仍拼入
            let nodeLabel = block.selectedEdgeNode != 0
                ? L10n.format("edge_node_label", block.selectedEdgeNode) : ""
            parts.append([L10n.format("irregular_node_switch"), nodeLabel].joined(separator: " · "))
        }
        if block.isIrregularTime {
            // 起止齐全才拼区间; 缺一(如跨午夜回退清空)只显示开关名
            if !block.startTime.isEmpty && !block.endTime.isEmpty {
                parts.append([L10n.format("irregular_time_switch"), "\(block.startTime)–\(block.endTime)"]
                    .joined(separator: " · "))
            } else {
                parts.append(L10n.format("irregular_time_switch"))
            }
        }
        let summary = parts.joined(separator: " / ")
        return summary.isEmpty ? L10n.format("irregular_options_section_sub") : summary
    }
}

// issue#22: 颜色三态 — 开关 OFF = 跟组色(GROUP);开关 ON 后可切 AUTO/CUSTOM
private struct ColorSection: View {
    @Environment(\.localWakeUpColors) private var colors
    @Binding var block: MeetingBlockDraft
    let groupSourceColorHex: String
    let onChangeGroupColor: () -> Void
    @State private var showColorPicker = false

    private var useDifferent: Bool { block.colorMode != CourseColorMode.GROUP }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.format("course_color"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(colors.onSurfaceVariant)
                Spacer()
                Text(L10n.format(useDifferent ? "color_use_different" : "color_follow_group"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(colors.onSurfaceVariant)
                Toggle("", isOn: Binding(
                    get: { useDifferent },
                    set: { on in
                        // 第一次打开: 落 AUTO(自动散色), 用户可再切自定义
                        block.colorMode = on ? CourseColorMode.AUTO : CourseColorMode.GROUP
                    }
                ))
                .labelsHidden()
            }
            if !useDifferent {
                // spec §6.1 GROUP 模式行: 跟随组色 [色块] [改组色]
                HStack(spacing: 8) {
                    GroupColorSwatch(hex: groupSourceColorHex)
                    Text(CourseColorUtil.hasCustomColorHex(groupSourceColorHex)
                         ? groupSourceColorHex
                         : L10n.format("color_group_auto"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(colors.onSurfaceVariant)
                    Spacer()
                    Button(action: onChangeGroupColor) {
                        Text(L10n.format("change_group_color"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(colors.primary)
                    }
                }
            }
            if useDifferent {
                HStack(spacing: 10) {
                    // 自动 — 渲染时由 hueForCourse 按黄金角散色
                    AutoColorDot(selected: block.colorMode == CourseColorMode.AUTO) {
                        block.colorMode = CourseColorMode.AUTO
                        block.color = ""
                    }
                    // 自定义 — 弹出调色盘选固定色
                    CustomColorDot(hex: block.colorMode == CourseColorMode.CUSTOM && !block.color.isEmpty
                                   ? block.color : nil) {
                        showColorPicker = true
                    }
                    if block.colorMode == CourseColorMode.CUSTOM && !block.color.isEmpty {
                        Text(block.color)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(colors.onSurfaceVariant)
                    }
                }
            }
        }
        .sheet(isPresented: $showColorPicker) {
            NativeColorPicker(initialHex: block.color.isEmpty ? "#FF6750A4" : block.color) { hex in
                block.color = hex
                block.colorMode = CourseColorMode.CUSTOM
                showColorPicker = false
            }
        }
    }
}

/// GROUP 模式组色色块 — 有自定义组色显示色块, 无则显示 AUTO 黄金角中性色
private struct GroupColorSwatch: View {
    @Environment(\.localWakeUpColors) private var colors
    let hex: String

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(swatchColor)
            .frame(width: 20, height: 20)
    }

    private var swatchColor: Color {
        if CourseColorUtil.hasCustomColorHex(hex), let argb = CourseColorUtil.parseColor(hex) {
            return Color(uiArgb: UInt32(argb))
        }
        return colors.surfaceVariant
    }
}

// ← MultiDayPicker: Form + Toggle 行表 (iOS 设置式多选), 替代自制 4+3 网格
private struct MultiDayPicker: View {
    @Environment(\.localWakeUpColors) private var colors
    let selectedDays: Set<Int>
    let onToggleDay: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(1...7, id: \.self) { day in
                let selected = selectedDays.contains(day)
                Button {
                    onToggleDay(day)
                } label: {
                    HStack {
                        Text(DateUtils.localizedDay(day))
                            .font(.system(size: 15))
                            .foregroundColor(colors.onSurface)
                        Spacer()
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(colors.primary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SleepyButtonStyle())
                if day < 7 {
                    Divider().background(colors.outlineVariant)
                }
            }
        }
        .background(colors.surfaceContainer)
        .cornerRadius(SleepyShapes.medium)
    }
}

// ← NumberField(数字输入, 外部值同步 + 空回退 min)
struct NumberStepperField: View {
    @Environment(\.localWakeUpColors) private var colors
    let label: String
    @Binding var value: Int
    var minV: Int
    var maxV: Int
    var onClamp: (() -> Void)? = nil

    @State private var text: String = ""

    var body: some View {
        HStack(spacing: 4) {
            TextField(label, text: Binding(
                get: { text.isEmpty ? "\(value)" : text },
                set: { txt in
                    text = txt
                    if txt.isEmpty {
                        value = minV   // 清空时回退最小值
                    } else if let v = Int(txt) {
                        let clamped = Swift.min(Swift.max(v, minV), maxV)
                        if clamped != v { onClamp?() }
                        value = clamped
                        text = "\(clamped)"
                    }
                }
            ))
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(colors.surfaceContainerHighest)   // ← fieldColors 容器色 surfaceContainerHighest
            .cornerRadius(SleepyTheme.fieldShape)
            // ← Android filled TextField, 无描边
        }
        .onAppear { text = "\(value)" }
    }
}

// ── issue#23 逐卡弹层 ──

/// issue#23 §2.2 候选弹层: Before 组升序 + After 组升序, 已有槽位显示默认时间,
/// 「新建」候选点击后进入 NewEdgeSlotDialog 填时间
private struct EdgeCandidatePickerDialog: View {
    @Environment(\.localWakeUpColors) private var colors
    let candidates: [TimeTableUtils.EdgeCandidate]
    let onPickExisting: (Int) -> Void
    let onPickNew: (TimeTableUtils.EdgeCandidate) -> Void
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.format("irregular_node_pick"))
                // ← AlertDialog title = headlineSmall 24sp regular
                .font(.system(size: 24))
                .foregroundColor(colors.onSurface)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(candidates, id: \.self) { c in
                        Button {
                            if c.exists { onPickExisting(c.node) } else { onPickNew(c) }
                        } label: {
                            Text(c.exists
                                 ? L10n.format("edge_node_range", c.node, c.start, c.end)
                                 : L10n.format("irregular_node_new", c.node))
                                .font(.system(size: 14))
                                .foregroundColor(c.exists ? colors.onSecondaryContainer : colors.onSurface)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(c.exists ? colors.secondaryContainer : colors.surfaceContainerHighest)
                                .cornerRadius(SleepyShapes.medium)
                        }
                        .buttonStyle(SleepyButtonStyle())
                    }
                }
            }
            HStack {
                Spacer()
                // ← AlertDialog confirmButton(cancel): labelLarge 14sp Medium, 右对齐
                Button(L10n.format("cancel")) { onDismiss() }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(colors.primary)
                    .buttonStyle(SleepyButtonStyle())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.background)
    }
}

/// issue#23: 新建槽位 — 输入起止时间后加入 pendingEdgeInserts (保存时写回课表)
private struct NewEdgeSlotDialog: View {
    @Environment(\.localWakeUpColors) private var colors
    let candidate: TimeTableUtils.EdgeCandidate
    let onConfirm: (_ start: String, _ end: String) -> Void
    let onDismiss: () -> Void
    @State private var start = ""
    @State private var end = ""

    private var valid: Bool {
        AddCourseScreen.parseHm(start) != nil && AddCourseScreen.parseHm(end) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.format("irregular_node_new_title", candidate.node))
                // ← AlertDialog title = headlineSmall 24sp regular
                .font(.system(size: 24))
                .foregroundColor(colors.onSurface)
            TimePickerField(value: start, onValueChange: { start = $0 },
                            label: L10n.format("edge_insert_start_label"))
            TimePickerField(value: end, onValueChange: { end = $0 },
                            label: L10n.format("edge_insert_end_label"))
            // ← AlertDialog 动作区: dismissButton(cancel) 在左, confirmButton(ok) 在右, 右对齐, labelLarge 14 Medium
            HStack {
                Spacer()
                Button(L10n.format("cancel")) { onDismiss() }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(colors.primary)
                    .buttonStyle(SleepyButtonStyle())
                Button(L10n.format("edge_insert_ok")) { onConfirm(start, end) }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(colors.primary)
                    .disabled(!valid)
                    .buttonStyle(SleepyButtonStyle())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.background)
    }
}

/// issue#23 §2.5: 已有槽位默认时间编辑 — 全局生效于所有引用该槽位的课程
private struct SlotEditDialog: View {
    @Environment(\.localWakeUpColors) private var colors
    let node: Int
    let initialStart: String
    let initialEnd: String
    let onConfirm: (_ start: String, _ end: String) -> Void
    let onDismiss: () -> Void
    @State private var start: String
    @State private var end: String

    init(node: Int, initialStart: String, initialEnd: String,
         onConfirm: @escaping (String, String) -> Void, onDismiss: @escaping () -> Void) {
        self.node = node
        self.initialStart = initialStart
        self.initialEnd = initialEnd
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
        _start = State(initialValue: initialStart)
        _end = State(initialValue: initialEnd)
    }

    private var valid: Bool {
        AddCourseScreen.parseHm(start) != nil && AddCourseScreen.parseHm(end) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.format("irregular_slot_edit_title", node))
                // ← AlertDialog title = headlineSmall 24sp regular
                .font(.system(size: 24))
                .foregroundColor(colors.onSurface)
            TimePickerField(value: start, onValueChange: { start = $0 },
                            label: L10n.format("edge_insert_start_label"))
            TimePickerField(value: end, onValueChange: { end = $0 },
                            label: L10n.format("edge_insert_end_label"))
            // ← AlertDialog 动作区: dismissButton(cancel) 在左, confirmButton(ok) 在右, 右对齐, labelLarge 14 Medium
            HStack {
                Spacer()
                Button(L10n.format("cancel")) { onDismiss() }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(colors.primary)
                    .buttonStyle(SleepyButtonStyle())
                Button(L10n.format("edge_insert_ok")) { onConfirm(start, end) }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(colors.primary)
                    .disabled(!valid)
                    .buttonStyle(SleepyButtonStyle())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.background)
    }
}

// ── 课程颜色选择器 ──

// ← AutoColorDot
private struct AutoColorDot: View {
    @Environment(\.localWakeUpColors) private var colors
    let selected: Bool
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            // ← AutoColorDot.kt: 选中 primaryContainer 色块, 无描边
            ZStack {
                Circle()
                    .fill(selected ? colors.primaryContainer : colors.surfaceVariant)
                    .frame(width: 32, height: 32)
                Text(L10n.format("label_from"))
                    .font(.system(size: 11))
                    .foregroundColor(selected ? colors.onPrimaryContainer : colors.onSurfaceVariant)
            }
        }
        .buttonStyle(SleepyButtonStyle())
    }
}

// ← CustomColorDot
private struct CustomColorDot: View {
    @Environment(\.localWakeUpColors) private var colors
    let hex: String?
    let onClick: () -> Void

    var body: some View {
        let c = hex.flatMap { CourseColorUtil.parseColor($0).map { Color(uiArgb: UInt32($0)) } }
            ?? colors.surfaceVariant
        Button(action: onClick) {
            // ← CustomColorDot.kt: 纯色圆 + ＋号, 无描边
            ZStack {
                Circle()
                    .fill(c)
                    .frame(width: 32, height: 32)
                if hex == nil {
                    Text("＋")
                        .font(.system(size: 16))
                        .foregroundColor(colors.onSurfaceVariant)
                }
            }
        }
        .buttonStyle(SleepyButtonStyle())
    }
}
