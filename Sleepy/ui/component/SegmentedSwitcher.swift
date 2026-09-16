// SegmentedSwitcher.swift — ← ui/component/SegmentedSwitcher.kt
// 单选分段按钮 — 主视图模式切换(整周/卡片)。
//
// 2026-09-10 原生化审计重写:旧版为复刻 Android M3 thumb「逐字符扫过变色」,
// 用 CoreText 逐字形测量 + 每字符矩形∩thumb 覆盖率 lerp(~230 行),
// 且 minimumScaleFactor 缩字时字符矩形与渲染字号失准。属边际效用递减,删除。
// iOS 原生即 SwiftUI 弹簧动画驱动 thumb 滑动(同一弹簧参数 response 0.18 /
// damping 1.0),标签整词翻色。视觉规格不变:
//   容器 surface-container 42pt 圆角14 / thumb secondaryContainer 32pt 圆角12
//   / 选中字重 semibold。确定性几何(PillNavigationBar v2.6 同课:不做异步
//   测量, thumb 位置 = inset + slot*i, 首帧即位,无 PreferenceKey/字符测量态)。

import SwiftUI

struct SegmentedSwitcher<T: Hashable>: View {
    @Environment(\.localWakeUpColors) private var colors
    let options: [(T, String)]
    let selected: T
    let onSelect: (T) -> Void

    private var selectedIndex: Int {
        max(options.firstIndex(where: { $0.0 == selected }) ?? 0, 0)
    }

    var body: some View {
        GeometryReader { geo in
            segmentedBody(containerWidth: geo.size.width)
        }
        .frame(height: 42)
    }

    private func segmentedBody(containerWidth: CGFloat) -> some View {
        let trackW = max(containerWidth - 8, 0)
        let segW = trackW / CGFloat(max(options.count, 1))

        return ZStack(alignment: .topLeading) {
            // 层0: thumb — 弹簧滑到选中段(确定性几何,无状态)
            RoundedRectangle(cornerRadius: 12)
                .fill(colors.secondaryContainer)
                .frame(width: segW, height: 34)
                .offset(x: 4 + CGFloat(selectedIndex) * segW, y: 4)
                .animation(.spring(response: 0.18, dampingFraction: 1.0), value: selectedIndex)

            // 层1: 点击段 + 整词单色标签
            HStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.offset) { idx, pair in
                    let isSel = idx == selectedIndex
                    Button {
                        onSelect(pair.0)
                    } label: {
                        Text(pair.1)
                            .font(.system(size: 14, weight: isSel ? .semibold : .medium))
                            .foregroundColor(isSel ? colors.onSecondaryContainer : colors.onSurfaceVariant)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .allowsTightening(true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(SleepyButtonStyle())
                    .accessibilityIdentifier("seg_\(pair.1)")
                    .accessibilityLabel(pair.1)
                    .accessibilityAddTraits(isSel ? .isSelected : [])
                }
            }
            .frame(height: 42)
        }
        .padding(4)
        .frame(width: containerWidth, height: 42)
        .background(colors.surfaceContainer)
        .cornerRadius(14)
    }
}
