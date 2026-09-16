// JwParseDiagnostics.swift — ← JwParseDiagnostics.kt
//
// 教务直连导入失败诊断 — T9
//
// 负责在 parser 调用之上做一次"分类嗅探"：区分
//   - 会话过期 / 登录页（HTTP 200 渲染的是登录页 HTML）
//   - 页面无课表容器（iframe 跨域 / WebView 抓取时序问题）
//   - 有容器但组头缺失（合并行 / OCR 截图 / 图片课表）
//   - 有容器有组头但课程格全空（图片课表 / 本学期无课）
//   - 可信空课表（页面文本含"暂无课表"/"未产生课表数据"）
//   - 抓取协议不匹配（parser 解析为 0 课但页面是其他协议 — T8 兜底失败）
//
// 关键约束：**绝不** 把学号 / 姓名 / Cookie / token / 完整 HTML 写入 userMessage 或 Log。
// 只输出"指纹片段"这种用户能看懂、技术人员也能定位的信息。

import Foundation
import SwiftSoup

enum JwParseDiagnostics {

    /// 失败分类 — 与 strings.xml 的 jw_diag_* 系列键一一对应
    enum Category: Equatable {
        /// 抓到的就是登录页 / 会话过期页 / CAS 跳转页
        case sessionExpired
        /// 没有任何课表容器（Table1 / kbtable / kbList / dateList / kbxx / kbgrid / kblist 全无）
        case noTableContainer
        /// 有容器但表头行全是合并或缺失节次行头
        case headerNoNode
        /// 有容器有行头但课程格是 <img> / 全 &nbsp; / 全空串（图片课表）
        case imageOrEmptyCells
        /// 页面文本含"暂无课表"/"本学期无课"/"尚未产生课表数据"等可信空声明
        case emptySemester
        /// 抓取协议与 parser 不匹配（多协议混淆 / iframe 抓取拿不到目标）
        case wrongProtocol
        /// 兜底：parser 解析为 0 课但不属于以上六类
        case unknownEmpty
    }

    /// 单次 parser 尝试的结果快照
    struct ParserAttempt: Equatable {
        let parserName: String
        let courseCount: Int
        let exception: String?
    }

    /// 完整诊断结果
    struct Result {
        let category: Category
        let attempts: [ParserAttempt]
        let matchedFeatures: [String]
        let courseCount: Int
        let userMessage: String
    }

