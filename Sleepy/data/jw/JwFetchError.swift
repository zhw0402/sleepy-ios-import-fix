// JwFetchError.swift — ← JwFetchError.kt
//
// T11: WebView 内 fetch 模式的错误分类与桥协议。
//
// ZF_NEW_FETCH_JS 与 QZ_FETCH_JS 把错误分成四类
// (会话过期 / 解析失败 / 网络异常 / 学期无课)，而不是笼统 ok:false。
// Kotlin sealed class 穷尽 → Swift enum + switch 穷尽等价。

import Foundation

/// 后端返回 HTML 登录页 / 302 CAS / JSON.parse 抛异常 —— 文案:重新登录
enum FetchErrorKind: Equatable {
    /// 后端返回 HTML 登录页 / 302 CAS / JSON.parse 抛异常 —— 文案:重新登录
    case sessionExpired
    /// 拿到数据但 Jw*Parser 报 0 课 + 后端不是登录页 —— 文案:可能未到课表页
    case parseFailed
    /// fetch reject / HTTP 4xx/5xx / TypeError —— 文案:网络异常
    case network
    /// 拿到数据且 parser 出 0 门但响应里明确说"本学期无课" —— 文案:切换学期
    case empty
}

struct FetchError: Equatable {
    let kind: FetchErrorKind
    let message: String
    var schoolType: String? = nil
    var url: String? = nil

    /// ← userMessage(ctx): L10n.t 四类文案键
    var userMessage: String {
        switch kind {
        case .sessionExpired: return L10n.t("jw_fetch_session_expired")
        case .parseFailed: return L10n.t("jw_fetch_parse_failed")
        case .network: return L10n.t("jw_fetch_network")
        case .empty: return L10n.t("jw_fetch_empty")
        }
    }
}

enum JwFetchError {
    private static let KEY_KIND = "kind"
    private static let KEY_MSG = "msg"
    private static let KEY_TYPE = "type"
    private static let KEY_URL = "url"

    static func toJson(_ err: FetchError) -> String {
        let kindStr: String
        switch err.kind {
        case .sessionExpired: kindStr = "SESSION_EXPIRED"
        case .parseFailed: kindStr = "PARSE_FAILED"
        case .network: kindStr = "NETWORK"
        case .empty: kindStr = "EMPTY"
        }
        let obj: [String: Any] = [
            KEY_KIND: kindStr,
            KEY_MSG: err.message,
            KEY_TYPE: err.schoolType ?? NSNull(),
            KEY_URL: err.url ?? NSNull(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func fromJson(_ s: String) -> FetchError? {
        guard let data = s.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let kind: FetchErrorKind
        switch obj[KEY_KIND] as? String ?? "" {
        case "SESSION_EXPIRED": kind = .sessionExpired
        case "PARSE_FAILED": kind = .parseFailed
        case "NETWORK": kind = .network
        case "EMPTY": kind = .empty
        default: return nil
        }
        func nonBlank(_ v: Any?) -> String? {
            guard let str = v as? String else { return nil }
            return str.trimmingCharacters(in: .whitespaces).isEmpty ? nil : str
        }
        return FetchError(
            kind: kind,
            message: obj[KEY_MSG] as? String ?? "",
            schoolType: nonBlank(obj[KEY_TYPE]),
            url: nonBlank(obj[KEY_URL])
        )
    }
}
