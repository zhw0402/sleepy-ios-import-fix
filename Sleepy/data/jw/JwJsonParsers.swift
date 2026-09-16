// JwJsonParsers.swift — ← JwSeuParser.kt / JwZjuParser.kt / JwUstcParser.kt / JwScuParser.kt / JwNeuParser.kt
// 五所高校课表 JSON 协议解析器(985 批次 B 档)。共同点: source 不是 HTML 而是课表 JSON
// (用户粘入或 WebView fetch 拿到), JSON 解析 + 字段映射一次性完成。
// 逐解析器的协议形态/上游参考/单双周限制见各 struct 头注释与 JwProtocol.swift 常量注释。

import Foundation

// MARK: - JSON 容器取值辅助(等价 Kotlin str() 扩展; 模块级 internal 供 JwCquParser 复用)

func jsonObj(_ any: Any?) -> [String: Any]? { any as? [String: Any] }
func jsonArr(_ any: Any?) -> [Any]? { any as? [Any] }

/// JsonPrimitive.contentOrNull 等价: 字符串/数字都取 trimmed 字符串
func jstr(_ o: [String: Any]?, _ key: String) -> String {
    guard let o = o, let v = o[key] else { return "" }
    if let s = v as? String { return s.trimmingCharacters(in: .whitespaces) }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}

func jint(_ o: [String: Any]?, _ key: String) -> Int? {
    let s = jstr(o, key)
    return s.isEmpty ? nil : Int(s)
}

// MARK: - 东南大学(正方 URP 系, newxk.urp.seu.edu.cn)
//
// 字段映射: KCM→name SKJS→teacher JASMC→room SKXQ→day KSJC→startNode JSJC→endNode ZCMC→周次段。
// 支持三形态 ZCMC: 范围"1-16周"/单双周"1-10周(单)"/离散"2,4,6周"。
// 单/双周端点收敛到第一个匹配周次(SEUTimetable parseWeekRange 语义)。
final class JwSeuParser: JwParser, JwParserConfidenceReporting {

    let source: String

    init(_ source: String) {
        self.source = source
    }

    func generateCourseList() throws -> [JwCourse] {
        guard let data = source.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return [] }

        var arr: [Any] = []
        if let a = root as? [Any] {
            arr = a
        } else if let o = root as? [String: Any], let a = jsonArr(o["data"]) {
            arr = a
        } else {
            return []
        }

        var out: [JwCourse] = []
        for el in arr {
            guard let o = jsonObj(el) else { continue }
            let name = jstr(o, "KCM")
            if name.isEmpty { continue }
            var teacher = jstr(o, "SKJS")
            if teacher.lowercased() == "null" { teacher = "" }
            var room = jstr(o, "JASMC")
            if room.lowercased() == "null" { room = "" }
            guard let day = jint(o, "SKXQ") else { continue }
            guard let startNode = jint(o, "KSJC") else { continue }
            let endNode = jint(o, "JSJC") ?? startNode
            let zcmc = jstr(o, "ZCMC")

            for (sw, ew, type) in parseWeekRanges(zcmc) {
                out.append(JwCourse(
                    name: name, room: room, teacher: teacher,
                    day: min(max(day, 1), 7),
                    startNode: max(startNode, 1),
                    endNode: max(endNode, startNode),
                    startWeek: sw, endWeek: ew, type: type))
            }
        }
        return out
    }

    /// ZCMC 串 → [(startWeek, endWeek, type)]。三形态: 范围/单双周(端点收敛)/离散/单值。
    func parseWeekRanges(_ zcmc: String) -> [(Int, Int, Int)] {
        if zcmc.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        var out: [(Int, Int, Int)] = []

        // 1. 单/双周标志
        let typeInt = zcmc.contains("(单)") ? 1 : (zcmc.contains("(双)") ? 2 : 0)

        // 2. 剥 "周" + "(单|双)" + 空白; 按逗号拆离散段
        let clean = zcmc
            .replacingOccurrences(of: "周", with: "")
            .replacingOccurrences(of: "(单)", with: "")
            .replacingOccurrences(of: "(双)", with: "")
            .trimmingCharacters(in: .whitespaces)
        let segments = clean.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for seg in segments {
            if seg.contains("-") {
                let parts = seg.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard let a = Int(parts[0]) else { continue }
                let b = parts.count > 1 ? (Int(parts[1]) ?? a) : a
                // 单双周端点收敛到第一个匹配周次
                let adjustedA: Int
                switch typeInt {
                case 1: adjustedA = a % 2 == 0 ? a + 1 : a   // 单周首=奇数
                case 2: adjustedA = a % 2 != 0 ? a + 1 : a   // 双周首=偶数
                default: adjustedA = a
                }
                out.append((adjustedA, b, typeInt))
            } else if let v = Int(seg) {
                out.append((v, v, 0))
            }
        }
        return out
    }

    var confidenceValue: Int {
        let quoted = source.contains("\"KCM\"") && source.contains("\"ZCMC\"")
        let bare = source.contains("KCM") && source.contains("ZCMC")
        if quoted { return 90 }
        if bare { return 70 }
        return 0
    }

    var matchedFeatureList: [String] {
        var out: [String] = []
        if source.contains("\"KCM\"") { out.append("KCM") }
        if source.contains("\"ZCMC\"") { out.append("ZCMC") }
        if source.contains("\"SKXQ\"") { out.append("SKXQ") }
        return out
    }
}