    /// 老正方通用"登录态失效"硬指纹 — 整段 script 只含
    ///   (window.)(parent|top).location(.href)?='logout.aspx'
    /// 一条即判, 不走 score≥2 门槛。
    ///
    /// 设计原因 (JOU 2026-09-09 jw-cross-verify-sop Step 5.5):
    /// 老正方 .aspx 协议惯用法 = HTTP 200 + 文档首行注入
    ///   <script>window.parent.location.href='logout.aspx'</script>
    /// 强制顶层跳回 logout.aspx。该形态:
    ///  - 只 1 条硬指纹, 既有 LOGIN_FINGERPRINTS score<2 永远漏报;
    ///  - 跳转前的 HTML 仍含真实 id="Table1" 骨架, 锚点会先命中,
    ///    把过期页误判 OK/EMPTY_SEMESTER 而非 SESSION_EXPIRED。
    /// → 必须在 selectBestFrame / rankAll 中先于锚点 + 先于 looksLikeLoginPage。
    ///
    /// 形态约束 (拒误伤):
    ///  - 必须整段 script 体只含此一句 (script 开闭间仅空白);
    ///  - 必须 (parent|top).location(.href)?= 的赋值形态,
    ///    拒绝 <a onclick="parent.location.href='logout.aspx'"> 菜单退出按钮;
    ///  - script 体内含其他语句时不得误伤 (独立 script 块须自闭合)。
    static let LOGOUT_REDIRECT = try! NSRegularExpression(
        pattern: #"(?is)<script[^>]*>\s*(?:window\.)?(?:parent|top)\.location(?:\.href)?\s*=\s*['"]logout\.aspx['"]\s*;?\s*</script>"#)

    private static func contains(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// 给一段 HTML 做"页面级嗅探"。
    /// 优先级: SessionExpired > NoContainer > ImageOrEmpty > EmptySemester > WrongProtocol > UnknownEmpty。
    static func classify(
        _ html: String,
        _ url: String,
        _ school: JwSchoolInfo?,
        _ parsersAttempted: [ParserAttempt]
    ) -> Result {
        precondition(!html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "html 不能为空")
        let doc = (try? SwiftSoup.parse(html)) ?? Document("")
        let bodyText = (try? doc.body()?.text()) ?? nil ?? ""
        var matched: [String] = []

        // 1) 会话过期 / 登录页
        let loginMarkers: [(String, NSRegularExpression)] = [
            ("logout-redirect", LOGOUT_REDIRECT),
            ("login_slogin", try! NSRegularExpression(pattern: #"login_slogin|csrfToken|csrftoken"#)),
            ("登录", try! NSRegularExpression(pattern: #"用户登录|请输入密码|请输入账号|登录系统|统一身份认证登录|请重新登录"#)),
            ("captcha", try! NSRegularExpression(pattern: #"kaptcha|verifycode|RANDOMCODE|输入验证码|CheckCode"#)),
            ("logon", try! NSRegularExpression(pattern: #"Logon\.do\?method=logon|/jsxsd/xk/LoginToXk|Logon\.do"#)),
            ("cas", try! NSRegularExpression(pattern: #"iaaa\.pku\.edu\.cn|/cas/login|casAuth"#)),
            ("viewstate", try! NSRegularExpression(pattern: #"__VIEWSTATE|ASP\.NET_SessionId"#)),
        ]
        var loginHit = false
        for (name, re) in loginMarkers {
            if contains(re, html) {
                matched.append(name)
                loginHit = true
            }
        }
        let formAction = ((try? doc.select("form[action]").first()?.attr("action")) ?? nil) ?? ""
        let looksLikeLogin = loginHit ||
            (!formAction.isEmpty &&
                (formAction.range(of: "login", options: .caseInsensitive) != nil ||
                 formAction.range(of: "Logon", options: .caseInsensitive) != nil ||
                 formAction.range(of: "slogin", options: .caseInsensitive) != nil) &&
                formAction.range(of: "xskbcx", options: .caseInsensitive) == nil &&
                formAction.range(of: "xskb", options: .caseInsensitive) == nil)
        if looksLikeLogin {
            return Result(
                category: .sessionExpired,
                attempts: parsersAttempted,
                matchedFeatures: matched,
                courseCount: 0,
                userMessage: "登录页与会话过期：检测到 \(matched.joined(separator: "/"))，" +
                    "请确认已完成登录并停留在「个人课表」页（而非登录页或首页）")
        }

        // 1.5) 可信空课表声明 — 优先于容器缺失判定（页面明确声明无课 → 不误报 NO_TABLE_CONTAINER）
        let emptySemesterMarkers = [
            "暂无课表", "暂无课程", "本学期暂无", "本学期无课",
            "尚未产生课表数据", "本学期暂无课表数据", "未查询到课表",
            "没有可选的课程", "未排课",
        ]
        if let emptyHit = emptySemesterMarkers.first(where: { bodyText.contains($0) }) {
            matched.append(emptyHit)
            return Result(
                category: .emptySemester,
                attempts: parsersAttempted,
                matchedFeatures: matched,
                courseCount: 0,
                userMessage: "页面声明本学期暂无课程：\"\(emptyHit)\"。请确认已选对学期，" +
                    "或下学期开学后再导入")
        }

        // 2) 页面无课表容器
        let containerMarkers: [(String, NSRegularExpression)] = [
            ("id=Table1", try! NSRegularExpression(pattern: #"(?i)id\s*=\s*["']Table1["']"#)),
            ("id=kbtable", try! NSRegularExpression(pattern: #"(?i)id\s*=\s*["']kbtable["']"#)),
            ("id=table1", try! NSRegularExpression(pattern: #"(?i)id\s*=\s*["']table1["']"#)),
            ("kbList", try! NSRegularExpression(pattern: #"["']kbList["']"#)),
            ("kbxx", try! NSRegularExpression(pattern: #"var\s+kbxx\s*=|kbxx\s*=\s*\["#)),
            ("kbgrid", try! NSRegularExpression(pattern: "kbgrid_table|kbgrid_view")),
            ("kblist", try! NSRegularExpression(pattern: "kblist_table")),
            ("dateList", try! NSRegularExpression(pattern: #"["']dateList["']"#)),
            ("datagrid", try! NSRegularExpression(pattern: #"\.datagrid\b|class\s*=\s*["'][^"']*datagrid"#)),
            ("displayTag", try! NSRegularExpression(pattern: #"class\s*=\s*["'][^"']*displayTag"#)),
        ]
        let containerHits = containerMarkers.filter { contains($0.1, html) }.map { $0.0 }
        if containerHits.isEmpty {
            matched.append("no_container")
            return Result(
                category: .noTableContainer,
                attempts: parsersAttempted,
                matchedFeatures: matched,
                courseCount: 0,
                userMessage: "未找到课表容器（Table1 / kbtable / kbList / dateList 均缺失）。" +
                    "可能原因：①抓取协议与实际教务系统不匹配；②WebView 抓取时机过早，课表尚未加载；" +
                    "③页面为图片课表或跨域 iframe")
        }
        matched.append(contentsOf: containerHits)

        // 3) 有容器但组头无逐节行头
        let hasNodeHeader = contains(
            try! NSRegularExpression(pattern: #"第\s*[一二三四五六七八九十0-9]+\s*节"#), bodyText)
        if !hasNodeHeader && containerHits.contains(where: { $0 != "kbList" && $0 != "dateList" && $0 != "kbxx" }) {
            // 纯 JSON 协议（kbList/dateList/kbxx）不做行头检查 — 它本来就没有行头
            return Result(
                category: .headerNoNode,
                attempts: parsersAttempted,
                matchedFeatures: matched,
                courseCount: 0,
                userMessage: "找到课表容器（\(containerHits.joined(separator: "/"))）但未识别到逐节行头。" +
                    "可能原因：①该课表为图片截图，请改用 HTML/CSV 文件导入或手动添加；" +
                    "②组头被合并（如'第一节-第二节'），请反馈开发者适配")
        }

        // 4) 容器在但课程格 <img> — 图片课表
        let imgInTable = ((try? doc.select("table img").size()) ?? 0)
            + ((try? doc.select("td img").size()) ?? 0)
        var imgWithLongAlt = 0
        if let imgs = try? doc.select("img") {
            for img in imgs {
                if (((try? img.attr("alt")) ?? "").count >= 3) { imgWithLongAlt += 1 }
            }
        }
        if imgInTable >= 2 || imgWithLongAlt >= 1 {
            return Result(
                category: .imageOrEmptyCells,
                attempts: parsersAttempted,
                matchedFeatures: matched + ["img_in_table"],
                courseCount: 0,
                userMessage: "课表单元格为图片（检测到 \(imgInTable) 个 <img>），Sleepy 无法识别。" +
                    "建议改用 HTML/CSV 文件导入，或手动添加课程")
        }

        // 6) 抓取协议不匹配
        let schoolType = school?.type
        let expectedFamily: Set<String>?
        switch schoolType ?? "" {
        case JwProtocol.TYPE_ZF, JwProtocol.TYPE_ZF_1: expectedFamily = ["id=Table1"]
        case JwProtocol.TYPE_ZF_NEW: expectedFamily = ["kbList", "kbgrid", "kblist"]
        case JwProtocol.TYPE_QZ, JwProtocol.TYPE_QZ_CRAZY, JwProtocol.TYPE_QZ_BR,
             JwProtocol.TYPE_QZ_WITH_NODE, JwProtocol.TYPE_QZ_OLD: expectedFamily = ["id=kbtable"]
        case JwProtocol.TYPE_URP_NEW: expectedFamily = ["dateList"]
        case JwProtocol.TYPE_URP: expectedFamily = ["displayTag"]
        case JwProtocol.TYPE_CF: expectedFamily = ["kbxx"]
        case JwProtocol.TYPE_PKU: expectedFamily = ["datagrid"]
        case JwProtocol.TYPE_BNUZ: expectedFamily = ["id=table1", "id=Table1"]
        default: expectedFamily = nil
        }
        if let expectedFamily = expectedFamily, !containerHits.contains(where: { expectedFamily.contains($0) }) {
            return Result(
                category: .wrongProtocol,
                attempts: parsersAttempted,
                matchedFeatures: matched,
                courseCount: 0,
                userMessage: "抓取协议与学校配置不一致：学校标注 \(schoolType ?? "")，" +
                    "但页面容器为 \(containerHits.joined(separator: "/"))。" +
                    "可能原因：①学校已切换教务系统，请反馈开发者更新 schools.json；" +
                    "②抓取时机过早；③页面为图片课表")
        }

        // 7) 兜底
        return Result(
            category: .unknownEmpty,
            attempts: parsersAttempted,
            matchedFeatures: matched,
            courseCount: 0,
            userMessage: "解析结果为空，但未找到明确原因。请尝试重新加载页面或反馈开发者。" +
                "（诊断特征：\(matched.prefix(5).joined(separator: "/"))）")
    }
}
