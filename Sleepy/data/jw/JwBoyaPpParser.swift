// JwBoyaPpParser.swift — ← JwBoyaPpParser.kt
// 博雅研究生平台 (超星 chaoxingbook 旗下"博雅研究生", /pp/ 前端) 课表 JSON 解析器。
//
// 适配学校：燕山大学研究生 (yjsxt.ysu.edu.cn/pp, fid=41571, 2026-09-06
// 采集包 + 逐周接口实采 390 行双实锤)。平台为多校 SaaS
// (代码内含 YANSHANDAXUE / DALIANJIAOTONG 等校 fid 常量), 后续同产品
// 学校可直接复用本 type。
// 与 JwCquParser / JwChaoxingParser 同类：source 不是 HTML, 而是课表
// API 的 JSON 响应 (WebView 内通过 fetch 拿到, 见 JwWebViewLoginScreen
// 的 boya_pp 分支 BOYA_PP_FETCH_JS)。
//
// 数据来源 (WebView 内 fetch 三段, token 头 + 同源 Cookie):
//   1) GET /api/microForm/term                     → 学期列表 (termBeginTime/weekEnd 在此)
//   2) GET /api/schedule/class/setting/current?yearTerm=… → lessonConfig 节次时间
//   3) GET /api/schedule/table/byStudent?whichWeek=N&yearTerm=…
//      → 逐周排课行 (2026-09 实测: 不带 whichWeek 返回的是不完整子集,
//        必须按 weekEnd 逐周抓; 每行自带 whichWeek int; 19 周 390 行)
//
// 输入 JSON 形态 (fetch JS 组装; 兼容裸 byStudent 数组与 {code,data} 信封):
//   {"term":"2026-2027-1","rows":[{…}]}   ← fetch JS 组装形态
//   [ {…}, … ]                            ← byStudent data 裸数组
//   {"code":200,"data":[{…}]}             ← byStudent 完整信封
//
// 行字段映射 (博雅 → JwCourse):
//   courseName        课程名                                → name
//   courseTeacher[].name 教师 (多人按姓名排序后"、"连接)     → teacher
//   classroomName     教室 (空则回退 classroomCode)          → room
//   week              星期 1..7 (int)                        → day
//   lessonNumber      起始节 (int; 每行单节粒度)             → startNode=endNode
//   whichWeek         周次 (int; 容忍字符串, 回退 originWhichWeek) → 周次集合
//
// 合并规则：同 (课名, 星期, 教室, 教师集合) 分组; 组内各节号的周次集合
// 完全相等且节号连续 → 合并为 startNode..endNode 单条 (研究生课常为
// 同一周集中授课, 同槽位拆成单节多行)。周次段口径与 JwChaoxingParser
// weekRuns 一致: 单连续段=每周(0); 整体等差 step=2=单周(1)/双周(2); 其余拆多段。
// suspension(停课) / deleted 行剔除 — 停课课不该进个人课表。

import Foundation

final class JwBoyaPpParser: JwParser, JwParserConfidenceReporting {

    let source: String

    init(_ source: String) {
        self.source = source
    }

    // MARK: - JSON 取值辅助 (← Kotlin str() / intOf())

    /// 行元素取字符串 (缺键/非原始类型返回空串)
    private func str(_ o: [String: Any], _ k: String) -> String {
        jstr(o, k)
    }

