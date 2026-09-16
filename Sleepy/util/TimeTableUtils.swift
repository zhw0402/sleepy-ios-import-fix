// TimeTableUtils.swift — ← util/TimeTableUtils.kt (逐行翻译, GPL-3.0)

import Foundation

/// 时间表 (timeJson) 解析与查询工具。
///
/// TimeTableEntity.timeJson 格式:
///   [{"node":1,"start":"08:00","end":"08:45"}, {"node":2,...}, ...]
///
/// UI 渲染时用 timeSlotsFor 把 JSON 转为每节独立的 TimeSlot；
/// 与 WakeUp 默认 12 节制对应，若用户改 nodesPerDay，会按节点列表拆段。
enum TimeTableUtils {

    /// 默认节次时间表（12 节 / 45-50 分钟）。
    ///
    /// 这是 timeJson 的**唯一权威默认值**；
    /// TimeTableEntity 默认构造、TimeTableUtils 解析、UI 渲染都从这里走。
    static let DEFAULT_TIME_JSON = """
        [
            {"node":1,"start":"08:00","end":"08:45"},
            {"node":2,"start":"08:55","end":"09:40"},
            {"node":3,"start":"10:00","end":"10:45"},
            {"node":4,"start":"10:55","end":"11:40"},
            {"node":5,"start":"14:00","end":"14:45"},
            {"node":6,"start":"14:55","end":"15:40"},
            {"node":7,"start":"16:00","end":"16:45"},
            {"node":8,"start":"16:55","end":"17:40"},
            {"node":9,"start":"19:00","end":"19:45"},
            {"node":10,"start":"19:55","end":"20:40"},
            {"node":11,"start":"20:50","end":"21:35"},
            {"node":12,"start":"21:45","end":"22:30"}
        ]
        """

    struct NodeTime: Equatable {
        let node: Int
        let start: Date   // 当日时刻,仅时分秒有意义
        let end: Date
    }

