// ScheduleRepository.swift — ← ScheduleRepository.kt
// 课表仓库 — 业务数据访问的唯一入口。
//
// UI 层只调这个类,不直接碰 DAO。
// (Flow → AsyncStream/Combine 视调用方需要;先落 suspend 等价 = 同步 throws)

import Foundation
import GRDB

final class ScheduleRepository {
    private let db: AppDatabase
    private let courseDao: CourseDao
    private let tableDao: TimeTableDao
    /// ← SleepyApp.get().notificationScheduler / WidgetUpdater
    /// iOS: 数据变更回调(由 App 壳注入: 刷 WidgetKit timeline + 重排 UNNotification)
    var onDataChangedHook: (() -> Void)?

    init(_ db: AppDatabase) {
        self.db = db
        self.courseDao = db.courseDao
        self.tableDao = db.timeTableDao
    }

    // ========== Undo 快照(← captureForUndo) ==========

    /// 公开写方法执行前调用 — 拍下改动前的全库状态。
    /// 复合动作(如导入)入口先 UndoManager.shared.beginBatch(), 批内只保首个快照=动作前时点。
    private func captureForUndo() throws {
        UndoManager.shared.capture(
            tables: try tableDao.getAll(),
            courses: try courseDao.getAllCourses(),
            defaultTableId: try tableDao.getDefault()?.id
        )
    }

    /// 撤回最近一次改动: 事务内清两表→重插快照→恢复 default → 刷 widget/通知。false = 无可撤回
    @discardableResult
    func restoreLastSnapshot() throws -> Bool {
        guard let snap = UndoManager.shared.poll() else { return false }
        UndoManager.shared.restoring = true
        defer { UndoManager.shared.restoring = false }
        try db.dbQueue.write { db in
            // 先插 tables 再插 courses — courses.tableId 有外键指向 time_tables.id,
            // 顺序颠倒(先课程后课表)会触发外键约束闪退(← 安卓同款顺序注释)
            try courseDao.deleteAllInDb(db)
            try db.execute(sql: "DELETE FROM time_tables")
            for t in snap.tables { var t = t; try t.insert(db, onConflict: .replace) }
            for c in snap.courses { var c = c; try c.insert(db, onConflict: .replace) }
            if let defId = snap.defaultTableId {
                try db.execute(sql: "UPDATE time_tables SET isDefault = (id = ?)", arguments: [defId])
            }
        }
        onDataChanged()
        return true
    }

    // ========== TimeTable ==========

    func getAllTables() throws -> [TimeTableEntity] { try tableDao.getAll() }

    func getTable(_ id: Int64) throws -> TimeTableEntity? { try tableDao.getById(id) }

    func getDefaultTable() throws -> TimeTableEntity? { try tableDao.getDefault() }

    @discardableResult
    func insertTable(_ table: TimeTableEntity) throws -> Int64 {
        try captureForUndo()
        let id = try tableDao.insert(table)
        let count = try tableDao.count()
        if table.isDefault || count == 1 {
            try tableDao.setDefault(id)
        }
        return id
    }

    func updateTable(_ table: TimeTableEntity) throws {
        try captureForUndo()
        try tableDao.update(table)
        onDataChanged()
    }

    func deleteTable(_ id: Int64) throws {
        // ★ 删除前先取该表全部课程 id:外键 CASCADE 级联删课程,
        //   删完后这些 id 已不在库里,当天的课前闹钟会残留到点继续响。
        //   因此必须在删除前捕获 id 列表,删除后对这些"孤儿 id"显式取消通知。
        try captureForUndo()
        let orphanCourseIds = try courseDao.getByTable(id).map { $0.id }
        try tableDao.deleteById(id)
        if !orphanCourseIds.isEmpty {
            NotificationScheduler.shared.cancelCourseNotifications(orphanCourseIds)
        }
        onDataChanged()
    }

    func setDefault(_ id: Int64) throws {
        try tableDao.setDefault(id)
        onDataChanged()
    }

    func tableCount() throws -> Int { try tableDao.count() }

    // ========== Course ==========

    func getCourses(_ tableId: Int64) throws -> [CourseEntity] { try courseDao.getByTable(tableId) }

