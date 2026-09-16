// SleepyNativeParserTests.swift — ← SleepyNativeParserTest.kt (逐测试翻译, GPL-3.0)
// sleepy-v1 解析器测试(规范 §3/§4/§5/§7):
// 示例①②③字段级断言 / 三态处置 / 上报双通道 / groupId 分区 / 空表二分 / 重复行 / 全角次级分隔。

import XCTest
@testable import Sleepy

final class SleepyNativeParserTests: XCTestCase {

    private func parse(_ text: String) throws -> ScheduleParser.ParseResult {
        switch ScheduleParser.parse(text, defaultTableId: 7, defaultColor: "#FF6750A4") {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }

    private func parseResult(_ text: String) -> Result<ScheduleParser.ParseResult, Error> {
        ScheduleParser.parse(text, defaultTableId: 7, defaultColor: "#FF6750A4")
    }

    // ---- 示例① 最小单课 (§9-①) ----

    func testMinimalSingleCourseDefaults() throws {
        let r = try parse("#sleepy-v1\nC高数|2|1-2")
        XCTAssertEqual(1, r.courses.count)
        let c = r.courses[0]
        XCTAssertEqual("高数", c.courseName)
        XCTAssertEqual(2, c.day)
        XCTAssertEqual(1, c.startNode)
        XCTAssertEqual(2, c.step)
        XCTAssertEqual(1, c.startWeek)      // 缺省 1-16 type 3
        XCTAssertEqual(16, c.endWeek)
        XCTAssertEqual(3, c.type)
        XCTAssertEqual("", c.teacher)
        XCTAssertEqual("", c.room)
        XCTAssertEqual(SleepyNativeFormat.AUTO_COLOR, c.color)
        XCTAssertFalse(c.ownTime)
        XCTAssertTrue(r.droppedLines.isEmpty)
        XCTAssertTrue(r.warnings.isEmpty)
        XCTAssertTrue(r.groupIdsAuthoritative)
    }

    // ---- 示例② 全字段单课 (§9-②) ----

    func testFullFieldCourse() throws {
        let r = try parse("#sleepy-v1\nT测试表|2026-03-02|20|12|n=1\nC高等数学A|1|1-2|1-16|张三|A101|1|带习题册|19:00-21:30|7")
        XCTAssertEqual(1, r.courses.count)
        let c = r.courses[0]
        XCTAssertEqual("张三", c.teacher)
        XCTAssertEqual("A101", c.room)
        XCTAssertEqual("#FFEADDFF", c.color)   // 调色板 1 → 8 位规范形
        XCTAssertEqual("带习题册", c.note)
        XCTAssertTrue(c.ownTime)
        XCTAssertEqual("19:00", c.startTime)
        XCTAssertEqual("21:30", c.endTime)
        XCTAssertEqual("测试表", r.tableName)
        XCTAssertEqual("2026-03-02", r.startDate)
        XCTAssertEqual(20, r.maxWeek)
        XCTAssertEqual(12, r.nodesPerDay)
    }

    // ---- 示例③ 完整表: 覆盖全部周类型与散周 partition (§9-③) ----

    func testFullTableAllWeekTypes() throws {
        let doc = """
            #sleepy-v1
            T软件工程2026春|2026-03-02|20|12|n=10
            N1|08:30|09:15
            N9|19:00|19:45
            C高等数学A|1|1-2|1-16|张三|A101|1|带好习题册||1
            C高等数学A|3|3-4|1-16|张三|B202||||1
            C大学英语|2|3-4|1-15单|李四|C301||||2
            C数据结构|2|3-4|2-16双|王五|C302|#388E3C|||3
            C体育|4|5-6|3-4定|赵六|田径场||||
            C物理实验|5|8-9|8定|钱七|实验楼501||穿实验服||
            CJava实战|4|9-11|1-16|孙八|机房|||19:00-21:30|4
            C电磁场|2|6-7|1-8|周九|F405||||9
            C电磁场|2|6-7|11-16|周九|F405||||9
            C影视鉴赏|7|6|10-16双||D001||A\\|B候选||
            """
        let r = try parse(doc)
        XCTAssertEqual(10, r.courses.count)
        XCTAssertTrue(r.droppedLines.isEmpty)
        XCTAssertTrue(r.warnings.isEmpty)
        let byWeekType = Dictionary(grouping: r.courses, by: { $0.type })
        XCTAssertEqual(Set([0, 1, 2, 3]), Set(byWeekType.keys))
        // type 1 单周
        let eng = byWeekType[1]!.first!
        XCTAssertEqual("大学英语", eng.courseName)
        XCTAssertEqual(1, eng.startWeek); XCTAssertEqual(15, eng.endWeek)
        // type 3 区间(体育)
        let pe = r.courses.first { $0.courseName == "体育" }!
        XCTAssertEqual(3, pe.startWeek); XCTAssertEqual(4, pe.endWeek); XCTAssertEqual(3, pe.type)
        // type 3 单值(物理实验 8定)
        let lab = r.courses.first { $0.courseName == "物理实验" }!
        XCTAssertEqual(8, lab.startWeek); XCTAssertEqual(8, lab.endWeek); XCTAssertEqual(3, lab.type)
        // 散周两行同组 token 9
        let em = r.courses.filter { $0.courseName == "电磁场" }
        XCTAssertEqual(2, em.count)
        XCTAssertEqual(em[0].groupId, em[1].groupId)
        XCTAssertEqual(1, em[0].startWeek); XCTAssertEqual(8, em[0].endWeek)
        XCTAssertEqual(11, em[1].startWeek); XCTAssertEqual(16, em[1].endWeek)
        // 稀疏作息: 只声明 N1/N9
        XCTAssertEqual(2, TimeTableUtils.parseNodes(r.timeJson).count)
        // 备注竖线转义
        XCTAssertEqual("A|B候选", r.courses.first { $0.courseName == "影视鉴赏" }!.note)
        // ownTime
        let java = r.courses.first { $0.courseName == "Java实战" }!
        XCTAssertTrue(java.ownTime); XCTAssertEqual("19:00", java.startTime); XCTAssertEqual("21:30", java.endTime)
        // 同名同组(高数两行 token 1)
        let math = r.courses.filter { $0.courseName == "高等数学A" }
        XCTAssertEqual(2, math.count)
        XCTAssertEqual(math[0].groupId, math[1].groupId)
    }

    // ---- 三态处置 (§7.2) ----

    func testEmptyMeansDefaultNoReport() throws {
        // 空列 = 默认, 不上报
        let r = try parse("#sleepy-v1\nC课|||||||||")
        XCTAssertEqual(1, r.courses.count)
        XCTAssertEqual(1, r.courses[0].day)
        XCTAssertTrue(r.warnings.isEmpty)
    }

    func testOutOfRangeClampedAndReported() throws {
        // day 0/8 → 钳 1/7 + 整行入 droppedLines(已入库行也上报 §7.3)
        let r = try parse("#sleepy-v1\nC甲|0|1-2|1-16\nC乙|8|1-2|1-16\nC丙|9|1-2|1-16")
        XCTAssertEqual(3, r.courses.count)
        XCTAssertEqual(1, r.courses[0].day)
        XCTAssertEqual(7, r.courses[1].day)
        XCTAssertEqual(7, r.courses[2].day)
        XCTAssertFalse(r.droppedLines.isEmpty)
    }

    func testIllegalShapeLineDropped() throws {
        let r = try parse("#sleepy-v1\nC好课|1|1-2|1-16\nC坏课|张三|1-2|1-16\nC好课2|1|1-2|1-16")
        XCTAssertEqual(2, r.courses.count)
        XCTAssertEqual(1, r.droppedLines.count)
        XCTAssertTrue(r.droppedLines[0].contains("坏课"))
    }

    func testNoNameLineDropped() {
        // 名称是行存在性的唯一充分条件 → 空 = 整行丢弃(全丢 → failure §7.8)
        let result = parseResult("#sleepy-v1\nC|1|1-2|1-16")
        guard case .failure(let e) = result else { XCTFail("应失败"); return }
        XCTAssertTrue(e.localizedDescription.contains("没进去") || e.localizedDescription.contains("未能"))
    }

    func testReversedNodeAndWeekSwappedAndReported() throws {
        let r = try parse("#sleepy-v1\nC甲|1|4-3|16-1")
        XCTAssertEqual(1, r.courses.count)
        XCTAssertEqual(3, r.courses[0].startNode)
        XCTAssertEqual(2, r.courses[0].step)
        XCTAssertEqual(1, r.courses[0].startWeek)
        XCTAssertEqual(16, r.courses[0].endWeek)
        XCTAssertFalse(r.droppedLines.isEmpty)
    }

    func testIllegalTimeSpanTimeDroppedCourseKept() throws {
        // 时间列非法 → ownTime=false 课程仍按节点落位 + 上报, 不产生幽灵课不弃行
        let r = try parse("#sleepy-v1\nC晚课|1|9-10|1-16||||||25:00-26:00\nC晚课|2|9-10|1-16||||||19:00-18:00")
        XCTAssertEqual(2, r.courses.count)
        XCTAssertTrue(r.courses.allSatisfy { !$0.ownTime }, "ownTime=\(r.courses.map { $0.ownTime }) dropped=\(r.droppedLines)")
    }

    func testWeekBeyondMaxWeekKeptNotClamped() throws {
        // maxWeek 是显示视野: 越过头表不钳不改(对照 P2 "endWeek=23 被困")
        let r = try parse("#sleepy-v1\nT|2026-03-02|20|12\nC长周课|1|1-2|1-23")
        XCTAssertEqual(23, r.courses[0].endWeek)
        XCTAssertTrue(r.warnings.isEmpty)
    }

    func testUnknownWeekSuffixType0WithReport() {
        // 未知后缀 → 形状非法, 整行丢弃, 单条 C 行即"全丢"→failure (§7.8)
        let result = parseResult("#sleepy-v1\nC甲|1|1-2|1-16x")
        guard case .failure = result else { XCTFail("应失败"); return }
    }

    // ---- 上报双通道 (§7.3) ----

    func testTRowClampGoesToWarnings() throws {
        let r = try parse("#sleepy-v1\nT|2026-13-99|99|999")
        // 坏日期→今天(warnings), maxWeek 99→钳 60(warnings), nodesPerDay 999→钳 30(warnings)
        XCTAssertGreaterThanOrEqual(r.warnings.count, 3)
        XCTAssertTrue(r.warnings.contains { $0.contains("maxWeek") || $0.contains("周数") })
    }

    func testNodeReachRaisesNodesPerDayWithWarning() throws {
        let r = try parse("#sleepy-v1\nT|2026-03-02|20|12\nC高节次课|1|13-15|1-16")
        XCTAssertEqual(15, r.nodesPerDay)   // 抬升不钳课程
        XCTAssertTrue(r.warnings.contains { $0.contains("13") || $0.contains("节") })
    }

    // ---- groupId 分区 (§3.4) ----

    func testSameNameEmptyTokenShareGroup() throws {
        let r = try parse("#sleepy-v1\nC甲课|1|1-2|1-16\nC甲课|2|3-4|1-16\nC乙课|3|1-2|1-16")
        XCTAssertEqual(r.courses[0].groupId, r.courses[1].groupId)
        XCTAssertNotEqual(r.courses[0].groupId, r.courses[2].groupId)
    }

    func testDistinctTokensSameNameNotMerged() throws {
        // 同名异组: token 不同 → 分区不塌缩
        let r = try parse("#sleepy-v1\nC同名课|1|1-2|1-16||||||1\nC同名课|2|3-4|1-16||||||2")
        XCTAssertNotEqual(r.courses[0].groupId, r.courses[1].groupId)
    }

    func testGroupIdDeterministic() throws {
        let doc = "#sleepy-v1\nC甲|1|1-2|1-16||||||5"
        let a = try parse(doc).courses[0].groupId
        let b = try parse(doc).courses[0].groupId
        XCTAssertEqual(a, b)
        // 确定性 UUID 形态
        XCTAssertEqual(36, a.count)
    }

    // ---- 作息 (§5) ----

    func testNdPresetExpands() throws {
        let r = try parse("#sleepy-v1\nNd\nC高数|1|1-2|1-16")
        XCTAssertEqual(12, TimeTableUtils.parseNodes(r.timeJson).count)
        XCTAssertEqual(12, r.nodesPerDay)
    }

    func testNdPlusOverrideMerges() throws {
        // Nd + 后续 N 行覆盖合并(手改友好)
        let r = try parse("#sleepy-v1\nNd\nN3|10:20|11:05\nC高数|1|1-2|1-16")
        let nodes = TimeTableUtils.parseNodes(r.timeJson)
        XCTAssertEqual(12, nodes.count)
        let cal = Calendar(identifier: .gregorian)
        let n3 = nodes.first { $0.node == 3 }!
        XCTAssertEqual(10 * 60 + 20, cal.component(.hour, from: n3.start) * 60 + cal.component(.minute, from: n3.start))
    }

    func testIllegalNodeLineDropped() throws {
        let r = try parse("#sleepy-v1\nNabc|08:00|08:45\nN2|xx|yy\nN3|09:00|08:00\nC高数|1|1-2|1-16")
        XCTAssertEqual(1, r.courses.count)
        XCTAssertEqual(3, r.droppedLines.count)
    }

    func testDuplicateNodeNumberFirstWins() throws {
        let r = try parse("#sleepy-v1\nN1|08:00|08:45\nN1|09:00|09:45\nC高数|1|1-2|1-16")
        let nodes = TimeTableUtils.parseNodes(r.timeJson)
        XCTAssertEqual(1, nodes.count)
        let cal = Calendar(identifier: .gregorian)
        XCTAssertEqual(8 * 60, cal.component(.hour, from: nodes[0].start) * 60 + cal.component(.minute, from: nodes[0].start))
        XCTAssertFalse(r.droppedLines.isEmpty)
    }

    // ---- 识别集成/杂项 (§6.3, §7) ----

    func testV2DocumentRejectedExplicitly() {
        let result = parseResult("#sleepy-v2\nC高数|1|1-2")
        guard case .failure(let e) = result else { XCTFail("应失败"); return }
        XCTAssertTrue(e.localizedDescription.contains("升级"))
    }

    func testSecondMagicInDroppedWithWarning() throws {
        let r = try parse("#sleepy-v1\nC甲|1|1-2|1-16\n#sleepy-v1\nT第二张表\nC乙|2|1-2|1-16")
        XCTAssertEqual(2, r.courses.count)
        XCTAssertTrue(r.warnings.contains { $0.contains("第 2 张") || $0.contains("2 张") || $0.contains("表头") },
                      "courses=\(r.courses.count) dropped=\(r.droppedLines) warnings=\(r.warnings)")
    }

    func testDuplicateLinesDedupedSecondDropped() throws {
        let r = try parse("#sleepy-v1\nC高数|1|1-2|1-16\nC高数|1|1-2|1-16")
        XCTAssertEqual(1, r.courses.count)
        XCTAssertEqual(1, r.droppedLines.count)
    }

    func testFullWidthPipeSecondarySeparatorOnlyWhenOneShort() throws {
        // 全角｜当次级分隔符: 恰差 1 列时重切; 合法含｜的课名不受影响
        let r = try parse("#sleepy-v1\nC物理课|周一|1-2|1-16")
        XCTAssertEqual(1, r.courses.count)
        XCTAssertEqual("物理课", r.courses[0].courseName)
        XCTAssertEqual(1, r.courses[0].day)
        // 列数正确时｜是文本一部分
        let r2 = try parse("#sleepy-v1\nCA｜B课|1|1-2|1-16")
        XCTAssertEqual("A｜B课", r2.courses[0].courseName)
    }

    func testCrcMismatchWarnsButImports() throws {
        // z 行 chk 不符 → 警告不硬拒
        let r = try parse("#sleepy-v1\nC高数|1|1-2|1-16\nz|chk=crc32:deadbeef")
        XCTAssertEqual(1, r.courses.count)
        XCTAssertTrue(r.warnings.contains { $0.contains("校验") || $0.contains("完整性") })
    }

    func testNMismatchWarns() throws {
        let r = try parse("#sleepy-v1\nT表|2026-03-02|20|12|n=5\nC高数|1|1-2|1-16")
        XCTAssertTrue(r.warnings.contains { $0.contains("n=") || $0.contains("计数") })
    }

    func testEmptyTableMagicOnlyIsSuccessZeroCourses() throws {
        let r = try parse("#sleepy-v1\nT空表备份|2026-03-02|20|12")
        XCTAssertEqual(0, r.courses.count)
        XCTAssertEqual("空表备份", r.tableName)
        XCTAssertTrue(r.droppedLines.isEmpty,
                      "tableName=\(r.tableName) courses=\(r.courses.count) dropped=\(r.droppedLines) warnings=\(r.warnings)")
    }

    func testAllCourseLinesDroppedIsFailure() {
        let result = parseResult("#sleepy-v1\nC|1|1-2\nC坏|xyz")
        guard case .failure(let e) = result else { XCTFail("应失败"); return }
        XCTAssertTrue(e.localizedDescription.contains("没进去") || e.localizedDescription.contains("未能"))
    }

    func testGbkGarbageFailsLoudWithEncodingCause() throws {
        // GBK 字节按 UTF-8 读 → U+FFFD → magic 仍命中(ASCII), 但 C 行名称成乱码
        // 断言: 不静默导入完整课程, 至少 dropped 或 dropped 行数与原 C 行数对得上
        // (Swift 无 GBK 编码直转, 用 U+FFFD 手工构造等价形态)
        let garbled = "#sleepy-v1\nC\u{FFFD}\u{FFFD}\u{FFFD}|1|1-2|1-16"
        let result = parseResult(garbled)
        if case .success(let pr) = result {
            // 全丢→失败 / 部分丢→警告 — 但绝不能"1 条 C 课完整入库当成功"
            XCTAssertTrue(pr.courses.isEmpty || !pr.droppedLines.isEmpty,
                          "courses=\(pr.courses.count) dropped=\(pr.droppedLines)")
        }
        // failure 也满足(§7.8 全丢语义)
    }

    func testCommentAndBlankLinesIgnored() throws {
        let r = try parse("#sleepy-v1\n# 这是注释\n\nC高数|1|1-2|1-16\n")
        XCTAssertEqual(1, r.courses.count)
        XCTAssertTrue(r.droppedLines.isEmpty)
    }

    func testUnknownLineInDropped() throws {
        let r = try parse("#sleepy-v1\nC高数|1|1-2|1-16\nX未知行类型|数据")
        XCTAssertEqual(1, r.courses.count)
        XCTAssertEqual(1, r.droppedLines.count)
    }

    func testTrailingExtraColumnsIgnoredV2Contract() throws {
        let r = try parse("#sleepy-v1\nC高数|1|1-2|1-16|||||||v2未来列|再来一列")
        XCTAssertEqual(1, r.courses.count)
        XCTAssertEqual("高数", r.courses[0].courseName)
    }

    func testCaseInsensitivePrefixes() throws {
        let r = try parse("#sleepy-v1\nt表名|2026-03-02|20|12\nc高数|1|1-2|1-16")
        XCTAssertEqual("表名", r.tableName)
        XCTAssertEqual(1, r.courses.count)
    }

    func testTRowAfterCoursesStillApplies() throws {
        // 两遍解析: T 行后置也生效
        let r = try parse("#sleepy-v1\nC高数|1|1-2|1-16\nT后置表|2026-03-02|18|14")
        XCTAssertEqual("后置表", r.tableName)
        XCTAssertEqual(18, r.maxWeek)
        XCTAssertEqual(14, r.nodesPerDay)
    }

    func testStartDateNonMondayNormalizedSilently() throws {
        let r = try parse("#sleepy-v1\nT表|2026-03-04|20|12")  // 周三
        XCTAssertEqual("2026-03-02", r.startDate)
        XCTAssertTrue(r.warnings.isEmpty)  // 归一不算钳制不上报
    }

    func testMarkerWrappedNativeDocDetected() throws {
        // 分享包裹形态: marker 剥除后 magic 露出
        let text = "转换结果：\n<<<SLEEPY-BEGIN>>>\n#sleepy-v1\nC高数|1|1-2|1-16\n<<<SLEEPY-END>>>"
        let r = try parse(text)
        XCTAssertEqual(1, r.courses.count)
    }

    // ---- issue#26 课程别名(可选第 11 列) ----

    func testAliasRoundTrip() throws {
        // 写入第 11 列 → 读回 alias; 空别名不写列(向后兼容)
        let r = try parse("#sleepy-v1\nC高数|1|1-2|1-16|||||||高数(甲班)")
        XCTAssertEqual(1, r.courses.count)
        XCTAssertEqual("高数(甲班)", r.courses[0].alias)
        let r2 = try parse("#sleepy-v1\nC高数|1|1-2|1-16||||||")
        XCTAssertEqual("", r2.courses[0].alias)
    }
}
