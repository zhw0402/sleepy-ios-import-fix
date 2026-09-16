// RowKeyDifferTests.swift — ← RowKeyDifferTest.kt 别名契约 3 用例 (a00007f7, GPL-3.0)
// 用户报障 2026-09-11: 编辑课程别名无法保存 — fieldsDiffer 漏比 alias。

import XCTest
@testable import Sleepy

final class RowKeyDifferTests: XCTestCase {

    private func course(_ id: Int64, room: String = "A", alias: String = "") -> CourseEntity {
        var c = CourseEntity(groupId: "g1", tableId: 1, courseName: "高数",
                             day: 1, startNode: 1, step: 2, startWeek: 1, endWeek: 16, color: "#FF0000")
        c.id = id
        c.room = room
        c.alias = alias
        return c
    }

    /// 只改别名 → 该行走 update 保留 id, 不删不插
    func testAliasOnlyChangeProducesUpdateKeepingId() {
        let server = [course(1)]
        let draft = [course(1, alias: "高数(强化)")]
        let diff = RowKeyDiffer.diff(draft, server)
        XCTAssertTrue(diff.toInsert.isEmpty)
        XCTAssertTrue(diff.toDelete.isEmpty)
        XCTAssertEqual(diff.toUpdate.count, 1)
        XCTAssertEqual(diff.toUpdate.first?.id, 1)
        XCTAssertEqual(diff.toUpdate.first?.alias, "高数(强化)")
    }

    /// 别名清空也是变更 — 存量行必须同步清掉
    func testAliasClearedProducesUpdateWithEmptyString() {
        let server = [course(1, alias: "高数(强化)")]
        let draft = [course(1, alias: "")]
        let diff = RowKeyDiffer.diff(draft, server)
        XCTAssertTrue(diff.toDelete.isEmpty)
        XCTAssertEqual(diff.toUpdate.count, 1)
        XCTAssertEqual(diff.toUpdate.first?.alias, "")
    }

    /// 相同别名不动 — diff 空(别让修补把跳过路径打穿成全量 update)
    func testSameAliasProducesEmptyDiff() {
        let server = [course(1, alias: "高数(强化)")]
        let draft = [course(1, alias: "高数(强化)")]
        let diff = RowKeyDiffer.diff(draft, server)
        XCTAssertTrue(diff.toInsert.isEmpty)
        XCTAssertTrue(diff.toUpdate.isEmpty)
        XCTAssertTrue(diff.toDelete.isEmpty)
    }
}