    func getCoursesByDay(_ tableId: Int64, day: Int) throws -> [CourseEntity] {
        try courseDao.getByTableAndDay(tableId, day: day)
    }

    func getCourse(_ id: Int64) throws -> CourseEntity? { try courseDao.getById(id) }

    @discardableResult
    func insertCourse(_ course: CourseEntity) throws -> Int64 {
        try captureForUndo()
        let id = try courseDao.insert(course)
        onDataChanged()
        return id
    }

    @discardableResult
    func insertCourses(_ courses: [CourseEntity]) throws -> [Int64] {
        // 导入时以规范化课程名为身份;时间、教师、教室只属于课程的一个时段。
        try captureForUndo()
        let withGroupIds = assignGroupIds(courses)
        let ids = try courseDao.insertAll(withGroupIds)
        onDataChanged()
        return ids
    }

    func updateCourse(_ course: CourseEntity) throws {
        try captureForUndo()
        try courseDao.update(course)
        onDataChanged()
    }

    /// 查同 groupId 下所有课程(用于编辑回填,按时段分 block)
    func getGroupCourses(_ tableId: Int64, _ groupId: String) throws -> [CourseEntity] {
        try courseDao.getByGroupId(tableId, groupId)
    }

    /// 编辑课程组:原子地删除同 groupId 全部记录并插入新草稿(DAO 层事务)
    func updateCourseGroup(_ tableId: Int64, _ groupId: String, _ newCourses: [CourseEntity]) throws {
        try captureForUndo()
        try courseDao.replaceGroup(tableId: tableId, groupId: groupId, newCourses: newCourses)
        onDataChanged()
    }

    /// issue#22 行级 diff/patch 落库 ← applyDiff(tableId, diff)
    /// Android 注释要求"调用前必须已 captureForUndo";iOS 侧 captureForUndo 是 private,
    /// 这里改为内部捕获(功能等价:撤销快照仍在写库前生成)。顺序 delete → update → insert。
    func applyDiff(_ tableId: Int64, _ diff: DiffResult) throws {
        try captureForUndo()
        if !diff.toDelete.isEmpty { try courseDao.deleteByIds(diff.toDelete) }
        if !diff.toUpdate.isEmpty { try courseDao.updateAll(diff.toUpdate) }
        if !diff.toInsert.isEmpty { try courseDao.insertAll(diff.toInsert) }
        onDataChanged()
    }

    /// 改组色(issue#22 spec §6.2 "改组色"按钮的落库路径):
    /// 把选中色写到同 groupId 所有 colorMode=GROUP 行的 color 字段。
    ///
    /// 只动 GROUP 行 — AUTO 行 hue 源来自组色源(groupSourceColorHex),组色变则
    /// 自动行跟着变(spec §5.2"组色变则自动跟随"),不需要写;CUSTOM 行独立色不跟组。
    /// 落所有 GROUP 行而非只落最小 id 行:避免 RowKeyDiffer 把未改 GROUP 行 diff 出假更新。
    func setGroupSourceColor(_ tableId: Int64, _ groupId: String, _ hex: String) throws {
        try captureForUndo()
        if groupId.trimmingCharacters(in: .whitespaces).isEmpty { return }
        let group = try courseDao.getByGroupId(tableId, groupId)
            .filter { $0.colorMode == CourseColorMode.GROUP }
        if group.isEmpty { return }
        var rows = group
        for i in rows.indices { rows[i].color = hex }
        try courseDao.updateAll(rows)
        onDataChanged()
    }

    func deleteCourse(_ id: Int64) throws {
        try captureForUndo()
        try courseDao.deleteById(id)
        onDataChanged()
    }

    /// 删除同 groupId 全部记录
    func deleteCourseGroup(_ tableId: Int64, _ groupId: String) throws {
        try captureForUndo()
        try courseDao.deleteByGroupId(tableId, groupId)
        onDataChanged()
    }

    func countCourses(_ tableId: Int64) throws -> Int { try courseDao.countByTable(tableId) }

    func totalCourseCount() throws -> Int { try courseDao.totalCount() }

