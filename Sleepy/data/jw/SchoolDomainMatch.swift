// SchoolDomainMatch.swift — ← SchoolDomainMatch.kt
//
// issue #25 — 把 typed URL 映射回 schools.json 目录条目。
//
// 失败链:
//   1. 用户输入 https://one.hfut.edu.cn/ (HFUT 统一信息门户, 非教务)
//   2. SchoolSelectScreen.UrlDirectRow 命中 → 创建自定义条目 type=nil
//   3. WebView 跳到门户 → 通用抓取 → 0 课
//
// 修复:
//   解析 typed URL 的 host, 取注册域, 在目录条目中查找相同注册域的 supported+有 URL 条目。
//   命中后用目录条目替代自定义条目 (拿到权威 URL + 协议 type)。
//
// 命名: 与 JwWebViewLoginScreen 的 SslBypassRegistry 一致, 委托同一 registrableDomain 实现
// (避免两个独立实现飘移)。

import Foundation

enum SchoolDomainMatch {

    /// 注册域启发式 — 与 SslBypassRegistry.registrableDomain 一致。
    /// 取末两段 (edu.cn / edu.hk / ac.uk / edu.tw / edu.jp 等多段后缀取末三段)。
    static func registrableDomain(_ host: String) -> String {
        let h = host.lowercased().trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if h.isEmpty { return "" }
        let parts = h.split(separator: ".").map(String.init)
        if parts.count <= 2 { return h }
        let secondLevel = parts[parts.count - 2]
        let tld = parts.last ?? ""
        if (tld == "cn" || tld == "hk" || tld == "uk" || tld == "tw" || tld == "jp"),
           ["edu", "ac", "gov", "org"].contains(secondLevel) {
            return parts.suffix(3).joined(separator: ".")
        }
        return parts.suffix(2).joined(separator: ".")
    }

    /// 抽 host: 处理 https?:// 前缀、尾部 /path、空白。空返回空串。
    static func hostOf(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespaces)
        if u.isEmpty { return "" }
        let schemeEnd: String.Index
        if let r = u.range(of: "://") {
            schemeEnd = r.upperBound
        } else {
            schemeEnd = u.startIndex
        }
        let rest = String(u[schemeEnd...])
        let hostAndPort: String
        if let slash = rest.firstIndex(of: "/") {
            hostAndPort = String(rest[..<slash])
        } else {
            hostAndPort = rest
        }
        if let colon = hostAndPort.firstIndex(of: ":") {
            return String(hostAndPort[..<colon])
        }
        return hostAndPort
    }

    /// 是否 WebVPN 重写 host (不可见原 host, 不可参与目录映射)。
    static func isVpnRewrite(_ host: String) -> Bool {
        if host.isEmpty { return false }
        return host.contains("/webvpn/")
            || host.contains(".webvpn.")
            || host.hasPrefix("webvpn.")
    }

    /// 在 catalog 中查找: 同注册域, supported (含 grad_supported), 有 URL。
    /// WebVPN / 未知域 / 空白 host → nil。
    static func matchSchool(_ url: String, _ catalog: [JwSchoolInfo]) -> JwSchoolInfo? {
        let host = hostOf(url)
        if host.isEmpty { return nil }
        if isVpnRewrite(host) { return nil }
        let targetReg = registrableDomain(host)
        if targetReg.isEmpty { return nil }
        // 唯一性: 同注册域多条候选 → 返回排序第一 (schools.json 已按拼音排序, 可接受)
        return catalog.first { s in
            s.isSupported && s.hasUrl && registrableDomain(hostOf(s.url)) == targetReg
        }
    }
}
