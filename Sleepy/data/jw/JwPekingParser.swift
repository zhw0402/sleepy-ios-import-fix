// JwPekingParser.swift — ← JwPekingParser.kt
//
// 北京大学（PKU）解析器 — T3。
//
// 协议：JwProtocol.TYPE_PKU = "pku"
// 上游：dIT8Zv/WakeupSchedule_BUPT (Apache-2.0) PekingParser.kt
//
// 页面结构：table[class=datagrid] > tbody > tr > 11 列 td
//   tds[0]=课名  tds[4]=教师(整行共用)  tds[7]=时段(<br> 分隔多段)
//   tds[8]=选课状态(含"未"跳过)
// 时段块按空格切 token：
//   timeInfo[0]="1~16周"  timeInfo[1]="周一1~2节"或"周一1~2节(单)"
//   timeInfo[2]=教室（缺失时从 timeInfo[1] 括号内取）
//
// 对上游偏离：kbtable/tbody null 时返回空而非 NPE（pku_login.html 登录页）。

import Foundation
import SwiftSoup

final class JwPekingParser: JwParser, JwParserConfidenceReporting {

    let source: String

    init(_ source: String) {
        self.source = source
    }

    func generateCourseList() throws -> [JwCourse] {
        var result: [JwCourse] = []
        let doc = try SwiftSoup.parse(source)
        guard let table = (try? doc.select("table[class=datagrid]").first()) ?? nil else { return result }
        guard let tbody = (try? table.select("tbody").first()) ?? nil else { return result }

        var teacher = ""
        let trs = (try? tbody.getElementsByTag("tr")) ?? Elements()
        for tr in trs {
            let tds = (try? tr.getElementsByTag("td")) ?? Elements()
            if tds.size() < 11 { continue }
            if (((try? tds.get(8).text()) ?? "").contains("未")) { continue }

            let courseName = ((try? tds.get(0).text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            teacher = ((try? tds.get(4).text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            var startWeek = 1, endWeek = 16
            var startNode = 1, endNode = 2
            var type = 0, day = 7

            let timeBlocks = ((try? tds.get(7).html()) ?? "").components(separatedBy: "<br>")
            for block in timeBlocks {
                let parsedText = ((try? SwiftSoup.parse(block).text()) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let rawTokens: [String] = parsedText.split(whereSeparator: { $0 == " " }).map { String($0) }
                let timeInfo: [String] = rawTokens.filter { token in
                    !token.trimmingCharacters(in: .whitespaces).isEmpty
                }
                if timeInfo.count < 2 { continue }

                let token0 = timeInfo[0]
                if token0.contains("~") {
                    let parts = token0.components(separatedBy: "~")
                    if parts.count >= 2 {
                        // ← token0.substringBefore('~').filter { isDigit }.toIntOrNull()
                        if let v = Int(parts[0].filter { $0.isNumber }) { startWeek = v }
                        // ← token0.substringAfter('~').substringBefore('周').filter { isDigit }.toIntOrNull()
                        let after = parts[1].components(separatedBy: "周").first ?? parts[1]
                        if let v = Int(after.filter { $0.isNumber }) { endWeek = v }
                    }
                }
                type = {
                    if timeInfo[1].contains("单") { return 1 }
                    if timeInfo[1].contains("双") { return 2 }
                    return 0
                }()
                for (index, s) in Self.CHINESE_WEEK_LIST.enumerated() {
                    if index != 0 && timeInfo[1].contains(s) { day = index; break }
                }
                let nodeMatch: Range<String.Index>? = timeInfo[1].range(of: Self.NODE_PATTERN1, options: [.regularExpression])
                if let m = nodeMatch {
                    let v = String(timeInfo[1][m])
                    let parts = v.components(separatedBy: "~")
                    if parts.count >= 2 {
                        if let sv = Int(parts[0].filter { $0.isNumber }) { startNode = sv }
                        let after = parts[1].components(separatedBy: "节").first ?? parts[1]
                        if let ev = Int(after.filter { $0.isNumber }) { endNode = ev }
                    }
                }
                let room = timeInfo.count >= 3
                    ? timeInfo[2]
                    : (timeInfo[1].components(separatedBy: "(").last.map { String($0) } ?? "")
                        .components(separatedBy: ")").first ?? ""

                result.append(JwCourse(
                    name: courseName, room: room, teacher: teacher,
                    day: day,
                    startNode: max(startNode, 1),
                    endNode: max(endNode, startNode),
                    startWeek: max(startWeek, 1),
                    endWeek: max(endWeek, startWeek),
                    type: type))
            }
        }
        return result
    }

    // MARK: - companion ← static

    /// 上游 Common.nodePattern1 原文，不可改字符
    private static let NODE_PATTERN1 = #"\d{1,2}[~]*\d*节"#
    private static let CHINESE_WEEK_LIST = ["", "周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    /// T8: table[class=datagrid] = 100; elective.pku = 90
    var confidenceValue: Int {
        guard let doc = try? SwiftSoup.parse(source) else { return 0 }
        if ((try? doc.select("table[class=datagrid]").first()) ?? nil) != nil { return 100 }
        if source.contains("elective.pku") { return 90 }
        return 0
    }

    var matchedFeatureList: [String] {
        var out: [String] = []
        if source.contains("datagrid") { out.append("class=datagrid") }
        if source.contains("elective.pku") { out.append("URL=elective.pku") }
        return out
    }
}
