// JwBoyaPpParserTests.swift — ← JwBoyaPpParserTest.kt (逐用例)
//
// 博雅研究生平台解析器测试。
//
// 数据源: 燕山大学研究生平台 (yjsxt.ysu.edu.cn/pp, 2026-09-06)。
// byStudent 逐周实采 (周 1..19 并集 390 行 — 无参请求实测为不完整子集)
// 按 5 门课抽周裁剪至 56 行, 期望值由真实行预演得出, 并与页面渲染 DOM
// (第 2 周视图) 逐格比对通过。研究生集中授课特点: 同课不同周可能落在
// 不同节次/教室 (材料与化工现代研究方法 day6 第 2 周占 5-8 节、第 5-7 周
// 占 5-6 节、第 6 周另占 3-4 节), 等周次集合合并规则把它们拆成独立课块。

import XCTest
@testable import Sleepy

final class JwBoyaPpParserTests: XCTestCase {

    private func loadFixture() throws -> String {
        let bundle = Bundle(for: JwBoyaPpParserTests.self)
        guard let url = bundle.url(forResource: "ysu-2026-2027-1", withExtension: "json")
            ?? bundle.url(forResource: "ysu-2026-2027-1", withExtension: "json", subdirectory: "resources") else {
            XCTFail("测试资源 ysu-2026-2027-1.json 应存在")
            throw NSError(domain: "test", code: 1)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func parse(_ source: String? = nil) throws -> [JwCourse] {
        try JwBoyaPpParser(source ?? loadFixture()).generateCourseList()
    }

    /// 从 fixture 抽 rows 数组原文 (供裸数组/信封形态变体测试)
    private func extractRowsForTest(_ source: String) throws -> String {
        guard let data = source.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["rows"] as? [Any] else {
            XCTFail("fixture 应有 rows 数组")
            throw NSError(domain: "test", code: 2)
        }
        let out = try JSONSerialization.data(withJSONObject: rows, options: [])
        return String(data: out, encoding: .utf8) ?? "[]"
    }

    func testParses56RowsInto18CourseBlocks() throws {  // ← `parses 56 rows into 18 course blocks`
        XCTAssertEqual(18, try parse().count)
    }

    func testConsecutiveSinglePeriodRowsMergeIntoContinuousBlock() throws {
        // ← `consecutive single-period rows merge into continuous block`
        // 心理健康教育专题: day2 节 5/6/7/8 各一行 (week 2) → 5-8 连堂
        let c = try parse().first { $0.name == "心理健康教育专题" }
        XCTAssertNotNil(c)
        XCTAssertEqual(2, c?.day)
        XCTAssertEqual(5, c?.startNode)
        XCTAssertEqual(8, c?.endNode)
        XCTAssertEqual(2, c?.startWeek)
        XCTAssertEqual(2, c?.endWeek)
        XCTAssertEqual(0, c?.type)
        XCTAssertEqual("李亚蕾", c?.teacher)
        XCTAssertEqual("西(四)201多媒体", c?.room)
    }

    func testGappedWeekSetSplitsIntoTwoRunsOfSameSlot() throws {  // ← `gapped week set splits into two runs of same slot`
        // 新时代 (weeks 裁剪为 2,3,10): day1 5-6 → [2-3] + [10] 两段
        let cs = try parse().filter { $0.name == "新时代中国特色社会主义理论与实践" && $0.day == 1 }
        XCTAssertEqual(2, cs.count)
        let cont = cs.first { $0.startWeek == 2 }
        XCTAssertEqual(3, cont?.endWeek)
        XCTAssertEqual(0, cont?.type)
        let gap = cs.first { $0.startWeek == 10 }
        XCTAssertEqual(10, gap?.endWeek)
        XCTAssertEqual(5, gap?.startNode)
        XCTAssertEqual(6, gap?.endNode)
        XCTAssertEqual("何茜曦", cs[0].teacher)
        XCTAssertEqual("（里）J207多媒体", cs[0].room)
    }

    func testSameSlotAcrossDifferentWeeksStaysSplitWhenNodeRangesDiffer() throws {
        // ← `same slot across different weeks stays split when node ranges differ`
        // 集中授课: 材料 day6 第2周占 5-8 节(拆 5-6/7-8 两块), 第5-7周占 5-6 节, 第6周另占 3-4 节
        let cs = try parse().filter { $0.name == "材料与化工现代研究方法" && $0.day == 6 }
        XCTAssertEqual(5, cs.count)
        XCTAssertTrue(cs.contains { $0.startNode == 3 && $0.endNode == 4 && $0.startWeek == 6 && $0.endWeek == 6 })
        XCTAssertTrue(cs.contains { $0.startNode == 5 && $0.endNode == 6 && $0.startWeek == 2 && $0.endWeek == 2 })
        XCTAssertTrue(cs.contains { $0.startNode == 5 && $0.endNode == 6 && $0.startWeek == 5 && $0.endWeek == 7 })
        XCTAssertTrue(cs.contains { $0.startNode == 7 && $0.endNode == 8 && $0.startWeek == 2 && $0.endWeek == 2 })
        XCTAssertTrue(cs.contains { $0.startNode == 7 && $0.endNode == 8 && $0.startWeek == 5 && $0.endWeek == 5 })
        XCTAssertEqual("田克松", cs[0].teacher)
    }

    func testSameCourseDifferentRoomsStaySeparateBlocks() throws {
        // ← `same course different rooms stay separate blocks`
        // 高等催化原理: day3 9-12 @AD401 与 day7 9-12 @J105, weeks 裁剪为 2,7 → 各拆 2 段
        let cs = try parse().filter { $0.name == "高等催化原理" }
        XCTAssertEqual(4, cs.count)
        let d3 = cs.filter { $0.day == 3 }
        XCTAssertEqual(2, d3.count)
        XCTAssertTrue(d3.allSatisfy { $0.startNode == 9 && $0.endNode == 12 && $0.room == "（里）AD401" })
        let d7 = cs.filter { $0.day == 7 }
        XCTAssertEqual(2, d7.count)
        XCTAssertTrue(d7.allSatisfy { $0.room == "（里）J105" })
        XCTAssertEqual("张亚茹", d3[0].teacher)
    }

    func testSuspensionRowsAreExcluded() throws {  // ← `suspension rows are excluded`
        XCTAssertTrue(try parse().allSatisfy { $0.name != "测试停课课" })
    }

    func testStringWhichWeekToleratedAndEmptyRoomFallsBackToCode() throws {
        // ← `string whichWeek is tolerated and empty room falls back to classroomCode`
        let c = try parse().first { $0.name == "测试字符串周次课" }
        XCTAssertNotNil(c)
        XCTAssertEqual(4, c?.day)
        XCTAssertEqual(3, c?.startNode)
        XCTAssertEqual(6, c?.startWeek)
        XCTAssertEqual("999888", c?.room)
        XCTAssertEqual("李四", c?.teacher)
    }

    func testTeacherNamesAreJoinedAndDeduplicated() throws {  // ← `teacher names are joined and deduplicated`
        let cs = try parse().filter { $0.name == "学科前沿专题" }
        XCTAssertTrue(!cs.isEmpty)
        // 真实行: 单教师 钟金玲, 两个课块教师一致
        for c in cs {
            XCTAssertEqual("钟金玲", c.teacher)
        }
    }

    func testRawBareArrayFormParsesLikeWrappedForm() throws {  // ← `raw bare-array form parses like wrapped form`
        // byStudent 不带信封时 data 就是裸数组 — 同一批行应得到同样结果
        let bare = try extractRowsForTest(loadFixture())
        XCTAssertEqual(18, try JwBoyaPpParser(bare).generateCourseList().count)
    }

    func testCodeEnvelopeFormParsesLikeFetchForm() throws {  // ← `code-envelope form parses like fetch form`
        // 完整 {code,data} 信封形态 (fetch JS 已剥壳, 兜底容忍)
        let envelope = """
            {"code":200,"message":"操作成功","data":\(try extractRowsForTest(loadFixture()))}
            """
        XCTAssertEqual(18, try JwBoyaPpParser(envelope).generateCourseList().count)
    }

    func testNonJsonGarbageYieldsEmptyListNotCrash() throws {  // ← `non-json garbage yields empty list not crash`
        XCTAssertTrue(try JwBoyaPpParser("<html>404</html>").generateCourseList().isEmpty)
        XCTAssertTrue(try JwBoyaPpParser("").generateCourseList().isEmpty)
        XCTAssertTrue(try JwBoyaPpParser("{\"code\":200,\"data\":[]}").generateCourseList().isEmpty)
    }

    func testConfidenceIsHighOnlyForBoyaAnchors() throws {  // ← `confidence is high only for boya anchors`
        XCTAssertTrue(JwBoyaPpParser(try loadFixture()).confidenceValue >= 80)
        XCTAssertEqual(0, JwBoyaPpParser("{\"kbList\":[]}").confidenceValue)
    }
}
