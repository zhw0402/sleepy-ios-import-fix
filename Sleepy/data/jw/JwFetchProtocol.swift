// JwFetchProtocol.swift — ← JwFetchProtocol.kt
//
// T11: WebView 内 fetch JS 选择表(纯函数)。
//
// pick 返回 nil = 走原有 outerHTML 路径(默认)。
// 决策依据: 学校 type 显式声明 > URL 路径指纹(含 WebVPN 重写形态) > enableFetch 开关。

import Foundation

enum FetchKind: Equatable {
    case wisedu
    case zfNew
    case qz
    case qzIeas
}

enum JwFetchProtocol {

    /// 学校 type + 当前 URL → fetch 类型; nil = 走 outerHTML 抓取
    static func pick(_ school: JwSchoolInfo, _ currentUrl: String?) -> FetchKind? {
        let u = (currentUrl ?? school.url).lowercased()
        // ① 显式 type 优先
        switch school.type ?? "" {
        case JwProtocol.TYPE_WISEDU:
            if u.contains("/jwapp/") { return .wisedu }
        case JwProtocol.TYPE_ZF_NEW:
            if u.contains("/jwglxt/") || contains(WEBVPN_HTTP_HEX, u) { return .zfNew }
        case JwProtocol.TYPE_QZ_IEAS:
            return .qzIeas
        case JwProtocol.TYPE_QZ, JwProtocol.TYPE_QZ_BR, JwProtocol.TYPE_QZ_WITH_NODE,
             JwProtocol.TYPE_QZ_OLD, JwProtocol.TYPE_QZ_CRAZY:
            // 默认策略: QZ 不强推 fetch, 仅 enableFetch=true 的学校走
            if school.enableFetch && u.contains("/jsxsd/") { return .qz }
            return nil
        default:
            break
        }
        // ② type 未命中但 URL 路径指纹命中
        if u.contains("/jwapp/") { return .wisedu }
        if u.contains("/ieas2.1/") || u.contains("jwxt.buaa.edu.cn") { return .qzIeas }
        if u.contains("/jwglxt/") || contains(WEBVPN_HTTP_HEX, u) { return .zfNew }
        if school.enableFetch && u.contains("/jsxsd/") { return .qz }
        return nil
    }

    private static func contains(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static let WEBVPN_HTTP_HEX = try! NSRegularExpression(pattern: #"/http/[0-9a-f]{4,8}/"#)

    /// 协议段(不带前导斜杠): jwapp / jwglxt / jsxsd
    static func pathSegment(_ kind: FetchKind) -> String {
        switch kind {
        case .wisedu: return "jwapp"
        case .zfNew: return "jwglxt"
        case .qz: return "jsxsd"
        case .qzIeas: return "ieas2.1"
        }
    }

    /// 从 URL 抓 gnmkdm 参数; 无则返回 default
    static func extractGnmkdm(_ url: String, _ defaultValue: String) -> String {
        guard let m = url.range(of: #"gnmkdm=([A-Za-z0-9]+)"#, options: .regularExpression) else {
            return defaultValue
        }
        let full = String(url[m])
        return String(full.dropFirst("gnmkdm=".count))
    }

    /// 去 WebVPN 前缀: /http/<hex>/ 与 /webvpn/<host>/ 两种; 无前缀原样返回
    static func stripWebvpnPrefix(_ pathname: String) -> String {
        if let m = pathname.range(of: #"^/http/[0-9a-f]{4,8}"#, options: .regularExpression) {
            return String(pathname[m.upperBound...])
        }
        if let m = pathname.range(of: #"^/webvpn/[^/]+"#, options: .regularExpression) {
            return String(pathname[m.upperBound...])
        }
        return pathname
    }
}
