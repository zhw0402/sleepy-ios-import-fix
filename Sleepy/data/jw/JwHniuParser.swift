// JwHniuParser.swift — ← JwHniuParser.kt
//
// 湖南信息职业技术学院（HNIU）解析器 — T8。
//
// 协议：JwProtocol.TYPE_HNIU = "hniu"
// 上游 wakeup 的 Common.kt 保留 type 常量但无独立 parser（实际按老正方 Table1 结构解析）。
// T8 按 §2.5 清单实现 confidence 锚点：bordercolordark="#FFFFFF"。
//
// 解析委托给 JwOldZfParser（HNIU 教务页面为老正方 Table1 变体）。
// (Kotlin 类名 JwHniuparser 小写 p 是上游手误, Swift 侧按命名规范 JwHniuParser)

import Foundation

final class JwHniuParser: JwParser, JwParserConfidenceReporting {

    let source: String
    private let delegate: JwOldZfParser

    init(_ source: String) {
        self.source = source
        self.delegate = JwOldZfParser(source)
    }

    func generateCourseList() throws -> [JwCourse] {
        try delegate.generateCourseList()
    }

    /// T8 §2.5: 命中 bordercolordark="#FFFFFF" = 100（HNIU 页面专属表格样式锚点）
    var confidenceValue: Int {
        source.lowercased().contains("bordercolordark=\"#ffffff\"") ? 100 : 0
    }

    var matchedFeatureList: [String] {
        source.lowercased().contains("bordercolordark=\"#ffffff\"")
            ? ["bordercolordark=#FFFFFF"]
            : []
    }
}