// MARK: - 浙江大学(正方新版 UGR 本研, zdbk.zju.edu.cn)
//
// 数据源: /classroom-web/classroom/searchTimetable 返回 kbList 数组。
// kcb 是 "课名<br>周次串<br>老师<br>教室" 拼接的 HTML 片段(以 zwf 截断);
// dsz="0"单/"1"双, djj=起始节, skcd=节次长度。单/双周端点修正由本 parser 负责。
final class JwZjuParser: JwParser, JwParserConfidenceReporting {

    let source: String

    init(_ source: String) {
        self.source = source
    }

    func generateCourseList() throws -> [JwCourse] {
        guard let data = source.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kbList = jsonArr(root["kbList"]) else { return [] }
        var out: [JwCourse] = []
        for el in kbList {
            guard let obj = jsonObj(el) else { continue }
            guard let xqj = jint(obj, "xqj") else { continue }
            let dsz = jstr(obj, "dsz")
            let typeInt = dsz == "0" ? 1 : (dsz == "1" ? 2 : 0)
            guard let djj = jint(obj, "djj") else { continue }
            let skcd = jint(obj, "skcd") ?? 1
            let rawKcb = jstr(obj, "kcb")
            // zwf 截断 + <br> 分段(忠实 Kotlin: rawKcb.split("zwf")[0].split("<br>"))
            let beforeZwf = rawKcb.components(separatedBy: "zwf").first ?? rawKcb
            let fields = beforeZwf.components(separatedBy: "<br>")
            if fields.isEmpty { continue }
            let name = fields.count > 0
                ? fields[0].replacingOccurrences(of: "(", with: "（").replacingOccurrences(of: ")", with: "）")
                    .trimmingCharacters(in: .whitespaces)
                : nil
            guard let name = name, !name.isEmpty else { continue }
            let timeString = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces) : ""
            let teacher = fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespaces) : ""
            let location = fields.count > 3 ? fields[3].trimmingCharacters(in: .whitespaces) : ""
            let segments = parseWeekSegments(timeString)
            for (startW, endW) in segments {
                let adjustedStart: Int
                switch typeInt {
                case 1: adjustedStart = startW % 2 == 0 ? startW + 1 : startW
                case 2: adjustedStart = startW % 2 != 0 ? startW + 1 : startW
                default: adjustedStart = startW
                }
                out.append(JwCourse(
                    name: name, room: location, teacher: teacher,
                    day: xqj, startNode: djj, endNode: djj + skcd - 1,
                    startWeek: adjustedStart, endWeek: endW, type: typeInt))
            }
        }
        return out
    }

    /// 解析周次串: "1-16周"/"2,4,6,8,10,12,14,16周"/"1-8周,10-16周"。
    /// 端点已定型不动调整(单/双修正交 generateCourseList)。
    func parseWeekSegments(_ s: String) -> [(Int, Int)] {
        if s.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        let clean = s
            .replacingOccurrences(of: "周", with: "")
            .replacingOccurrences(of: "(单)", with: "")
            .replacingOccurrences(of: "(双)", with: "")
            .trimmingCharacters(in: .whitespaces)
        var out: [(Int, Int)] = []
        for seg in clean.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
            if seg.contains("-") {
                let parts = seg.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard let a = Int(parts[0]) else { continue }
                let b = parts.count > 1 ? (Int(parts[1]) ?? a) : a
                out.append((a, b))
            } else if let v = Int(seg) {
                out.append((v, v))
            }
        }
        return out
    }

    var confidenceValue: Int {
        guard let data = source.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return 0 }
        return root["kbList"] is [Any] ? 90 : 0
    }

    var matchedFeatureList: [String] {
        guard let data = source.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["kbList"] is [Any] else { return [] }
        return ["kbList"]
    }
}