    /// 覆盖式导入(先删后插)
    func replaceCourses(_ tableId: Int64, _ courses: [CourseEntity]) throws {
        try captureForUndo()
        let withGroupIds = assignGroupIds(courses)
        try courseDao.replaceAll(tableId: tableId, courses: withGroupIds)
        onDataChanged()
    }

    /// sleepy-v1 (§3.4 契约一): groupId 已由解析端权威生成(按文档内 token 分区),
    /// 落库绕过 assignGroupIds — 否则同名不同 token 的分区会被静默合并, 分区往返被破坏。
    @discardableResult
    func insertCoursesKeepingGroups(_ courses: [CourseEntity]) throws -> [Int64] {
        try captureForUndo()
        let ids = try courseDao.insertAll(courses)
        onDataChanged()
        return ids
    }

    /// 覆盖式导入(保留解析端 groupId), 配合 insertCoursesKeepingGroups 的 sleepy-v1 路径
    func replaceCoursesKeepingGroups(_ tableId: Int64, _ courses: [CourseEntity]) throws {
        try captureForUndo()
        try courseDao.replaceAll(tableId: tableId, courses: courses)
        onDataChanged()
    }

    /// 数据变更后:刷新所有 widget,并在提醒开启时重排通知。
    /// ★ 修复(继承自 Android):之前只刷 widget 不重排通知,导致编辑课表后课前提醒仍按旧时间。
    private func onDataChanged() {
        pruneDefaultTopPrefs()
        onDataChangedHook?()
    }

    /// v7.10.16p: 课程集变化后清理指向已失效课程的置顶偏好 — repId 已删/键已不存在
    /// (锚课被删·簇解体)的条目静默失效还会画出幽灵图层选项, 按现存课全量校验删除。
    /// 删课/删组/覆盖导入/撤销四条写路径都会走到(全部收敛于 onDataChanged)。
    /// 用户报障 2026-09-10: liveKeys 与网格聚簇同一时间域, 偏好不被节点域误删。
    private func pruneDefaultTopPrefs() {
        let stored = AppPrefs.shared.getConflictDefaultTop()
        if stored.isEmpty { return }
        guard let allCourses = try? courseDao.getAllCourses() else { return }
        let timeJson = try? tableDao.getDefault()?.timeJson
        let pruned = ConflictLayoutEngine.pruneConflictDefaultTop(
            stored, allCourses, timeJson: timeJson ?? nil)
        if pruned.count != stored.count {
            AppPrefs.shared.setConflictDefaultTop(pruned)
        }
    }

    // ========== Flow 观察 ← observeAllTables / observeCourses(Room Flow) ==========

    /// Room Flow → GRDB ValueObservation(Combine Publisher)。
    /// 数据库任何写操作后自动 emit 最新列表(表列表/课程列表各自观察)。

    func observeAllTables() -> DatabasePublishers.Value<[TimeTableEntity]> {
        ValueObservation
            .tracking { db in try TimeTableEntity.fetchAll(db, sql: "SELECT * FROM time_tables ORDER BY createdAt DESC") }
            .publisher(in: db.dbQueue)
    }

    func observeCourses(_ tableId: Int64) -> DatabasePublishers.Value<[CourseEntity]> {
        ValueObservation
            .tracking { db in try CourseEntity.fetchAll(db, sql: "SELECT * FROM courses WHERE tableId = ? ORDER BY day, startNode, startWeek", arguments: [tableId]) }
            .publisher(in: db.dbQueue)
    }

    private func assignGroupIds(_ courses: [CourseEntity]) -> [CourseEntity] {
        var nameToGroupId: [String: String] = [:]
        return courses.map { c in
            // ← courseName.trim().replace(Regex("\\s+"), " ").lowercase()
            let key = c.courseName.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
                .lowercased()
            let gid: String
            if let existing = nameToGroupId[key] {
                gid = existing
            } else {
                let newGid = !c.groupId.isEmpty ? c.groupId : UUID().uuidString
                nameToGroupId[key] = newGid
                gid = newGid
            }
            var copy = c
            copy.groupId = gid
            return copy
        }
    }
}
