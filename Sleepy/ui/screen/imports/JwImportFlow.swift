// JwImportFlow.swift — ← ui/screen/imports/JwImportActivity.kt (320 行)
// 教务直连导入主屏: 学校选择 → WebView 登录抓 HTML → 解析 → 配置确认 → 落库。
// Activity+Stage sealed → NavigationStack-less 状态机 View。

import SwiftUI

enum JwStage {
    case selectSchool
    case webViewLogin
    case configureConfirm
}

struct JwImportFlow: View {
    @Environment(\.localWakeUpColors) private var colors
    @Environment(\.dismiss) private var dismiss
    let onFinish: () -> Void

    @StateObject private var jwViewModel = JwImportViewModel()

    @State private var selectedSchool: JwSchoolInfo? = nil
    @State private var stage: JwStage = .selectSchool
    @State private var errorMsg: String? = nil
    @State private var statusMsg: String? = nil
    @State private var importFinished = false
    // 解析后的课程暂存 + 配置确认状态
    @State private var parsedCourses: [JwCourse] = []
    @State private var parsedSchool: JwSchoolInfo? = nil
    @State private var configStartDate = ""
    @State private var configTimeJson = ""
    @State private var configRows: [TimeTableUtils.TimeSlotRow] = []
    // 课表名 — 默认 jw_import_title(校名)模板, 用户可编辑; 与 Android 1.0.51 ConfigureConfirm
    // AlertDialog 里 OutlinedTextField 一致。
    @State private var configTableName = ""

    var body: some View {
        ZStack {
            content

            // 错误提示(中央 errorContainer 卡 — 原生 Button 一键关闭)
            if let msg = errorMsg {
                Button {
                    errorMsg = nil
                } label: {
                    Text(msg)
                        .font(.system(size: 14))
                        .foregroundColor(colors.onErrorContainer)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .buttonStyle(SleepyButtonStyle())
                .background(colors.errorContainer)
                .cornerRadius(SleepyShapes.medium)
                .padding(32)
                .accessibilityIdentifier("jw_error_banner")
                .accessibilityLabel(msg)
            }
            // 状态提示(底部)
            if let msg = statusMsg {
                VStack {
                    Spacer()
                    Text(msg)
                        .font(.system(size: 14)) // ← Android Snackbar bodyMedium 14
                        .foregroundColor(colors.onSurface)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(colors.surfaceContainerHighest)
                        .cornerRadius(8)
                        .padding(.bottom, 16)
                }
            }
        }
        .onAppear {
            if importFinished { onFinish() }
        }
        .onChange(of: importFinished) { finished in
            if finished { onFinish() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if importFinished {
            EmptyView()   // LaunchedEffect(finish) → onFinish 已由 onChange 触发
        } else if stage == .configureConfirm && !parsedCourses.isEmpty {
            if parsedSchool == nil {
                // school 丢失 → 回 WebView
                Color.clear.onAppear {
                    stage = .webViewLogin
                    parsedCourses = []
                }
            } else {
                configureConfirmSheet
            }
        } else if stage == .selectSchool {
            SchoolSelectScreen(onSchoolSelected: { school in
                if school.url.isEmpty {
                    errorMsg = L10n.format("jw_no_url")
                    return
                }
                selectedSchool = school
                stage = .webViewLogin
            }, onDismiss: onFinish)
        } else if stage == .webViewLogin {
            if let school = selectedSchool {
                JwWebViewLoginScreen(school: school, onHtmlCaptured: onHtmlCaptured) {
                    stage = .selectSchool
                }
            } else {
                Color.clear.onAppear { stage = .selectSchool }
            }
        }
    }

    // ← ConfigureConfirm AlertDialog
    private var configureConfirmSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.format("jw_config_title"))
                        .font(.system(size: 24))   // ← M3 AlertDialog title = headlineSmall 24sp 常规
                        .foregroundColor(colors.onSurface)
                    Text("\(parsedCourses.count) \(L10n.format("import_courses"))")
                        .font(.system(size: 12))
                        .foregroundColor(colors.onSurfaceVariant)
                }
                // ← Android 1.0.51 ConfigureConfirm 字段序: DatePickerField → 课表名 TextField;
                // 名默认 jw_import_title(校名), 用户可改; 提交时空字符串 fallback 回模板。
                DatePickerField(value: configStartDate, onValueChange: { configStartDate = $0 },
                                label: L10n.format("import_week_start"), isError: false,
                                fillsWidth: true)
                TextField(L10n.format("jw_table_name_label"), text: $configTableName)
                    .frame(maxWidth: .infinity)   // ← Android fillMaxWidth()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(colors.surfaceContainer)
                    .cornerRadius(SleepyTheme.fieldShape)
                    .accessibilityIdentifier("jw_config_table_name")
                TimeSlotEditor(rows: configRows, onRowsChange: { newRows in
                    configRows = newRows
                    configTimeJson = TimeTableUtils.buildTimeJsonFromRows(newRows)
                })

                HStack {
                    // ← Android TextButton 默认色 = primary, labelLarge 14sp Medium, 高 40dp
                    Button(L10n.format("back")) {
                        stage = .webViewLogin
                        parsedCourses = []
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(colors.primary)
                    .frame(height: 40)
                    Spacer()
                    Button(L10n.format("jw_config_confirm")) {
                        confirmAndImport()
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(colors.primary)
                    .frame(height: 40)
                }
                .buttonStyle(SleepyButtonStyle())
            }
            .padding(20)
        }
        .background(colors.surface)
    }

