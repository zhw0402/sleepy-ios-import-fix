// PillNavigationBar.swift — ← ui/component/PillNavigationBar.kt
//
// v2.5 (2026-09-08): 悬浮形态按 Android v1.0.45 NavDockSpec / DockNavigationBar 逐行重写。
//   之前 iOS 悬浮错把「贴底 76pt barBody」整套几何复用了过去(高 76 / 角 28 / thumb 64×32),
//   表现出来就是又胖又方 + thumb 不盖满座位 → 用户报障「悬浮样式完全不对」。
//
//   现在分流两套独立几何(贴底 = DockedBar / 悬浮 = FloatingBar),与 Kotlin
//   if (dock) DockNavigationBar(...) else Box(...) 同构。
//
//   NavDockSpec(逐行对齐,1:1):
//     horizontalMargin = 16pt  bottomFloat = 12pt  capsuleHeight = 64pt
//     itemSeat = 56pt  itemGap = 4pt  innerPad = 8pt
//   形态常量(DockSpec / DockedSpec)集中放一处,改动单点。
//
//   DockedBar(贴底 76pt)保持 v2.4 既有实现:thumb 64×32 y=12 + 逐字符扫过变色。
//   FloatingBar(悬浮胶囊)按 Kotlin DockNavigationBar:定宽 totalWidth = itemSeat*count +
//   itemGap*(count-1) + innerPad*2、50% 圆角、Material.ultraThinMaterial + 0.86 tint、
//   shadow radius 12 y 4 black 0.2、thumb 56×52 y=6 完整罩住图标+文字、icon 24pt +
//   spacer 2pt + labelSmall 整座位单色 lerp(不分字符)、选中色 onSecondaryContainer。
//
// v2.6 (2026-09-08) 修高亮慢一拍:
//   旧版 DockedBar 用 PreferenceKey 异步测 pill center → 首次跳到某 tab 时该 center
//   可能还没上报,animateThumbToSelected() 拿到旧值/fallback → 下一 tap 才补 →
//   "高亮永远慢一次"。改为确定性几何:thumb 中心 = inset + slot*i + slot/2,
//   跟 Android PillNavBar.kt SpaceEvenly + positionInRoot 等价,不依赖异步测量。
//   PreferenceKey 仍保留,但只用于 label 字符扫过的左缘(不影响 thumb 位置)。
// v2.2 (2026-09-06): 贴底 thumb 由 .offset(y:0)+padding 改为 .offset(y:12),
//                    76 - (12+32) = 32pt 上下对称。
// v2.3 (2026-09-06): PreferenceKey 收 pill center + label left,bar 局部坐标。
// v2.4 (2026-09-06): 根层 .onPreferenceChange → thumb 弹簧跟随 selectedIndex 滑动。

import SwiftUI
import CoreText
import UIKit

// MARK: - 公开入口

struct PillNavigationBar: View {
    @Environment(\.localWakeUpColors) private var colors
    let items: [PillNavItemData]
    /// 底栏样式: .docked(贴底 默认) / .floating(悬浮玻璃胶囊) ← Android v1.0.45 b0f8280/351436d
    var dockStyle: DockStyle = .docked

    enum DockStyle { case docked, floating }

    var body: some View {
        // 形态分流:贴底 / 悬浮 各用独立几何(← Kotlin if (dock) DockNavigationBar() else Box())
        Group {
            switch dockStyle {
            case .docked:
                DockedBar(items: items, colors: colors)
            case .floating:
                FloatingBar(items: items, colors: colors)
            }
        }
    }
}

/// Tab 数据(← Android PillNavItemSpec {icon, label} — v1 兼容垫片)
struct PillNavItemData: Identifiable {
    let id: String
    let icon: String
    let label: String
    let selected: Bool
    let onClick: () -> Void
}

// MARK: - 几何规格常量(对应 Android NavDockSpec,逐行对齐)

// 悬浮胶囊尺寸(← Android NavDockSpec 1:1)
//   暴露 module-internal 是为了让 SleepyApp.floatingScrollBottomPadding 也能读到,
//   集中单点维护(不要把 64/12 散到 SleepyApp 里再写一遍)。
enum DockSpec {
    static let horizontalMargin: CGFloat = 16   // 左右距屏幕边缘
    static let bottomFloat: CGFloat = 12        // 胶囊底边悬于手势条上方的高度
    static let capsuleHeight: CGFloat = 64      // 胶囊本体高(icon+label 双行)
    static let itemSeat: CGFloat = 56           // 每 tab 座位宽(≥48pt 触摸目标)
    static let itemGap: CGFloat = 4             // 座位间距
    static let innerPad: CGFloat = 8            // 胶囊内边距

