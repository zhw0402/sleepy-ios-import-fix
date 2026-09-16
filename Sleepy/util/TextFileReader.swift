// TextFileReader.swift — 课表文件导入的读取层(编码探测 + 二进制识别 + 可读报错)
//
// 背景(2026-09-16 修复):
//   旧实现散落在 ImportSheet.swift 的 .fileImporter 回调里, 只有一行
//       let text = try String(contentsOf: url, encoding: .utf8)
//   三种真实场景必然失败:
//     ① 中国教务系统导出的 CSV/ICS, 或 Excel「另存为 CSV」, 绝大多数是 GBK/GB18030
//        → UTF-8 严格解码抛错, 用户只看到一句「读取失败: ...」
//     ② 文件在 iCloud 云盘且本地未下载(占位文件) → 直接读 URL 抛 NSFileReadNoSuchFile
//     ③ xlsx/docx/pdf 是二进制, 当文本读必然失败, 且报错内容对用户毫无指导意义
//
//   本文件把「取字节」和「认编码」两件事分别做稳:
//     取字节: NSFileCoordinator 协调读取(iCloud 占位文件会被强制下载) + Data(contentsOf:) 兜底
//     认编码: 魔数判别(先排除二进制) → BOM → UTF-8 → UTF-16 → GB18030/GBK/Big5 → Latin-1 兜底
//
//   只依赖 Foundation/CoreFoundation, 因此 app target 与 widget target 都能编(见 project.yml)。

import Foundation
import CoreFoundation

enum TextFileReader {

    // MARK: - 错误

    enum ReadError: LocalizedError {
        case empty(String)
        case binaryOffice(String)
        case binaryPDF(String)
        case undecodable(String, Int, String)

        var errorDescription: String? {
            switch self {
            case .empty(let name):
                return "\(name) 是空文件, 没有任何内容可解析"
            case .binaryOffice(let name):
                return "\(name) 是 Excel/Office 压缩格式(xlsx/docx/pptx 等二进制文件), iOS 版暂不支持;" +
                       "请在 Excel/WPS 里「另存为 CSV(逗号分隔)」后再从文件导入"
            case .binaryPDF(let name):
                return "\(name) 是 PDF 文件, 不是课表文本"
            case .undecodable(let name, let bytes, let header):
                return "\(name) 无法识别文本编码(共 \(bytes) 字节, 文件头 \(header));" +
                       "请另存为 UTF-8 或 GBK 编码的 CSV / ICS / JSON 后重试"
            }
        }
    }

    // MARK: - 对外入口

    /// 读取文件为字符串。抛出的 ReadError.errorDescription 已是可直接给用户看的中文。
    static func read(url: URL) throws -> String {
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        let data = try readData(url: url)
        guard !data.isEmpty else { throw ReadError.empty(name) }
        return try decode(data, fileName: name)
    }

    /// 纯解码: 便于外部(如 Inbox 拷贝、剪贴板以外的字节)复用与单测。
    static func decode(_ data: Data, fileName name: String = "文件") throws -> String {
        guard !data.isEmpty else { throw ReadError.empty(name) }

        // ① 二进制魔数先行剔除 —— 给出可执行的建议, 而不是「乱码/失败」
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) ||   // PK..  zip 家族
           data.starts(with: [0x50, 0x4B, 0x05, 0x06]) ||   // 空 zip
           data.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) {    // OLE2  .xls/.doc 旧版
            throw ReadError.binaryOffice(name)
        }
        if data.starts(with: Array("%PDF".utf8)) {
            throw ReadError.binaryPDF(name)
        }

        // ② BOM 显式声明
        if data.starts(with: [0xEF, 0xBB, 0xBF]),                       // UTF-8 BOM
           let s = String(data: data.dropFirst(3), encoding: .utf8) {
            return s
        }
        if data.starts(with: [0xFF, 0xFE]),                             // UTF-16 LE
           let s = String(data: data, encoding: .utf16LittleEndian) {
            return s
        }
        if data.starts(with: [0xFE, 0xFF]),                             // UTF-16 BE
           let s = String(data: data, encoding: .utf16BigEndian) {
            return s
        }

        // ③ UTF-8(严格) — 现代导出/唤醒 JSON/分享文本都走这里
        if let s = String(data: data, encoding: .utf8) { return s }

        // ④ 无 BOM UTF-16(Excel 另存「Unicode 文本」常见): 头部有大量 0x00 即判
        if looksLikeUTF16(data), let s = String(data: data, encoding: .utf16) { return s }

        // ⑤ 中文老编码: GB18030 ⊃ GBK ⊃ GB2312, 教务系统 CSV/ICS 的主力
        for cfEnc in [CFStringEncodings.GB_18030_2000,
                      CFStringEncodings.GB_2312_80,
                      CFStringEncodings.big5] {
            let enc = nsEncoding(cfEnc)
            if let s = String(data: data, encoding: enc) { return s }
        }

        // ⑥ 兜底: Latin-1 永不失败, 至少让解析器拿到内容而不是报错
        if let s = String(data: data, encoding: .isoLatin1) { return s }

        throw ReadError.undecodable(name, data.count, headerHex(data))
    }

    // MARK: - 取字节

    /// 协调读取: iCloud 占位文件(未下载)在 NSFileCoordinator 下会被拉取完成,
    /// 直接 Data(contentsOf:) 对占位文件常抛「文件不存在」。
    private static func readData(url: URL) throws -> Data {
        var coordinated: Data?
        var innerError: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            do { coordinated = try Data(contentsOf: readURL) } catch { innerError = error }
        }
        if let d = coordinated { return d }
        if let e = innerError { throw e }
        if let e = coordError { throw e }
        // 某些沙箱内 URL(如 Documents/Inbox 拷贝)协调器不回调 → 直接读兜底
        return try Data(contentsOf: url)
    }

    // MARK: - 工具

    private static func nsEncoding(_ enc: CFStringEncoding) -> String.Encoding {
        String.Encoding(rawValue: UInt(CFStringConvertEncodingToNSStringEncoding(enc)))
    }

    private static func looksLikeUTF16(_ data: Data) -> Bool {
        let probe = data.prefix(64)
        guard probe.count >= 8 else { return false }
        var zeros = 0
        for (i, byte) in probe.enumerated() where byte == 0x00 && i % 2 == 1 { zeros += 1 }
        return zeros >= probe.count / 4
    }

    private static func headerHex(_ data: Data) -> String {
        data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
