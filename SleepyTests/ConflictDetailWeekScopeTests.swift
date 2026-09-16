// ConflictDetailWeekScopeTests.swift — ← ConflictDetailWeekScopeTest.kt
// v7.10.16q — 详情弹窗"幽灵图层"回归(用户 2026-09-03 报障):
// ICS 往返后周四 8-10 节的电路与电子II存在两行(周1-4 / 周6-13, 间隔周5),
// 加上 6-9(周16) 实验室行 — 三行节次两两重叠但周次永不相交。
// 网格按周过滤后本周只有一行(无冲突);详情弹窗此前拿全周课程 → 3 图层 →
// 错误地弹"选择默认置顶课程"。
// 定案: 详情弹窗的簇判定必须与网格同周域 — 课程集先按选中周过滤再聚簇。

import XCTest
@testable import Sleepy

final class ConflictDetailWeekScopeTests: XCTestCase {

    /// fixture 与安卓同款(消费 day/startNode/step/startWeek/endWeek/type)
    private func c(
        _ id: Int64, _ day: Int, _ startNode: Int, _ endNode: Int,
        _ startWeek: Int, _ endWeek: Int, _ type: Int = 0,
        name: String = "电路与电子II"
    ) -> CourseEntity {
        var course = CourseEntity(
            groupId: "g\(id)", tableId: 1, courseName: name,
            day: day, startNode: startNode, step: endNode - startNode + 1,
            startWeek: startWeek, endWeek: endWeek, type: type, color: "")
        course.id = id
        return course
    }

    /// ICS 往返后的周四全量行(真实形态)
    private lazy var thursdayRows: [CourseEntity] = [
        c(1, 4, 1, 2, 2, 4, 0, name: "工程设计与计算"),
        c(2, 4, 1, 4, 16, 16, 0, name: "电路与电子II"),      // 周16 实验室
        c(3, 4, 3, 4, 1, 4, 0, name: "大学物理C（二）"),
        c(12, 4, 3, 4, 6, 13, 0, name: "大学物理C（二）"),   // 换教师拆行(周6-13 王雷)
        c(4, 4, 6, 9, 16, 16, 0, name: "电路与电子II"),      // 周16 实验室
        c(5, 4, 8, 10, 1, 4, 0, name: "电路与电子II"),       // 周1-4
        c(6, 4, 8, 10, 6, 13, 0, name: "电路与电子II"),      // 周6-13 ← 用户点的(周6 视角)
        c(7, 4, 11, 13, 6, 6, 0, name: "迈克尔逊"),
    ]

    func testWeekFilteredThursdayHasNoPhantomConflictAtNodes8to10() {
        // 周2 视角(网格所见): 只有周1-4 的行存在
        let week2 = thursdayRows.filter { $0.inWeek(2) }
        let nodes89 = week2.filter { $0.startNode <= 8 && 8 <= $0.startNode + $0.step - 1 }
        XCTAssertEqual(nodes89.filter { $0.startNode == 8 }.count, 1,
                       "week 2 has exactly one 8-10 row")

        let clusters = ConflictLayoutEngine.findClusters(week2)
        let tappedCluster = clusters.first { cl in cl.courses.contains { $0.id == 5 } }
        XCTAssertNil(tappedCluster,
            "week 2: tapped 8-10 has NO conflict cluster (weeks 1-4 rows only overlap 工设1-2/物理3-4 — not 8-10)")
    }

    func testWeekFilteredWeek6KeepsRealLayeringForTappedCourse() {
        // 周6 视角: 8-10(b) 与 迈克尔逊11-13 不重叠节次; 8-10 只此一行 → 仍无置顶可选
        let week6 = thursdayRows.filter { $0.inWeek(6) }
        let clusters = ConflictLayoutEngine.findClusters(week6)
        let tappedCluster = clusters.first { cl in cl.courses.contains { $0.id == 6 } }
        // 周6 的 8-10(b) 邻居: 11-13 迈克尔逊(不相交), 6-9实验室不在周6 → 单课不成簇
        XCTAssertNil(tappedCluster, "week 6: tapped 8-10(b) has no overlapping neighbor")
    }

    func testUnfilteredCoursesReproduceReportedThreeLayers() {
        // 改前行为存档: 全周课程聚簇 → 被点课所在簇 = {6-9, 8-10(a), 8-10(b)} → 3 图层
        let clusters = ConflictLayoutEngine.findClusters(thursdayRows)
        let tappedCluster = clusters.first { cl in cl.courses.contains { $0.id == 6 } }!
        let layers = ConflictLayoutEngine.chainGroups(tappedCluster.courses)
        XCTAssertEqual(layers.count, 3)
    }

    func testWeek16LabRowsFormNoPhantomCluster() {
        // 周16 视角: 在场行 = 1-4(电路实验室) + 6-9(电路实验室)。
        // 节次 1-4 与 6-9 不相交 → 无任何簇(不弹置顶)。
        let week16 = thursdayRows.filter { $0.inWeek(16) }
        XCTAssertEqual(week16.count, 2)
        let clusters = ConflictLayoutEngine.findClusters(week16)
        XCTAssertNil(
            clusters.first { cl in cl.courses.contains { $0.id == 4 } },
            "week16: lab rows 1-4 / 6-9 don't overlap nodes — no cluster")
    }
}