    // 悬浮 thumb:56×52pt y=6pt → 完整罩住图标+文字(座位内容高 ~40,上下各留 6pt 呼吸)
    static let thumbWidth: CGFloat = 56
    static let thumbHeight: CGFloat = 52
    static let thumbYOffset: CGFloat = 6
    static let iconSize: CGFloat = 24           // ← Android 24dp(贴底用 20dp)
    static let iconSpacer: CGFloat = 2          // 图标 → label 间距
    static let labelFontSize: CGFloat = 11      // labelSmall 默认 11pt
}

// 贴底几何(保持 v2.4 既有值,确保 docked 视觉不变)
private enum DockedSpec {
    static let barHeight: CGFloat = 76
    static let thumbWidth: CGFloat = 64
    static let thumbHeight: CGFloat = 32
    static let thumbYOffset: CGFloat = 12       // 顶栏 12pt + thumb 32pt + 底栏 32pt = 76pt 上下对称
    static let iconSize: CGFloat = 20
    static let labelFontSize: CGFloat = 11      // ← Android labelSmall = 11sp
    static let labelFontWeight: Font.Weight = .medium
    static let labelFontWeightSelected: Font.Weight = .semibold
    static let iconHalf: CGFloat = 10           // thumb 覆盖计算用
    static let innerInset: CGFloat = 6          // HStack 水平内边距(deterministicCenter fallback)
}

// MARK: - Docked (贴底) 76pt 通栏

private struct DockedBar: View {
    let items: [PillNavItemData]
    let colors: WakeUpColorScheme

    @State private var labelLeftsBar: [Int: CGFloat] = [:]
    @State private var charRectsCache: [Int: [CGRect]] = [:]
    @State private var barWidth: CGFloat = 0

    private var selectedIndex: Int { items.firstIndex(where: { $0.selected }) ?? 0 }

