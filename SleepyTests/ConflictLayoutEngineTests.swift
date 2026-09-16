// ConflictLayoutEngineTests.swift — ← ConflictLayoutEngineTest.kt + ConflictCardGeometryTest.kt
// (忠实对齐安卓 107 用例的引擎子集, GPL-3.0) Sleepy iOS — 100% port of sleepy Android

import XCTest
@testable import Sleepy

final class ConflictLayoutEngineTests: XCTestCase {

    /// fixture 与安卓同款: 判定仅消费 day/startNode/step/id,其余字段填默认值。
    private func course(
        _ id: Int64, _ day: Int, _ startNode: Int, _ step: Int,
        name: String = "课程"
    ) -> CourseEntity {
        var c = CourseEntity(
            groupId: "grp-\(id)", tableId: 1, courseName: name,
            day: day, startNode: startNode, step: step,
            startWeek: 1, endWeek: 16, color: "")
        c.id = id
        return c
    }

    private func layoutById(
        _ courses: [CourseEntity], _ style: String,
        topOverrideId: Int64? = nil, maxNode: Int? = nil
    ) -> [Int64: LaidOutCourse] {
        precondition(!courses.isEmpty)
        let cluster = ConflictCluster(day: courses[0].day, courses: courses)
        return Dictionary(uniqueKeysWithValues: ConflictLayoutEngine.layoutCluster(
            cluster, style: style, topOverrideId: topOverrideId, maxNode: maxNode
        ).map { ($0.course.id, $0) })
    }

    private func eq(_ a: LaidOutCourse, _ b: LaidOutCourse) -> Bool {
        a.course.id == b.course.id && a.zRank == b.zRank && a.hidden == b.hidden
            && a.variant == b.variant && a.chainFront == b.chainFront
    }

