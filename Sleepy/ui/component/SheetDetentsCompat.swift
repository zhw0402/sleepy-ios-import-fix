// SheetDetentsCompat.swift — presentationDetents 的 iOS 15 兼容层
// 6s Plus 真机 = iOS 15.8.8;presentationDetents 是 iOS16+ API,iOS 15 上
// 硬错误(条件分支内)/静默无效(sheet 闭包上)。此 modifier:
//   iOS 16+ → 原样转发 presentationDetents(行为与原代码 1:1)
//   iOS 15  → 回退 .frame 固定高度(iOS15 无 partial detent,全高 sheet
//             内固定内容高度是官方前推荐做法,视觉接近原意图)
// Detent 枚举按原代码用到的三档建模(height/medium/large;多档取首档)

import SwiftUI

enum SheetDetent: Equatable {
    case height(CGFloat)
    case medium
    case large
}

struct SheetDetentsModifier: ViewModifier {
    let detents: [SheetDetent]

    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.presentationDetents(Self.resolve(detents))
        } else {
            // iOS 15 真·半屏:UISheetPresentationController 是 iOS 15.0 API
            // (SwiftUI presentationDetents 才是 16+)。旧回退 .frame 固定高会让
            // 全高 sheet 里飘一个内容框(全屏滑上+底部大片空白)。medium/large
            // 直接设 detents;height 档 iOS 15 无自定义 detent,保留 frame 方案。
            let h = Self.preferredHeight(detents)
            if let h = h {
                content.frame(height: h)
                    .background(IOS15DetentIntrospector(detents: [.large]))
            } else {
                content.background(IOS15DetentIntrospector(detents: detents))
            }
        }
    }

    @available(iOS 16.0, *)
    private static func resolve(_ detents: [SheetDetent]) -> Set<PresentationDetent> {
        var out = Set<PresentationDetent>()
        for d in detents {
            switch d {
            case .height(let h): out.insert(.height(h))
            case .medium: out.insert(.medium)
            case .large: out.insert(.large)
            }
        }
        return out
    }

    private static func preferredHeight(_ detents: [SheetDetent]) -> CGFloat? {
        for d in detents {
            switch d {
            case .height(let h): return h
            case .medium: return 400 // iOS15 无 medium 语义,取近似固定高
            case .large: return nil
            }
        }
        return nil
    }
}

extension View {
    /// 与 .presentationDetents([...]) 等价的 iOS15 兼容调用
    func sheetDetents(_ detents: [SheetDetent]) -> some View {
        modifier(SheetDetentsModifier(detents: detents))
    }
}

// iOS 15:后台 1×1 透明 VC introspect — 沿 parent 链上溯到带 sheetPresentationController
// 的宿主(即被 present 的 sheet 根 VC),把 detents 设成真半屏。parent 走完兜底
// presentingViewController 以防宿主层级被系统私有 VC 隔断。
private struct IOS15DetentIntrospector: UIViewControllerRepresentable {
    let detents: [SheetDetent]

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        vc.view.isUserInteractionEnabled = false
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        let wanted = Self.resolve(detents)
        let grabber = detents.contains(.medium)
        // 首次 update 可能早于 sheet present(presentationController 尚未挂上),
        // 有界重试兜底时序(每 100ms,最多 ~2s)。
        var attempts = 0
        func apply() {
            var node: UIViewController? = vc
            while let cur = node {
                if let sheet = cur.sheetPresentationController {
                    sheet.detents = wanted
                    sheet.prefersGrabberVisible = grabber
                    return
                }
                node = cur.parent ?? cur.presentingViewController
            }
            attempts += 1
            if attempts < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: apply) }
        }
        DispatchQueue.main.async(execute: apply)
    }

    // iOS 15 只有 medium/large 两档(自定义 detent 是 16+)
    private static func resolve(_ detents: [SheetDetent])
        -> [UISheetPresentationController.Detent] {
        detents.contains(.large) ? [.large()] : [.medium()]
    }
}

// presentationDragIndicator(.hidden) 的 iOS15 兼容(iOS15 无此 API 也无把手,无需动作)
struct HideDragIndicatorIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.presentationDragIndicator(.hidden)
        } else {
            content
        }
    }
}

// 多行文本输入兼容层:TextField(axis: .vertical) + lineLimit(range) 是 iOS16+ API。
// iOS 15 → TextEditor(原生多行);iOS 16+ → 原生 axis API。
// 视觉差异点:TextEditor 自带内边距,用 padding(-4) 补偿对齐;无 placeholder,
// 用 ZStack overlay 实现与 TextField 一致的占位行为。
struct MultilineFieldCompat: View {
    let placeholder: String
    @Binding var text: String
    let minLines: Int
    let maxLines: Int

    var body: some View {
        if #available(iOS 16.0, *) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(minLines...maxLines)
        } else {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundColor(Color(.placeholderText))
                        .padding(.top, 8)
                        .padding(.leading, 4)
                }
                TextEditor(text: $text)
                    .padding(-4) // 抵消 TextEditor 内建 inset,对齐 TextField 基线
            }
        }
    }
}
