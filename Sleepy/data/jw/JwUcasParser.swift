// JwUcasParser.swift — ← JwUcasParser.kt 1:1 translation (GPL-3.0) — 1.0.52 alignment
// UCAS (中国科学院大学) personal schedule parser — JSON (authoritative) + HTML (fallback).

import Foundation
import SwiftSoup

final class JwUcasParser: JwParser, JwParserConfidenceReporting {

    let source: String

    init(_ source: String) {
        self.source = source
    }

    /// HTML path provisional weeks (详情页尚未捕获, 1-16 周占位)
    static let PROVISIONAL_START_WEEK = 1
    static let PROVISIONAL_END_WEEK = 16

    /// 组合源里详情页段的分段标记。UcasDetailFetch 把网格 HTML 与逐课详情页拼成一个
    /// source 喂给本 parser; 解析器按标记切段, 标记里的 URL 仅信息性。
    static let DETAIL_MARKER_OPEN = "<!--sleepy-ucas-detail:"
    static let DETAIL_MARKER_CLOSE = "<!--/sleepy-ucas-detail-->"

    /// UCAS 详情站 host (相对形态 /course/coursetime/<id> 补全用)
    static let DETAIL_HOST = "https://xkcts.ucas.ac.cn:8443"

    /// ldiex/UCAS_Course_Schedule_Convertor 实测 dayBits -> 星期 1..7 (POSITIVE 证据, hardcode 不发明新编码)
    static let DAY_BITS: [String: Int] = [
        "10": 1, "11": 1, "100": 2, "110": 3,
        "1000": 4, "1010": 5, "1100": 6, "1110": 7,
    ]

    /// 课程周次类型: 0=每周, 1=单周, 2=双周
    static let TYPE_DEFAULT = 0
    static let TYPE_ODD = 1
    static let TYPE_EVEN = 2

    func generateCourseList() throws -> [JwCourse] {
        return parseJson() ?? parseHtml()
    }

    /// ← confidence(): JSON 命中 95 / HTML 命中 90 (iOS 检测层不消费, 保留供对齐)
    var confidenceValue: Int {
        if source.contains("\"courseTimeList\"") && source.contains("\"selectedCourse\"") { return 95 }
        if source.contains("个人课表") && source.contains("/course/coursetime/") { return 90 }
        return 0
    }

    var matchedFeatureList: [String] {
        var f: [String] = []
        if source.contains("\"courseTimeList\"") { f.append("json:courseTimeList") }
        if source.contains("\"selectedCourse\"") { f.append("json:selectedCourse") }
        if source.contains("个人课表") { f.append("title:个人课表") }
        if source.contains("/course/coursetime/") { f.append("href:/course/coursetime/") }
        return f
    }

    /// JSON path: pick courseTimeList array, decode each schedule.
    /// nil return = no parsable JSON, caller falls back to HTML path.
    private func parseJson() -> [JwCourse]? {
        guard let courseTimeList = JwUcasParser.extractCourseTimeList(source) else { return nil }
        var result: [JwCourse] = []
        for item in courseTimeList {
            guard let item = item as? [String: Any] else { continue }
            let name = trim(item["courseName"])
            let place = trim(item["coursePlace"])
            guard let weekInt = optInt(item, "courseWeek"), let timeInt = optInt(item, "courseTime") else { continue }
            if name.isEmpty { continue }

            let weeks = JwUcasParser.decodeWeeks(weekInt)
            if weeks.isEmpty { continue }
            guard let (day, startNode, endNode) = JwUcasParser.decodeTime(timeInt) else { continue }
            // 位图周次集合 → 可表示周次段; 带洞集合拆多段, 禁 first..last 有损合并
            for run in JwUcasParser.splitWeekRuns(weeks) {
                result.append(JwCourse(name: name, room: place, day: day,
                                       startNode: startNode, endNode: endNode,
                                       startWeek: run.startWeek, endWeek: run.endWeek,
                                       type: run.type))
            }
        }
        return result
    }

