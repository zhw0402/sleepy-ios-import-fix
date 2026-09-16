// UndoManager.swift — ← data/undo/UndoManager.kt (逐行翻译, GPL-3.0)
// Sleepy iOS — 100% port of sleepy Android

import Foundation
import SwiftUI

/// 改动前的全库快照 — tables+courses+默认表 id。
struct UndoSnapshot {
    let tables: [TimeTableEntity]
    let courses: [CourseEntity]
    let defaultTableId: Int64?
}

/**
 * 单级撤回的快照槽(进程内单例)。
 *
 * repo 写方法执行前 capture(), 用户点撤回时 poll() 取走并清空 —
 * 单级语义: 撤回不可再撤回; App 进程被杀快照即失效(不落盘)。
 *
 * beginBatch() 支持复合动作(如导入=建表+插课+设默认):
 * 批内多次 capture 只保留第一次, 保证整个动作回退到同一时点;
 * 不在批内时每次 capture 都覆盖槽(单写动作语义)。
 *
 * restoring 抑制恢复动作自身的捕获, 防止 undo 生成新的 undo。
 *
 * Compose mutableStateOf → SwiftUI ObservableObject:
 * 视图订阅 hasSnapshot, 撤回按钮随有无快照显隐(用户 2026-09-03)。
 */
final class UndoManager: ObservableObject {
    static let shared = UndoManager()

    /// 槽本体 — 同步读写(语义对齐 Kotlin mutableStateOf: capture 立即可见)。
    /// @Published 的 objectWillChange 手动在主线程发,供 SwiftUI 按钮显隐订阅。
    private var slotStorage: UndoSnapshot? = nil
    private let lock = NSLock()
    private var batchDepth: Int = 0
    /// 本批首拍是否已落: 批内多次 capture 只保第一次 — 但锚定的是本批开始前(非旧快照)
    private var batchCaptured: Bool = false
    /// 恢复动作进行中标记(语义同 Kotlin @Volatile 单开关)
    var restoring: Bool = false

    var hasSnapshot: Bool {
        lock.lock(); defer { lock.unlock() }
        return slotStorage != nil
    }

    private init() {}

    func beginBatch() {
        batchDepth += 1
        // 批边界 = 新用户动作开始 — 旧动作的快照对新动作是过期锚点, 立即作废。
        // 若真要嵌套批(当前无此用法), 内层 begin 不清 batchCaptured(只在 0→1 清)。
        if batchDepth == 1 { batchCaptured = false }
    }

    func endBatch() { batchDepth = max(batchDepth - 1, 0) }

    func capture(tables: [TimeTableEntity], courses: [CourseEntity], defaultTableId: Int64?) {
        if restoring { return }
        lock.lock()
        if batchDepth > 0 {
            if batchCaptured {
                lock.unlock()
                return // 批内已有本动作快照 — 保动作链起点
            }
            batchCaptured = true
        }
        slotStorage = UndoSnapshot(tables: tables, courses: courses, defaultTableId: defaultTableId)
        lock.unlock()
        // SwiftUI 订阅通知必须在主线程发(Combine 要求);槽写入本身保持同步
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    @discardableResult
    func poll() -> UndoSnapshot? {
        lock.lock()
        let s = slotStorage
        slotStorage = nil
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
        return s
    }

    func clear() {
        lock.lock()
        slotStorage = nil
        lock.unlock()
    }
}
