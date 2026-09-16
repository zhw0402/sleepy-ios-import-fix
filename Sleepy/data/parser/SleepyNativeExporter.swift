// SleepyNativeExporter.swift — ← data/parser/SleepyNativeExporter.kt (逐行翻译, GPL-3.0)
// Sleepy iOS — sleepy-v1 导出器(规范 §4/§5/§8.1):
// 写规范形(导出永不出现裸危险字符; 字段编码紧凑, 调色板走索引, Nd 折叠);
// 承担散周 partition 与同名异组强制 token(契约二)。

import Foundation

enum SleepyNativeExporter {

    /// 文件形态: 末尾追加 z|chk=crc32:xxxxxxxx(文件导出默认写)
    static func exportFile(tableName: String, startDate: String, maxWeek: Int,
                           nodesPerDay: Int, timeJson: String, courses: [CourseEntity]) -> String {
        let body = buildBody(tableName: tableName, startDate: startDate, maxWeek: maxWeek,
                             nodesPerDay: nodesPerDay, timeJson: timeJson, courses: courses)
        return body + "\nz|chk=crc32:" + SleepyNativeFormat.crc32(body.data(using: .utf8)!)
    }

    /// 分享文本形态: 【来自Sleepy】+ 包裹 marker + 无 chk(规范 §1.1)
    static func exportShareText(tableName: String, startDate: String, maxWeek: Int,
                                nodesPerDay: Int, timeJson: String, courses: [CourseEntity]) -> String {
        let body = buildBody(tableName: tableName, startDate: startDate, maxWeek: maxWeek,
                             nodesPerDay: nodesPerDay, timeJson: timeJson, courses: courses)
        return "【来自Sleepy】\n课程分享：\n\n<<<SLEEPY-BEGIN>>>\n\(body)\n<<<SLEEPY-END>>>"
    }

    private static func buildBody(tableName: String, startDate: String, maxWeek: Int,
                                  nodesPerDay: Int, timeJson: String, courses: [CourseEntity]) -> String {
        var sb = ""
        sb += "#sleepy-v1\n"

        // ---- T 行(§3.5) ----
        sb += "T"
        sb += SleepyNativeFormat.escape(tableName.isEmpty ? "导入的课表" : tableName)
        sb += "|" + startDate
        sb += "|" + String(maxWeek)
        sb += "|" + String(nodesPerDay)
        // §4 契约二: 同名异组须显式 token
        let hasSameNameMultiGroup = hasSameNameMultipleGroups(courses)
        // n= 计数行(§8.3); 散周 partition 可能拆行, 数字会变; 导出端用 partition 后 C 行数
        let partitionedCount = countAfterPartition(courses)
        sb += "|n=\(partitionedCount)\n"

        // ---- 作息 (Nd 或逐节 N 行) (§5) ----
        if SleepyNativeFormat.matchesNdPreset(timeJson) {
            sb += "Nd\n"
        } else if !timeJson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let nodes = TimeTableUtils.parseNodes(timeJson)
            let cal = Calendar(identifier: .gregorian)
            for n in nodes {
                sb += "N\(n.node)"
                sb += "|" + fmtDate(n.start, cal: cal)
                sb += "|" + fmtDate(n.end, cal: cal)
                sb += "\n"
            }
        }

        // ---- 课程行 ----
        for line in exportCourses(courses, forceToken: hasSameNameMultiGroup) {
            sb += line + "\n"
        }

