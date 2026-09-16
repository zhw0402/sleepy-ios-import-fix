// JwUcasParserTests.swift — ← JwUcasParserTest.kt (逐用例)
//
// UCAS (中国科学院大学) 解析器测试: JSON 权威路径 (ldiex 位图协议) +
// HTML 网格回退路径 + v1.2 采集包详情页 exact-week enrich。

import XCTest
@testable import Sleepy

final class JwUcasParserTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> String {
        let bundle = Bundle(for: JwUcasParserTests.self)
        guard let url = bundle.url(forResource: name, withExtension: ext)
            ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "resources") else {
            XCTFail("测试资源 \(name).\(ext) 应存在")
            throw NSError(domain: "test", code: 1)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func htmlFixture() throws -> String { try fixture("person-schedule.sample", "html") }
    private func jsonFixture() throws -> String { try fixture("course-time-list.sample", "json") }
    private func detailFixture(_ name: String) throws -> String { try fixture(name, "html") }

    /// ← Android detailSection(): 标记里的 URL 仅信息性
    private func detailSection(_ url: String, _ html: String) -> String {
        JwUcasParser.DETAIL_MARKER_OPEN + url + "-->\n" + html + "\n" + JwUcasParser.DETAIL_MARKER_CLOSE + "\n"
    }

    private func grid() throws -> String { try htmlFixture() }

    // ---- HTML 路径 (fallback) ----

    func testParsesUcasScheduleGridAndMergesAdjacentNodes() throws {
        let courses = try JwUcasParser(grid()).generateCourseList()
        XCTAssertEqual(6, courses.count)
        let theory = try XCTUnwrap(courses.first { $0.name == "新时代中国特色社会主义理论与实践" })
        XCTAssertEqual(1, theory.day)
        XCTAssertEqual(1, theory.startNode)
        XCTAssertEqual(2, theory.endNode)
        XCTAssertEqual(JwUcasParser.PROVISIONAL_START_WEEK, theory.startWeek)
        XCTAssertEqual(JwUcasParser.PROVISIONAL_END_WEEK, theory.endWeek)
        let architecture = try XCTUnwrap(courses.first { $0.name == "计算机体系结构" && $0.day == 1 })
        XCTAssertEqual(10, architecture.startNode)
        XCTAssertEqual(11, architecture.endNode)
    }

    func testUcasHtmlParserIdentifiesCapturedPageShape() throws {
        let parser = JwUcasParser(try grid())
        XCTAssertGreaterThanOrEqual(parser.confidenceValue, 90)
        XCTAssertTrue(parser.matchedFeatureList.contains("href:/course/coursetime/"))
    }

    // ---- JSON 路径 (ldiex 协议契约) ----

    func testParsesUcasJsonCourseTimeListWithBitmapWeeksAndNodes() throws {
        let parser = JwUcasParser(try jsonFixture())
        XCTAssertEqual(95, parser.confidenceValue)
        XCTAssertTrue(parser.matchedFeatureList.contains("json:courseTimeList"))
        XCTAssertTrue(parser.matchedFeatureList.contains("json:selectedCourse"))

        let courses = try parser.generateCourseList()
        // 第 4 条 (courseWeek=0/courseTime=0) 应被跳过
        XCTAssertEqual(3, courses.count)

        // 全周 1-16: 新时代中国特色社会主义理论与实践, 周一 第 1-2 节, type=0
        let theory = try XCTUnwrap(courses.first { $0.name == "新时代中国特色社会主义理论与实践" })
        XCTAssertEqual(1, theory.day)
        XCTAssertEqual(1, theory.startNode)
        XCTAssertEqual(2, theory.endNode)
        XCTAssertEqual(1, theory.startWeek)
        XCTAssertEqual(16, theory.endWeek)
        XCTAssertEqual(JwUcasParser.TYPE_DEFAULT, theory.type)
        XCTAssertEqual("教学楼A101", theory.room)

        // 单周: 计算机体系结构, 周三 第 10-11 节, type=1
        let architecture = try XCTUnwrap(courses.first { $0.name == "计算机体系结构" })
        XCTAssertEqual(3, architecture.day)
        XCTAssertEqual(10, architecture.startNode)
        XCTAssertEqual(11, architecture.endNode)
        XCTAssertEqual(1, architecture.startWeek)
        XCTAssertEqual(15, architecture.endWeek)
        XCTAssertEqual(JwUcasParser.TYPE_ODD, architecture.type)

        // 双周: 羽毛球, 周五 第 5 节, type=2
        let badminton = try XCTUnwrap(courses.first { $0.name == "羽毛球" })
        XCTAssertEqual(5, badminton.day)
        XCTAssertEqual(5, badminton.startNode)
        XCTAssertEqual(5, badminton.endNode)
        XCTAssertEqual(2, badminton.startWeek)
        XCTAssertEqual(16, badminton.endWeek)
        XCTAssertEqual(JwUcasParser.TYPE_EVEN, badminton.type)
    }

    func testUcasJsonParserSkipsCourseTimeListEntriesWithInvalidBitmap() throws {
        // courseWeek=0 + courseTime=0 应被跳过, 不抛异常
        let courses = try JwUcasParser(jsonFixture()).generateCourseList()
        XCTAssertTrue(courses.allSatisfy { $0.name != "无效条目" })
    }

    func testUcasParserDecodesDayBitsToDayPerLdiexDictionary() throws {
        // 直接用单课 courseInfo 形态 (顶层 courseTimeList) 验证字典全覆盖
        let samples: [(String, String)] = [
            ("周一", "10"), ("周二", "100"), ("周三", "110"), ("周四", "1000"),
            ("周五", "1010"), ("周六", "1100"), ("周日", "1110"),
        ]
        for (index, sample) in samples.enumerated() {
            let timeInt = Int(sample.1 + "000000000001", radix: 2)!
            let json = """
            {"courseTimeList":[{"courseName":"x","coursePlace":"","courseWeek":1,"courseTime":\(timeInt)}]}
            """
            let courses = try JwUcasParser(json).generateCourseList()
            XCTAssertEqual(1, courses.count, sample.0)
            XCTAssertEqual(index + 1, courses.first?.day, sample.0)
        }
    }

    func testUcasParserReturnsEmptyListWhenSourceHasNeitherJsonNorHtmlAnchor() throws {
        let courses = try JwUcasParser("nothing relevant").generateCourseList()
        XCTAssertEqual(0, courses.count)
        XCTAssertEqual(0, JwUcasParser("nothing relevant").confidenceValue)
    }

    func testUcasParserHandlesMalformedJsonGracefullyAndFallsBack() throws {
        // JSON 不合法但包含 selectedCourse 字符串 → confidence 仍判 JSON 路径;
        // 解析时 extractCourseTimeList 在非数组时返回 nil → 回退 HTML, HTML 也没命中 → 空
        let malformedJson = """
        {"selectedCourse":{"list":[]},"courseTimeList":"not-an-array"}
        """
        let courses = try JwUcasParser(malformedJson).generateCourseList()
        XCTAssertEqual(0, courses.count)
    }

    // ---- HTML 详情路径 (v1.2 采集包, exact-week) ----

    func testCombinedGridAndDetailSectionsGiveExactWeeksForHoleyLists() throws {
        let combined = try grid() + detailSection(
            "https://xkcts.ucas.ac.cn:8443/course/coursetime/313611",
            detailFixture("coursetime-multi.sample")
        )
        let courses = try JwUcasParser(combined).generateCourseList()

        // 周二 10-11: {2,3,4,5,7..12} 缺第 6 周 → 拆 [2-5] + [7-12] 两条 (每周)
        let tue = courses.filter { $0.name == "网络攻防基础" && $0.day == 2 }
        XCTAssertEqual(2, tue.count)
        XCTAssertEqual(10, tue[0].startNode)
        XCTAssertEqual(11, tue[0].endNode)
        XCTAssertEqual(2, tue[0].startWeek)
        XCTAssertEqual(5, tue[0].endWeek)
        XCTAssertEqual(JwUcasParser.TYPE_DEFAULT, tue[0].type)
        XCTAssertEqual(7, tue[1].startWeek)
        XCTAssertEqual(12, tue[1].endWeek)
        XCTAssertEqual(JwUcasParser.TYPE_DEFAULT, tue[1].type)
        XCTAssertEqual("实验楼207", tue[0].room)
        XCTAssertEqual("实验楼207", tue[1].room)

        // 周日 10-11: 单周次 {3} → 一条 3-3
        let sun = try XCTUnwrap(courses.first { $0.name == "网络攻防基础" && $0.day == 7 })
        XCTAssertEqual(10, sun.startNode)
        XCTAssertEqual(11, sun.endNode)
        XCTAssertEqual(3, sun.startWeek)
        XCTAssertEqual(3, sun.endWeek)
        XCTAssertEqual("实验楼207", sun.room)

        // 详情页里的周四块在网格没有对应格子 → 不造课 (网格权威)
        XCTAssertTrue(courses.allSatisfy { !($0.name == "网络攻防基础" && $0.day == 4) })
        // 无详情的课保持占位
        let badminton = try XCTUnwrap(courses.first { $0.name == "羽毛球" })
        XCTAssertEqual(JwUcasParser.PROVISIONAL_START_WEEK, badminton.startWeek)
        XCTAssertEqual(JwUcasParser.PROVISIONAL_END_WEEK, badminton.endWeek)
    }

    func testContinuousWeeksStaySingleCourseAndRoomIsEnriched() throws {
        let combined = try grid() + detailSection(
            "https://xkcts.ucas.ac.cn:8443/course/coursetime/315751",
            detailFixture("coursetime-continuous.sample")
        )
        let courses = try JwUcasParser(combined).generateCourseList()
        let theory = try XCTUnwrap(
            courses.first { $0.name == "新时代中国特色社会主义理论与实践" && $0.day == 1 })
        XCTAssertEqual(1, theory.day)
        XCTAssertEqual(1, theory.startNode)
        XCTAssertEqual(2, theory.endNode)
        XCTAssertEqual(2, theory.startWeek)
        XCTAssertEqual(10, theory.endWeek)
        XCTAssertEqual(JwUcasParser.TYPE_DEFAULT, theory.type)
        XCTAssertEqual("教一楼107", theory.room)

        // 同名但节点不重叠的格子 (计算机体系结构 周六第 2 节 vs 详情块周一 1-2) 不误挂
        let arch = try XCTUnwrap(courses.first { $0.name == "计算机体系结构" && $0.day == 6 })
        XCTAssertEqual(JwUcasParser.PROVISIONAL_START_WEEK, arch.startWeek)
        XCTAssertEqual(JwUcasParser.PROVISIONAL_END_WEEK, arch.endWeek)
    }

    /// 单格网格 (甲, 周一第 1 节)
    private let parityGrid = """
    <html><body><table><thead><tr><th>节次/星期</th>\
    <th>星期一</th><th>星期二</th><th>星期三</th><th>星期四</th><th>星期五</th><th>星期六</th><th>星期日</th></tr></thead><tbody>\
    <tr><th>1</th><td><a href='https://xkcts.ucas.ac.cn:8443/course/coursetime/1'>甲</a></td><td></td><td></td><td></td><td></td><td></td><td></td></tr>\
    </tbody></table></body></html>
    """

    private func parityDetail(_ weeks: String) -> String {
        detailSection(
            "https://xw.ucas.ac.cn:8443/course/coursetime/1",
            "<html><body><table><tbody>" +
                "<tr><th>课程名称</th><td>甲</td></tr>" +
                "<tr><th>上课时间</th><td>星期一： 第1、2节。</td></tr>" +
                "<tr><th>上课地点</th><td>教室A</td></tr>" +
                "<tr><th>上课周次</th><td>\(weeks)</td></tr>" +
                "</tbody></table></body></html>"
        )
    }

    func testParityWeekRunsCollapseToASingleOddOrEvenCourse() throws {
        // 双周 {2,4,6,8} → 一条 type=2 (2-8)
        let even = try JwUcasParser(parityGrid + parityDetail("2、4、6、8")).generateCourseList()
        let evenCourse = try XCTUnwrap(even.first)
        XCTAssertEqual(1, even.count)
        XCTAssertEqual(2, evenCourse.startWeek)
        XCTAssertEqual(8, evenCourse.endWeek)
        XCTAssertEqual(JwUcasParser.TYPE_EVEN, evenCourse.type)

        // 单周 {13,15} → 一条 type=1 (13-15)
        let odd = try JwUcasParser(parityGrid + parityDetail("13、15")).generateCourseList()
        let oddCourse = try XCTUnwrap(odd.first)
        XCTAssertEqual(1, odd.count)
        XCTAssertEqual(13, oddCourse.startWeek)
        XCTAssertEqual(15, oddCourse.endWeek)
        XCTAssertEqual(JwUcasParser.TYPE_ODD, oddCourse.type)
    }

    func testMalformedDetailSectionFallsBackToPlaceholder() throws {
        let combined = try grid() + detailSection(
            "https://xkcts.ucas.ac.cn:8443/course/coursetime/999999",
            "<html><body>无标签内容</body></html>")
        let courses = try JwUcasParser(combined).generateCourseList()
        XCTAssertEqual(6, courses.count)
        XCTAssertTrue(courses.allSatisfy {
            $0.startWeek == JwUcasParser.PROVISIONAL_START_WEEK
                && $0.endWeek == JwUcasParser.PROVISIONAL_END_WEEK
        })
    }

    func testDetailSectionForUnknownCourseIsIgnored() throws {
        let detail = "<html><body><table><tbody>" +
            "<tr><th>课程名称</th><td>不存在的课</td></tr>" +
            "<tr><th>上课时间</th><td>星期一： 第1、2节。</td></tr>" +
            "<tr><th>上课地点</th><td>教室A</td></tr>" +
            "<tr><th>上课周次</th><td>1、2、3</td></tr>" +
            "</tbody></table></body></html>"
        let combined = try grid() + detailSection(
            "https://xkcts.ucas.ac.cn:8443/course/coursetime/1", detail)
        let courses = try JwUcasParser(combined).generateCourseList()
        XCTAssertEqual(6, courses.count)
        XCTAssertTrue(courses.allSatisfy {
            $0.startWeek == JwUcasParser.PROVISIONAL_START_WEEK
                && $0.endWeek == JwUcasParser.PROVISIONAL_END_WEEK
        })
    }

    func testExtractDetailUrlsDedupesAndAbsolutizesRelativeForms() throws {
        let urls = JwUcasParser.extractDetailUrls(try grid())
        XCTAssertFalse(urls.isEmpty)
        XCTAssertTrue(urls.allSatisfy { $0.hasPrefix("https://xkcts.ucas.ac.cn:8443/course/coursetime/") })
        XCTAssertEqual(urls.count, Set(urls).count)

        let relative = JwUcasParser.extractDetailUrls(
            "<a href='/course/coursetime/315751'>x</a><a href=\"/course/coursetime/315751\">y</a>")
        XCTAssertEqual(["https://xkcts.ucas.ac.cn:8443/course/coursetime/315751"], relative)
    }

    func testSplitWeekRunsCoversParityGapsAndMixedSteps() {
        func triples(_ weeks: [Int]) -> [(Int, Int, Int)] {
            JwUcasParser.splitWeekRuns(weeks).map { ($0.startWeek, $0.endWeek, $0.type) }
        }
        func assertRuns(_ expected: [(Int, Int, Int)], _ actual: [(Int, Int, Int)],
                       file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(expected.count, actual.count, file: file, line: line)
            for (e, a) in zip(expected, actual) {
                XCTAssertEqual(e.0, a.0, file: file, line: line)
                XCTAssertEqual(e.1, a.1, file: file, line: line)
                XCTAssertEqual(e.2, a.2, file: file, line: line)
            }
        }

        // 缺口断开: {2,3,4,5,7..12} → [2-5] + [7-12]
        assertRuns([(2, 5, 0), (7, 12, 0)], triples([2, 3, 4, 5, 7, 8, 9, 10, 11, 12]))
        // 步长 2 同奇偶 → 单条单/双周
        assertRuns([(2, 8, 2)], triples([2, 4, 6, 8]))
        assertRuns([(1, 5, 1)], triples([1, 3, 5]))
        // 单元素 → 每周
        assertRuns([(3, 3, 0)], triples([3]))
        // 步长 2 段被缺口打断: {2,4} + {8} → [2-4 双周] + [8 每周]
        assertRuns([(2, 4, 2), (8, 8, 0)], triples([2, 4, 8]))
        // 步长切换断开: {2,3} 每周 + {5,6} 每周
        assertRuns([(2, 3, 0), (5, 6, 0)], triples([2, 3, 5, 6]))
        // 连续 1-16 → 单条每周
        assertRuns([(1, 16, 0)], triples(Array(1...16)))
        // 空集 / 非正数 → 空
        XCTAssertTrue(triples([]).isEmpty)
        XCTAssertTrue(triples([0, -3]).isEmpty)
    }

    func testParseNumberListHandlesEnumCommaAsciiCommaAndRanges() {
        XCTAssertEqual([2, 3, 4], JwUcasParser.parseNumberList("2、3、4"))
        XCTAssertEqual([1, 3], JwUcasParser.parseNumberList("1，3"))
        XCTAssertEqual(Array(1...16), JwUcasParser.parseNumberList("1-16"))
        XCTAssertEqual(Array(1...16), JwUcasParser.parseNumberList("1~16"))
        XCTAssertEqual([3], JwUcasParser.parseNumberList("3"))
        // 无数字 → 空
        XCTAssertTrue(JwUcasParser.parseNumberList("无周次").isEmpty)
    }

    func testJsonPathSplitsNonContiguousBitmapWeeksIntoRuns() throws {
        // courseWeek 位图: 第 2/3/4/5/7 周 → bits 1,2,3,4,6 → 2+4+8+16+64 = 94
        let timeInt = Int("10" + "000000000001", radix: 2)!  // 周一 第 1 节
        let json = """
        {"selectedCourse":{},"courseTimeList":[{"courseName":"x","coursePlace":"R","courseWeek":94,"courseTime":\(timeInt)}]}
        """
        let courses = try JwUcasParser(json).generateCourseList()
        XCTAssertEqual(2, courses.count)
        XCTAssertEqual(2, courses[0].startWeek)
        XCTAssertEqual(5, courses[0].endWeek)
        XCTAssertEqual(JwUcasParser.TYPE_DEFAULT, courses[0].type)
        XCTAssertEqual(7, courses[1].startWeek)
        XCTAssertEqual(7, courses[1].endWeek)
    }

    // ---- UcasDetailFetch (组合源拼装 + 字符集) ----

    func testCombineWrapsEachDetailInMarkersParserCanRead() throws {
        let grid = try grid()
        let detail = try detailFixture("coursetime-continuous.sample")
        let url = "https://xkcts.ucas.ac.cn:8443/course/coursetime/315751"
        let combined = UcasDetailFetch.combine(grid, [UcasDetailFetch.Detail(url: url, html: detail)])

        XCTAssertTrue(combined.hasPrefix(grid))
        XCTAssertEqual([detail.trimmingCharacters(in: .whitespacesAndNewlines)],
                       JwUcasParser.detailSections(combined)
                           .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        // 组合源仍可被解析, 且详情段真的把周次补上了 (等价于 enrich 成功后的下游行为)
        let courses = try JwUcasParser(combined).generateCourseList()
        let theory = try XCTUnwrap(
            courses.first { $0.name == "新时代中国特色社会主义理论与实践" && $0.day == 1 })
        XCTAssertEqual(2, theory.startWeek)
        XCTAssertEqual(10, theory.endWeek)
        XCTAssertEqual("教一楼107", theory.room)
    }

    func testEnrichDegradesToOriginalHtmlWhenNoDetailUrl() async {
        // 无详情链接的 HTML → 原样返回, 不发请求也不抛
        let html = "<html><body><p>no links</p></body></html>"
        let out = await UcasDetailFetch.enrich(html)
        XCTAssertEqual(html, out)
        // 空 HTML 同样安全 (precondition 防呆)
        let emptyOut = await UcasDetailFetch.enrich("")
        XCTAssertEqual("", emptyOut)
    }

    func testDetailFetchTimeoutAndCapMatchAndroid() {
        XCTAssertEqual(50, UcasDetailFetch.MAX_DETAILS)
    }

    func testCharsetParsingFallsBackToUtf8() {
        XCTAssertEqual("utf-8", UcasDetailFetch.charsetName("text/html; charset=utf-8"))
        XCTAssertEqual("GBK", UcasDetailFetch.charsetName("text/html;Charset=GBK"))
        XCTAssertEqual("gb2312", UcasDetailFetch.charsetName("text/html;charset=\"gb2312\""))
        XCTAssertNil(UcasDetailFetch.charsetName("text/html"))
        XCTAssertNil(UcasDetailFetch.charsetName(nil))
        XCTAssertNil(UcasDetailFetch.charsetName(""))
        // 缺失/未知字符集 → UTF-8 (← Android charset(name) 默认值)
        XCTAssertEqual(String.Encoding.utf8, UcasDetailFetch.encoding(forContentType: nil))
        XCTAssertEqual(String.Encoding.utf8, UcasDetailFetch.encoding(forContentType: "text/html"))
        XCTAssertEqual(String.Encoding.utf8, UcasDetailFetch.encoding(forContentType: "text/html;charset=bogus-9"))
        XCTAssertNotEqual(String.Encoding.utf8, UcasDetailFetch.encoding(forContentType: "text/html;charset=gbk"))
    }
}
