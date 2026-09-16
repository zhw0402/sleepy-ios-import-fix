// JwQzBrParser.swift / JwQzWithNodeParser.swift / JwOldQzParser.swift
// — ← JwQzBrParser.kt / JwQzWithNodeParser.kt / JwOldQzParser.kt
//
// 强智 qz 三个变体解析器(QzBr / QzWithNode 同 QzParser 骨架; OldQz 完全独立)。
// 逐文件注释见对应 Kotlin 原文。

import Foundation
import SwiftSoup

/// 强智 qz_br 变体解析器。
///
/// 与 JwQzParser 的唯一差异：单元格内课名行后跟 `<br>` 而非 `<font>`，
/// 因此课名提取必须用 `substringBefore("<br>")` 而非 `substringBefore("<font")`。
///
/// 样本学校（上游 WakeupSchedule_BUPT SchoolListActivity.kt 实证）：
///   - 北京林业大学 newjwxt.bjfu.edu.cn
///   - 长春大学 cdjwc.ccu.edu.cn/jsxsd
///   - 长沙理工 xk.csust.edu.cn
///   - 广东金融 jwxt.gduf.edu.cn
///   - 江西农大南昌商学院 223.83.249.67:8080/jsxsd
///
/// 上游源码：dIT8Zv/WakeupSchedule_BUPT QzBrParser.kt (Apache-2.0)
final class JwQzBrParser: JwQzParser {

    /// 课名提取：用课名后第一个 `<br>` 截断，不再走 `<font` 路径。
    /// 上游原始实现见 QzBrParser.parseCourseName。
    ///
    /// 注意：上游没有对 substringBefore 缺失 `<br>` 做兜底，强行走 Jsoup 解析会
    /// 把整段 HTML 当课名；我们保留上游忠实行为，依赖 `generateCourseList`
    /// 入口处的 `courseElements.html()` 必然含 `<br>`（强智单元格结构）。
    override func parseCourseName(_ infoStr: String) -> String {
        infoStr.components(separatedBy: "<br>").first ?? infoStr
    }

    /// T8 §2.5: 继承 kbtable 锚点 + br-not-font 特征
    override var matchedFeatureList: [String] {
        super.matchedFeatureList + ["br-not-font"]
    }
}

/// 强智 qz_with_node 变体解析器。
///
/// 差异：title="周次(节次)" 的文本携带节次信息（不再让节次=所在大格位置），
/// 支持三种文本形态：
///   1) 含空格 → "1-16(周) 1-2节" — 按空格拆 [周次段, 节次段]
///   2) 无空格且无 [ ] → 独立 title="周次" + title="节次"
///   3) 其它 → "周N-X节[Y-Z节]" / "1-16(周)[1-2节]" 格式按 '周[' ']' 拆
///
/// 样本学校：北邮 jwgl.bupt.edu.cn/jsxsd、广外 jxgl.gdufs.edu.cn/jsxsd、
///          北邮 WebVPN、北理工、北理工珠海、海南大学、江苏师大等 14 所。
///
/// 上游源码：dIT8Zv/WakeupSchedule_BUPT QzWithNodeParser.kt (Apache-2.0)
final class JwQzWithNodeParser: JwQzParser {