    /// 原始标量 → Int (数字 / 数字字符串皆容; 布尔与非数字串 → nil)
    private func intFromScalar(_ v: Any?) -> Int? {
        guard let v = v else { return nil }
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : Int(t)
        }
        if let n = v as? NSNumber {
            if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() { return nil }
            return Int(n.stringValue)
        }
        return nil
    }

    /// 行元素取 int: 原始数字 / 数字字符串 / [n,…] 数组首元素 皆容; 依次试多键
    private func intOf(_ o: [String: Any], _ keys: [String]) -> Int? {
        for k in keys {
            guard let el = o[k] else { continue }
            let n: Int?
            if let arr = el as? [Any] {
                n = intFromScalar(arr.first)
            } else if el is [String: Any] {
                n = nil
            } else {
                n = intFromScalar(el)
            }
            if let n = n { return n }
        }
        return nil
    }

    /// JsonPrimitive.contentOrNull == "true" 语义: 布尔 true 或字符串 "true"
    private func isTrueFlag(_ o: [String: Any], _ k: String) -> Bool {
        guard let v = o[k] else { return false }
        if let s = v as? String { return s.trimmingCharacters(in: .whitespaces) == "true" }
        if let n = v as? NSNumber, CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() {
            return n.boolValue
        }
        return false
    }

    // MARK: - 静态锚点

    /// 静态锚点快查 (confidence 不做完整解析, 避免 Registry 兜底时 N+1)
    var confidenceValue: Int {
        (source.contains("\"rows\"") && source.contains("\"courseName\"")) ? 90 : 0
    }

    var matchedFeatureList: [String] {
        var hits: [String] = []
        if source.contains("\"rows\"") { hits.append("boya_pp:rows") }
        if source.contains("\"courseName\"") { hits.append("boya_pp:courseName") }
        if source.contains("\"whichWeek\"") { hits.append("boya_pp:whichWeek") }
        if source.contains("\"lessonNumber\"") { hits.append("boya_pp:lessonNumber") }
        return hits
    }

    // MARK: - 解析

    private struct Prim {
        let name: String
        let day: Int
        let node: Int
        let week: Int
        let room: String
        let teacher: String
    }

    /// 分组键: (课名, 星期, 教室, 教师)
    private struct GroupKey: Hashable {
        let name: String
        let day: Int
        let room: String
        let teacher: String
    }

    func generateCourseList() throws -> [JwCourse] {
        guard let rows = extractRows() else { return [] }

        var prims: [Prim] = []
        for el in rows {
            guard let o = el as? [String: Any] else { continue }

            // 停课/已删除行剔除
            if isTrueFlag(o, "suspension") { continue }
            if isTrueFlag(o, "deleted") { continue }

            let name = str(o, "courseName")
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

            guard let day = intOf(o, ["week"]), (1...7).contains(day) else { continue }
            guard let node = intOf(o, ["lessonNumber"]), node >= 1 else { continue }
            guard let week = intOf(o, ["whichWeek", "originWhichWeek"]) else { continue }

            let room = str(o, "classroomName").isEmpty ? str(o, "classroomCode") : str(o, "classroomName")
            // courseTeacher[].name → 去重 + 按姓名排序 + "、"连接
            var names: [String] = []
            if let teachers = o["courseTeacher"] as? [Any] {
                for t in teachers {
                    guard let to = t as? [String: Any] else { continue }
                    let n = jstr(to, "name").trimmingCharacters(in: .whitespacesAndNewlines)
                    if n.isEmpty { continue }
                    if !names.contains(n) { names.append(n) }
                }
            }
            let teacher = names.sorted().joined(separator: "、")

            prims.append(Prim(name: name, day: day, node: node, week: week, room: room, teacher: teacher))
        }
        if prims.isEmpty { return [] }

        // 分组: (课名, 星期, 教室, 教师) → 节号 → 周次集合 (保序, ← Kotlin LinkedHashMap)
        var groupOrder: [GroupKey] = []
        var grouped: [GroupKey: [Int: Set<Int>]] = [:]
        for p in prims {
            let key = GroupKey(name: p.name, day: p.day, room: p.room, teacher: p.teacher)
            if grouped[key] == nil {
                groupOrder.append(key)
                grouped[key] = [:]
            }
            grouped[key, default: [:]][p.node, default: []].insert(p.week)
        }

        // 组内合并: 节号连续且周次集合相等 → 一条课块; 周次段展开
        var result: [JwCourse] = []
        for key in groupOrder {
            let nodeWeeks = grouped[key] ?? [:]
            let nodes = nodeWeeks.keys.sorted()
            var i = 0
            while i < nodes.count {
                var j = i
                while j + 1 < nodes.count,
                      nodes[j + 1] == nodes[j] + 1,
                      nodeWeeks[nodes[j + 1]] == nodeWeeks[nodes[j]] {
                    j += 1
                }
                let startNode = nodes[i]
                let endNode = nodes[j]
                let weeks = (nodeWeeks[nodes[i]] ?? []).sorted()
                for (sw, ew, type) in weekRuns(weeks) {
                    result.append(JwCourse(
                        name: key.name,
                        room: key.room,
                        teacher: key.teacher,
                        day: key.day,
                        startNode: startNode,
                        endNode: endNode,
                        startWeek: sw,
                        endWeek: ew,
                        type: type))
                }
                i = j + 1
            }
        }
        return result
    }

    /// 从 source 提取排课行数组: {rows:[…] } / [ […] ] / {code,data:[…] } 三形态
    private func extractRows() -> [Any]? {
        guard let data = source.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        if let arr = root as? [Any] { return arr }
        guard let obj = root as? [String: Any] else { return nil }
        if let rows = obj["rows"] as? [Any] { return rows }
        switch obj["data"] {
        case let d as [Any]: return d
        case let d as [String: Any]: return d["rows"] as? [Any]
        default: return nil
        }
    }

    /// 周次列表 → 连续段 [(startWeek, endWeek, type)], 口径与 JwChaoxingParser 一致
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
}
