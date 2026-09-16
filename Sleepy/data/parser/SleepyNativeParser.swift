// SleepyNativeParser.swift — ← data/parser/SleepyNativeParser.kt (逐行翻译, GPL-3.0)
// Sleepy iOS — sleepy-v1 解析器(规范 §3/§4/§5/§7)。
//
// 三态处置: 空=默认(不上报) · 形状合法但越界=钳制+上报 · 形状非法=整行丢弃+上报。
// 上报双通道: droppedLines(行级) + ParseResult.warnings(表级)。
// groupId 分区: 非空 token 按分区; 空 token 按归一化课名(复刻 assignGroupIds 语义);
// 生成的最终 groupId 由 groupIdsAuthoritative=true 声明权威, 落库绕过再分配(§3.4 契约一)。

import Foundation
import CryptoKit

enum SleepyNativeParser {

    /// 两遍解析: 先扫 T 行(表级), 再解析其余行
    static func parse(_ trimmed: String, defaultTableId: Int64, defaultColor: String) throws -> ScheduleParser.ParseResult {
        let lines = trimmed.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        }
        var dropped: [String] = []
        var warnings: [String] = []

        // ---- pass 1: T 行 ----
        var tSeen = false
        var tableName = ""
        var startDateStr = ""
        var maxWeekRaw: Int?
        var nodesPerDayRaw: Int?
        var declaredCount: Int?
        var bodyStart = 0
        var foundMagic = false

        for (idx, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if !foundMagic {
                // 单行探测: 该行本身是不是 magic
                if SleepyNativeFormat.isMagicLine(line) {
                    foundMagic = true
                    bodyStart = idx + 1
                }
                continue
            }
            if !tSeen && line.uppercased().hasPrefix("T") && !line.uppercased().hasPrefix("ND") {
                // 显式记录已被 pass1 消化; pass2 走到同前缀时按"二次 T"语义入 dropped
                tSeen = true
                if let cols = splitCols(line, prefixLen: 1, dropped: &dropped, warnings: &warnings) {
                    if cols.indices.contains(0) { tableName = SleepyNativeFormat.unescape(cols[0].trimmingCharacters(in: .whitespaces)) }
                    if cols.indices.contains(1) { startDateStr = cols[1].trimmingCharacters(in: .whitespaces) }
                    if cols.indices.contains(2) { maxWeekRaw = Int(cols[2].trimmingCharacters(in: .whitespaces)) }
                    if cols.indices.contains(3) { nodesPerDayRaw = Int(cols[3].trimmingCharacters(in: .whitespaces)) }
                    // 扩展键区: key=value
                    for kv in cols.dropFirst(4) {
                        if let eq = kv.firstIndex(of: "=") {
                            let k = String(kv[..<eq]).trimmingCharacters(in: .whitespaces)
                            let v = String(kv[kv.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                            if k == "n" { declaredCount = Int(v) }
                            // 未知键静默忽略(v2 契约)
                        }
                    }
                }
            }
        }
        if !foundMagic {
            throw ScheduleParser.ParseError("内部错误: sleepy-v1 解析器被无 magic 文本调用")
        }

        // ---- 表级默认与钳制(§3.5) ----
        let startDate: String
        if startDateStr.isEmpty {
            startDate = todayMonday()
        } else if let d = SleepyNativeFormat.parseDate(startDateStr) {
            startDate = d
        } else {
            warnings.append("开始日期「\(startDateStr)」无法解析，已使用今天")
            startDate = todayMonday()
        }
        let maxWeekClamped = clampField(maxWeekRaw, default: 20, lo: 1, hi: 60, label: "总周数", warnings: &warnings)
        let declaredNodes = clampField(nodesPerDayRaw, default: nil, lo: 1, hi: 30, label: "每天节数", warnings: &warnings)

        // ---- pass 2: 正文行 ----
        var courses: [CourseEntity] = []
        // sortedMapOf<Int, Pair<LocalTime, LocalTime>> → 按 node 升序保持
        var nodeTimes: [Int: (Int, Int)] = [:]
        var nodeOrder: [Int] = []
        var ndSeen = false
        var seenExactLines = Set<String>()
        var seenCourseLines = false
        var secondTableHeader = false
        var chkLine: String?
        var tokenByIndex: [Int: String] = [:]

        for raw in lines.dropFirst(bodyStart) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                // 注释行(非 magic)忽略 — 但 magic 行恰好以 # 开头, 必须先判定
                if SleepyNativeFormat.isMagicLine(line) {
                    dropped.append(shorten(line))
                    secondTableHeader = true
                }
                continue
            }
            if SleepyNativeFormat.isMagicLine(line) {
                // 二次 magic: 不硬拒, 整行上报 + warning(§6.3-P)
                dropped.append(shorten(line))
                secondTableHeader = true
                continue
            }
            if seenExactLines.contains(line) { dropped.append(shorten(line)); continue }  // 字节级重复(§7.9)
            let prefix = String(line.prefix(1)).uppercased()

            switch prefix {
            case "T":
                // 首次 T 行已被 pass 1 消化(tSeen=true), 这里跳过它; 二次 T 行入 dropped
                if tSeen { continue }
                dropped.append(shorten(line))
            case "Z":
                // z|chk=crc32:xxxxxxxx — 记录, 结束时校验
                chkLine = line
            case "N":
                if line.count >= 2 && (line[line.index(line.startIndex, offsetBy: 1)] == "d" || line[line.index(line.startIndex, offsetBy: 1)] == "D") {
                    ndSeen = true
                } else {
                    seenExactLines.insert(line)
                    parseNodeLine(line, &nodeTimes, &nodeOrder, &dropped)
                }
            case "C":
                seenCourseLines = true
                seenExactLines.insert(line)
                parseCourseLine(line, defaultTableId: defaultTableId, defaultColor: defaultColor,
                                tableName: tableName, &courses, &dropped, &tokenByIndex)
            default:
                // 未知行类型(v2 信号)或无前缀垃圾 → dropped(诚实上报)
                dropped.append(shorten(line))
            }
        }