    /// 兼容两种 JSON 形态: A. 顶层 courseTimeList (拼合文档) B. 嵌套 data 字段 / 顶层数组
    static func extractCourseTimeList(_ raw: String) -> [Any]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        // 跳过前导 HTML 注释/空白, 找首个 '{' 或 '[' 真正 JSON 起点(优先 '{', 避开注释里 [2:] 误命中)
        let objStart = trimmed.firstIndex(of: "{")
        let arrStart = trimmed.firstIndex(of: "[")
        // ← Kotlin: 有 '{' 就用 '{', 顶层对象更常见, 避开注释里 `[2:]` 这类方括号误命中
        let jsonStart: String.Index
        if let o = objStart { jsonStart = o }
        else if let a = arrStart { jsonStart = a }
        else { return nil }
        let jsonBody = String(trimmed[jsonStart...])
        guard let obj = try? JSONSerialization.jsonObject(with: Data(jsonBody.utf8)) else { return nil }
        if let dict = obj as? [String: Any] {
            return (dict["courseTimeList"] as? [Any])
                ?? ((dict["data"] as? [String: Any])?["courseTimeList"] as? [Any])
        }
        if let arr = obj as? [Any] { return arr }
        return nil
    }

    /// courseWeek 整数位图 -> 周次列表 (低位=第1周)。21 (0b10101) -> [1,3,5]
    static func decodeWeeks(_ weekInt: Int) -> [Int] {
        if weekInt <= 0 { return [] }
        var weeks: [Int] = []
        var bit = 0
        var n = weekInt
        while n > 0 {
            if n & 1 == 1 { weeks.append(bit + 1) }
            bit += 1
            n >>= 1
        }
        return weeks
    }

    /// courseTime 整数 -> (day, startNode, endNode)。dayBits 不在 DAY_BITS 内 = 数据异常, 返回 nil。
    static func decodeTime(_ timeInt: Int) -> (Int, Int, Int)? {
        if timeInt <= 0 { return nil }
        let binary = String(timeInt, radix: 2)
        if binary.count <= 12 { return nil }
        let dayBits = String(binary.prefix(binary.count - 12))
        guard let day = JwUcasParser.DAY_BITS[dayBits] else { return nil }
        let nodeBits = String(String(binary.suffix(12)).reversed())
        var nodes: [Int] = []
        for (idx, c) in nodeBits.enumerated() where c == "1" { nodes.append(idx + 1) }
        if nodes.isEmpty { return nil }
        return (day, nodes.first!, nodes.last!)
    }

    /// weeks 列表归类 type: 全单周=1, 全双周=2, 混合=0
    static func weeksToType(_ weeks: [Int]) -> Int {
        if weeks.allSatisfy({ $0 % 2 == 1 }) { return TYPE_ODD }
        if weeks.allSatisfy({ $0 % 2 == 0 }) { return TYPE_EVEN }
        return TYPE_DEFAULT
    }

    // ---- HTML 详情路径 (v1.2 采集包, exact-week) ----

    /// 可表示周次段: startWeek..endWeek + type (每周/单周/双周)
    struct WeekRun: Equatable {
        let startWeek: Int
        let endWeek: Int
        let type: Int
    }

    /// 单个时间块: 星期 + 节次区间 + 教室 + 周次集合
    struct DetailBlock: Equatable {
        let day: Int
        let startNode: Int
        let endNode: Int
        var room: String = ""
        var weeks: [Int] = []
    }

    /// 详情页解析模型: 课程名 + 时间/地点/周次块列表
    struct DetailPage: Equatable {
        let courseName: String
        let blocks: [DetailBlock]
    }

    /// 数字列表 token: 纯数字或范围 (1-16 / 1~16 / 1至16)
    private static let numToken = try! NSRegularExpression(pattern: #"(\d+)\s*(?:[-–—~至]\s*(\d+))?"#)

    /// "2、3、4、5、7、8" → [2,3,4,5,7,8]。顿号枚举是实测唯一形态, 范围/逗号/全角逗号是宽容超集。
    static func parseNumberList(_ text: String) -> [Int] {
        var out: [Int] = []
        for m in matches(numToken, text) {
            guard let aStr = group(m, 1, text), let a = Int(aStr) else { continue }
            let bStr = group(m, 2, text)
            if let bStr = bStr, let b = Int(bStr) {
                if a <= b { out.append(contentsOf: Array(a...b)) }
            } else {
                out.append(a)
            }
        }
        return out
    }

    /// 任意周次集合 → 可表示周次段。步长 1 → 每周段; 步长 2 → 单/双周段;
    /// 两种步长混排时在步长切换处断开, 缺口 > 2 也断开。单元素段 → 每周。
    static func splitWeekRuns(_ weeks: [Int]) -> [WeekRun] {
        let sorted = weeks.filter { $0 > 0 }.reduce(into: [Int]()) { acc, w in
            if !acc.contains(w) { acc.append(w) }
        }.sorted()
        if sorted.isEmpty { return [] }
        var runs: [WeekRun] = []
        var runStart = 0
        var prev = 0
        var step = 0  // 0=未定, 1=每周, 2=单/双周
        func flush() {
            if runStart == 0 { return }
            let type: Int
            if step == 2 { type = (runStart % 2 == 1) ? TYPE_ODD : TYPE_EVEN }
            else { type = TYPE_DEFAULT }
            runs.append(WeekRun(startWeek: runStart, endWeek: prev, type: type))
        }
        for w in sorted {
            if runStart == 0 {
                runStart = w; prev = w; step = 0
            } else if w == prev + 1 && step != 2 {
                prev = w; step = 1
            } else if w == prev + 2 && step != 1 {
                prev = w; step = 2
            } else {
                flush(); runStart = w; prev = w; step = 0
            }
        }
        flush()
        return runs
    }

    /// 详情页 URL: 绝对形态 (网格真实形态) / 相对形态容错
    private static let detailUrlAbs = try! NSRegularExpression(pattern: #"https?://[^\s"'<>]+/course/coursetime/\d+"#)
    private static let detailUrlRel = try! NSRegularExpression(pattern: #"["'\s](/course/coursetime/\d+)"#)

    /// 从网格 HTML 提取详情页 URL 列表 (绝对 + 相对, 去重保序) ← UcasDetailFetch 的抓取清单
    static func extractDetailUrls(_ gridHtml: String) -> [String] {
        var found: [String] = []
        func add(_ s: String) { if !found.contains(s) { found.append(s) } }
        for m in matches(detailUrlAbs, gridHtml) { add(range(m, gridHtml)) }
        for m in matches(detailUrlRel, gridHtml) { add(DETAIL_HOST + (group(m, 1, gridHtml) ?? "")) }
        return found
    }

    /// 组合源切段: 取每个详情页 HTML 段 (标记内 URL 不参与解析)
    static func detailSections(_ source: String) -> [String] {
        let re = try! NSRegularExpression(
            pattern: NSRegularExpression.escapedPattern(for: DETAIL_MARKER_OPEN) + "(.*?)" +
                NSRegularExpression.escapedPattern(for: "-->") + "(.*?)" +
                NSRegularExpression.escapedPattern(for: DETAIL_MARKER_CLOSE),
            options: [.dotMatchesLineSeparators])
        return matches(re, source).compactMap { group($0, 2, source) }
    }

    /// 详情页行标签 (真实页面形态, 2026-09-08 v1.2 采集包)
    private static let LABEL_NAME = "课程名称"
    private static let LABEL_TIME = "上课时间"
    private static let LABEL_PLACE = "上课地点"
    private static let LABEL_WEEKS = "上课周次"

    /// 星期X → 1..7 (日/天 都算第 7 天)
    private static let dayNames: [String: Int] = [
        "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "日": 7, "天": 7,
    ]

    private static let detailTimeRe = try! NSRegularExpression(
        pattern: #"星期\s*([一二三四五六日天])\s*[：:]\s*第?\s*([\d、，,\s\-–—~至]+?)\s*节"#)
    private static let detailNameRe = try! NSRegularExpression(pattern: #"课程名称\s*[：:]\s*([^<\r\n]+?)\s*<"#)
    private static let htmlCommentRe = try! NSRegularExpression(
        pattern: #"<!--.*?-->"#, options: [.dotMatchesLineSeparators])

    /// 解析一个 /course/coursetime/<id> 详情页 HTML → DetailPage。
    /// 三行一组 (上课时间/上课地点/上课周次) 按顺序组装; 缺时间行或周次行不完整的组丢弃。
    /// nil = 页面没有 课程名称 或一个完整块都没有 (非详情页/异常页)。
    static func parseDetailPage(_ html: String) -> DetailPage? {
        let doc = try? SwiftSoup.parse(html)
        // 课程名称两种形态: ① 真实页 <p>课程名称：X</p> (标签+名同一文本节点);
        // ② 宽容兼容 th/td 分离行 (课程名称 | X)
        let stripped = htmlCommentRe.stringByReplacingMatches(
            in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "")
        var name = firstGroup(detailNameRe, stripped, 1)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if name?.isEmpty ?? true {
            name = nil
            let rows = ((try? doc?.select("tr")) ?? nil)?.array() ?? []
            for tr in rows {
                guard cellText(tr, "th") == LABEL_NAME else { continue }
                if let td = cellText(tr, "td"), !td.isEmpty { name = td; break }
            }
        }
        guard let courseName = name, !courseName.isEmpty else { return nil }

        var blocks: [DetailBlock] = []
        var pendingDay = 0
        var pendingNodes: [Int] = []
        var pendingRoom = ""
        var pendingValid = false
        let rows = ((try? doc?.select("tr")) ?? nil)?.array() ?? []
        for tr in rows {
            let th = cellText(tr, "th")
            let td = cellText(tr, "td") ?? ""
            switch th {
            case LABEL_TIME:
                let m = firstMatch(detailTimeRe, td)
                let nodes = m.flatMap { parseNumberList(group($0, 2, td) ?? "") } ?? []
                pendingDay = m.flatMap { dayNames[group($0, 1, td) ?? ""] } ?? 0
                pendingNodes = nodes
                pendingRoom = ""
                pendingValid = pendingDay > 0 && !nodes.isEmpty
            case LABEL_PLACE:
                if pendingValid { pendingRoom = td }
            case LABEL_WEEKS:
                if pendingValid {
                    let weeks = parseNumberList(td).filter { $0 > 0 }
                    if !weeks.isEmpty && !pendingNodes.isEmpty {
                        blocks.append(DetailBlock(day: pendingDay,
                                                  startNode: pendingNodes.first!,
                                                  endNode: pendingNodes.last!,
                                                  room: pendingRoom, weeks: weeks))
                    }
                }
                pendingValid = false
            default:
                break
            }
        }
        if blocks.isEmpty { return nil }
        return DetailPage(courseName: courseName, blocks: blocks)
    }

    // ---- SwiftSoup / NSRegularExpression 小工具 ----

    /// ← Jsoup: tr.selectFirst(tag)?.text()?.trim()
    private static func cellText(_ tr: Element, _ tag: String) -> String? {
        guard let el = ((try? tr.select(tag)) ?? nil)?.first() else { return nil }
        return ((try? el.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> [NSTextCheckingResult] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s))
    }

    private static func firstMatch(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String? {
        guard i < m.numberOfRanges else { return nil }
        let r = m.range(at: i)
        guard r.location != NSNotFound, let rng = Range(r, in: s) else { return nil }
        return String(s[rng])
    }

    private static func firstGroup(_ re: NSRegularExpression, _ s: String, _ i: Int) -> String? {
        guard let m = firstMatch(re, s) else { return nil }
        return group(m, i, s)
    }

    private static func range(_ m: NSTextCheckingResult, _ s: String) -> String {
        guard let rng = Range(m.range, in: s) else { return "" }
        return String(s[rng])
    }

    /// 网格格子 (课程名 × 星期 × 节次)
    private struct GridEntry {
        let name: String
        let day: Int
        let node: Int
    }

    /// 详情块 + 其所属课程名 (网格链接文本与详情页 课程名称 同源)
    private struct DetailRef {
        let name: String
        let block: JwUcasParser.DetailBlock
    }

    /// HTML 路径: 服务端课表网格 + (可选) 组合源里的详情页段。
    ///
    /// 网格定位 (课程名 × 星期 × 节次) 是权威; 详情块仅 enrich 周次/教室,
    /// 不会凭详情造网格里没有的课。没有详情段时整体回退 1-16 占位。
    private func parseHtml() -> [JwCourse] {
        guard let doc = try? SwiftSoup.parse(source) else { return [] }
        guard let table = findScheduleTable(doc) else { return [] }

        // 平铺网格格子 → (name, day, node); 同格同名去重
        var entries: [GridEntry] = []
        let gridRows = ((try? table.getElementsByTag("tr")) ?? nil)?.array() ?? []
        for row in gridRows {
            guard let th = (try? row.getElementsByTag("th").first()) ?? nil else { continue }
            let nodeText = ((try? th.text()) ?? "").trimmingCharacters(in: .whitespaces)
            guard let node = Int(nodeText) else { continue }
            let tds = ((try? row.getElementsByTag("td")) ?? nil)?.array() ?? []
            for (index, cell) in tds.enumerated() {
                let day = index + 1
                let links = ((try? cell.select("a[href*=/course/coursetime/]")) ?? nil)?.array() ?? []
                var names: [String] = []
                for link in links {
                    let n = ((try? link.text()) ?? "").trimmingCharacters(in: .whitespaces)
                    if n.isEmpty || names.contains(n) { continue }
                    names.append(n)
                }
                for n in names { entries.append(GridEntry(name: n, day: day, node: node)) }
            }
        }

        // 详情段 → 页面模型, 平铺成 (课程名, 块) 列表
        let allBlocks: [DetailRef] = JwUcasParser.detailSections(source)
            .compactMap { JwUcasParser.parseDetailPage($0) }
            .flatMap { page in page.blocks.map { DetailRef(name: page.courseName, block: $0) } }

        // 每个 (name, day, node) 找第一个 (同名 + 同日 + 节次落块区间) 的详情块
        func blockIndexFor(_ name: String, _ day: Int, _ node: Int) -> Int? {
            for (i, ref) in allBlocks.enumerated()
            where ref.name == name && ref.block.day == day
                && node >= ref.block.startNode && node <= ref.block.endNode {
                return i
            }
            return nil
        }

        // 分组键带块身份 → 同一块命中的相邻格子自然共享周次 (Dictionary 无序, 另记插入序)
        var groupOrder: [String] = []
        var grouped: [String: (name: String, day: Int, blockIdx: Int?, nodes: [Int])] = [:]
        for e in entries {
            let blockIdx = blockIndexFor(e.name, e.day, e.node)
            let key = "\(e.name)|\(e.day)|\(blockIdx.map(String.init) ?? "nil")"
            if grouped[key] == nil {
                groupOrder.append(key)
                grouped[key] = (e.name, e.day, blockIdx, [])
            }
            grouped[key]!.nodes.append(e.node)
        }

        var result: [JwCourse] = []
        for key in groupOrder {
            guard let g = grouped[key] else { continue }
            let room = g.blockIdx.map { allBlocks[$0].block.room } ?? ""
            let runs: [JwUcasParser.WeekRun]
            if let idx = g.blockIdx {
                runs = JwUcasParser.splitWeekRuns(allBlocks[idx].block.weeks)
            } else {
                runs = [JwUcasParser.WeekRun(startWeek: JwUcasParser.PROVISIONAL_START_WEEK,
                                             endWeek: JwUcasParser.PROVISIONAL_END_WEEK,
                                             type: JwUcasParser.TYPE_DEFAULT)]
            }
            // 同组内相邻节次合并 (10,11 → 10-11)
            var segments: [(Int, Int)] = []
            for n in g.nodes.sorted() {
                if let last = segments.last, n == last.1 + 1 {
                    segments[segments.count - 1] = (last.0, n)
                } else {
                    segments.append((n, n))
                }
            }
            for seg in segments {
                for run in runs {
                    result.append(JwCourse(name: g.name, room: room, day: g.day,
                                           startNode: seg.0, endNode: seg.1,
                                           startWeek: run.startWeek, endWeek: run.endWeek,
                                           type: run.type))
                }
            }
        }
        return result
    }

    private func findScheduleTable(_ doc: Document) -> Element? {
        let tables = ((try? doc.getElementsByTag("table")) ?? nil)?.array() ?? []
        for t in tables {
            guard tableHasHeader(t) else { continue }
            let links = (try? t.select("a[href*=/course/coursetime/]")) ?? nil
            if (links?.array().count ?? 0) > 0 { return t }
        }
        return nil
    }

    private func tableHasHeader(_ t: Element) -> Bool {
        guard let thead = (try? t.getElementsByTag("thead").first()) ?? nil else { return false }
        let ths = ((try? thead.getElementsByTag("th")) ?? nil)?.array() ?? []
        return ths.contains { ((try? $0.text()) ?? "").contains("节次/星期") }
    }

    private func trim(_ v: Any?) -> String {
        (v as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func optInt(_ d: [String: Any], _ k: String) -> Int? {
        guard let v = d[k], !(v is NSNull) else { return nil }
        return v as? Int ?? (v as? String).flatMap(Int.init)
    }
}