    var body: some View {
        let selected = selectedIndex
        ZStack(alignment: .topLeading) {
            // thumb 色块 — 64×32 y=12 → 上下对称(SleepyShapes.large 圆角)
            // ★ v2.7 强制绑定:thumb 位置 = centerForIndex(selectedIndex) 派生值,
            //   没有 @State 滞后,没有 onChange 闭包捕获。SwiftUI .animation(value:)
            //   自动在 selectedIndex 变化时滑移,旧值与新值之间没有"错帧"。
            RoundedRectangle(cornerRadius: SleepyShapes.large)
                .fill(colors.secondaryContainer)
                .frame(width: DockedSpec.thumbWidth, height: DockedSpec.thumbHeight)
                .offset(x: thumbX, y: DockedSpec.thumbYOffset)
                .animation(.spring(response: 0.18, dampingFraction: 1.0), value: thumbCenterX)

            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    dockedTabColumn(idx: idx, item: item, selected: selected)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: DockedSpec.barHeight)
            .padding(.horizontal, DockedSpec.innerInset)
            .coordinateSpace(name: "pillBar")
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { barWidth = g.size.width }
                        .onChange(of: g.size.width) { w in barWidth = w }
                }
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: DockedSpec.barHeight)
        .background(colors.surfaceContainer)
        // 收集 label 左缘(bar 局部)— 仅服务字符扫过变色,不再用于 thumb 位置
        .onPreferenceChange(PillGeomKey.self) { value in
            labelLeftsBar = value.labelLefts
        }
    }

    // ★ v2.6 确定性几何 — 不依赖异步测量,thumb 位置 = inset + slot*i + slot/2
    //   等价于 Android PillNavBar.kt SpaceEvenly + positionInRoot
    private var itemCount: Int { max(items.count, 1) }
    private var inset: CGFloat { DockedSpec.innerInset }
    private var usableWidth: CGFloat { max(barWidth - inset * 2, 0) }
    private var slotWidth: CGFloat { usableWidth / CGFloat(itemCount) }
    private func centerForIndex(_ i: Int) -> CGFloat {
        inset + slotWidth * CGFloat(i) + slotWidth / 2
    }

    // ★ v2.7 强制绑定:thumb 中心 = 选中项中心(派生值,非 @State)
    private var thumbCenterX: CGFloat { centerForIndex(selectedIndex) }
    private var thumbX: CGFloat { thumbCenterX - DockedSpec.thumbWidth / 2 }

    @ViewBuilder
    private func dockedTabColumn(idx: Int, item: PillNavItemData, selected: Int) -> some View {
        let isSel = idx == selected
        // ★ v2.6: 确定性几何,不用 PreferenceKey 异步测量
        let pillCenter = centerForIndex(idx)
        let labelLeft = labelLeftsBar[idx] ?? 0
        let pillHalf = DockedSpec.thumbWidth / 2
        let iconHalf = DockedSpec.iconHalf
        let thumbStart = thumbCenterX - pillHalf
        let thumbEnd = thumbCenterX + pillHalf
        let iconCov = intervalCoverage(
            thumbStart: thumbStart, thumbEnd: thumbEnd,
            bStart: pillCenter - iconHalf, bEnd: pillCenter + iconHalf)
        let rects = charRectsCache[idx]
        let labelCov = rects.map {
            sweepCoverage(rects: $0,
                          thumbStart: thumbStart,
                          thumbEnd: thumbEnd,
                          labelLeftEdge: labelLeft)
        } ?? (isSel ? 1.0 : 0.0)
        let t = max(0, min(1, labelCov))
        let labelColor = lerpColor(
            from: colors.onSurfaceVariant,
            to: colors.onSurface,
            fraction: Double(t))

        VStack(spacing: 4) {
            // 图标(确定性居中 — thumb 用 inset+slot*i,图标叠在 thumb 上自然居中)
            Color.clear
                .frame(width: DockedSpec.thumbWidth, height: DockedSpec.thumbHeight)
                .overlay(
                    Image(systemName: item.icon)
                        .font(.system(size: DockedSpec.iconSize))
                        .foregroundColor(lerpColor(
                            from: colors.onSurfaceVariant,
                            to: colors.onSurface,
                            fraction: Double(iconCov)))
                )
            // label(测字符矩形 + 左缘)
            Text(item.label)
                .font(.system(size: DockedSpec.labelFontSize,
                              weight: isSel ? DockedSpec.labelFontWeightSelected
                                            : DockedSpec.labelFontWeight))
                .foregroundColor(labelColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .allowsTightening(true)
                .background(
                    GeometryReader { g in
                        let frame = g.frame(in: .named("pillBar"))
                        Color.clear
                            .preference(
                                key: PillGeomKey.self,
                                value: PillGeomValue(
                                    labelLefts: [idx: frame.minX]))
                            .onAppear {
                                let rects = characterRects(text: item.label, in: g.size)
                                charRectsCache[idx] = rects
                            }
                            .onChange(of: item.label) { _ in
                                let rects = characterRects(text: item.label, in: g.size)
                                charRectsCache[idx] = rects
                            }
                    }
                )
        }
        .frame(maxWidth: .infinity)
        // ★ v1.0.49 原生化: tab 操作语义化为 Button — 外部 onClick 改 items[*].selected → 上层重渲染
        .contentShape(Rectangle())
        .overlay(
            Button(action: item.onClick) {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(SleepyButtonStyle())
            .accessibilityIdentifier("pill_\(item.id)")
            .accessibilityLabel(item.label)
            .accessibilityAddTraits(isSel ? .isSelected : [])
        )
    }
}

// MARK: - Floating (悬浮胶囊) 64pt 玻璃胶囊

/// iOS 26 floating tab bar 语义(← Android v1.0.45 ff66ddd/351436d/5209767/0d7d4f6):
///   - 64pt 玻璃胶囊 + 16pt 水平边距 + 12pt 底部悬于手势条
///   - 总宽定值 itemSeat*count + itemGap*(count-1) + innerPad*2(居中,非全宽)
///   - 选中色块 56×52pt y=6pt → 完整罩住图标+文字
///   - 图标 24pt + spacer 2pt + labelSmall 整座位单色 lerp(不分字符)
///   - 选中色 = onSecondaryContainer(背景 secondaryContainer)
///   - shadow radius 12 y 4 black 0.2 + Material.ultraThinMaterial + 0.86 tint
private struct FloatingBar: View {
    let items: [PillNavItemData]
    let colors: WakeUpColorScheme

    private var count: Int { max(items.count, 1) }
    private var seatTotal: CGFloat { DockSpec.itemSeat + DockSpec.itemGap }
    /// 总宽 = 座位宽 × 个数 + 间距 × (n-1) + 内边距 × 2
    private var totalWidth: CGFloat {
        DockSpec.itemSeat * CGFloat(count) +
        DockSpec.itemGap * CGFloat(max(count - 1, 0)) +
        DockSpec.innerPad * 2
    }
    /// 座位中心(capsule 局部坐标) — 同步 Kotlin DockNavigationBar centers 算法
    private var seatCenters: [CGFloat] {
        (0..<count).map { i in
            DockSpec.innerPad + DockSpec.itemSeat / 2 + seatTotal * CGFloat(i)
        }
    }

    private var selectedIndex: Int { items.firstIndex(where: { $0.selected }) ?? 0 }

    // ★ v2.7 强制绑定:thumb 中心直接由当前选中项座位派生,不保存独立位置 state。
    //   .animation(value:) 在 selectedIndex 变化时自动滑移,无 @State 滞后帧。
    private var thumbCenterX: CGFloat {
        guard selectedIndex >= 0, selectedIndex < seatCenters.count else { return 0 }
        return seatCenters[selectedIndex]
    }
    private var thumbX: CGFloat { thumbCenterX - DockSpec.thumbWidth / 2 }

    var body: some View {
        let selected = selectedIndex
        let cornerRadius = DockSpec.capsuleHeight / 2   // 50% 圆角 = 完全胶囊

        // 外层 HStack 用 Spacer 撑出 16pt 左右边距,capsule 居中
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack(alignment: .topLeading) {
                // 选中色块 — 56×52pt y=6pt → 完整罩住图标+label
                RoundedRectangle(cornerRadius: DockSpec.thumbHeight / 2)
                    .fill(colors.secondaryContainer)
                    .frame(width: DockSpec.thumbWidth, height: DockSpec.thumbHeight)
                    .offset(x: thumbX, y: DockSpec.thumbYOffset)
                    .animation(.spring(response: 0.18, dampingFraction: 1.0), value: thumbCenterX)

                // 4 个 tab HStack:itemGap=4 居中分布,内边距 innerPad=8
                HStack(spacing: DockSpec.itemGap) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        floatingTabColumn(idx: idx, item: item, selected: selected)
                    }
                }
                .padding(.horizontal, DockSpec.innerPad)
                .frame(width: totalWidth, height: DockSpec.capsuleHeight)
            }
            .frame(width: totalWidth, height: DockSpec.capsuleHeight)
            // 表面色 0.86 — 与 Android DockNavigationBar glassBg = surfaceContainer.copy(alpha=0.86f) 1:1。
            // 不加 .ultraThinMaterial: Android 是纯平面色(无高斯模糊),双层 tint 会发白发灰。
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(colors.surfaceContainer.opacity(0.86))
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            // shadow elevation 12dp(Compose) ≈ SwiftUI radius 12 y 4 black 0.2
            .shadow(color: Color.black.opacity(0.2), radius: 12, y: 4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DockSpec.horizontalMargin)
        .padding(.bottom, DockSpec.bottomFloat)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func floatingTabColumn(idx: Int, item: PillNavItemData, selected: Int) -> some View {
        let isSel = idx == selected
        let seatHalf = DockSpec.itemSeat / 2
        let iconHalf: CGFloat = 12
        let tc = thumbCenterX
        // 单色 lerp:icon + label 共用 iconCov(不分字符扫过,贴底才分字符)
        let iconCov = intervalCoverage(
            thumbStart: tc - seatHalf, thumbEnd: tc + seatHalf,
            bStart: seatCenters[idx] - iconHalf, bEnd: seatCenters[idx] + iconHalf)
        let color = lerpColor(
            from: colors.onSurfaceVariant,
            to: colors.onSecondaryContainer,
            fraction: Double(iconCov))

        VStack(spacing: DockSpec.iconSpacer) {
            Image(systemName: item.icon)
                .font(.system(size: DockSpec.iconSize))
                .foregroundColor(color)
            Text(item.label)
                .font(.system(size: DockSpec.labelFontSize, weight: .medium))
                .foregroundColor(color)
                .lineLimit(1)
        }
        .frame(width: DockSpec.itemSeat, height: DockSpec.capsuleHeight)
        // ★ v1.0.49 原生化: tab 操作语义化为 Button
        .contentShape(Rectangle())
        .overlay(
            Button(action: item.onClick) {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(SleepyButtonStyle())
            .accessibilityIdentifier("pill_\(item.id)")
            .accessibilityLabel(item.label)
            .accessibilityAddTraits(isSel ? .isSelected : [])
        )
    }
}

// MARK: - 几何收集(贴底专用,悬浮用 seatCenters 直接推算)

private struct PillGeomValue: Equatable {
    var labelLefts: [Int: CGFloat]
}

private struct PillGeomKey: PreferenceKey {
    static var defaultValue: PillGeomValue = .init(labelLefts: [:])
    static func reduce(value: inout PillGeomValue, nextValue: () -> PillGeomValue) {
        let v = nextValue()
        for (k, val) in v.labelLefts { value.labelLefts[k] = val }
    }
}

// ── 几何辅助函数 ──

private func intervalCoverage(thumbStart: CGFloat, thumbEnd: CGFloat,
                               bStart: CGFloat, bEnd: CGFloat) -> CGFloat {
    let w = bEnd - bStart
    if w <= 0 { return 0 }
    let overlap = min(thumbEnd, bEnd) - max(thumbStart, bStart)
    return max(0, min(overlap, w)) / w
}

private func sweepCoverage(rects: [CGRect], thumbStart: CGFloat, thumbEnd: CGFloat,
                           labelLeftEdge: CGFloat) -> CGFloat {
    if rects.isEmpty { return 0 }
    var sum: CGFloat = 0
    var total: CGFloat = 0
    for r in rects {
        let w = r.width
        if w <= 0 { continue }
        let l = r.minX + labelLeftEdge
        let e = r.maxX + labelLeftEdge
        let overlap = max(0, min(thumbEnd, e) - max(thumbStart, l))
        sum += min(overlap, w)
        total += w
    }
    if total <= 0 { return 0 }
    return min(1, max(0, sum / total))
}

private func characterRects(text: String, in size: CGSize) -> [CGRect] {
    guard !text.isEmpty, size.width > 0 else { return [] }
    let font = UIFont.systemFont(ofSize: 11, weight: .semibold)
    let attr = NSAttributedString(string: text, attributes: [.font: font])
    let framesetter = CTFramesetterCreateWithAttributedString(attr)
    let path = CGPath(rect: CGRect(origin: .zero,
                                  size: CGSize(width: max(size.width, 1), height: max(size.height, 1))),
                      transform: nil)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attr.length), path, nil)
    guard let lines = CTFrameGetLines(frame) as? [CTLine], let line = lines.first else { return [] }
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    let xOffset = (size.width - lineWidth) / 2
    var rects: [CGRect] = []
    let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
    var xCursor: CGFloat = 0
    for run in runs {
        let glyphCount = CTRunGetGlyphCount(run)
        var advances = [CGSize](repeating: .zero, count: glyphCount)
        CTRunGetAdvances(run, CFRange(location: 0, length: glyphCount), &advances)
        for g in 0..<glyphCount {
            let w = advances[g].width
            if w > 0 {
                rects.append(CGRect(x: xOffset + xCursor, y: 0, width: w, height: size.height))
            }
            xCursor += w
        }
    }
    return rects
}

private func lerpColor(from: Color, to: Color, fraction: Double) -> Color {
    let a = UIColor(from).cgColor
    let b = UIColor(to).cgColor
    let aComps = a.components ?? [0, 0, 0, 1]
    let bComps = b.components ?? [0, 0, 0, 1]
    let aN = max(a.numberOfComponents, 1)
    let bN = max(b.numberOfComponents, 1)
    let ar = aN >= 3 ? aComps[0] : 0
    let ag = aN >= 3 ? aComps[1] : 0
    let ab = aN >= 3 ? aComps[2] : 0
    let aa = aN >= 4 ? aComps[3] : 1
    let br = bN >= 3 ? bComps[0] : 0
    let bg = bN >= 3 ? bComps[1] : 0
    let bb = bN >= 3 ? bComps[2] : 0
    let ba = bN >= 4 ? bComps[3] : 1
    let mixR = ar + (br - ar) * CGFloat(fraction)
    let mixG = ag + (bg - ag) * CGFloat(fraction)
    let mixB = ab + (bb - ab) * CGFloat(fraction)
    let mixA = aa + (ba - aa) * CGFloat(fraction)
    return Color(red: Double(mixR), green: Double(mixG), blue: Double(mixB), opacity: Double(mixA))
}