        // Nd 展开(§5: 冻结 12 节常量)
        if ndSeen {
            for (i, preset) in SleepyNativeFormat.ND_PRESET.enumerated() {
                let node = i + 1
                if nodeTimes[node] == nil {
                    nodeTimes[node] = preset
                    nodeOrder.append(node)
                }
            }
        }
        nodeOrder.sort()

        // chk 校验(§6.3-Q: 警告不硬拒)
        if let chk = chkLine {
            if let m = chk.range(of: #"chk=([a-z0-9]+):([0-9a-fA-F]{8})"#, options: .regularExpression) {
                let segs = chk[m].dropFirst(4)  // 去掉 "chk="
                let parts = segs.components(separatedBy: ":")
                if parts.count == 2 {
                    let algo = parts[0]
                    let expected = parts[1]
                    if algo == "crc32" {
                        // 校验范围 = magic 行(含)至 z 行(不含)的全部字节
                        let zIdx = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == chk }
                        if let zi = zIdx, zi > bodyStart - 1 {
                            let bodyToChk = lines.prefix(zi).joined(separator: "\n")
                            let actual = SleepyNativeFormat.crc32(bodyToChk.data(using: .utf8) ?? Data())
                            if actual.lowercased() != expected.lowercased() {
                                warnings.append("完整性校验不符，文件可能被截断或修改")
                            }
                        }
                    } else {
                        warnings.append("未知校验算法 \(algo)，已跳过校验")
                    }
                }
            }
        }

        // n= 计数核对(§8.3: 警告不硬拒)
        if let declared = declaredCount, declared != courses.count {
            warnings.append("课程行计数 n=\(declared) 与实际 \(courses.count) 不符，文件可能被截断")
        }
        if secondTableHeader {
            warnings.append("检测到第 2 张表头，其课程已并入当前表")
        }

        // nodesPerDay = max(声明, 课程到达)(§5 优先级)
        let courseReach = courses.map { $0.startNode + $0.step - 1 }.max() ?? 0
        var nodesPerDay = declaredNodes ?? max(12, nodeTimes.keys.max() ?? 0)
        if declaredNodes == nil && nodeTimes.isEmpty && !courses.isEmpty {
            nodesPerDay = max(12, courseReach)
        }
        if courseReach > nodesPerDay {
            nodesPerDay = courseReach
            warnings.append("课程到达第 \(courseReach) 节，超过声明的每天节数，已自动扩展")
        }

        // timeJson 序列化(稀疏语义: 只写声明过的节)
        var timeJson = ""
        if !nodeTimes.isEmpty {
            let parts: [String] = nodeOrder.compactMap { node in
                guard let se = nodeTimes[node] else { return nil }
                return "{\"node\":\(node),\"start\":\"\(fmt(se.0))\",\"end\":\"\(fmt(se.1))\"}"
            }
            timeJson = "[" + parts.joined(separator: ",") + "]"
        }

        // ---- groupId 分区(§3.4) ----
        assignFinalGroupIds(&courses, tableName: tableName, tokenByIndex: tokenByIndex)

        // ---- 空表/全丢二分(§7.8) ----
        // 仅在 C 前缀行存在但全部被丢时失败; 0 行 C 前缀 = 空表成功
        if seenCourseLines && courses.isEmpty {
            throw ScheduleParser.ParseError(
                "未能解析任何课程（\(dropped.count) 行没进去）：\(dropped.prefix(3).joined(separator: " / "))")
        }

        return ScheduleParser.ParseResult(
            tableName: tableName,
            startDate: startDate,
            courses: courses,
            timeJson: timeJson,
            nodesPerDay: nodesPerDay,
            droppedLines: dropped,
            warnings: warnings,
            maxWeek: maxWeekClamped ?? 20,
            groupIdsAuthoritative: true)
    }

    // MARK: - 行解析

    private static func parseNodeLine(_ line: String,
                                      _ nodeTimes: inout [Int: (Int, Int)],
                                      _ nodeOrder: inout [Int],
                                      _ dropped: inout [String]) {
        let body = String(line.dropFirst())
        let cols = splitRespectingEscape(body)
        let nodeNo = cols.indices.contains(0) ? Int(cols[0].trimmingCharacters(in: .whitespaces)) : nil
        let start = cols.indices.contains(1) ? SleepyNativeFormat.parseClock(cols[1]) : nil
        let end = cols.indices.contains(2) ? SleepyNativeFormat.parseClock(cols[2]) : nil
        let ok = nodeNo != nil && nodeNo! > 0 && start != nil && end != nil &&
            (start!.h * 60 + start!.min) < (end!.h * 60 + end!.min)
        if !ok {
            dropped.append(shorten(line))
            return
        }
        if nodeTimes[nodeNo!] != nil {
            dropped.append(shorten(line))  // 重复节号: 首行生效
            return
        }
        nodeTimes[nodeNo!] = (start!.h * 60 + start!.min, end!.h * 60 + end!.min)
        nodeOrder.append(nodeNo!)
    }

    /// C 行 (§3.1, 恒 10 列 + issue#26 可选第 11 列=课程别名)
    private static func parseCourseLine(_ line: String, defaultTableId: Int64, defaultColor: String,
                                        tableName: String, _ courses: inout [CourseEntity],
                                        _ dropped: inout [String], _ tokenByIndex: inout [Int: String]) {
        var cols = splitRespectingEscape(String(line.dropFirst()))
        // 全角｜次级分隔符: 仅当半角切分列数 < 10 且全角重切恰好补齐到规范列数(10 或 11=带别名)时(§7.6)
        if cols.count < 10 && cols.allSatisfy({ !$0.contains("|") }) {
            let alt = splitRespectingEscape(String(line.dropFirst()).replacingOccurrences(of: "｜", with: "|"))
            // 精确重切仅在 alt.size ∈ {10, 11} 时采纳
            if alt.count == 10 || alt.count == 11 { cols = alt }
        }

        func col(_ i: Int) -> String { cols.indices.contains(i) ? cols[i].trimmingCharacters(in: .whitespaces) : "" }
        func text(_ i: Int) -> String { SleepyNativeFormat.unescape(col(i)) }

        let name = text(0)
        if name.isEmpty { dropped.append(shorten(line)); return }  // 名称是行存在性唯一充分条件
        if name.contains("\u{FFFD}") { dropped.append(shorten(line)); return }  // GBK 乱码 → 响亮丢弃(规范 §7.7)

        // day(2列)
        let dayRaw = col(1)
        let dayParsed = SleepyNativeFormat.parseDay(dayRaw)
        let day: Int
        if dayRaw.isEmpty {
            day = 1
        } else if dayParsed == nil {
            dropped.append(shorten(line)); return
        } else if dayParsed! < 1 || dayParsed! > 7 {
            day = min(max(dayParsed!, 1), 7)
            markClamped(line, &dropped)
        } else {
            day = dayParsed!
        }

        // nodeSpan(3列)
        let spanRaw = col(2)
        var nodeStart: Int
        var nodeEnd: Int
        if spanRaw.isEmpty {
            (nodeStart, nodeEnd) = (1, 1)
        } else if let span = SleepyNativeFormat.parseNodeSpan(spanRaw) {
            (nodeStart, nodeEnd) = span
        } else {
            dropped.append(shorten(line)); return
        }
        if nodeEnd < nodeStart { swap(&nodeStart, &nodeEnd); markClamped(line, &dropped) }
        if nodeStart < 1 { nodeStart = 1; markClamped(line, &dropped) }
        let step = nodeEnd - nodeStart + 1

        // weekSpec(4列)
        let weekRaw = col(3)
        let weekParsed: SleepyNativeFormat.WeekSpec
        if weekRaw.isEmpty {
            weekParsed = SleepyNativeFormat.WeekSpec(start: 1, end: 16, type: 3)
        } else if let w = SleepyNativeFormat.parseWeekSpec(weekRaw) {
            weekParsed = w
        } else {
            dropped.append(shorten(line)); return
        }
        var wStart = weekParsed.start
        var wEnd = weekParsed.end
        if wEnd < wStart { swap(&wStart, &wEnd); markClamped(line, &dropped) }
        if wStart < 1 { wStart = 1; markClamped(line, &dropped) }
        if wEnd > 300 { wEnd = 300; markClamped(line, &dropped) }

        // teacher(5) room(6) — 自由文本无非法态
        let teacher = text(4)
        let room = text(5)

        // color(7)
        let colorRaw = col(6)
        let color: String
        if colorRaw.isEmpty || colorRaw == "0" {
            color = defaultColor.isEmpty ? SleepyNativeFormat.AUTO_COLOR : defaultColor
        } else {
            if let idx = Int(colorRaw), idx > 9 { markClamped(line, &dropped) }
            color = SleepyNativeFormat.colorFromToken(colorRaw)
        }

        // note(8)
        let note = text(7)

        // timeSpan(9)
        let timeRaw = col(8)
        var ownTime = false
        var startTime = ""
        var endTime = ""
        if !timeRaw.isEmpty {
            let parts = timeRaw.components(separatedBy: CharacterSet(charactersIn: "-～~"))
            if parts.count == 2,
               let st = SleepyNativeFormat.parseClock(parts[0]),
               let et = SleepyNativeFormat.parseClock(parts[1]),
               (st.h * 60 + st.min) < (et.h * 60 + et.min) {
                ownTime = true
                startTime = SleepyNativeFormat.fmtTime(h: st.h, min: st.min)
                endTime = SleepyNativeFormat.fmtTime(h: et.h, min: et.min)
            } else {
                markClamped(line, &dropped)  // 时间列非法: 课程仍按节点落位
            }
        }

        // group(10)
        let token = text(9)

        // issue#26: 可选第 11 列 = 课程别名。缺列/空值 → ""(向后兼容既有 v1 文件)
        let alias = cols.count >= 11 ? text(10) : ""

        courses.append(CourseEntity(
            groupId: "",   // 分区在 pass 结束后统一分配
            tableId: defaultTableId,
            courseName: name,
            teacher: teacher,
            room: room,
            note: note,
            day: day,
            startNode: nodeStart,
            step: step,
            startWeek: wStart,
            endWeek: wEnd,
            type: weekParsed.type,
            color: color,
            ownTime: ownTime,
            startTime: startTime,
            endTime: endTime,
            alias: alias))
        tokenByIndex[courses.count - 1] = token
    }

    // MARK: - 工具

    /// 按半角 | 切列; 恰差 1 列时全角｜作次级分隔符重切一次(§7.6)
    private static func splitCols(_ line: String, prefixLen: Int,
                                  dropped: inout [String], warnings: inout [String]) -> [String]? {
        let body = String(line.dropFirst(prefixLen))
        return splitRespectingEscape(body)
    }

    /// 反斜杠感知的竖线切分: \| 不是分隔符
    private static func splitRespectingEscape(_ body: String) -> [String] {
        var cols: [String] = []
        var sb = ""
        let chars = Array(body)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" && i + 1 < chars.count {
                sb.append(c); sb.append(chars[i + 1]); i += 2
            } else if c == "|" {
                cols.append(sb); sb = ""; i += 1
            } else {
                sb.append(c); i += 1
            }
        }
        cols.append(sb)
        return cols
    }

    private static func todayMonday() -> String {
        let cal = Calendar(identifier: .gregorian)
        let wd = cal.component(.weekday, from: Date())
        let daysBack = (wd + 5) % 7
        let monday = cal.date(byAdding: .day, value: -daysBack, to: cal.startOfDay(for: Date()))!
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: monday)
    }

    private static func clampField(_ raw: Int?, default def: Int?, lo: Int, hi: Int,
                                   label: String, warnings: inout [String]) -> Int? {
        guard let raw = raw else { return def }
        if raw < lo { warnings.append("\(label) \(raw) 低于下限，已调整为 \(lo)"); return lo }
        if raw > hi { warnings.append("\(label) \(raw) 超过上限，已调整为 \(hi)"); return hi }
        return raw
    }

    /// 已入库行发生过钳制 → 整行原文入 dropped(§7.3)
    private static func markClamped(_ line: String, _ dropped: inout [String]) {
        dropped.append(shorten(line))
    }

    private static func shorten(_ line: String) -> String {
        String(line.prefix(40))
    }

    private static func fmt(_ minutes: Int) -> String {
        SleepyNativeFormat.fmtTime(h: minutes / 60, min: minutes % 60)
    }

    /// §3.4: 非空 token 按分区; 空 token 按归一化课名; 确定性 UUID
    private static func assignFinalGroupIds(_ courses: inout [CourseEntity], tableName: String,
                                            tokenByIndex: [Int: String]) {
        var tokenGroups: [String: String] = [:]
        var nameGroups: [String: String] = [:]
        for idx in courses.indices {
            let c = courses[idx]
            let token = tokenByIndex[idx] ?? ""
            let gid: String
            if !token.isEmpty {
                if let g = tokenGroups[token] {
                    gid = g
                } else {
                    gid = deterministicUUID("\(tableName)|\(token)")
                    tokenGroups[token] = gid
                }
            } else {
                let key = c.courseName.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .lowercased()
                if let g = nameGroups[key] {
                    gid = g
                } else {
                    gid = deterministicUUID("\(tableName)|\(key)")
                    nameGroups[key] = gid
                }
            }
            courses[idx].groupId = gid
        }
    }

    /// UUID.nameUUIDFromBytes 等价: MD5(name 字节) → RFC 4122 version 3 / variant 1
    static func deterministicUUID(_ name: String) -> String {
        let digest = Insecure.MD5.hash(data: name.data(using: .utf8)!)
        var b = Array(digest)
        b[6] = (b[6] & 0x0F) | 0x30  // version 3
        b[8] = (b[8] & 0x3F) | 0x80  // variant 10
        func hex(_ v: UInt8) -> String { String(format: "%02x", v) }
        let s = b.map(hex).joined()
        return "\(s.prefix(8))-\(s.dropFirst(8).prefix(4))-\(s.dropFirst(12).prefix(4))-\(s.dropFirst(16).prefix(4))-\(s.dropFirst(20))"
    }
}
