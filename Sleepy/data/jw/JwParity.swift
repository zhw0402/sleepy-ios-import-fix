// JwParity.swift — ← JwParity.kt
//
// 单/双周 (parity) 共享工具 — JwZju/JwUstc/JwSeu/JwNeu/JwScu 五 parser 同型端点
// 修正的单一实现 (审计 2026-09-04: 三处复制且都只抬 start 不动 end, 端点相等
// 时产出倒挂区间 (7,6) 类, 下游 coerce 会把课挤到错误周)。
//
// Sleepy 语义: type 0=每周 1=单周(奇数周) 2=双周(偶数周)。

import Foundation

enum JwParity {

    /// 单/双周起点端点修正: 单周起点须奇数 / 双周起点须偶数。
    /// 修正后超出 endWeek (端点相等场景如 "6-6(单)" → 7,6) 时把 end 一并抬到
    /// start — 端点倒挂会把课挤到错误周, 让它落回首个合法周。
    ///
    /// - Parameters:
    ///   - startWeek: 原始起点周
    ///   - endWeek: 原始终点周
    ///   - parity: 0=每周(不修正) 1=单周 2=双周
    static func adjustedRange(_ startWeek: Int, _ endWeek: Int, parity: Int) -> (start: Int, end: Int) {
        if parity != 1 && parity != 2 { return (startWeek, endWeek) }
        let start: Int
        switch parity {
        case 1: start = startWeek % 2 == 0 ? startWeek + 1 : startWeek
        default: start = startWeek % 2 != 0 ? startWeek + 1 : startWeek
        }
        return (start, max(endWeek, start))
    }
}