    /// 解析 timeJson -> 按 node 排序的 list
    static func parseNodes(_ timeJson: String) -> [NodeTime] {
        guard let data = timeJson.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: Date())
        return arr.compactMap { o -> NodeTime? in
            guard let node = (o["node"] as? NSNumber)?.intValue,
                  let startS = o["start"] as? String,
                  let endS = o["end"] as? String,
                  let start = parseTime(startS, base: today),
                  let end = parseTime(endS, base: today) else { return nil }
            return NodeTime(node: node, start: start, end: end)
        }.sorted { $0.node < $1.node }
    }

    private static func parseTime(_ s: String, base: Date) -> Date? {
        // "HH:mm" (也容忍 "HH:mm:ss")
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: base)
        comps.hour = parts[0]; comps.minute = parts[1]; comps.second = parts.count > 2 ? parts[2] : 0
        return Calendar.current.date(from: comps)
    }

    static func formatTime(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// 把节点时间表转为每节独立的 TimeSlotRow 展示行(D5 TimeSlot 的数据来源)
    static func timeSlotsFor(timeJson: String) -> [TimeSlotRow] {
        parseNodes(timeJson).map { n in
            TimeSlotRow(node: n.node, start: formatTime(n.start), end: formatTime(n.end))
        }
    }

    /// 课程的开始节-结束节对应的"开始时间-结束时间"。
    /// 直接用节点的 start/end 拼接，不依赖外层 TimeSlot。
    /// 找不到节点则返回 nil。
    static func courseTimeString(courseStartNode: Int, courseStep: Int, timeJson: String,
                                 ownTime: Bool = false, startTime: String = "", endTime: String = "") -> String? {
        let parts = courseTimeParts(courseStartNode: courseStartNode, courseStep: courseStep,
                                    timeJson: timeJson, ownTime: ownTime,
                                    startTime: startTime, endTime: endTime)
        return parts.map { "\($0.0)-\($0.1)" }
    }

    /// 课程的 (开始时间, 结束时间)，用于需要分行渲染的场景。
    /// 逻辑同 courseTimeString，但返回拆分后的两部分，避免外层再 split。
    static func courseTimeParts(courseStartNode: Int, courseStep: Int, timeJson: String,
                                ownTime: Bool = false, startTime: String = "", endTime: String = "") -> (String, String)? {
        if ownTime && !startTime.isEmpty && !endTime.isEmpty {
            return (startTime, endTime)
        }
        let nodes = parseNodes(timeJson)
        if nodes.isEmpty { return nil }
        let endNode = courseStartNode + courseStep - 1
        guard let first = nodes.first(where: { $0.node == courseStartNode }),
              let last = nodes.first(where: { $0.node == endNode }) else { return nil }
        return (formatTime(first.start), formatTime(last.end))
    }

    /// 根据课程的 startTime/endTime 反算等效的 (startNode, step)。
    /// 用于把 ownTime=true 的课映射到节次网格上。
    ///
    /// 规则：
    /// - startNode = 时间表中 start ≤ courseStart 的最大节点（向下取）
    /// - endNode   = 从 startNode 起沿节点序连续延伸的最后一节 — 课程在节次空隙内
    ///   结束时停在空隙前的那一节, 绝不跨过空隙吸附到下一节 (用户 2026-09-09:
    ///   12:30 结束跨午间空隙被吸进 14:00 节 = 报障本体; 旧行为 "end ≥ courseEnd
    ///   的最小节点" 会跨空隙撑大 step, 已否决)
    /// - step      = endNode - startNode + 1
    /// - 若 StartTime 早于第一节，用第1节；endTime 晚于最后一节，用最后一节
    /// 返回 nil 表示无法映射（时间格式错误或时间表为空）。
    static func timeToNode(_ startTime: String, _ endTime: String, _ timeJson: String) -> (Int, Int)? {
        let nodes = parseNodes(timeJson)
        if nodes.isEmpty { return nil }
        let refDay = Calendar.current.startOfDay(for: nodes[0].start)
        guard let st = parseTime(startTime, base: refDay),
              let et = parseTime(endTime, base: refDay) else { return nil }

        let startIdx = nodes.lastIndex { $0.start <= st } ?? -1
        let sIdx = max(startIdx, 0)
        var endIdx = sIdx
        var i = sIdx + 1
        while i < nodes.count && nodes[i].start < et {
            endIdx = i
            i += 1
        }

        let startNode = nodes[sIdx].node
        let endNode = nodes[endIdx].node
        if endNode < startNode { return nil }
        return (startNode, endNode - startNode + 1)
    }

    // ------------------------------------------------------------------
    // issue#23 §5 渲染: 非常规时间胶囊按真实分钟在网格内按比例定位
    // ------------------------------------------------------------------

    /// "HH:mm"/"HH:mm:ss" → 自午夜起秒数; 非法 → nil
    static func hmToSeconds(_ s: String) -> Int? {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + (parts.count > 2 ? parts[2] : 0)
    }

    /// 便捷: 拿 TimeTableEntity 直接出 rows
    static func timeSlotsFor(table: TimeTableEntity?) -> [TimeSlotRow] {
        table.map { timeSlotsFor(timeJson: $0.timeJson) } ?? []
    }

    // ------------------------------------------------------------------
    // 编辑用的 row 数据模型 + JSON 互转
    // 共享给 EditTableScreen + ImportSheet
    // ------------------------------------------------------------------

    /// 节次编辑用的行模型：node=节次编号, start/end="HH:mm"。
    /// 节点编号在删除时会重新 1..N 连续编号。
    struct TimeSlotRow: Codable, Equatable {
        var node: Int
        var start: String
        var end: String
        /// Non-null only for nodes created by the manual-course edge controls.
        var edgeClass: EdgeClass? = nil
    }

    /// timeJson -> 编辑 rows (按数组顺序)
    static func parseTimeSlotRows(_ timeJson: String) -> [TimeSlotRow] {
        guard let data = timeJson.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return (1...12).map { node in TimeSlotRow(node: node, start: smartStartDefault(node), end: smartEndDefault(node)) }
        }
        return arr.enumerated().map { i, o in
            TimeSlotRow(
                node: (o["node"] as? NSNumber)?.intValue ?? (i + 1),
                start: (o["start"] as? String) ?? smartStartDefault(i + 1),
                end: (o["end"] as? String) ?? smartEndDefault(i + 1),
                edgeClass: (o["edge"] as? String).flatMap(TimeTableUtils.parseEdgeClass)
            )
        }
    }

    /// rows -> timeJson (edge 元数据只在边缘节点时写出 "edge" 键)
    static func buildTimeJsonFromRows(_ rows: [TimeSlotRow]) -> String {
        let arr: [[String: Any]] = rows.map { row in
            var d: [String: Any] = ["node": row.node, "start": row.start, "end": row.end]
            if let e = row.edgeClass {
                d["edge"] = e.rawValue
            }
            return d
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// 删除某 node 后**重新编号**为 1..N (用户友好)，返回新 list。
    static func removeAndRenumber(_ rows: [TimeSlotRow], node: Int) -> [TimeSlotRow] {
        rows.filter { $0.node != node }.enumerated().map { idx, r in
            var copy = r; copy.node = idx + 1; return copy
        }
    }

    /// 追加一节 (node = max + 1)，时间留空让用户填。
    static func appendEmptyRow(_ rows: [TimeSlotRow]) -> [TimeSlotRow] {
        let nextNode = (rows.map { $0.node }.max() ?? 0) + 1
        return rows + [TimeSlotRow(node: nextNode, start: "", end: "")]
    }

    // ------------------------------------------------------------------
    // 课表外节次 (issue #23 / 手动课程"非常规"开关)
    // 标准节次 = 1..maxContiguousFromOne 的连续节点; 前置边缘 < 1, 后置边缘 > maxContiguous。
    // 这些节点是 timeJson 的真实结构: 删除边缘节点的最后一门课时必须回收该节点。
    // ------------------------------------------------------------------

    /// 边缘节次的方向: 前置 (< 1) / 后置 (> maxContiguous)
    enum EdgeClass: String, Codable, Equatable {
        case before = "before"
        case after = "after"
    }

    /// timeJson 中 1..N 的最大连续 N — 标准节次的上界。
    /// 标准节点的 edgeClass 必须为 null; 默认 12 节制返回 12, 全删/异常返回 0。
    private static func maxContiguousFromOne(_ rows: [TimeSlotRow]) -> Int {
        let std = rows.filter { $0.edgeClass == nil }.map { $0.node }
        let present = Set(std)
        guard present.contains(1) else { return 0 }
        var n = 1
        while present.contains(n + 1) { n += 1 }
        return n
    }

    /// "before"/"after" (大小写不敏感) -> EdgeClass, 其他 -> nil
    private static func parseEdgeClass(_ s: String) -> EdgeClass? {
        EdgeClass(rawValue: s.lowercased())
    }

    /// 在 timeJson 新增边缘节次节点:
    ///   - Before: 无前置时 = 0, 否则 = (现有前置最小值) - 1
    ///   - After:  无后置时 = maxContiguous + 1, 否则 = (现有后置最大值) + 1
    static func insertEdgeNode(timeJson: String, edgeClass: EdgeClass, start: String, end: String) -> String {
        let rows = parseTimeSlotRows(timeJson)
        let newNode: Int
        switch edgeClass {
        case .before:
            let eb = rows.filter { $0.edgeClass == .before }
            newNode = eb.isEmpty ? 0 : (eb.map { $0.node }.min() ?? 0) - 1
        case .after:
            let maxStd = maxContiguousFromOne(rows)
            let ea = rows.filter { $0.edgeClass == .after }
            newNode = ea.isEmpty ? maxStd + 1 : (ea.map { $0.node }.max() ?? 0) + 1
        }
        return buildTimeJsonFromRows(rows + [TimeSlotRow(node: newNode, start: start, end: end, edgeClass: edgeClass)])
    }

    /// 删除边缘节次节点 — 仅当 (a) 确实是边缘节点 (b) 无课程引用时才回收; 否则原样返回
    static func removeEdgeNodeIfUnused(timeJson: String, edgeNode: Int, usedNodes: Set<Int>) -> String {
        let rows = parseTimeSlotRows(timeJson)
        guard let target = rows.first(where: { $0.node == edgeNode }) else { return timeJson }
        if target.edgeClass == nil { return timeJson }
        if usedNodes.contains(edgeNode) { return timeJson }
        return buildTimeJsonFromRows(rows.filter { $0.node != edgeNode })
    }

    /// 列出某方向的边缘节点号: Before 降序 (0,-1,...), After 升序 (13,14,...)
    static func edgeNodesOf(timeJson: String, edgeClass: EdgeClass) -> [Int] {
        let nodes = parseTimeSlotRows(timeJson)
            .filter { $0.edgeClass == edgeClass }
            .map { $0.node }
        if edgeClass == .before {
            return nodes.sorted(by: >)
        }
        return nodes.sorted()
    }

    // MARK: - issue#23 逐卡非常规 (← effectiveCourseTime / maxStandardNode / EdgeCandidate / edgeCandidates / updateEdgeNodeTimes)

    /**
     * issue#23 §3.3 逐卡 effective 时间解析 — validateCourseDraft / buildCourseEntity /
     * blockRangeMinutes 共用契约, 四处解析必须一致:
     *   1. isIrregularTime=true → 课程自带覆盖起止直接生效 (不受槽位默认时间窗口约束, §2.3)
     *   2. startNode 为边缘槽位 (edgeClass != null) → 槽位默认时间
     *   3. 否则 → 标准 1..N 节次时间 (startNode..startNode+step-1)
     * 无法解析 (时间无效 / 节次不存在) → nil, 由调用方校验报错, 不静默给值。
     */
    static func effectiveCourseTime(isIrregularTime: Bool, startTime: String, endTime: String,
                                    startNode: Int, step: Int, timeJson: String) -> (String, String)? {
        if isIrregularTime {
            guard let s = normalizedHm(startTime), let e = normalizedHm(endTime) else { return nil }
            return (s, e)
        }
        let rows = parseTimeSlotRows(timeJson)
        guard let first = rows.first(where: { $0.node == startNode }),
              let last = rows.first(where: { $0.node == startNode + step - 1 }) else { return nil }
        return (first.start, last.end)
    }

    /// "HH:mm" → 当日分钟数 (widget 窗口/冲突聚簇共用的时间域刻度); 非法 → nil
    static func hmMinutes(_ v: String) -> Int? {
        let parts = v.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    /// "H:mm"/"HH:mm" 规范为 "HH:mm"(LocalTime.toString 语义); 非法 → nil
    private static func normalizedHm(_ v: String) -> String? {
        let t = v.trimmingCharacters(in: .whitespaces)
        let parts = t.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return String(format: "%02d:%02d", h, m)
    }

    /// 标准 1..N 连续节次上界 (edge 行不参与) — 逐卡重构后标准卡片只允许 1..maxStd
    static func maxStandardNode(_ timeJson: String) -> Int {
        maxContiguousFromOne(parseTimeSlotRows(timeJson))
    }

    /// 候选节次: exists=true = 复用已有槽位(带默认时间); exists=false = 新建(时间待用户填)
    struct EdgeCandidate: Hashable {
        let node: Int
        let start: String
        let end: String
        let exists: Bool
        /// 候选归属: Before 组节点 <= 0, After 组节点 > 0 (edgeCandidates 构造保证)
        var edgeClass: EdgeClass { node <= 0 ? .before : .after }
    }

    /**
     * 候选节次集合 (§2.2): Before 组升序(-2,-1,0...) + After 组升序(N+1,N+2...)。
     * 每组 = 该方向全部已有边缘槽位 + 紧贴边界的一个「新建」候选;
     * 无任何槽位时新建候选 = 0 / maxContiguous+1。禁止跳号。
     */
    static func edgeCandidates(_ timeJson: String) -> [EdgeCandidate] {
        let rows = parseTimeSlotRows(timeJson)
        let beforeSlots = rows.filter { $0.edgeClass == .before }.sorted { $0.node < $1.node }
        let afterSlots = rows.filter { $0.edgeClass == .after }.sorted { $0.node < $1.node }
        let maxStd = maxContiguousFromOne(rows)
        let newBefore = (beforeSlots.map { $0.node }.min() ?? 1) - 1
        let newAfter = (afterSlots.map { $0.node }.max() ?? maxStd) + 1
        let beforeGroup = [EdgeCandidate(node: newBefore, start: "", end: "", exists: false)] +
            beforeSlots.map { EdgeCandidate(node: $0.node, start: $0.start, end: $0.end, exists: true) }
        let afterGroup = afterSlots.map { EdgeCandidate(node: $0.node, start: $0.start, end: $0.end, exists: true) } +
            [EdgeCandidate(node: newAfter, start: "", end: "", exists: false)]
        return beforeGroup + afterGroup
    }

    /**
     * 修改某边缘槽位的默认时间 — 仅 edgeClass != nil 的行可改;
     * 节点不存在或为标准行时原样返回入参 (调用方无需预检)。
     */
    static func updateEdgeNodeTimes(timeJson: String, node: Int, start: String, end: String) -> String {
        let rows = parseTimeSlotRows(timeJson)
        guard let target = rows.first(where: { $0.node == node }) else { return timeJson }
        if target.edgeClass == nil { return timeJson }
        return buildTimeJsonFromRows(
            rows.map { $0.node == node ? TimeSlotRow(node: $0.node, start: start, end: end, edgeClass: $0.edgeClass) : $0 })
    }

    /// v7.10.16k 无损合并 — "哪个大用哪个"(用户 2026-09-03):
    /// 双方作息逐节合并, 结果 = max(两边节次数, requiredNodeCount), 任何一方不得把另一方压小。
    /// 同一节次: 导入源非空时间优先(空串视为没声明), 否则原表, 都没有用 smart 默认。
    /// 超出双方声明的节次(requiredNodeCount=导入课程实际到达的最大节)用 smart 默认铺底。
    static func mergeMostComplete(currentJson: String, incomingJson: String, requiredNodeCount: Int = 0) -> String {
        // 空串 = 没声明 — 不能进 parseTimeSlotRows(它会 catch 出 12 行 smart 伪声明,
        // 反过来把有真实作息的一方当"缺省"盖掉)
        var currentRows: [TimeSlotRow] = []
        if !currentJson.isEmpty { currentRows = parseTimeSlotRows(currentJson) }
        var incomingRows: [TimeSlotRow] = []
        if !incomingJson.isEmpty { incomingRows = parseTimeSlotRows(incomingJson) }
        let cur = Dictionary(currentRows.map { ($0.node, $0) }, uniquingKeysWith: { a, _ in a })
        let inc = Dictionary(incomingRows.map { ($0.node, $0) }, uniquingKeysWith: { a, _ in a })
        let declared = max(currentRows.map { $0.node }.max() ?? 0,
                           incomingRows.map { $0.node }.max() ?? 0)
        if declared == 0 && requiredNodeCount <= 0 { return DEFAULT_TIME_JSON }
        let count = max(declared, requiredNodeCount, 1)
        let rows = (1...count).map { node -> TimeSlotRow in
            let i = inc[node]
            let c = cur[node]
            return TimeSlotRow(
                node: node,
                start: i.flatMap { $0.start.isEmpty ? nil : $0.start }
                    ?? c.flatMap { $0.start.isEmpty ? nil : $0.start }
                    ?? smartStartDefault(node),
                end: i.flatMap { $0.end.isEmpty ? nil : $0.end }
                    ?? c.flatMap { $0.end.isEmpty ? nil : $0.end }
                    ?? smartEndDefault(node))
        }
        return buildTimeJsonFromRows(rows)
    }

    private static func smartStartDefault(_ node: Int) -> String {
        switch node {
        case ...2: return "08:00"
        case ...4: return "10:00"
        case ...6: return "14:00"
        case ...8: return "16:00"
        case ...10: return "19:00"
        default: return "20:50"
        }
    }

    private static func smartEndDefault(_ node: Int) -> String {
        switch node {
        case ...2: return "09:40"
        case ...4: return "11:40"
        case ...6: return "15:40"
        case ...8: return "17:40"
        case ...10: return "20:40"
        default: return "22:30"
        }
    }
}