    private func assertLaid(_ a: LaidOutCourse, _ zRank: Int, _ hidden: Bool,
                            _ variant: ConflictVariant, chainFront: Bool = false,
                            _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.zRank, zRank, msg, file: file, line: line)
        XCTAssertEqual(a.hidden, hidden, msg, file: file, line: line)
        XCTAssertEqual(a.variant, variant, msg, file: file, line: line)
        XCTAssertEqual(a.chainFront, chainFront, msg, file: file, line: line)
    }

    // ============================ findClusters ============================

    func testClustersShareNodeMergeIntoOneCluster() {
        let a = course(1, 1, 1, 2), b = course(2, 1, 2, 2)
        let clusters = ConflictLayoutEngine.findClusters([a, b])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].day, 1)
        XCTAssertEqual(clusters[0].courses.map { $0.id }, [a.id, b.id])
    }

    func testClustersTransitiveClosureThroughChain() {
        let a = course(1, 2, 1, 2), b = course(2, 2, 2, 2), c = course(3, 2, 3, 2)
        let clusters = ConflictLayoutEngine.findClusters([a, b, c])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].day, 2)
        XCTAssertEqual(clusters[0].courses.map { $0.id }, [a.id, b.id, c.id])
    }

    func testClustersDisjointSameDayNotMerged() {
        let a = course(1, 1, 1, 2), b = course(2, 1, 3, 2)
        XCTAssertTrue(ConflictLayoutEngine.findClusters([a, b]).isEmpty)
    }

    func testClustersCrossDayNeverMerged() {
        let a = course(1, 1, 1, 2), b = course(2, 2, 1, 2)
        XCTAssertTrue(ConflictLayoutEngine.findClusters([a, b]).isEmpty)
    }

    func testClustersSingleCourseAndEmptyInputNotReturned() {
        XCTAssertTrue(ConflictLayoutEngine.findClusters([course(1, 1, 1, 2)]).isEmpty)
        XCTAssertTrue(ConflictLayoutEngine.findClusters([]).isEmpty)
    }

    func testClustersOutputDaysAscending() {
        let d3 = course(1, 3, 1, 2), d3b = course(2, 3, 2, 2)
        let d1 = course(3, 1, 1, 2), d1b = course(4, 1, 2, 2)
        let clusters = ConflictLayoutEngine.findClusters([d3, d3b, d1, d1b])
        XCTAssertEqual(clusters.map { $0.day }, [1, 3])
        XCTAssertEqual(clusters[0].courses.map { $0.id }, [d1.id, d1b.id])
        XCTAssertEqual(clusters[1].courses.map { $0.id }, [d3.id, d3b.id])
    }

    // ============================ primaryOrder ============================

    func testPrimaryOrderStepDescendingIsFirstComponent() {
        let one = course(1, 1, 1, 1), two = course(2, 1, 2, 2), three = course(3, 1, 3, 3)
        XCTAssertEqual(ConflictLayoutEngine.primaryOrder([one, three, two]).map { $0.id },
                       [three.id, two.id, one.id])
    }

    func testPrimaryOrderSameStepStartNodeAscending() {
        let late = course(1, 1, 3, 2), early = course(2, 1, 1, 2)
        XCTAssertEqual(ConflictLayoutEngine.primaryOrder([late, early]).map { $0.id },
                       [early.id, late.id])
    }

    func testPrimaryOrderSameStepSameStartNodeIdAscending() {
        let bigId = course(9, 1, 1, 2), smallId = course(4, 1, 1, 2)
        XCTAssertEqual(ConflictLayoutEngine.primaryOrder([bigId, smallId]).map { $0.id },
                       [smallId.id, bigId.id])
    }

    func testPrimaryOrderFullTieBreakChain() {
        let startLate = course(5, 1, 4, 2), idSmall = course(2, 1, 1, 2), idBig = course(7, 1, 1, 2)
        XCTAssertEqual(ConflictLayoutEngine.primaryOrder([startLate, idBig, idSmall]).map { $0.id },
                       [idSmall.id, idBig.id, startLate.id])
    }

    // ============================ layoutCluster ============================

    func testLayoutFullyOverlappingPairHiddenTrueVariantsPerStyle() {
        let top = course(1, 1, 1, 3), under = course(2, 1, 1, 3)
        XCTAssertEqual(layoutById([top, under], "stack")[2]?.variant, .stack)
        XCTAssertEqual(layoutById([top, under], "fold")[2]?.variant, .fold)
        XCTAssertEqual(layoutById([top, under], "rail")[2]?.variant, .rail)
        for style in ["stack", "fold", "rail"] {
            let byId = layoutById([top, under], style)
            assertLaid(byId[1]!, 0, false, .noMark)
            assertLaid(byId[2]!, 1, true, style == "fold" ? .fold : style == "rail" ? .rail : .stack)
        }
    }

    func testLayoutSameStartDifferentEndShortCourseZeroExposureHidden() {
        let long14 = course(1, 1, 1, 4), short13 = course(2, 1, 1, 3)
        let byId = layoutById([long14, short13], "rail")
        XCTAssertEqual(byId[1]?.zRank, 0)
        XCTAssertEqual(byId[1]?.hidden, false)
        XCTAssertEqual(byId[2]?.zRank, 1)
        XCTAssertEqual(byId[2]?.hidden, true)
        XCTAssertEqual(byId[2]?.variant, .rail)
        XCTAssertEqual(byId[1]?.variant, .noMark)
    }

    func testLayoutFullyContainedInnerCourseHidden() {
        // v7.10.16f: fold 永远折角 — 起点不齐不再回落 STACK
        let outer = course(1, 2, 1, 5), inner = course(2, 2, 2, 2)
        let byId = layoutById([outer, inner], "fold")
        assertLaid(byId[1]!, 0, false, .noMark)
        assertLaid(byId[2]!, 1, true, .fold)
    }

    func testLayoutTrapezoidAllCoursesHaveExposure() {
        // v7.8: Layer1={2-4} 置顶(z0), Layer0={1-3,3-5} 垫底;链组态全员 hidden=false
        let a13 = course(1, 3, 1, 2), b24 = course(2, 3, 2, 2), c35 = course(3, 3, 3, 2)
        let laid = ConflictLayoutEngine.layoutCluster(ConflictCluster(day: 3, courses: [a13, b24, c35]), style: "stack")
        XCTAssertEqual(laid.count, 3)
        assertLaid(laid[0], 0, false, .noMark, chainFront: false, "2-4 顶层")
        assertLaid(laid[1], 1, false, .noMark, chainFront: false, "1-3")
        assertLaid(laid[2], 2, false, .noMark, chainFront: false, "3-5")
        XCTAssertEqual(laid[0].course.id, b24.id)
        XCTAssertEqual(laid[1].course.id, a13.id)
        XCTAssertEqual(laid[2].course.id, c35.id)
    }

    func testLayoutTopOverrideIdFlipsZOrderAndRecomputesHidden() {
        let a = course(1, 1, 1, 5), b = course(2, 1, 2, 5)
        let flipped = layoutById([a, b], "stack", topOverrideId: 2)
        XCTAssertEqual(flipped[2]?.zRank, 0)
        XCTAssertEqual(flipped[2]?.hidden, false)
        XCTAssertEqual(flipped[1]?.zRank, 1)
        XCTAssertEqual(flipped[1]?.hidden, false) // 独占节 1 仍露出

        let t = course(1, 2, 1, 3), u = course(2, 2, 1, 3)
        let sameRangeFlipped = layoutById([t, u], "stack", topOverrideId: 2)
        XCTAssertEqual(sameRangeFlipped[2]?.zRank, 0)
        XCTAssertEqual(sameRangeFlipped[1]?.zRank, 1)
        XCTAssertEqual(sameRangeFlipped[1]?.hidden, true)
        XCTAssertEqual(sameRangeFlipped[1]?.variant, .stack)
        XCTAssertEqual(sameRangeFlipped[2]?.variant, .noMark)
    }

    func testLayoutTopOverrideIdMissFallsBackToPrimaryOrder() {
        let top = course(1, 1, 1, 3), under = course(2, 1, 1, 3)
        let byId = layoutById([top, under], "rail", topOverrideId: 999)
        XCTAssertEqual(byId[1]?.zRank, 0)
        XCTAssertEqual(byId[2]?.hidden, true)
        XCTAssertEqual(byId[2]?.variant, .rail)
    }

    func testLayoutThreeCoursesStackConvergesToFold() {
        let a = course(1, 1, 1, 3), b = course(2, 1, 1, 3), c = course(3, 1, 1, 3)
        let byId = layoutById([a, b, c], "stack")
        assertLaid(byId[1]!, 0, false, .noMark)
        assertLaid(byId[2]!, 1, true, .fold)
        assertLaid(byId[3]!, 2, true, .fold)
    }

    func testLayoutRailVariantIndependentOfClusterSize() {
        let two = [course(1, 1, 1, 3), course(2, 1, 1, 3)]
        XCTAssertEqual(layoutById(two, "rail")[2]?.variant, .rail)
        let three = two + [course(3, 1, 1, 3)]
        XCTAssertEqual(layoutById(three, "rail")[2]?.variant, .rail)
        XCTAssertEqual(layoutById(three, "rail")[3]?.variant, .rail)
    }

    // ============================ v7.9 默认置顶偏好集成 ============================

    func testV79DefaultTopLiftsChainLayerAtomically() {
        let a = course(1, 1, 1, 3, name: "A")
        let b = course(2, 1, 3, 4, name: "B")
        let c = course(3, 1, 1, 2, name: "C")
        let cluster = ConflictCluster(day: 1, courses: [a, b, c])
        let groups = ConflictLayoutEngine.chainGroups(cluster.courses)
        XCTAssertEqual(groups.count, 2)

        let defaultLaid = layoutById(cluster.courses, "rail")
        XCTAssertEqual(defaultLaid[1]?.zRank, 0) // A 默认顶层
        XCTAssertEqual(defaultLaid[3]?.zRank, 1) // C 次
        XCTAssertEqual(defaultLaid[2]?.zRank, 2) // B 末

        // 用户保存默认置顶 = C → {C, B} 整组置顶
        let pickedLaid = layoutById(cluster.courses, "rail", topOverrideId: 3)
        XCTAssertEqual(pickedLaid[3]?.zRank, 0)
        XCTAssertEqual(pickedLaid[2]?.zRank, 1)
        XCTAssertEqual(pickedLaid[1]?.zRank, 2)
    }

    func testV79DefaultTopLiftsSingletonLayer() {
        let outer = course(10, 1, 1, 3), inner = course(20, 1, 1, 2)
        let defaultLaid = layoutById([outer, inner], "rail")
        XCTAssertEqual(defaultLaid[10]?.zRank, 0)
        XCTAssertEqual(defaultLaid[20]?.zRank, 1)
        let pickedLaid = layoutById([outer, inner], "rail", topOverrideId: 20)
        XCTAssertEqual(pickedLaid[20]?.zRank, 0)
        XCTAssertEqual(pickedLaid[10]?.zRank, 1)
    }

    func testV79DefaultTopChainRepSameAsMemberLiftsWholeLayer() {
        let a = course(1, 1, 1, 3), b = course(2, 1, 3, 4), c = course(3, 1, 1, 2)
        let pickedLaid = layoutById([a, b, c], "rail", topOverrideId: 2) // 选 B → {C,B} 整组置顶
        XCTAssertEqual(pickedLaid[3]?.zRank, 0) // C 顶层(startNode 小)
        XCTAssertEqual(pickedLaid[2]?.zRank, 1)
        XCTAssertEqual(pickedLaid[1]?.zRank, 2)
    }

    // ============================ v7.6 图层语义 ============================

    func testChainGroupsLayerCountGroupCountsAsSingleLayer() {
        let courses = [course(1, 1, 1, 3), course(2, 1, 4, 3), course(3, 1, 1, 6)]
        let groups = ConflictLayoutEngine.chainGroups(courses)
        XCTAssertEqual(groups.map { $0.count }, [2, 1])
    }

    func testLayoutGroupedOverlapperHiddenVariantNotDrivenByRawCourseCount() {
        let courses = [course(1, 1, 1, 3), course(2, 1, 4, 3), course(3, 1, 1, 6)]
        let byId = layoutById(courses, "stack")
        XCTAssertEqual(byId[3]?.hidden, false)
        XCTAssertEqual(byId[3]?.variant, .noMark)
    }

    func testLayoutOutputPreservesPrimaryOrderWithOverrideLast() {
        let a = course(1, 1, 1, 3), b = course(2, 1, 1, 3), c = course(3, 1, 1, 3)
        let defaultOrder = ConflictLayoutEngine.layoutCluster(
            ConflictCluster(day: 1, courses: [c, a, b]), style: "rail").map { $0.course.id }
        XCTAssertEqual(defaultOrder, [a.id, b.id, c.id])
        let overrideOrder = ConflictLayoutEngine.layoutCluster(
            ConflictCluster(day: 1, courses: [c, a, b]), style: "rail", topOverrideId: 3).map { $0.course.id }
        XCTAssertEqual(overrideOrder, [c.id, a.id, b.id])
    }

    // ============================ maxNode 裁剪 ============================

    func testLayoutClusterMaxNodeClampsExposureSpaceOutOfGridTailHidden() {
        let y = course(1, 1, 10, 3), x = course(2, 1, 11, 3)
        let byId = layoutById([y, x], "rail", maxNode: 12)
        XCTAssertEqual(byId[1]?.zRank, 0)
        XCTAssertEqual(byId[1]?.hidden, false)
        XCTAssertEqual(byId[2]?.hidden, true)
        XCTAssertEqual(byId[2]?.variant, .rail)
    }

    func testLayoutClusterMaxNodeMixedGroupsInOneCluster() {
        let a1 = course(1, 1, 1, 2), a2 = course(2, 1, 1, 2)
        let b1 = course(3, 1, 3, 2), b2 = course(4, 1, 3, 2)
        let byId = layoutById([a1, a2, b1, b2], "stack")
        assertLaid(byId[1]!, 0, false, .noMark, chainFront: true)
        assertLaid(byId[3]!, 1, false, .noMark, chainFront: true)
        assertLaid(byId[2]!, 2, false, .noMark, chainFront: false)
        assertLaid(byId[4]!, 3, false, .noMark, chainFront: false)
    }

    func testLayoutClusterMaxNodeTailOutOfGridCourseProducesNoPhantomCoverage() {
        let z = course(1, 1, 13, 3), c = course(2, 1, 12, 2)
        let byId = layoutById([z, c], "rail", maxNode: 12)
        XCTAssertEqual(byId[1]?.hidden, true)
        XCTAssertEqual(byId[2]?.hidden, false)
    }

    // ============================ layoutFor ============================

    func testLayoutForMultiClusterInputFlattensAllClusterCourses() {
        let d1a = course(1, 1, 1, 2), d1b = course(2, 1, 2, 2)
        let d3a = course(3, 3, 1, 3), d3b = course(4, 3, 1, 3), d3c = course(5, 3, 1, 3)
        let solo = course(9, 2, 1, 2)
        let laid = ConflictLayoutEngine.layoutFor([d1a, d1b, d3a, d3b, d3c, solo], style: "stack")
        XCTAssertEqual(laid.map { $0.course.id }, [1, 2, 3, 4, 5])
    }

    func testLayoutForZRankRestartsFromZeroPerCluster() {
        let d1a = course(1, 1, 1, 2), d1b = course(2, 1, 2, 2)
        let d3a = course(3, 3, 1, 3), d3b = course(4, 3, 1, 3)
        let laid = ConflictLayoutEngine.layoutFor([d1a, d1b, d3a, d3b], style: "stack")
        XCTAssertEqual(laid.map { $0.zRank }, [0, 1, 0, 1])
    }

    func testLayoutForTopOverrideIdAppliesToTargetClusterOnly() {
        let d1a = course(1, 1, 1, 2), d1b = course(2, 1, 2, 2)
        let d3a = course(3, 3, 1, 3), d3b = course(4, 3, 1, 3)
        let laid = ConflictLayoutEngine.layoutFor([d1a, d1b, d3a, d3b], style: "stack", topOverrideId: 4)
        XCTAssertEqual(laid[0].course.id, d1a.id)
        XCTAssertEqual(laid[1].course.id, d1b.id)
        XCTAssertEqual(laid[2].course.id, d3b.id)
        XCTAssertEqual(laid[3].course.id, d3a.id)
        XCTAssertEqual(laid[3].hidden, true)
        XCTAssertEqual(laid[3].variant, .stack)
    }

    func testLayoutForNoConflictsReturnsEmpty() {
        let a = course(1, 1, 1, 2), b = course(2, 1, 3, 2)
        XCTAssertTrue(ConflictLayoutEngine.layoutFor([a, b], style: "rail").isEmpty)
        XCTAssertTrue(ConflictLayoutEngine.layoutFor([], style: "rail").isEmpty)
    }

    func testLayoutForStylePropagatesToHiddenVariants() {
        let a = course(1, 1, 1, 3), b = course(2, 1, 1, 3)
        XCTAssertEqual(ConflictLayoutEngine.layoutFor([a, b], style: "rail").first { $0.course.id == 2 }?.variant, .rail)
        XCTAssertEqual(ConflictLayoutEngine.layoutFor([a, b], style: "fold").first { $0.course.id == 2 }?.variant, .fold)
    }

    // ============================ overlayMarkOrder ============================

    private func drawOrderIds(_ items: [ConflictLayoutEngine.CourseDrawItem]) -> [String] {
        items.map {
            switch $0 {
            case .card(let l): return "Card:\(l.course.id)"
            case .mark(let id, _): return "Mark:\(id)"
            }
        }
    }

    func testOverlayMarkOrderMarksComeAfterTopCardInDrawOrder() {
        let a = course(1, 1, 1, 3), b = course(2, 1, 1, 3)
        let order = ConflictLayoutEngine.overlayMarkOrder(
            ConflictLayoutEngine.layoutFor([a, b], style: "stack"))
        XCTAssertEqual(drawOrderIds(order), ["Card:2", "Card:1", "Mark:2"])
    }

    func testOverlayMarkOrderAllHiddenMarksAppendedAndPickable() {
        let a = course(1, 1, 1, 3), b = course(2, 1, 1, 3), c = course(3, 1, 1, 3)
        let order = ConflictLayoutEngine.overlayMarkOrder(
            ConflictLayoutEngine.layoutFor([a, b, c], style: "rail"))
        XCTAssertEqual(drawOrderIds(order), ["Card:3", "Card:2", "Card:1", "Mark:2", "Mark:3"])
    }

    func testOverlayMarkOrderNoHiddenOnlyCardsAndTopLast() {
        let a13 = course(1, 3, 1, 2), b24 = course(2, 3, 2, 2), c35 = course(3, 3, 3, 2)
        let order = ConflictLayoutEngine.overlayMarkOrder(
            ConflictLayoutEngine.layoutFor([a13, b24, c35], style: "stack"))
        XCTAssertEqual(drawOrderIds(order), ["Card:3", "Card:1", "Card:2"])
    }

    func testOverlayMarkOrderOverrideMovesHiddenMarkWithCourse() {
        let a = course(1, 1, 1, 3), b = course(2, 1, 1, 3)
        let order = ConflictLayoutEngine.overlayMarkOrder(
            ConflictLayoutEngine.layoutFor([a, b], style: "fold", topOverrideId: 2))
        XCTAssertEqual(drawOrderIds(order), ["Card:1", "Card:2", "Mark:1"])
    }

    func testOverlayMarkOrderOutOfGridTopFallsBackToFirstVisible() {
        let visible = [
            LaidOutCourse(course: course(2, 1, 1, 2), zRank: 1, hidden: false, variant: .noMark),
            LaidOutCourse(course: course(3, 1, 2, 2), zRank: 2, hidden: false, variant: .noMark),
        ]
        let order = ConflictLayoutEngine.overlayMarkOrder(visible)
        XCTAssertEqual(drawOrderIds(order), ["Card:3", "Card:2"])
    }

    func testOverlayMarkOrderEmptyInputReturnsEmpty() {
        XCTAssertTrue(ConflictLayoutEngine.overlayMarkOrder([]).isEmpty)
    }

    // ============================ markHitArea / foldSwitchHitArea ============================

    func testMarkHitAreaStackIsBottomEdgeStripNotFullCard() {
        let (w, h) = ConflictLayoutEngine.markHitArea(.stack, cardWidth: 60, cardHeight: 120)
        XCTAssertEqual(w, 36, accuracy: 0.001)
        XCTAssertEqual(h, 36, accuracy: 0.001)
    }

    func testMarkHitAreaFoldIsTopCornerTriangleZoneNotFullCard() {
        let (w, h) = ConflictLayoutEngine.markHitArea(.fold, cardWidth: 60, cardHeight: 120)
        XCTAssertEqual(w, 36, accuracy: 0.001)
        XCTAssertEqual(h, 36, accuracy: 0.001)
    }

    func testMarkHitAreaRailIsSameAsStackNotRightStripe() {
        let (w, h) = ConflictLayoutEngine.markHitArea(.rail, cardWidth: 60, cardHeight: 120)
        XCTAssertEqual(w, 36, accuracy: 0.001)
        XCTAssertEqual(h, 36, accuracy: 0.001)
    }

    func testFoldSwitchHitAreaFoldCoversFlapAndCutout36dp() {
        let (w, h) = ConflictLayoutEngine.foldSwitchHitArea(.fold, cardWidth: 60, cardHeight: 120)
        XCTAssertEqual(w, 36, accuracy: 0.001)
        XCTAssertEqual(h, 36, accuracy: 0.001)
    }

    func testFoldSwitchHitAreaNonFoldVariantsAreNotTappable() {
        for v in [ConflictVariant.stack, .rail, .noMark] {
            let (w, h) = ConflictLayoutEngine.foldSwitchHitArea(v, cardWidth: 60, cardHeight: 120)
            XCTAssertEqual(w, 0, accuracy: 0.001)
            XCTAssertEqual(h, 0, accuracy: 0.001)
        }
    }

    func testFoldSwitchHitAreaScalesWithUserFoldSize() {
        let (w, h) = ConflictLayoutEngine.foldSwitchHitArea(.fold, cardWidth: 60, cardHeight: 120, foldSize: 24)
        XCTAssertEqual(w, 44, accuracy: 0.001)
        let (w8, h8) = ConflictLayoutEngine.foldSwitchHitArea(.fold, cardWidth: 60, cardHeight: 120, foldSize: 8)
        XCTAssertEqual(w8, 28, accuracy: 0.001)
        let (w16, h16) = ConflictLayoutEngine.foldSwitchHitArea(.fold, cardWidth: 60, cardHeight: 120)
        XCTAssertEqual(w16, 36, accuracy: 0.001)
    }

    // ============================ v7.10.16r 轮换 ============================

    func testRotationNextCyclesLeft() {
        XCTAssertEqual(ConflictLayoutEngine.rotationNext(123), 231)
        XCTAssertEqual(ConflictLayoutEngine.rotationNext(231), 312)
        XCTAssertEqual(ConflictLayoutEngine.rotationNext(12), 21)
        // 非法输入
        XCTAssertEqual(ConflictLayoutEngine.rotationNext(0), 0)
        XCTAssertEqual(ConflictLayoutEngine.rotationNext(-1), 0)
        XCTAssertEqual(ConflictLayoutEngine.rotationNext(10), 0)  // 含 0 位
        XCTAssertEqual(ConflictLayoutEngine.rotationNext(5), 5)   // 1 层无轮换
    }

    func testApplyLayerRotationModulo() {
        let order: [Int64] = [1, 2, 3]
        XCTAssertEqual(ConflictLayoutEngine.applyLayerRotation(order, 1), [2, 3, 1])
        XCTAssertEqual(ConflictLayoutEngine.applyLayerRotation(order, 3), order)
        XCTAssertEqual(ConflictLayoutEngine.applyLayerRotation(order, -1), [3, 1, 2])
        XCTAssertEqual(ConflictLayoutEngine.applyLayerRotation([1], 5), [1])
    }

    func testDefaultLayerIdOrderMatchesLayoutClusterDefault() {
        // 1-3/1-4/4-6: 层 {1-4} 先, {1-3,4-6} 垫底 → [id3, id1](1-4 是 id3)
        let a = course(1, 1, 1, 3), b = course(3, 1, 1, 4), c = course(4, 1, 4, 3)
        XCTAssertEqual(ConflictLayoutEngine.defaultLayerIdOrder([a, b, c]), [3, 1])
    }

    func testMemberToLayerRepMapsWholeGroup() {
        // {1-3,4-6} 组(层代表 = 1-3, id=1)+ 1-6 自成层: 1↔1, 2↔1, 3↔3
        let a = course(1, 1, 1, 3), b = course(2, 1, 4, 3), c = course(3, 1, 1, 6)
        let rep = ConflictLayoutEngine.memberToLayerRep([a, b, c])
        XCTAssertEqual(rep[1], 1)
        XCTAssertEqual(rep[2], 1) // b 与 a 同层,层代表 = 主序最前 = a(id=1)
        XCTAssertEqual(rep[3], 3)
    }

    // ============================ v7.10.16p 簇键 + 清理 ============================

    func testConflictClusterKeyFormat() {
        XCTAssertEqual(ConflictLayoutEngine.conflictClusterKey(course(7, 3, 5, 2)), "3:5:2")
    }

    func testPruneConflictDefaultTopDropsDeadKeysAndReps() {
        let live = [course(1, 1, 1, 2), course(2, 1, 2, 2)]
        let stored: [String: Int64] = [
            "1:1:2": 1,   // 键有效 rep 有效 → 保留
            "5:1:2": 1,   // 键不存在于现存簇 → 删
            "2:2:2": 99,  // rep 指向不存在课 → 删
        ]
        let pruned = ConflictLayoutEngine.pruneConflictDefaultTop(stored, live)
        XCTAssertEqual(pruned, ["1:1:2": 1])
    }

    func testPruneConflictDefaultTopEmptyInputs() {
        XCTAssertTrue(ConflictLayoutEngine.pruneConflictDefaultTop([:], [course(1, 1, 1, 2)]).isEmpty)
        XCTAssertTrue(ConflictLayoutEngine.pruneConflictDefaultTop(["1:1:2": 1], []).isEmpty)
    }

    // ============================ 周视图分栏 ============================

    func testWeekLaneSegmentsDisjointRegionFullWidth() {
        let a = course(1, 1, 1, 2), b = course(2, 1, 5, 2)
        let segs = ConflictLayoutEngine.weekLaneSegments([a, b])
        XCTAssertEqual(segs.count, 2)
        XCTAssertTrue(segs.allSatisfy { $0.laneCount == 1 && $0.lane == 0 })
    }

    func testWeekLaneSegmentsConflictRegionTwoLanes() {
        // 1-3 与 2-4 完全重叠不可并排 → 2 栏
        let a = course(1, 1, 1, 3), b = course(2, 1, 2, 3)
        let segs = ConflictLayoutEngine.weekLaneSegments([a, b])
        XCTAssertEqual(segs.count, 2)
        XCTAssertTrue(segs.allSatisfy { $0.laneCount == 2 })
        XCTAssertEqual(segs.first { $0.course.id == 1 }?.lane, 0)
        XCTAssertEqual(segs.first { $0.course.id == 2 }?.lane, 1)
    }

    func testWeekLaneRowsPartitionAndOrder() {
        // 链式 1-2/2-3/3-4 一个区域一行;chainGroups 右端点贪心: 1-2 与 3-4 可并排同栏,
        // 2-3 独栏 → 2 栏(与安卓同 fixture 真值一致)
        let a = course(1, 1, 1, 2), b = course(2, 1, 2, 2), c = course(3, 1, 3, 2)
        let rows = ConflictLayoutEngine.weekLaneRows([a, b, c])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].courses.count, 3)
        XCTAssertEqual(rows[0].laneCount, 2)
        XCTAssertEqual(rows[0].laneOf[a.id], 0)
        XCTAssertEqual(rows[0].laneOf[b.id], 1)
        XCTAssertEqual(rows[0].laneOf[c.id], 0)
    }

    func testGridDayLanesHalvesForPair() {
        let a = course(1, 1, 1, 3), b = course(2, 1, 1, 3)
        let rects = ConflictLayoutEngine.gridDayLanes([a, b])
        XCTAssertEqual(rects.count, 2)
        let ra = rects.first { $0.course.id == 1 }!
        let rb = rects.first { $0.course.id == 2 }!
        XCTAssertEqual(ra.laneStartFraction, 0, accuracy: 0.001)
        XCTAssertEqual(ra.laneWidthFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(rb.laneStartFraction, 0.5, accuracy: 0.001)
    }

    func testDaysExceedingTwoLanesDetectsThirdLayer() {
        // 三课完全重叠 → 3 栏 → day 1 违规
        let a = course(1, 1, 1, 2), b = course(2, 1, 1, 2), c = course(3, 1, 1, 2)
        XCTAssertEqual(ConflictLayoutEngine.daysExceedingTwoLanes([a, b, c]), [1])
        // 两课重叠合法
        XCTAssertEqual(ConflictLayoutEngine.daysExceedingTwoLanes([a, b]), [])
    }
}