    // ← onHtmlCaptured: 解析 → 配置确认页
    private func onHtmlCaptured(_ html: String, _ sch: JwSchoolInfo,
                                _ periods: [(Int, String, String)],
                                _ termStartDate: String) {
        statusMsg = L10n.format("import_parsing")
        // UCAS 详情补全要发原生 HTTP, 必须离开主线程; 回来后仍回主线程改 @State
        Task { @MainActor in
            await parseAndAdvance(html, sch, periods, termStartDate)
        }
    }

    private func parseAndAdvance(_ html: String, _ sch: JwSchoolInfo,
                                 _ periods: [(Int, String, String)],
                                 _ termStartDate: String) async {
        // T6 双层判定: sch.type 已知直接用; 空 → HTML/URL 组合兜底
        let rawType = sch.type
        let effectiveType = (rawType?.isEmpty == false ? rawType : nil)
            ?? JwImportViewModel.detectProtocol(html, url: sch.url.isEmpty ? nil : sch.url)
        // #18 UCAS: 课程格链到跨源详情站 xkcts:8443 (WebView fetch 被 CORS 挡),
        // 详情页免登录 → 原生 HTTP 逐课直抓补全周次/教室; 失败降级原 HTML
        // (parser 落 1-16 占位, 与既有行为一致)
        let htmlForParse = effectiveType == JwProtocol.TYPE_UCAS
            ? await UcasDetailFetch.enrich(html)
            : html
        let parsed = JwParseDispatch.parse(htmlForParse, effectiveType ?? "")
        let courses = parsed.courses
        let attempts = parsed.attempts
        if courses.isEmpty {
            // T9 诊断壳: classify 先做页面级嗅探再选文案 (← JwImportActivity.kt:302)
            errorMsg = DiagMapper.diagnosis(html: html, school: sch, attempts: attempts)
            statusMsg = nil
            return
        }
        // 不直接落库, 进配置确认页
        parsedCourses = courses
        parsedSchool = sch
        // 课程实际节次数生成行; WebView 抓到 periods 则预填
        let maxNode = courses.map { max($0.startNode, $0.endNode) }.max() ?? 0
        let periodMap = Dictionary(periods.map { ($0.0, ($0.1, $0.2)) }, uniquingKeysWith: { a, _ in a })
        configRows = (1...max(1, maxNode)).map { node in
            let filled = periodMap[node]
            return TimeTableUtils.TimeSlotRow(node: node,
                                              start: filled?.0 ?? "",
                                              end: filled?.1 ?? "")
        }
        // 学期起始日预填: JSON 直连协议 (boya_pp/cqu/chaoxing) 能从接口拿到第一周周一
        // (如燕大 2026-2027-1 实为 2026-08-31, 本地 9 月首一推断会差一周), 用户仍可改
        configStartDate = termStartDate
        configTimeJson = ""
        configTableName = L10n.format("jw_import_title", sch.name)
        stage = .configureConfirm
        statusMsg = nil
    }

