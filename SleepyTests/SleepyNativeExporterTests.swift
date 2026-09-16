// SleepyNativeExporterTests.swift — ← SleepyNativeExporterTest.kt (逐测试翻译, GPL-3.0)
// sleepy-v1 导出器(规范 §4/§8.1/§10): 字段级 + 字节级往返 / 散周 partition / 同名异组 token 必写 / Nd 折叠 / chk。

import XCTest
@testable import Sleepy

final class SleepyNativeExporterTests: XCTestCase {

    private func parse(_ text: String) throws -> ScheduleParser.ParseResult {
        switch ScheduleParser.parse(text, defaultTableId: 1) {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }

    private func table(name: String = "测试表", startDate: String = "2026-03-02",
                       maxWeek: Int = 20, nodesPerDay: Int = 12,
                       timeJson: String = TimeTableUtils.DEFAULT_TIME_JSON) -> TimeTableEntity {
        var t = TimeTableEntity(name: name, startDate: startDate, maxWeek: maxWeek,
                                nodesPerDay: nodesPerDay, timeJson: timeJson, isDefault: true)
        t.id = 1
        t.color = "#FF6750A4"
        return t
    }

    private func course(_ name: String, day: Int = 1, startNode: Int = 1, step: Int = 2,
                        startWeek: Int = 1, endWeek: Int = 16, type: Int = 0,
                        teacher: String = "", room: String = "", note: String = "",
                        color: String = "#FF6750A4",
                        ownTime: Bool = false, startTime: String = "", endTime: String = "",
                        groupId: String = "") -> CourseEntity {
        var c = CourseEntity(groupId: groupId, tableId: 1, courseName: name,
                             teacher: teacher, room: room, note: note, day: day,
                             startNode: startNode, step: step, startWeek: startWeek, endWeek: endWeek,
                             type: type, color: color, ownTime: ownTime,
                             startTime: startTime, endTime: endTime)
        c.groupId = groupId
        return c
    }

    // ---- 字段级往返 (§8.2) ----

    func testRoundTripMinimal() throws {
        let doc = "#sleepy-v1\nC高数|2|1-2"
        let r = try parse(doc)
        let out = SleepyNativeExporter.exportFile(tableName: r.tableName, startDate: r.startDate,
                                                  maxWeek: r.maxWeek, nodesPerDay: r.nodesPerDay,
                                                  timeJson: r.timeJson, courses: r.courses)
        let r2 = try parse(out)
        XCTAssertEqual(1, r2.courses.count)
        XCTAssertEqual(r.courses[0].courseName, r2.courses[0].courseName)
        XCTAssertEqual(r.courses[0].day, r2.courses[0].day)
        XCTAssertEqual(r.courses[0].startNode, r2.courses[0].startNode)
        XCTAssertEqual(r.courses[0].step, r2.courses[0].step)
        XCTAssertEqual(r.courses[0].startWeek, r2.courses[0].startWeek)
        XCTAssertEqual(r.courses[0].endWeek, r2.courses[0].endWeek)
        XCTAssertEqual(r.courses[0].type, r2.courses[0].type)
    }

    func testRoundTripFullTableExample3() throws {
        // §9-③ 完整示例往返(用真实 TimeTableEntity → export → parse → 等价)
        let courses = [
            course("高等数学A", day: 1, startNode: 1, step: 2, startWeek: 1, endWeek: 16, type: 0, teacher: "张三", room: "A101", color: "#FFEADDFF", groupId: "g1"),
            course("高等数学A", day: 3, startNode: 3, step: 2, startWeek: 1, endWeek: 16, type: 0, teacher: "张三", room: "B202", groupId: "g1"),
            course("大学英语", day: 2, startNode: 3, step: 2, startWeek: 1, endWeek: 15, type: 1, teacher: "李四", room: "C301", groupId: "g2"),
            course("数据结构", day: 2, startNode: 3, step: 2, startWeek: 2, endWeek: 16, type: 2, teacher: "王五", room: "C302", color: "#FF388E3C", groupId: "g3"),
            course("体育", day: 4, startNode: 5, step: 2, startWeek: 3, endWeek: 4, type: 3, teacher: "赵六", room: "田径场", groupId: "g4"),
            course("物理实验", day: 5, startNode: 8, step: 2, startWeek: 8, endWeek: 8, type: 3, teacher: "钱七", room: "实验楼501", note: "穿实验服", groupId: "g5"),
            course("Java实战", day: 4, startNode: 9, step: 3, startWeek: 1, endWeek: 16, type: 0, teacher: "孙八", room: "机房", ownTime: true, startTime: "19:00", endTime: "21:30", groupId: "g6"),
            course("电磁场", day: 2, startNode: 6, step: 2, startWeek: 1, endWeek: 8, type: 0, teacher: "周九", room: "F405", groupId: "g7"),
            course("电磁场", day: 2, startNode: 6, step: 2, startWeek: 11, endWeek: 16, type: 0, teacher: "周九", room: "F405", groupId: "g7"),
            course("影视鉴赏", day: 7, startNode: 6, step: 1, startWeek: 10, endWeek: 16, type: 2, room: "D001", note: "A|B候选", groupId: "g8")
        ]
        let out = SleepyNativeExporter.exportFile(tableName: "软件工程2026春", startDate: "2026-03-02",
            maxWeek: 20, nodesPerDay: 12,
            timeJson: "[{\"node\":1,\"start\":\"08:30\",\"end\":\"09:15\"},{\"node\":3,\"start\":\"10:00\",\"end\":\"10:45\"},{\"node\":4,\"start\":\"10:55\",\"end\":\"11:40\"},{\"node\":5,\"start\":\"14:00\",\"end\":\"14:45\"},{\"node\":7,\"start\":\"16:00\",\"end\":\"16:45\"},{\"node\":8,\"start\":\"16:55\",\"end\":\"17:40\"},{\"node\":9,\"start\":\"19:00\",\"end\":\"19:45\"},{\"node\":10,\"start\":\"19:55\",\"end\":\"20:40\"},{\"node\":11,\"start\":\"20:50\",\"end\":\"21:35\"},{\"node\":12,\"start\":\"21:45\",\"end\":\"22:30\"}]",
            courses: courses)
        // 字段级断言
        let r = try parse(out)
        XCTAssertTrue(r.droppedLines.isEmpty, "dropped=\(r.droppedLines) warnings=\(r.warnings)")
        XCTAssertTrue(r.warnings.isEmpty, "warnings=\(r.warnings)")
        XCTAssertEqual(courses.count, r.courses.count)
        // 按 (courseName|day|startNode) 复合 key 对齐后逐条断言
        func key(_ c: CourseEntity) -> String { "\(c.courseName)|\(c.day)|\(c.startNode)|\(c.startWeek)-\(c.endWeek)" }
        let inByKey = Dictionary(grouping: courses, by: key)
        let outByKey = Dictionary(grouping: r.courses, by: key)
        XCTAssertEqual(inByKey.keys.sorted(), outByKey.keys.sorted(), "keys")
        for (k, ins) in inByKey {
            guard let outs = outByKey[k] else { XCTFail("missing key \(k)"); continue }
            XCTAssertEqual(ins.count, outs.count, "key \(k) size")
            for (i, c) in ins.enumerated() {
                XCTAssertEqual(c.courseName, outs[i].courseName)
                XCTAssertEqual(c.teacher, outs[i].teacher)
                XCTAssertEqual(c.room, outs[i].room)
                XCTAssertEqual(c.note, outs[i].note)
                XCTAssertEqual(c.day, outs[i].day)
                XCTAssertEqual(c.startNode, outs[i].startNode)
                XCTAssertEqual(c.step, outs[i].step)
                XCTAssertEqual(c.startWeek, outs[i].startWeek)
                XCTAssertEqual(c.endWeek, outs[i].endWeek)
                XCTAssertEqual(c.type, outs[i].type)
                // color 归一对比
                XCTAssertEqual(c.color.uppercased(), outs[i].color.uppercased(), "key=\(k) idx=\(i) color")
            }
        }
        // 分组保真: 输入同组 → 输出同组; 输入异组 → 输出异组
        var groupMap: [String: String] = [:]  // in groupId → out groupId
        for c in courses {
            let oc = r.courses.first { key($0) == key(c) && $0.note == c.note }
            if let oc = oc {
                if let prev = groupMap[c.groupId] {
                    XCTAssertEqual(prev, oc.groupId, "group drift for \(c.groupId)")
                }
                groupMap[c.groupId] = oc.groupId
            }
        }
        // ownTime 课
        let java = r.courses.first { $0.courseName == "Java实战" }
        XCTAssertNotNil(java)
        XCTAssertTrue(java!.ownTime)
        XCTAssertEqual("19:00", java!.startTime)
        XCTAssertEqual("21:30", java!.endTime)
        // 影视鉴赏备注含 | 已转义
        let movie = r.courses.first { $0.courseName == "影视鉴赏" }
        XCTAssertEqual("A|B候选", movie?.note)
    }

    // ---- 字节级往返 (§8.2) ----

    func testByteLevelRoundTrip() throws {
        // export(parse(export(T))) == export(T)
        let t = table()
        let cs = [
            course("高数", day: 1, startNode: 1, step: 2, startWeek: 1, endWeek: 16, type: 0, teacher: "张三", room: "A101", color: "#FFEADDFF", groupId: "g1"),
            course("英语", day: 2, startNode: 3, step: 2, startWeek: 1, endWeek: 15, type: 1, teacher: "李四", room: "C301", groupId: "g2")
        ]
        let first = SleepyNativeExporter.exportFile(tableName: t.name, startDate: t.startDate,
                                                    maxWeek: t.maxWeek, nodesPerDay: t.nodesPerDay,
                                                    timeJson: t.timeJson, courses: cs)
        let parsed = try parse(first)
        let second = SleepyNativeExporter.exportFile(tableName: parsed.tableName, startDate: parsed.startDate,
                                                     maxWeek: parsed.maxWeek, nodesPerDay: parsed.nodesPerDay,
                                                     timeJson: parsed.timeJson, courses: parsed.courses)
        // 字节级相等(切掉 z 行再比较——chk 每次重算但 body 稳定)
        func stripChk(_ s: String) -> String {
            s.components(separatedBy: .newlines).filter { !$0.hasPrefix("z|") }.joined(separator: "\n")
        }
        XCTAssertEqual(stripChk(first), stripChk(second))
    }

    // ---- 散周 partition (§4) ----

    func testScatteredWeekPartition() throws {
        // type=3 区间恒真, 单实体不能表达"1-8 + 11-16", 导出端按连续段拆多行同 token
        let courses = [
            course("散课", day: 1, startNode: 1, step: 2, startWeek: 1, endWeek: 16, type: 3, groupId: "g1"),
            course("散课", day: 1, startNode: 1, step: 2, startWeek: 11, endWeek: 16, type: 3, groupId: "g1")
        ]
        let out = SleepyNativeExporter.exportFile(tableName: "t", startDate: "2026-03-02",
                                                  maxWeek: 20, nodesPerDay: 12, timeJson: "", courses: courses)
        // 应该两行同组 token
        XCTAssertTrue(out.contains("\nC散课|1|1-2|1-16定|g1\n") || out.contains("\nC散课|1|1-2|1-16定|"))
        let parsed = try parse(out)
        XCTAssertEqual(2, parsed.courses.count)
        XCTAssertEqual(parsed.courses[0].groupId, parsed.courses[1].groupId)
    }

    // ---- 同名异组强制 token (§3.4 契约二) ----

    func testSameNameDifferentGroupsMustEmitToken() throws {
        let courses = [
            course("同名", day: 1, startNode: 1, step: 1, groupId: "g1"),
            course("同名", day: 2, startNode: 1, step: 1, groupId: "g2")
        ]
        let out = SleepyNativeExporter.exportFile(tableName: "t", startDate: "2026-03-02",
                                                  maxWeek: 20, nodesPerDay: 12, timeJson: "", courses: courses)
        // 两行都必须有 token(空=按名合并会塌缩)
        let lines = out.components(separatedBy: .newlines).filter { $0.hasPrefix("C同名") }
        XCTAssertEqual(2, lines.count)
        // token 必须非空(§3.4 契约二: 同名异组必显式写 token)
        for l in lines {
            let cols = l.components(separatedBy: "|")
            XCTAssertFalse(cols.last!.isEmpty, "empty token in: \(l)")
        }
    }

    // ---- Nd 折叠 (§5) ----

    func testNdPresetCollapsed() throws {
        let out = SleepyNativeExporter.exportFile(tableName: "t", startDate: "2026-03-02",
                                                  maxWeek: 20, nodesPerDay: 12,
                                                  timeJson: TimeTableUtils.DEFAULT_TIME_JSON, courses: [])
        // 作息等于冻结预设时写 Nd
        XCTAssertTrue(out.contains("\nNd\n") || out.hasSuffix("Nd"))
        let parsed = try parse(out)
        let nodes = TimeTableUtils.parseNodes(parsed.timeJson)
        XCTAssertEqual(12, nodes.count)
    }

    func testSparseTimeTableNotCollapsedToNd() throws {
        let custom = "[{\"node\":1,\"start\":\"08:00\",\"end\":\"08:45\"}]"
        let out = SleepyNativeExporter.exportFile(tableName: "t", startDate: "2026-03-02",
                                                  maxWeek: 20, nodesPerDay: 12, timeJson: custom, courses: [])
        // 不等于冻结预设时写逐节 N 行
        XCTAssertTrue(out.contains("N1|"), "out=\(out)")
        XCTAssertFalse(out.contains("\nNd\n") || out.hasSuffix("Nd"))
    }

    // ---- chk 写入 (§8.1) ----

    func testChkWrittenInFileMode() {
        let out = SleepyNativeExporter.exportFile(tableName: "t", startDate: "2026-03-02",
                                                  maxWeek: 20, nodesPerDay: 12, timeJson: "",
                                                  courses: [course("高数")])
        XCTAssertTrue(out.contains("z|chk=crc32:"))
        XCTAssertNotNil(out.range(of: #"chk=crc32:([0-9a-f]{8})"#, options: .regularExpression))
    }

    // ---- share 形态 (§1.1, 无 chk + marker 包裹) ----

    func testShareTextWrappedNoChk() {
        let out = SleepyNativeExporter.exportShareText(tableName: "t", startDate: "2026-03-02",
                                                       maxWeek: 20, nodesPerDay: 12, timeJson: "",
                                                       courses: [course("高数")])
        XCTAssertTrue(out.hasPrefix("【来自Sleepy】"))
        XCTAssertTrue(out.contains("<<<SLEEPY-BEGIN>>>"))
        XCTAssertTrue(out.contains("<<<SLEEPY-END>>>"))
        XCTAssertFalse(out.contains("z|chk="))
    }

    // ---- 调色板输出 (规范 §3.2) ----

    func testPaletteOutputCompactIndex() {
        let c = course("课", color: "#FFEADDFF")
        let out = SleepyNativeExporter.exportFile(tableName: "t", startDate: "2026-03-02",
                                                  maxWeek: 20, nodesPerDay: 12, timeJson: "", courses: [c])
        // 第 7 列 color = 调色板索引 1
        XCTAssertTrue(out.contains("\nC课|1|1-2|1-16|||1|||\n") || out.contains("\nC课|1|1-2|1-16|||1|||"), "out=\(out)")
    }

    func testCustomHexOutput6Digit() {
        // alpha=FF 其他色 → 6 位 #RRGGBB
        let c = course("课", color: "#FF388E3C")
        let out = SleepyNativeExporter.exportFile(tableName: "t", startDate: "2026-03-02",
                                                  maxWeek: 20, nodesPerDay: 12, timeJson: "", courses: [c])
        XCTAssertTrue(out.contains("|#388E3C|"), "out=\(out)")
    }

    func testCustomHexOutput9DigitKeptForTransparency() {
        // 非 FF alpha → 9 位
        let c = course("课", color: "#80388E3C")
        let out = SleepyNativeExporter.exportFile(tableName: "t", startDate: "2026-03-02",
                                                  maxWeek: 20, nodesPerDay: 12, timeJson: "", courses: [c])
        XCTAssertTrue(out.contains("|#80388E3C|"), "out=\(out)")
    }

    func testAutoColorEmpty() {
        let c = course("课", color: "#FF6750A4")
        let out = SleepyNativeExporter.exportFile(tableName: "t", startDate: "2026-03-02",
                                                  maxWeek: 20, nodesPerDay: 12, timeJson: "", courses: [c])
        // 自动色 → 第 7 列空
        XCTAssertTrue(out.contains("\nC课|1|1-2|1-16||||||"), "out=\(out)")
    }

    // ---- 密度锚 (§10) ----

    func testByteLevelDensityAnchor() {
        // 示例① 24 B
        let out1 = SleepyNativeExporter.exportFile(tableName: "t", startDate: "2026-03-02",
                                                   maxWeek: 20, nodesPerDay: 12, timeJson: "",
                                                   courses: [course("高数", day: 2, startNode: 1, step: 2)])
        XCTAssertTrue(out1.count <= 100, "len=\(out1.count) out=\(out1)")  // 含 T 行 + chk 行也远小于 100
    }
}
