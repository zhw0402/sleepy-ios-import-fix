import Foundation

/**
 * 更新日志 Markdown 解析 — 纯 Swift, 无 UIKit/SwiftUI 依赖, 可 XCTest 单测。
 *
 * Android MarkdownBlocks.kt 1:1 移植: 取代第三方 MarkdownText 黑盒,
 * 上一版用 compose-markdown(Markwon)渲染真机标题/列表/粗体与普通正文无视觉差异
 * 且行为不可控。解析出确定性的块结构 + 行内结构, 由 UpdateChangelogDialog
 * 显式排版 — 每种块的实际视觉结果由本仓库代码决定, 不依赖第三方隐式行为。
 *
 * 覆盖 release notes 实际用到的语法: # 标题、- 列表、**粗体**、`代码`、
 * [文字](链接)、普通段落。其余 Markdown 语法按普通文本原样显示(安全兜底)。
 */

public enum MarkdownBlock {
    /// ATX 标题, level 1-6
    public struct Heading: Equatable {
        public let level: Int
        public let text: String
    }
    /// 连续列表项合为一组
    public struct Bullet: Equatable {
        public let items: [String]
    }
    /// 普通段落(可能多行, 已合并为单串)
    public struct Paragraph: Equatable {
        public let text: String
    }
}

public enum MarkdownInline {
    public struct Text: Equatable { public let text: String }
    public struct Bold: Equatable { public let text: String }
    public struct Code: Equatable { public let text: String }
    public struct Link: Equatable { public let text: String; public let url: String }
}

public enum MarkdownBlocksLegacy {

    public static func parse(_ markdown: String) -> [Any] {
        var blocks: [Any] = []
        var listItems: [String] = []
        var paragraphLines: [String] = []

        func flushList() {
            guard !listItems.isEmpty else { return }
            blocks.append(MarkdownBlock.Bullet(items: listItems))
            listItems = []
        }
        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(MarkdownBlock.Paragraph(text: paragraphLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)))
            paragraphLines = []
        }
        func flushAll() { flushList(); flushParagraph() }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: ""))
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                flushAll()
                continue
            }
            // ATX 标题: #..###### + 空格 + 内容
            if let m = headingRegex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) {
                flushAll()
                let levelRange = m.range(at: 1)
                let textRange = m.range(at: 2)
                let level = (t as NSString).substring(with: levelRange).count
                let text = (t as NSString).substring(with: textRange)
                    .trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock.Heading(level: level, text: text))
                continue
            }
            // 列表项: - / * / + + 空格
            if let m = bulletRegex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) {
                flushParagraph()
                let itemRange = m.range(at: 1)
                var item = (t as NSString).substring(with: itemRange)
                // 拍平嵌套缩进: 去掉可能的前缀符号
                for prefix in ["-", "*", "+"] {
                    if item.hasPrefix("\(prefix) ") {
                        item = String(item.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
                listItems.append(item)
                continue
            }
            // 兜底: 段落行
            flushList()
            paragraphLines.append(t)
        }
        flushAll()
        return blocks
    }

    /** 行内解析: **粗体**、`代码`、[文字](链接) → 有序 span 列表 */
    public static func parseInline(_ text: String) -> [any Equatable] {
        var spans: [any Equatable] = []
        let patterns: [NSRegularExpression] = [boldRegex, codeRegex, linkRegex]
        var i = text.startIndex
        while i < text.endIndex {
            var bestMatch: NSTextCheckingResult?
            var bestKind = -1
            var bestRange: Range<String.Index>?
            for (kind, p) in patterns.enumerated() {
                let nsRange = NSRange(i..<text.endIndex, in: text)
                guard let m = p.firstMatch(in: text, range: nsRange) else { continue }
                let range = Range(m.range, in: text)!
                if bestMatch == nil || range.lowerBound < bestRange!.lowerBound {
                    bestMatch = m
                    bestKind = kind
                    bestRange = range
                }
            }
            guard let bm = bestMatch, let br = bestRange else {
                spans.append(MarkdownInline.Text(text: String(text[i..<text.endIndex])))
                break
            }
            if br.lowerBound > i {
                spans.append(MarkdownInline.Text(text: String(text[i..<br.lowerBound])))
            }
            switch bestKind {
            case 0:
                let groupRange = Range(bm.range(at: 1), in: text)!
                spans.append(MarkdownInline.Bold(text: String(text[groupRange])))
            case 1:
                let groupRange = Range(bm.range(at: 1), in: text)!
                spans.append(MarkdownInline.Code(text: String(text[groupRange])))
            default:
                let textRange = Range(bm.range(at: 1), in: text)!
                let urlRange = Range(bm.range(at: 2), in: text)!
                spans.append(MarkdownInline.Link(
                    text: String(text[textRange]),
                    url: String(text[urlRange])
                ))
            }
            i = br.upperBound
        }
        return spans.filter { span in
            if let t = span as? MarkdownInline.Text { return !t.text.isEmpty }
            return true
        }
    }

    // MARK: - 内部正则

    private static let headingRegex: NSRegularExpression = {
        return try! NSRegularExpression(pattern: "^(#{1,6})\\s+(.*)$")
    }()
    private static let bulletRegex: NSRegularExpression = {
        return try! NSRegularExpression(pattern: "^[-*+]\\s+(.*)$")
    }()
    private static let boldRegex: NSRegularExpression = {
        return try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
    }()
    private static let codeRegex: NSRegularExpression = {
        return try! NSRegularExpression(pattern: "`([^`]+)`")
    }()
    private static let linkRegex: NSRegularExpression = {
        return try! NSRegularExpression(pattern: "\\[([^\\]]+)]\\(([^)]+)\\)")
    }()
}