    // ← confirmButton 校验链 + 落库
    private func confirmAndImport() {
        // 校验(与 ImportConfirmDialog 同链)
        if configStartDate.isEmpty ||
           configStartDate.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil {
            errorMsg = L10n.format("start_date_format")
            return
        }
        if let first = configRows.first(where: { $0.start.isEmpty || $0.end.isEmpty }) {
            errorMsg = L10n.format("slot_time_required", first.node)
            return
        }
        if let first = configRows.first(where: {
            $0.start.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) == nil ||
            $0.end.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) == nil ||
            $0.start >= $0.end
        }) {
            errorMsg = L10n.format("slot_time_invalid", first.node)
            return
        }
        configTimeJson = TimeTableUtils.buildTimeJsonFromRows(configRows)
        // 落库
        statusMsg = L10n.format("import_parsing")
        guard let school = parsedSchool else { return }
        do {
            let maxNode = configRows.map { $0.node }.max() ?? 0
            // ← Android 1.0.51 一致: 用户编辑的课表名为空时回退 jw_import_title(校名)
            let trimmedName = configTableName.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalTableName = trimmedName.isEmpty
                ? L10n.format("jw_import_title", school.name)
                : trimmedName
            let tableId = try JwImportViewModel.importAsNewTable(
                AppDatabase.getShared(),
                courses: parsedCourses,
                tableName: finalTableName,
                startDate: configStartDate,
                timeJson: configTimeJson,
                nodesPerDay: maxNode)
            _ = tableId
            statusMsg = L10n.format("jw_import_success", parsedCourses.count)
            importFinished = true
        } catch {
            errorMsg = L10n.format("jw_parse_failed", error.localizedDescription)
            statusMsg = nil
        }
    }
}

/// 诊断结果 → 用户可见文案 ← JwImportActivity.kt DiagMapper (433-470)。
///
/// 0 课不等于"空学期": 会话过期 / 图片课表 / 协议标注错 都会解析出 0 课,
/// 统一一句"本学期无课"会把用户引向错误方向。先 classify 分类, 再按类选文案,
/// 最后按学校/协议族补一条网络提示。
enum DiagMapper {

