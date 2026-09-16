// SystemDocumentPicker.swift — 直接用 UIKit 弹系统文件选择器
//
// 背景(2026-09-16 修复):
//   旧实现用 SwiftUI 的 .fileImporter, 挂在「从文件导入」上, 并且:
//     · allowedContentTypes 混入 .data 之类的类型, 选择器行为依赖 UTType 推断
//     · asCopy 语义不可控: 回调给的是 security-scoped URL, 需要 startAccessingSecurityScopedResource()
//       成功才行; 失败时代码静默继续读 → 任何文件都报「读取失败」
//     · ImportSheet 本身是 sheet, sheet 内再弹 fileImporter 在部分 iOS 版本上
//       会出现「点了没反应 / 回调丢失」
//
//   本实现改为 UIKit 直驱 UIDocumentPickerViewController:
//     · asCopy: true —— 系统先把文件复制进 App 沙箱(临时目录)再回调,
//       iCloud 未下载文件会被顺带下载, 且回调 URL 一定是本地可读的真实文件;
//     · 自己找 keyWindow 的顶层 VC 来 present, 不再受 SwiftUI sheet 嵌套影响;
//     · 回调三态(选中/取消/失败)明确, 不再出现「静默什么都没发生」。
//
//   放在 ui/ 下, 因为 project.yml 里 widget target 排除了 ui 目录(扩展里不能用 UIApplication)。

import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class SystemDocumentPicker: NSObject, UIDocumentPickerDelegate {

    enum Outcome {
        case picked(URL)
        case cancelled
        case failed(Error)
    }

    struct NoHostError: LocalizedError {
        var errorDescription: String? { "找不到可用的窗口来弹出文件选择器, 请退出重进 App 再试" }
    }

    /// 静态持有: UIDocumentPickerViewController.delegate 是 weak, 不持有会被立刻释放
    private static var retained: SystemDocumentPicker?
    private var completion: ((Outcome) -> Void)?

    /// 允许选择的类型。注意 .data(public.data) 是所有文件的父类型 —— 保留它,
    /// 否则「从文件导入」里很多真实课表文件(如 .csv/.ics 的某些 UTI 推断)会变灰不可选。
    private static var allowedTypes: [UTType] {
        [.json, .plainText, .text, .commaSeparatedText, .html, .spreadsheet, .data]
    }

    static func present(completion: @escaping (Outcome) -> Void) {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: allowedTypes, asCopy: true)
        let delegate = SystemDocumentPicker()
        delegate.completion = completion
        controller.delegate = delegate
        controller.allowsMultipleSelection = false
        controller.shouldShowFileExtensions = true
        retained = delegate

        guard let host = topViewController() else {
            retained = nil
            completion(.failed(NoHostError()))
            return
        }
        host.present(controller, animated: true)
    }

    private func finish(_ outcome: Outcome) {
        let callback = completion
        completion = nil
        SystemDocumentPicker.retained = nil
        callback?(outcome)
    }

    // MARK: - UIDocumentPickerDelegate

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return finish(.cancelled) }
        finish(.picked(url))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(.cancelled)
    }

    // MARK: - 宿主 VC

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
            ?? scenes.first?.windows.first
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        if let nav = controller as? UINavigationController {
            controller = nav.visibleViewController ?? nav
        }
        if let tab = controller as? UITabBarController {
            controller = tab.selectedViewController ?? tab
        }
        return controller
    }
}