// MARK: - 中国科学技术大学(自研新版, jw.ustc.edu.cn)
//
// JSON 路径: x.studentTableVm.activities[]。weeksStr 一次性给完整周次串:
// "1-16"/"1-16单"/"1-16双"/"2,4,6..."。lessonCode 4 位数字, 1-2 位=startNode, 3-4 位=endNode。
final class JwUstcParser: JwParser, JwParserConfidenceReporting {

    let source: String

    init(_ source: String) {
        self.source = source
    }

    func generateCourseList() throws -> [JwCourse] {
        guard let data = source.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tableVm = jsonObj(root["studentTableVm"]),
              let activities = jsonArr(tableVm["activities"]) else { return [] }
        var out: [JwCourse] = []
        for el in activities {
            guard let obj = jsonObj(el) else { continue }
            let name = jstr(obj, "courseName")
            if name.isEmpty { continue }
            let room = fallbackRoom(obj)
            let teacher = joinTeachers(obj)
            let (startNode, endNode) = parseLessonCode(obj)
            if startNode == 0 { continue }
            guard let weekday = jint(obj, "weekday") else { continue }
            let weeksStr = jstr(obj, "weeksStr")
            if weeksStr.isEmpty { continue }
            let (typeInt, cleanStr) = parseWeeksType(weeksStr)
            for (sw, ew) in parseWeekSegments(cleanStr) {
                let adjustedStart: Int
                switch typeInt {
                case 1: adjustedStart = sw % 2 == 0 ? sw + 1 : sw
                case 2: adjustedStart = sw % 2 != 0 ? sw + 1 : sw
                default: adjustedStart = sw
                }
                out.append(JwCourse(
                    name: name, room: room, teacher: teacher,
                    day: weekday, startNode: startNode, endNode: endNode,
                    startWeek: adjustedStart, endWeek: ew, type: typeInt))
            }
        }
        return out
    }

    /// weeksStr → (type, cleanStr): type 0=每周 1=单 2=双, cleanStr 已剥"单/双"后缀。
    func parseWeeksType(_ s: String) -> (Int, String) {
        if s.contains("单") { return (1, s.replacingOccurrences(of: "单", with: "").trimmingCharacters(in: .whitespaces)) }
        if s.contains("双") { return (2, s.replacingOccurrences(of: "双", with: "").trimmingCharacters(in: .whitespaces)) }
        return (0, s.trimmingCharacters(in: .whitespaces))
    }

    /// 解析 "1-16"/"2,4,6,8" 形式的周次串(已剥"单/双")。
    func parseWeekSegments(_ s: String) -> [(Int, Int)] {
        if s.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        var out: [(Int, Int)] = []
        for seg in s.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
            if seg.contains("-") {
                let parts = seg.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard let a = Int(parts[0]) else { continue }
                let b = parts.count > 1 ? (Int(parts[1]) ?? a) : a
                out.append((a, b))
            } else if let v = Int(seg) {
                out.append((v, v))
            }
        }
        return out
    }

    /// room 优先; room 为空/缺失时回退 customPlace; 两者皆空则空串。
    private func fallbackRoom(_ o: [String: Any]) -> String {
        let room = jstr(o, "room")
        if !room.isEmpty { return room }
        return jstr(o, "customPlace")
    }

    private func joinTeachers(_ o: [String: Any]) -> String {
        guard let arr = jsonArr(o["teachers"]) else { return jstr(o, "teachers") }
        let names = arr.compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return names.joined(separator: " ")
    }

    private func parseLessonCode(_ o: [String: Any]) -> (Int, Int) {
        let s = jstr(o, "lessonCode")
        guard s.count >= 4, s.allSatisfy({ $0.isNumber }) else { return (0, 0) }
        let start = Int(s.prefix(2)) ?? 0
        let end = Int(s.suffix(2)) ?? start
        return (start, end)
    }

    var confidenceValue: Int {
        guard let data = source.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return 0 }
        return root["studentTableVm"] is [String: Any] ? 90 : 0
    }

    var matchedFeatureList: [String] {
        guard let data = source.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["studentTableVm"] is [String: Any] else { return [] }
        return ["studentTableVm"]
    }
}