    /// 完整入口: 分类 + 映射。classify 的 html 非空是硬前置 (Swift 侧是
    /// precondition 而非可捕获异常) → 空 HTML 直接走兜底文案, 绝不喂进去。
    static func diagnosis(html: String, school: JwSchoolInfo,
                          attempts: [ParserAttemptSnapshot]) -> String {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return L10n.format("jw_err_empty_semester")
        }
        let diag = JwParseDiagnostics.classify(
            html, "", school, attempts.map { $0.asDiag })
        return map(diag, school)
    }

    static func map(_ diag: JwParseDiagnostics.Result, _ school: JwSchoolInfo) -> String {
        let features = diag.matchedFeatures.prefix(5).joined(separator: "/")
        let base: String
        switch diag.category {
        case .sessionExpired:     base = L10n.format("jw_diag_session_expired", school.name)
        case .noTableContainer:   base = L10n.format("jw_diag_no_container", school.name)
        case .headerNoNode:       base = L10n.format("jw_diag_header_no_node", school.name)
        case .imageOrEmptyCells:  base = L10n.format("jw_diag_image_cells", school.name)
        case .emptySemester:      base = L10n.format("jw_diag_empty_semester", school.name)
        case .wrongProtocol:      base = L10n.format("jw_diag_wrong_protocol", school.name)
        case .unknownEmpty:       base = L10n.format("jw_diag_unknown_empty", school.name, features)
        }
        // UNKNOWN_EMPTY 的文案里已内嵌诊断特征占位符, 不再二次追加
        if diag.category == .unknownEmpty { return base }
        let hint = schoolHint(school)
        return hint.isEmpty ? base : base + "\n\n" + hint
    }

    /// 特殊学校 hint: 临沂大学(校园网限制) / 强智系(会话踢下线) / B 档 985 校
    /// (校外多须 VPN/WebVPN) ← mapImpl 的 schoolHint
    static func schoolHint(_ school: JwSchoolInfo) -> String {
        let campusOnlyHosts = [
            "jwgl.lyu.edu.cn", "jwxt.lyu.edu.cn",
            // v1.0.46 B 档新 985 校: 教务域名普遍校外受限, 0 课兜底文案易被误读为学期选错
            "jwxt.neu.edu.cn",          // 东北大学
            "newxk.urp.seu.edu.cn",     // 东南大学
            "xsjw2018.jw.scut.edu.cn",  // 华南理工大学
            "jxglstu.hfut.edu.cn",      // 合肥工业大学
            "zdbk.zju.edu.cn",          // 浙江大学
            "jw.ustc.edu.cn",           // 中国科学技术大学
            "jwms.bit.edu.cn",          // 北京理工大学 (legacy URL 兼容)
            "jxzxehallapp.bit.edu.cn",  // 北京理工大学 (现行 URL)
            "csujwc.its.csu.edu.cn",    // 中南大学
            "jwxt.whut.edu.cn",         // 武汉理工大学 (登录后偶发限流, 提示换网络)
            // 2026-09 211 批量收录: 海外探测超时率高/域名校内受限的新校
            "jwxt.scnu.edu.cn",         // 华南师范大学
            "hdjw.hnu.edu.cn",          // 湖南大学 (Njw2017)
            "jw.ruc.edu.cn",            // 中国人民大学 (Njw2017)
            "jw.dhu.edu.cn",            // 东华大学
            "jw.ahu.edu.cn",            // 安徽大学 (supwisdom 新版)
            "jwxt.cumtb.edu.cn",        // 矿大北京 (supwisdom 新版)
            "jwxt.ybu.edu.cn",          // 延边大学
            "jwgl.shzu.edu.cn",         // 石河子大学
            "eams.uestc.edu.cn",        // 电子科技大学 (经典 EAMS, 202 鉴权)
            "eams.sufe.edu.cn",         // 上海财经大学 (经典 EAMS)
            "jwglnew.hunnu.edu.cn",     // 湖南师范大学 (经典 EAMS, iframe)
            "aao-eas.nuaa.edu.cn",      // 南京航空航天大学 (经典 EAMS)
            "jwgl.gzhmu.edu.cn",        // 广州医科大学 (强智, 教务域公网不解析)
        ]
        if campusOnlyHosts.contains(where: { school.url.contains($0) }) {
            return L10n.format("jw_diag_campus_vpn_hint")
        }
        // 四川大学条目 URL 即门户域, 整串相等才判
        if school.url == "https://scu.edu.cn/" {
            return L10n.format("jw_diag_campus_vpn_hint")
        }
        if [JwProtocol.TYPE_QZ, JwProtocol.TYPE_QZ_CRAZY, JwProtocol.TYPE_QZ_BR,
            JwProtocol.TYPE_QZ_WITH_NODE, JwProtocol.TYPE_QZ_OLD].contains(school.type) {
            return L10n.format("jw_diag_qz_vpn_hint")
        }
        return ""
    }
}