    override func convert(day: Int, nodeCount: Int, infoStr: String, courseList: inout [JwCourse]) {
        let courseHtml = try! SwiftSoup.parse(infoStr)
        // 课名提取：上游 substringBefore("<font").substringBefore("<span>")
        // 第二段 needle 是 "<span>"（带尖括号），对 "<span title=..>" 永不命中，
        // 因此 with_node 页面必须用 <font title=..> 结构（实测 BUPT/JSNU 适配器一致）
        var namePart = infoStr.components(separatedBy: "<font").first ?? infoStr
        namePart = namePart.components(separatedBy: "<span>").first ?? namePart
        let courseName = ((try? SwiftSoup.parse(namePart.trimmingCharacters(in: .whitespaces)).text()) ?? "")
        let teacher = ((try? courseHtml.getElementsByAttributeValue("title", "老师").text()) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let room = (((try? courseHtml.getElementsByAttributeValue("title", "教室").text()) ?? "")
            + ((try? courseHtml.getElementsByAttributeValue("title", "分组").text()) ?? ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tempStr = ((try? courseHtml.getElementsByAttributeValue("title", "周次(节次)").text()) ?? "")

        // 三分支周次/节次提取
        let weekStr: String
        let nodeList: [String]
        if tempStr.contains(" ") {
            let parts = tempStr.components(separatedBy: " ")
            weekStr = parts.first ?? ""
            let nodePart = parts.count > 1 ? parts[1] : ""
            nodeList = nodePart
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .components(separatedBy: "-")
        } else if tempStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            weekStr = ((try? courseHtml.getElementsByAttributeValue("title", "周次").text()) ?? "")
            let nodeRaw = ((try? courseHtml.getElementsByAttributeValue("title", "节次").text()) ?? "")
            let afterParen = nodeRaw.components(separatedBy: ")").dropFirst().joined(separator: ")")
            nodeList = afterParen
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .components(separatedBy: "-")
        } else {
            weekStr = tempStr.components(separatedBy: ")").first.map { $0 + ")" } ?? tempStr
            let afterParen = tempStr.components(separatedBy: ")").dropFirst().joined(separator: ")")
            nodeList = afterParen
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .components(separatedBy: "-")
        }

        let weekList = weekStr.components(separatedBy: ",")
        var startWeek = 0
        var endWeek = 0
        var type = 0

        for item in weekList {
            if item.contains("-") {
                let weeks = item.components(separatedBy: "-")
                if !weeks.isEmpty { startWeek = Int(weeks[0].trimmingCharacters(in: .whitespaces)) ?? startWeek }
                if weeks.count > 1 {
                    type = {
                        if weeks[1].contains("单") { return 1 }
                        if weeks[1].contains("双") { return 2 }
                        return 0
                    }()
                    // ← weeks[1].substringBefore('(').toInt()
                    let before = weeks[1].components(separatedBy: "(").first ?? weeks[1]
                    endWeek = Int(before.trimmingCharacters(in: .whitespaces)) ?? endWeek
                }
            } else {
                let before = item.components(separatedBy: "(").first ?? item
                let v = Int(before.trimmingCharacters(in: .whitespaces)) ?? startWeek
                startWeek = v
                endWeek = v
            }
            // ← nodeList.first().substringBefore('节').toInt()
            let startNode = Int((nodeList.first ?? "1").components(separatedBy: "节").first ?? "1")
                ?? 1
            let endNode = Int((nodeList.last ?? "1").components(separatedBy: "节").first ?? "1")
                ?? startNode
            courseList.append(JwCourse(
                name: courseName,
                room: room,
                teacher: teacher,
                day: day,
                startNode: startNode,
                endNode: endNode,
                startWeek: startWeek,
                endWeek: endWeek,
                type: type))
        }
    }

    /// T8 §2.5: 继承 + title=周次(节次) 含空格 / 独立 title=周次+节次 特征
    override var matchedFeatureList: [String] {
        let base = super.matchedFeatureList
        guard let jsoup = try? SwiftSoup.parse(source) else { return base }
        let withNode = (try? jsoup.getElementsByAttributeValue("title", "周次(节次)")) ?? Elements()
        var hasSpace = false
        for el in withNode {
            if (((try? el.text()) ?? "").contains(" ")) { hasSpace = true; break }
        }
        if hasSpace { return base + ["title=周次(节次)空格"] }
        if ((try? jsoup.getElementsByAttributeValue("title", "周次")) ?? Elements()).isEmpty() == false {
            return base + ["title=周次独立", "title=节次独立"]
        }
        return base
    }
}

/// 强智 qz_old 变体解析器（"需要 IE 的那种"老强智教务，如湖南工学院）。
///
/// 与新版 QzParser 完全不同：单元格内无 title 属性，靠 `<br>` 分隔 + 时间串
/// 含 `[` + `]` + `周` + `节` 四要素来定位。type 恒为 0，不识别单/双周。
///
/// 样本学校（上游 SchoolListActivity.kt 实证）：湖南工学院等 3 所。
///
/// 上游源码：dIT8Zv/WakeupSchedule_BUPT OldQzParser.kt (Apache-2.0)
final class JwOldQzParser: JwParser, JwParserConfidenceReporting {

    let source: String

    init(_ source: String) {
        self.source = source
    }

    func generateCourseList() throws -> [JwCourse] {
        var courseList: [JwCourse] = []
        let doc = try SwiftSoup.parse(source)
        guard let kbtable = (try? doc.getElementById("kbtable")) ?? nil else { return courseList }
        let trs = (try? kbtable.getElementsByTag("tr")) ?? Elements()

        for tr in trs {
            let tds = (try? tr.getElementsByTag("td")) ?? Elements()
            if tds.isEmpty() { continue }

            // day 初始 -1: td[0]=节次标签 day=0, td[1..7]=周一..周日 day=1..7
            var day = -1

            for td in tds {
                day += 1
                let divs = (try? td.getElementsByTag("div")) ?? Elements()
                for div in divs {
                    // 过滤 display:none 和空白格
                    // 上游原文是 == "display: none;"（带空格），真实页面存在
                    // "display:none;"（无空格）变体（fixture timetable_kbtable_hidden.html
                    // 有两种写法各一个 div，expected 要求两者都被过滤），
                    // 因此去掉空格后比较 — 有意偏离 upstream 的 bug fix。
                    if (((try? div.attr("style")) ?? "").replacingOccurrences(of: " ", with: "") == "display:none;") { continue }
                    if ((try? div.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

                    let split = ((try? div.html()) ?? "").components(separatedBy: "<br>")
                    var preIndex = -1

                    func toCourse() {
                        if preIndex == -1 { return }
                        // 课名 = split[0] (SwiftSoup 解析剥残留 HTML 标签)
                        let courseName = ((try? SwiftSoup.parse(split[0]).text()) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        // room = split[preIndex+1], teacher = split[preIndex-1]
                        let room = ((try? SwiftSoup.parse(split[preIndex + 1]).text()) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let teacher = ((try? SwiftSoup.parse(split[preIndex - 1]).text()) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        // 时间串形如 "1-16周[1-2节]" 或 "10周[1-2节]"
                        let timeInfo = ((try? SwiftSoup.parse(split[preIndex]).text()) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .components(separatedBy: "周[")
                        guard timeInfo.count >= 2 else { return }
                        let weekPart = timeInfo[0]
                        let nodePart = timeInfo[1]
                        let startWeek: Int
                        let endWeek: Int
                        if weekPart.contains("-") {
                            let ws = weekPart.components(separatedBy: "-")
                            startWeek = Int(ws.first ?? "") ?? 0
                            endWeek = Int(ws.count > 1 ? ws[1] : "") ?? 0
                        } else {
                            startWeek = Int(weekPart) ?? 0
                            endWeek = startWeek
                        }
                        let ns = nodePart.components(separatedBy: "-")
                        let startNode = Int(ns.first ?? "") ?? 0
                        // "[1-2节]" split('-') 得 ["1","2节]"]，endNode 去 '节' 后再 toInt
                        let endRaw = ns.count > 1 ? ns[1] : ""
                        let endBefore = endRaw.components(separatedBy: "节").first ?? endRaw
                        let endNode = Int(endBefore) ?? 0

                        courseList.append(JwCourse(
                            name: courseName,
                            room: room,
                            teacher: teacher,
                            day: day,
                            startNode: startNode,
                            endNode: endNode,
                            startWeek: startWeek,
                            endWeek: endWeek,
                            type: 0))
                    }

                    for i in split.indices {
                        // 时间串特征：[ + ] + 周 + 节 四要素
                        if split[i].contains("[") && split[i].contains("]") &&
                            split[i].contains("节") && split[i].contains("周") {
                            if preIndex != -1 { toCourse() }
                            preIndex = i
                        }
                        if i == split.count - 1 { toCourse() }
                    }
                }
            }
        }
        return courseList
    }

    /// T8: kbtable + 单元格含[周][节]四要素 = 100; 仅 kbtable = 50
    var confidenceValue: Int {
        guard let doc = try? SwiftSoup.parse(source) else { return 0 }
        guard ((try? doc.getElementById("kbtable")) ?? nil) != nil else { return 0 }
        let hasTimeToken = source.contains("[") && source.contains("]") &&
            source.contains("周") && source.contains("节")
        return hasTimeToken ? 100 : 50
    }

    var matchedFeatureList: [String] {
        var out: [String] = []
        if source.contains("kbtable") { out.append("id=kbtable") }
        if source.contains("[") && source.contains("周") && source.contains("节") { out.append("单元格含[周][节]") }
        return out
    }
}