// MARK: - 四川大学(scu.edu.cn 自建门户 mobile JSON)
//
// JSON 路径: x.dateList[0].selectCourseList[].timeAndPlaceList[]。
// weekDescription 剥非数字/横/逗后展开(上游 replaceAll 语义) — 单/双信息协议层丢失, 强制 type=0。
// classDay 0-6 → day 1-7。
final class JwScuParser: JwParser, JwParserConfidenceReporting {

    let source: String

    init(_ source: String) {
        self.source = source
    }

    func generateCourseList() throws -> [JwCourse] {
        guard let data = source.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dateList = jsonArr(root["dateList"]),
              let first = dateList.first as? [String: Any],
              let selectCourseList = jsonArr(first["selectCourseList"]) else { return [] }
        var out: [JwCourse] = []
        for el in selectCourseList {
            guard let course = jsonObj(el) else { continue }
            let name = jstr(course, "courseName")
            if name.isEmpty { continue }
            let teacher = jstr(course, "attendClassTeacher")
            guard let timeAndPlaceList = jsonArr(course["timeAndPlaceList"]) else { continue }
            for tpEl in timeAndPlaceList {
                guard let tp = jsonObj(tpEl) else { continue }
                let building = jstr(tp, "teachingBuildingName")
                let classroom = jstr(tp, "classroomName")
                let room = building + classroom
                let weekDesc = jstr(tp, "weekDescription")
                guard let startNode = jint(tp, "classSessions") else { continue }
                let continuing = jint(tp, "continuingSession") ?? 1
                let endNode = startNode + continuing - 1
                guard let rawDay = jint(tp, "classDay") else { continue }
                let day = rawDay + 1  // 0-indexed Mon..Sun → 1..7
                for (sw, ew) in parseWeeks(weekDesc) {
                    out.append(JwCourse(
                        name: name, room: room, teacher: teacher,
                        day: day, startNode: startNode, endNode: endNode,
                        startWeek: sw, endWeek: ew, type: 0))
                }
            }
        }
        return out
    }

    /// 解析 weekDescription — "1-16周"/"2,4,6,8"/"1-15周(单)"。
    /// 严格按上游 replaceAll("[^\\d\\-,]", "") 剥后展开; 单/双丢失, 按每周(type=0)输出。
    func parseWeeks(_ s: String) -> [(Int, Int)] {
        if s.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        let clean = String(s.unicodeScalars.filter { CharacterSet(charactersIn: "0123456789-,").contains($0) })
        if clean.isEmpty { return [] }
        var out: [(Int, Int)] = []
        for seg in clean.components(separatedBy: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
            if seg.contains("-") {
                let parts = seg.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard let a = Int(parts[0]) else { continue }
                let b = parts.count > 1 ? (Int(parts[1]) ?? a) : a
                out.append((a, b))
            } else if let v = Int(seg) {
                out.append((v, v))
            }
        }
        return out
    }

    var confidenceValue: Int {
        guard let data = source.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dl = jsonArr(root["dateList"]), !dl.isEmpty,
              let first = dl.first as? [String: Any],
              first["selectCourseList"] is [Any] else { return 0 }
        return 90
    }

    var matchedFeatureList: [String] {
        guard let data = source.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dl = jsonArr(root["dateList"]), !dl.isEmpty,
              let first = dl.first as? [String: Any],
              first["selectCourseList"] is [Any] else { return [] }
        return ["selectCourseList"]
    }
}

// MARK: - 东北大学(强智新版 mobile JSON, jwxt.neu.edu.cn)
//
// JSON 路径: x.datas.arrangedList[]。titleDetail[0]=汇总; titleDetail[1..]="周数串 教室"。
// teacher 从 weeksAndTeachers "/" 末段剥 [主讲] 标记。单/双周协议层丢失, 强制 type=0。
final class JwNeuParser: JwParser, JwParserConfidenceReporting {

    let source: String

    init(_ source: String) {
        self.source = source
    }

