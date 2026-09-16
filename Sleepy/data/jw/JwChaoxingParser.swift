// JwChaoxingParser.swift — ← JwChaoxingParser.kt
//
// 超星学习通/ChaoXing「综合教务管理系统」课表 JSON 解析器。
//
// 适配学校：吉林工商学院 (jwxt.jlbtc.edu.cn, 2026-09-05 采集包实锤 —
// 页面页脚 "Powered by ChaoXing") 及其他超星综合教务部署。
// 与 JwCquParser / JwWiseduParser 同类：source 不是 HTML，而是课表
// API 的 JSON 响应（在 WebView 内通过 fetch 拿到，见
// JwWebViewLoginScreen 的 chaoxing 分支 CHAOXING_FETCH_JS）。
//
// 数据来源（WebView 内 fetch 两段）：
//   1) GET /pkgl/xskb/queryKbForGrdb?sf_request_type=ajax   → 个人课表 rows
//      （无参数，服务端按会话取学期；学生须已在课表页会话内）
//   2) GET /admin/api/getZclistByXnxq?xnxq=…&sf_request_type=ajax → 节次时间
//      （部分部署路径无 /admin 前缀，fetch JS 按学校 URL 推断）
//
// 输入 JSON 形态（fetch JS 组装）：
//   {"xnxq":"2026-2027-1","dqzc":1,
//    "rows":[{"kcmc":…,"xjc":"1","xingqi":1,"rqxl":"101","zcstr":"1,2,..",
//             "tmc":…,"croommc":…}],
//    "periods":[{"jc":"1","kssj":"8:20","jssj":"9:05"}]}
//
// 字段映射（超星 → JwCourse）：
//   kcmc    课程名（班级表形态带 <a onclick=openKckb(..)>，剥 HTML）→ name
//   croommc 教室（同上剥 HTML；可空——体育课常无固定教室）       → room
//   tmc     教师（同上剥 HTML）                                  → teacher
//   xingqi  星期 1..7（int）；缺位回退 rqxl/100                  → day
//   xjc     节号（字符串/数字皆容）；缺位回退 rqxl%100            → startNode=endNode
//   zcstr   周次串 "1,2,3" 逗号形态 / "1-16" 区间形态             → 周次段
//
// 合并规则：同(课名,星期,教室,教师,周次串)且节号连续的行 → 合并为
// startNode..endNode 单条（超星按单节粒度返回行, 连堂课拆多行）。

import Foundation

final class JwChaoxingParser: JwParser {

    let source: String

    init(_ source: String) {
        self.source = source
    }

    /// 剥离 <a href=.. onclick=..>名字</a> 等标签，留纯文本（班级表接口形态）
    private func stripHtml(_ s: String) -> String {
        if s.contains("<") {
            return s.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 周次串 → 连续段列表（1..16 逗号/区间/混合形态）
    private func expandWeeks(_ zcstr: String) -> [Int] {
        var weeks = Set<Int>()
        for part in zcstr.split(whereSeparator: { $0 == "," || $0 == "，" }) {
            let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if t.contains("-") || t.contains("～") || t.contains("~") {
                let se = t.split(whereSeparator: { $0 == "-" || $0 == "～" || $0 == "~" })
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if se.count == 2, let a = Int(se[0]), let b = Int(se[1]), a <= b {
                    for w in a...b { weeks.insert(w) }
                }
            } else if let v = Int(t) {
                weeks.insert(v)
            }
        }
        return weeks.sorted()
    }

    /// 周次列表 → 连续段 [(startWeek, endWeek, type)]，口径与 JwWiseduParser.weekRuns 一致：
    /// 单连续段=每周(0)；整体等差 step=2=单周(1)/双周(2)；其余拆多段每段 0。
    private func weekRuns(_ weeks: [Int]) -> [(Int, Int, Int)] {
        if weeks.isEmpty { return [] }
        var runs: [(Int, Int)] = []
        var start = weeks[0]
        var prev = weeks[0]
        for w in weeks.dropFirst() {
            if w == prev + 1 {
                prev = w
            } else {
                runs.append((start, prev))
                start = w
                prev = w
            }
        }
        runs.append((start, prev))
        if runs.count == 1 { return [(runs[0].0, runs[0].1, 0)] }
        if weeks.count >= 2 && (1..<weeks.count).allSatisfy({ weeks[$0] - weeks[$0 - 1] == 2 }) {
            let type = weeks.first! % 2 == 1 ? 1 : 2
            return [(weeks.first!, weeks.last!, type)]
        }
        return runs.map { ($0.0, $0.1, 0) }
    }

    func generateCourseList() throws -> [JwCourse] {
        guard let data = source.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        let rows = root["rows"] as? [[String: Any]] ?? []

        struct Row {
            let name: String
            let day: Int
            let node: Int
            let weeks: [Int]
            let room: String
            let teacher: String
        }

        var parsed: [Row] = []
        for o in rows {
            func str(_ k: String) -> String {
                ((o[k] as? String) ?? (o[k] as? NSNumber)?.stringValue ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let name = stripHtml(str("kcmc"))
            if name.isEmpty { continue }

            // 星期: xingqi 优先, 缺位回退 rqxl 前缀 (rqxl = 星期*100 + 节号)
            let dayOpt = str("xingqi").toInt() ?? str("rqxl").toInt().map { $0 / 100 }
            guard let day = dayOpt, (1...7).contains(day) else { continue }

            // 节号: xjc 优先, 缺位回退 rqxl 后两位
            let nodeOpt = str("xjc").toInt() ?? str("rqxl").toInt().map { $0 > 99 ? $0 % 100 : $0 }
            guard let node = nodeOpt else { continue }

            let weeks = expandWeeks(str("zcstr"))
            if weeks.isEmpty { continue }

            parsed.append(Row(
                name: name, day: day, node: node, weeks: weeks,
                room: stripHtml(str("croommc")), teacher: stripHtml(str("tmc"))))
        }

        // 合并连堂: 排序后同(name,day,room,teacher,weeks串)且 node 前后衔接 → 拉通
        let sorted = parsed.sorted { a, b in
            if a.day != b.day { return a.day < b.day }
            if a.node != b.node { return a.node < b.node }
            return a.name < b.name
        }
        var result: [JwCourse] = []
        var i = 0
        while i < sorted.count {
            let cur = sorted[i]
            var endNode = cur.node
            var j = i + 1
            while j < sorted.count &&
                    sorted[j].name == cur.name && sorted[j].day == cur.day &&
                    sorted[j].room == cur.room && sorted[j].teacher == cur.teacher &&
                    sorted[j].weeks == cur.weeks && sorted[j].node == endNode + 1 {
                endNode = sorted[j].node
                j += 1
            }
            let weeks = cur.weeks
            // 周次段: 一行可能展开为多段 (非连续周次, 如 1-3周 + 8-9周)
            for (sw, ew, type) in weekRuns(weeks) {
                result.append(JwCourse(
                    name: cur.name, room: cur.room, teacher: cur.teacher,
                    day: cur.day, startNode: cur.node, endNode: endNode,
                    startWeek: sw, endWeek: ew,
                    type: type))
            }
            i = j
        }
        return result
    }
}

private extension String {
    /// Kotlin String.toIntOrNull() 语义
    func toInt() -> Int? {
        let t = trimmingCharacters(in: .whitespaces)
        return Int(t)
    }
}
