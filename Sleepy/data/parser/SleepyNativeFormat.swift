// SleepyNativeFormat.swift — ← data/parser/SleepyNativeFormat.kt (逐行翻译, GPL-3.0)
// Sleepy iOS — sleepy-v1 原生格式 纯函数层(规范: sleepy-v1-终稿规范.md §2/§3/§5/§6.1)。
//
// 行式竖线分列: magic 行 `#sleepy-v1` + T(表) / N(作息) / Nd(预设) / C(课程, 恒10列, 可选第11列=课程别名 issue#26) / z(校验) 行。
// 本 enum 只放无状态的常量与纯函数; 解析见 SleepyNativeParser, 导出见 SleepyNativeExporter。

import Foundation

enum SleepyNativeFormat {

    // MARK: - magic 识别 (§6.1)

    /// 行首锚定: ≤4 字符引用/空白前缀 + 1-2 个井号(半/全角) + sleepy + 可选拼缝 + v + 数字。
    /// 整模式大小写不敏感(#SLEEPY-V1 命中且版本=1)。行尾多余内容由 $ 前的宽容处理忽略——
    /// 我们用 find + 范围前缀判定而非严格 fullMatch, 允许尾随标点(§6.3-M「#sleepy-v1。」)。
    private static let MAGIC_RE = try! NSRegularExpression(
        pattern: "^[>\\s]{0,4}[#＃]{1,2}\\s*sleepy[\\s\\-_－]*v(\\d+)",
        options: [.caseInsensitive, .anchorsMatchLines])

    /// magic 必须位于前 32 个非空行之一(微信长转发头)
    static let MAGIC_WINDOW = 32

    private static let MAGIC_TEST_RE = try! NSRegularExpression(
        pattern: "^[>\\s]{0,4}[#＃]{1,2}\\s*sleepy[\\s\\-_－]*v(\\d+)",
        options: [.caseInsensitive])