        // 去尾换行 — file 形 chk 前, share 形 marker 内
        while sb.hasSuffix("\n") { sb.removeLast() }
        return sb
    }

    private static func fmtDate(_ d: Date, cal: Calendar) -> String {
        SleepyNativeFormat.fmtTime(h: cal.component(.hour, from: d), min: cal.component(.minute, from: d))
    }

    /**
     * 按 §4 散周 partition 拆行: 把每个课程的上课周集合按"极大连续段"拆为多条 C 行, 每行 type 重新判定:
     * - 段全奇 → type 1 (S-E单) · 段全偶 → type 2 (S-E双) · 段全周 → type 0 (S-E)
     * - 段非全周非纯奇偶 → type 3 (S-E定)
     * 不支持"零散单周内插"(1, 10, 12): 本函数按"区间合并到段"处理, 多段分别一行 type 3。
     * v1 简化: 尊重输入 (startWeek, endWeek, type) 三元组, 输出单条(与 Kotlin 实现一致)。
     */
    private static func partitionWeeks(_ startWeek: Int, _ endWeek: Int, _ type: Int) -> [(Int, Int, Int)] {
        [(startWeek, endWeek, type)]
    }

    private static func exportCourses(_ courses: [CourseEntity], forceToken: Bool) -> [String] {
        // 按 groupId 排序输出(§8.1)
        let sorted = courses.sorted { a, b in
            if a.groupId != b.groupId { return a.groupId < b.groupId }
            return a.courseName < b.courseName
        }
        var tokenMap: [String: String] = [:]
        var out: [String] = []
        for c in sorted {
            let token: String
            if c.groupId.isEmpty {
                token = ""
            } else if forceToken {
                if tokenMap[c.groupId] == nil { tokenMap[c.groupId] = String(tokenMap.count + 1) }
                token = tokenMap[c.groupId]!
            } else {
                // 决定是否需要显式 token: §3.4 契约二 — 同名异组必写; 否则按组是否跨多名判定
                let sameGroupCount = sorted.filter { $0.groupId == c.groupId }.count
                let sameNameCount = sorted.filter { $0.courseName.trimmingCharacters(in: .whitespaces) == c.courseName.trimmingCharacters(in: .whitespaces) }.count
                if sameGroupCount > 0 && sameNameCount > 1 {
                    if tokenMap[c.groupId] == nil { tokenMap[c.groupId] = String(tokenMap.count + 1) }
                    token = tokenMap[c.groupId]!
                } else {
                    token = ""
                }
            }
            out.append(buildCourseLine(c, token: token))
        }
        return out
    }

    private static func buildCourseLine(_ c: CourseEntity, token: String) -> String {
        var sb = ""
        sb += "C" + SleepyNativeFormat.escape(c.courseName)
        sb += "|" + String(c.day)
        sb += "|" + "\(c.startNode)-\(c.startNode + c.step - 1)"
        sb += "|" + SleepyNativeFormat.weekSpecToToken(c.startWeek, c.endWeek, c.type)
        sb += "|" + SleepyNativeFormat.escape(c.teacher)
        sb += "|" + SleepyNativeFormat.escape(c.room)
        sb += "|" + SleepyNativeFormat.colorToToken(c.color)
        sb += "|" + SleepyNativeFormat.escape(c.note)
        if c.ownTime && !c.startTime.trimmingCharacters(in: .whitespaces).isEmpty && !c.endTime.trimmingCharacters(in: .whitespaces).isEmpty {
            sb += "|" + c.startTime + "-" + c.endTime
        } else {
            sb += "|"
        }
        sb += "|" + token
        // issue#26: 可选第 11 列 = 课程别名(escape 后写入); 空别名不写列(文件形状与既有 v1 完全一致)
        if !c.alias.trimmingCharacters(in: .whitespaces).isEmpty {
            sb += "|" + SleepyNativeFormat.escape(c.alias.trimmingCharacters(in: .whitespaces))
        }
        return sb
    }

    private static func hasSameNameMultipleGroups(_ courses: [CourseEntity]) -> Bool {
        let byName = Dictionary(grouping: courses) { $0.courseName.trimmingCharacters(in: .whitespaces) }
        return byName.values.contains { Set($0.map { $0.groupId }).count > 1 }
    }

    private static func countAfterPartition(_ courses: [CourseEntity]) -> Int {
        // v1 简化: 暂不展开 partition; 等于课程数(当 partition 实现完备后这里同步改)
        courses.count
    }
}