    func generateCourseList() throws -> [JwCourse] {
        guard let data = source.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let datas = jsonObj(root["datas"]),
              let arranged = jsonArr(datas["arrangedList"]) else { return [] }
        var out: [JwCourse] = []
        for el in arranged {
            guard let obj = jsonObj(el) else { continue }
            let name = jstr(obj, "courseName")
            if name.isEmpty { continue }
            guard let day = jint(obj, "dayOfWeek") else { continue }
            guard let begin = jint(obj, "beginSection") else { continue }
            let end = jint(obj, "endSection") ?? begin
            let weeksAndTeachers = jstr(obj, "weeksAndTeachers")
            let teacher = extractTeacher(weeksAndTeachers)
            let titleDetail = jsonArr(obj["titleDetail"])
            let (weeksStr, room) = extractWeeksAndRoom(titleDetail, weeksAndTeachers)
            if weeksStr.isEmpty { continue }
            for (sw, ew) in parseWeeks(weeksStr) {
                out.append(JwCourse(
                    name: name, room: room, teacher: teacher,
                    day: day, startNode: begin, endNode: end,
                    startWeek: sw, endWeek: ew, type: 0))
            }
        }
        return out
    }

    /// "1-16周/王教授[主讲]" → teacher: 取 "/" 末段剥 [主讲] 标记; 无 "/" 或剥后为空 → 空串。
    func extractTeacher(_ s: String) -> String {
        if s.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        let parts = s.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last else { return "" }
        return last
            .replacingOccurrences(of: "[主讲]", with: "")
            .replacingOccurrences(of: "[主讲 ", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// titleDetail 提取 (weeksStr, room):
    ///   - [1..] 中有以数字开头的 → 取首条 split " " 首段作 weeks, 末段作 room("X校区" 视待定跳过)
    ///   - 否则回退 weeksAndTeachers "/" 前段作 weeks, room 空串
    func extractWeeksAndRoom(_ titleDetail: [Any]?, _ weeksAndTeachers: String) -> (String, String) {
        if let titleDetail = titleDetail {
            for i in 1..<titleDetail.count {
                var s = ""
                if let str = titleDetail[i] as? String { s = str.trimmingCharacters(in: .whitespaces) }
                else if let n = titleDetail[i] as? NSNumber { s = n.stringValue }
                if s.isEmpty || !s.first!.isNumber { continue }
                let parts = s.components(separatedBy: " ").filter { !$0.isEmpty }
                if parts.count >= 2 {
                    let weeks = parts.first!.trimmingCharacters(in: .whitespaces)
                    let room = parts.last!.trimmingCharacters(in: .whitespaces)
                    if room.hasSuffix("校区") { continue }
                    return (weeks, room)
                } else if parts.count == 1 {
                    return (parts[0].trimmingCharacters(in: .whitespaces), "")
                }
            }
        }
        let fallbackWeeks = weeksAndTeachers.components(separatedBy: "/").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return (fallbackWeeks, "")
    }

    /// 周次串(已剥中文): "1-16周"/"2,4,6,8"/"2-15单周"。单/双已丢失, type 强制 0。
    func parseWeeks(_ s: String) -> [(Int, Int)] {
        if s.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        let clean = s
            .replacingOccurrences(of: "周", with: "")
            .replacingOccurrences(of: "单周", with: "")
            .replacingOccurrences(of: "双周", with: "")
            .replacingOccurrences(of: "单", with: "")
            .replacingOccurrences(of: "双", with: "")
            .trimmingCharacters(in: .whitespaces)
        if clean.isEmpty { return [] }
        var out: [(Int, Int)] = []
        for seg in clean.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
            if seg.contains("-") {
                let parts = seg.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard let a = Int(parts[0]) else { continue }
                let b = parts.count > 1 ? (Int(parts[1]) ?? a) : a
                out.append((a, b))
            } else if let v = Int(seg) {
                out.append((v, v))
            }
        }
        return out
    }

    var confidenceValue: Int {
        guard let data = source.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let datas = jsonObj(root["datas"]),
              datas["arrangedList"] is [Any] else { return 0 }
        return 90
    }

    var matchedFeatureList: [String] {
        guard let data = source.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let datas = jsonObj(root["datas"]),
              datas["arrangedList"] is [Any] else { return [] }
        return ["arrangedList"]
    }
}