    /// 识别 sleepy-v* 家族。返回版本号(1=本格式), 未命中 -1。作用于归一后的 trimmed 文本。
    static func detectVersion(_ trimmed: String) -> Int {
        var seen = 0
        for line in trimmed.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if t.isEmpty { continue }
            seen += 1
            if seen > MAGIC_WINDOW { return -1 }
            let tns = t as NSString
            let full = NSRange(location: 0, length: tns.length)
            guard let m = MAGIC_TEST_RE.firstMatch(in: t, range: full),
                  m.range(at: 1).location != NSNotFound else { continue }
            return Int(tns.substring(with: m.range(at: 1))) ?? -1
        }
        return -1
    }

    /// 单行 magic 判定(parser 内层用): 该行本身是否为 magic 行
    static func isMagicLine(_ line: String) -> Bool {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let m = MAGIC_TEST_RE.firstMatch(in: line, range: full),
              m.range(at: 1).location != NSNotFound else { return false }
        return Int(ns.substring(with: m.range(at: 1))) != nil
    }

    // MARK: - 转义 (§3.3)

    static let RESERVED: Set<Character> = ["\\", "|", "\"", "\n", "\t", "<", "{", "("]

    /// 导出端转义 8 字符: \ | " \n \t < { (
    static func escape(_ s: String) -> String {
        if s.allSatisfy({ !RESERVED.contains($0) }) { return s }
        var out = ""
        out.reserveCapacity(s.count + 8)
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "|": out += "\\|"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "<", "{", "(": out += "\\\(c)"
            default: out.append(c)
            }
        }
        return out
    }

    /// 导入端: \n→换行 \t→制表; 其余 \x → 字面 x; 尾部孤立 \ → 字面 \
    static func unescape(_ s: String) -> String {
        if !s.contains("\\") { return s }
        var out = ""
        out.reserveCapacity(s.count)
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" && i + 1 < chars.count {
                switch chars[i + 1] {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(chars[i + 1])
                }
                i += 2
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
    }

    // MARK: - 调色板 (§3.2, 9 色冻结 8 位规范形)

    static let AUTO_COLOR = "#FF6750A4"

    static let PALETTE: [Int: String] = [
        1: "#FFEADDFF", 2: "#FFFFD8E4", 3: "#FFFFDCC4",
        4: "#FFFFF2B8", 5: "#FFD4F7C5", 6: "#FFC5F2E3",
        7: "#FFC9E8FF", 8: "#FFCDD7FF", 9: "#FFF2C4DE"
    ]

    private static let PALETTE_BY_VALUE: [String: Int] = {
        var m: [String: Int] = [:]
        for (k, v) in PALETTE { m[v.uppercased()] = k }
        return m
    }()

    /// 导出: 课程色 → token。自动色哨兵→空; 调色板命中→索引; FF alpha 其他→#RRGGBB; 非 FF→#AARRGGBB; 垃圾→空
    static func colorToToken(_ color: String) -> String {
        guard let norm = normalizeColor(color) else { return "" }
        if norm == AUTO_COLOR.uppercased() { return "" }
        if let idx = PALETTE_BY_VALUE[norm] { return String(idx) }
        return norm.hasPrefix("#FF") ? "#" + String(norm.dropFirst(3)) : norm
    }

    /// 导入: token → 课程色。索引→规范形; #6 位→补 FF; #9 位→原样; 空/非法→自动色
    static func colorFromToken(_ token: String) -> String {
        let t = token.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return AUTO_COLOR }
        if let idx = Int(t) { return PALETTE[idx] ?? AUTO_COLOR }
        if t.hasPrefix("#") {
            let hex = String(t.dropFirst()).uppercased()
            switch hex.count {
            case 6: return "#FF\(hex)"
            case 8:
                let ok = hex.allSatisfy { $0.isNumber || ("A"..."F").contains($0) }
                return ok ? "#\(hex)" : AUTO_COLOR
            default: return AUTO_COLOR
            }
        }
        return AUTO_COLOR
    }

    /// 归一为 8 位 #AARRGGBB 大写; 非法 → nil
    private static func normalizeColor(_ color: String) -> String? {
        let t = color.trimmingCharacters(in: .whitespaces).uppercased()
        guard t.hasPrefix("#") else { return nil }
        let hex = String(t.dropFirst())
        if hex.contains(where: { !($0.isNumber || ("A"..."F").contains($0)) }) { return nil }
        switch hex.count {
        case 6: return "#FF\(hex)"
        case 8: return "#\(hex)"
        default: return nil
        }
    }

    // MARK: - lenient 基元解析 (§2 文法, §7 容错)

    /// `H:mm` / `HH:mm` / 全角冒号 → (h, min); 越界/非法 → nil
    static func parseClock(_ s: String) -> (h: Int, min: Int)? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "：", with: ":")
        guard let m = t.range(of: #"^(\d{1,2}):(\d{2})$"#, options: .regularExpression) else { return nil }
        let parts = t[m].components(separatedBy: ":")
        guard let h = Int(parts[0]), let min = Int(parts[1]), (0...23).contains(h), (0...59).contains(min) else { return nil }
        return (h, min)
    }

    private static let DATE_RE = try! NSRegularExpression(pattern: #"^(\d{4})[-/.]?(\d{1,2})[-/.]?(\d{1,2})$"#)

    /// `YYYY-MM-DD`(/ . 或紧凑) → 归一到所在周一的 `YYYY-MM-DD`; 非法 → nil
    static func parseDate(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let ns = t as NSString
        guard let m = DATE_RE.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { return nil }
        guard let y = Int(ns.substring(with: m.range(at: 1))),
              let mo = Int(ns.substring(with: m.range(at: 2))),
              let d = Int(ns.substring(with: m.range(at: 3))),
              1 <= mo && mo <= 12, 1 <= d && d <= 31,
              let date = dateFrom(y: y, mo: mo, d: d) else { return nil }
        return mondayOf(date)
    }

    private static func dateFrom(y: Int, mo: Int, d: Int) -> Date? {
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        let cal = Calendar(identifier: .gregorian)
        guard let date = cal.date(from: comps) else { return nil }
        // LocalDate.of 语义: 溢出日期(2/30 等)抛异常 → null
        var probe = DateComponents()
        probe.year = y; probe.month = mo; probe.day = 1
        guard let first = cal.date(from: probe),
              cal.component(.month, from: date) == mo else { return nil }
        _ = first
        return date
    }

    private static func mondayOf(_ date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        // DayOfWeek.MONDAY 语义: ISO, 周一=1; 找到本周或上周一
        let wd = cal.component(.weekday, from: date)  // 1=Sunday ... 7=Saturday
        let daysBack = (wd + 5) % 7  // Sunday(1)→6, Monday(2)→0, ... Saturday(7)→5
        let monday = cal.date(byAdding: .day, value: -daysBack, to: date)!
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: monday)
    }

    /// `S` / `S-E` → (startNode, endNode); 形状非法 → nil
    static func parseNodeSpan(_ s: String) -> (Int, Int)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        let parts = t.components(separatedBy: "-")
        switch parts.count {
        case 1: return Int(parts[0]).map { ($0, $0) }
        case 2:
            guard let a = Int(parts[0]), let b = Int(parts[1]) else { return nil }
            return (a, b)
        default: return nil
        }
    }

    // MARK: - 周次

    /// 周次五形态 + 容忍后缀 → WeekSpec; 形状非法 → nil。反写区间 (E<S) 交调用方钳制。
    struct WeekSpec { let start: Int; let end: Int; let type: Int }

    private static let WEEK_SPEC_RE = try! NSRegularExpression(
        pattern: #"^(\d+)(?:([-~–—〜至])(\d+))?(单|双|定|散|奇|偶|o|odd|e|even)?$"#)

    static func parseWeekSpec(_ s: String) -> WeekSpec? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        let ns = t as NSString
        guard let m = WEEK_SPEC_RE.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { return nil }
        guard let start = Int(ns.substring(with: m.range(at: 1))) else { return nil }
        let hasEnd = m.range(at: 3).location != NSNotFound
        let end = hasEnd ? (Int(ns.substring(with: m.range(at: 3))) ?? start) : start
        // 参与组判定: 未参与返回 NSNotFound(等价 Kotlin 空串语义)
        let suffix = m.range(at: 4).location != NSNotFound ? ns.substring(with: m.range(at: 4)) : ""
        let type: Int
        switch suffix {
        case "", "null":
            type = hasEnd ? 0 : 3  // 裸单数字=只上这周; 区间无后缀=每周
        case "单", "奇", "o", "odd": type = 1
        case "双", "偶", "e", "even": type = 2
        case "定", "散": type = 3
        default: return nil
        }
        return WeekSpec(start: start, end: end, type: type)
    }

    // MARK: - 周次导出(§4 规范形)

    /// (S,E,type) → 规范形 token。type 0 恒带横线(8-8); type 3 恒带后缀(单值写 S定)。
    static func weekSpecToToken(_ startWeek: Int, _ endWeek: Int, _ type: Int) -> String {
        let range = "\(startWeek)-\(endWeek)"
        switch type {
        case 1: return range + "单"
        case 2: return range + "双"
        case 3: return startWeek == endWeek ? "\(startWeek)定" : range + "定"
        default: return range
        }
    }

    // MARK: - 星期 (§3.1 day 列)

    private static let DAY_NAMES: [String: Int] = [
        "一": 1, "二": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "日": 7, "天": 7
    ]

    /// `1..7` / `周X` / `星期X` / `礼拜X` / 裸`三`; 非法形状 → nil。越界单数字(0/8/9)交调用方钳制。
    static func parseDay(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        // §2 文法 day = DIGIT{1}|周X…: 形状层只认单数字, 多位(13/2026)属形状非法
        if t.count == 1, let d = t.first, d.isNumber { return d.wholeNumberValue }
        var stripped = Substring(t)
        for p in ["礼拜", "星期", "周"] where stripped.hasPrefix(p) { stripped = stripped.dropFirst(p.count) }
        if let v = DAY_NAMES[String(stripped)] { return v }
        // 周X/星期X 后跟单数字 (§2: ...|"天"|DIGIT{1})
        if stripped.count == 1, let c = stripped.first, c.isNumber { return c.wholeNumberValue }
        return nil
    }

    // MARK: - Nd 冻结预设 (§5; 规范常量而非应用当前默认)

    /// (start, end) 对, 节号 = 下标 + 1。与 TimeTableUtils.DEFAULT_TIME_JSON 逐值一致(测试锁定)。
    static let ND_PRESET: [(Int, Int)] = [
        (8 * 60 + 0, 8 * 60 + 45), (8 * 60 + 55, 9 * 60 + 40),
        (10 * 60 + 0, 10 * 60 + 45), (10 * 60 + 55, 11 * 60 + 40),
        (14 * 60 + 0, 14 * 60 + 45), (14 * 60 + 55, 15 * 60 + 40),
        (16 * 60 + 0, 16 * 60 + 45), (16 * 60 + 55, 17 * 60 + 40),
        (19 * 60 + 0, 19 * 60 + 45), (19 * 60 + 55, 20 * 60 + 40),
        (20 * 60 + 50, 21 * 60 + 35), (21 * 60 + 45, 22 * 60 + 30)
    ]

    /// 作息逐值等于冻结预设? (导出端决定写 Nd 还是逐节 N 行)
    static func matchesNdPreset(_ timeJson: String) -> Bool {
        let nodes = TimeTableUtils.parseNodes(timeJson)
        if nodes.count != ND_PRESET.count { return false }
        let cal = Calendar(identifier: .gregorian)
        for (i, n) in nodes.enumerated() {
            if n.node != i + 1 { return false }
            let sm = cal.component(.hour, from: n.start) * 60 + cal.component(.minute, from: n.start)
            let em = cal.component(.hour, from: n.end) * 60 + cal.component(.minute, from: n.end)
            if sm != ND_PRESET[i].0 || em != ND_PRESET[i].1 { return false }
        }
        return true
    }

    /// HH:mm
    static func fmtTime(h: Int, min: Int) -> String {
        String(format: "%02d:%02d", h, min)
    }

    // MARK: - crc32 (§8.1-3, 8 位小写 hex)

    /// 标准 CRC-32 (IEEE 802.3, 多项式 0xEDB88320 反射) — 与 java.util.zip.CRC32 逐位一致
    static func crc32(_ data: Data) -> String {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        crc = ~crc
        return String(format: "%08x", crc)
    }
}
