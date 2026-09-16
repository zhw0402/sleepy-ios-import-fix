// AboutScreen.swift — ← ui/screen/mine/AboutScreen.kt + UpdateChangelogDialog.kt
// 关于页: App 名+版本 / 一键更新(检查+changelog+下载 IPA)/作者/源码/许可证。
// 平台差异表#2: Android 下载 APK 自装 → iOS 下载 IPA 后提示重新侧载(install 动作降级)。

import SwiftUI

// ← UpdateUiState sealed class
enum UpdateUiState: Equatable {
    case idle
    case checking
    case noUpdate(String)
    case updateAvailable(version: String, changelog: String, url: String)
    case downloading(Int)
    case installing
    case failed(message: String, version: String, changelog: String, url: String, isCheckFailure: Bool)

    var isActiveDialog: Bool {
        switch self {
        case .updateAvailable, .downloading, .failed, .installing: return true
        default: return false
        }
    }
}

struct AboutScreen: View {
    @Environment(\.localWakeUpColors) private var colors
    let onDismiss: () -> Void
    // ★ v7.10.18 Track D: 长 License 卡拆二级页, AboutScreen 留入口行
    var onOpenLicense: () -> Void = {}

    @State private var uiState: UpdateUiState = .idle
    @State private var downloadTask: Task<Void, Never>? = nil
    @State private var snackMessage: String? = nil
    @State private var downloadedIpa: URL? = nil
    // ← 1.0.51: 冷启动更新检查结果(横幅/高亮) + 自动检查开关(持久化 key 同 Android)
    @ObservedObject private var updateNotifier = UpdateNotifier.shared
    @State private var updateCheckEnabled = UpdateCheckPrefs.isEnabled

    var body: some View {
        VStack(spacing: 0) {
            SettingsTopBar(title: L10n.format("about_title"), onBack: onDismiss)
            ScrollView {
                VStack(spacing: 12) {
                    // ← 1.0.51 UpdateBanner: 检查到新版时顶部横幅, 点击跳 Releases tag 页
                    if let banner = updateNotifier.updateAvailable {
                        UpdateBanner(version: banner.version) {
                            openURL("https://gh.qdp.qzz.io/lingion/sleepy-ios/releases/tag/v\(banner.version)")
                        }
                    }

                    appNameHeader

                    // Version info card
                    InfoCard {
                        HStack(spacing: 12) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .font(.system(size: 24))
                                .foregroundColor(colors.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.format("about_version"))
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(colors.onSurface)
                                Text(L10n.format("about_version_detail",
                                                 UpdateManager.currentVersionName, buildCode))
                                    .font(.system(size: 14))
                                    .foregroundColor(colors.onSurfaceVariant)
                            }
                        }
                    }

                    // One-click update
                    InfoCard {
                        VStack(spacing: 12) {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 24))
                                    .foregroundColor(colors.primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L10n.format("about_update"))
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(colors.onSurface)
                                    Text(L10n.format("about_update_detail"))
                                        .font(.system(size: 12))
                                        .foregroundColor(colors.onSurfaceVariant)
                                }
                            }
                            Button(action: checkUpdate) {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.down.circle")
                                    Text(isChecking ? L10n.format("about_update_checking")
                                                    : L10n.format("about_update"))
                                }
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(colors.onPrimary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                                .background(colors.primary)
                                .cornerRadius(20) // ← M3 Button 默认 shape=full-round(胶囊), 40 高 → 圆角 20
                            }
                            .buttonStyle(SleepyButtonStyle())
                            .disabled(isChecking)
                            .accessibilityIdentifier("about_check_update")
                        }
                    }

                    // Author card
                    InfoCard {
                        HStack(spacing: 12) {
                            Image(systemName: "person")
                                .font(.system(size: 24))
                                .foregroundColor(colors.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.format("about_author"))
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(colors.onSurface)
                                Text(L10n.format("about_author_name"))
                                    .font(.system(size: 14))
                                    .foregroundColor(colors.onSurfaceVariant)
                            }
                            Spacer()
                            Button {
                                openURL("https://github.com/lingion")
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 20))
                                    .foregroundColor(colors.primary)
                            }
                            .buttonStyle(SleepyButtonStyle())
                        }
                    }

                    // Source code card
                    InfoCard {
                        HStack(spacing: 12) {
                            Image(systemName: "curlybraces")
                                .font(.system(size: 24))
                                .foregroundColor(colors.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.format("about_source"))
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(colors.onSurface)
                                Button {
                                    openURL("https://github.com/lingion/sleepy")
                                } label: {
                                    Text(L10n.format("about_source_url"))
                                        .font(.system(size: 14))
                                        .foregroundColor(colors.primary)
                                        .underline()
                                }
                                .buttonStyle(SleepyButtonStyle())
                            }
                            Spacer()
                            Button {
                                openURL("https://github.com/lingion/sleepy")
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 20))
                                    .foregroundColor(colors.primary)
                            }
                            .buttonStyle(SleepyButtonStyle())
                        }
                    }

                    // Feedback card — ← 1.0.51 反馈卡: GitHub Issue / 邮件两个入口
                    //   (FeedbackComposer 已 1:1 移植, 这里只是接上 UI)
                    InfoCard {
                        HStack(spacing: 12) {
                            Image(systemName: "ant")
                                .font(.system(size: 24))
                                .foregroundColor(colors.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.format("about_feedback"))
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(colors.onSurface)
                                Text(L10n.format("about_feedback_detail"))
                                    .font(.system(size: 12))
                                    .foregroundColor(colors.onSurfaceVariant)
                            }
                            Spacer()
                            Button { openGitHubFeedback() } label: {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 20))
                                    .foregroundColor(colors.primary)
                            }
                            .buttonStyle(SleepyButtonStyle())
                            .accessibilityLabel(L10n.format("about_feedback_github"))
                            Button { openEmailFeedback() } label: {
                                Image(systemName: "envelope")
                                    .font(.system(size: 20))
                                    .foregroundColor(colors.primary)
                            }
                            .buttonStyle(SleepyButtonStyle())
                            .accessibilityLabel(L10n.format("about_feedback_email"))
                        }
                    }

                    // License 入口行(v1.0.46 用户令): 长卡拆独立二级页, 这里只留入口
                    InfoCard {
                        Button(action: onOpenLicense) {
                            // ← Android 无前导图标: 标题+副题+尾随 ChevronRight(20dp)
                            HStack(spacing: 0) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L10n.format("about_license_title"))
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(colors.onSurface)
                                    Text(L10n.format("about_license_detail"))
                                        .font(.system(size: 12))
                                        .foregroundColor(colors.onSurfaceVariant)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 20))
                                    .foregroundColor(colors.onSurfaceVariant)
                            }
                        }
                        .buttonStyle(SleepyButtonStyle())
                    }

                    // ← 1.0.51 自动检查更新 Toggle: 关闭后冷启动不拉远端, 高亮也立即消失
                    InfoCard {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.format("about_update_check"))
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(colors.onSurface)
                                Text(L10n.format("about_update_check_detail"))
                                    .font(.system(size: 12))
                                    .foregroundColor(colors.onSurfaceVariant)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Toggle("", isOn: $updateCheckEnabled)
                                .labelsHidden()
                                .tint(colors.primary) // ← M3 Switch checkedTrack=primary
                                .onChange(of: updateCheckEnabled) { v in
                                    UpdateCheckPrefs.setEnabled(v)
                                    if !v { updateNotifier.clearCache() }
                                }
                        }
                    }

                    Spacer().frame(height: 32)
                }
                .padding(.horizontal, 20)
            }
        }
        // ← 1.0.51: 有更新可用时页面底色高亮 primary 5%
        .background(updateNotifier.updateAvailable != nil ? colors.primary.opacity(0.05) : colors.background)
        // Android 在 MainActivity.onCreate 检查; iOS 入口不可改, 由关于页触发(一次进程最多一次)
        .task { updateNotifier.maybeCheckOnStart() }
        .overlay(alignment: .bottom) {
            if let msg = snackMessage {
                Text(msg)
                    .font(.system(size: 14)) // ← Android Snackbar bodyMedium 14
                    .foregroundColor(colors.onSurface)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(colors.surfaceContainerHighest)
                    .cornerRadius(8)
                    .padding(.bottom, 12)
                    .task(id: msg) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation { snackMessage = nil }
                    }
            }
        }
        // ← UpdateChangelogDialog
        .sheet(isPresented: Binding(
            get: { uiState.isActiveDialog },
            set: { if !$0 { uiState = .idle } }
        )) {
            UpdateChangelogDialog(state: uiState,
                                  onDismiss: { uiState = .idle },
                                  onDownload: { version, changelog, url in
                                      startDownload(version: version, changelog: changelog, url: url)
                                  },
                                  onCancelDownload: { cancelDownload() },
                                  onRetry: { version, changelog, url in
                                      if case .failed(_, _, _, _, let isCheck) = uiState, isCheck {
                                          checkUpdate()
                                      } else {
                                          startDownload(version: version, changelog: changelog, url: url)
                                      }
                                  })
                .sheetDetents([.medium])
        }
    }

    private var isChecking: Bool {
        if case .checking = uiState { return true }
        return false
    }

    private var buildCode: Int {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) ?? 0
    }

    // App name(← 1.0.51: 纯文字, 无 logo 图; headlineMedium bold 28sp)
    @ViewBuilder
    private var appNameHeader: some View {
        VStack(spacing: 4) {
            Spacer().frame(height: 8)
            Text(L10n.format("app_name"))
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(colors.onSurface)
            Text("v\(UpdateManager.currentVersionName)")
                .font(.system(size: 14))
                .foregroundColor(colors.onSurfaceVariant)
            Spacer().frame(height: 24)
        }
    }

    private func openURL(_ s: String) {
        if let url = URL(string: s) { UIApplication.shared.open(url) }
    }

    // ← diagnostic(): Android FeedbackComposer.Diagnostic 的 iOS 填实
    private func diagnostic() -> FeedbackComposer.Diagnostic {
        let scale = UIScreen.main.scale
        let bounds = UIScreen.main.bounds.size
        return FeedbackComposer.Diagnostic(
            versionName: UpdateManager.currentVersionName,
            versionCode: buildCode,
            osVersion: UIDevice.current.systemVersion,
            deviceBrand: "Apple",
            deviceModel: UIDevice.current.model,
            resolution: "\(Int(bounds.width * scale))x\(Int(bounds.height * scale))",
            locale: Locale.preferredLanguages.first ?? "en",
            isDebug: isDebugBuild)
    }

    private var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    // ← openGitHubFeedback: bug_report.yml 模板 + 诊断块(标题/正文与 Android 同源)
    private func openGitHubFeedback() {
        openURL(FeedbackComposer.githubIssueUrl(
            title: "[Sleepy] ",
            body: "请描述你遇到的问题或建议：",
            diag: diagnostic(),
            template: "bug_report.yml"))
    }

    // ← openEmailFeedback: 无邮件客户端 → snackbar 改用 GitHub Issue
    private func openEmailFeedback() {
        let uri = FeedbackComposer.mailtoUri(
            subject: L10n.format("about_feedback_email_subject"),
            body: L10n.format("about_feedback_email_body"),
            diag: diagnostic())
        guard let url = URL(string: uri), UIApplication.shared.canOpenURL(url) else {
            snackMessage = L10n.format("about_feedback_no_mail_app")
            return
        }
        UIApplication.shared.open(url)
    }

    // ← checkUpdate
    private func checkUpdate() {
        guard !isChecking else { return }
        uiState = .checking
        Task {
            do {
                let info = try await UpdateManager.fetchUpdateInfo()
                if info.isUpdateAvailable {
                    uiState = .updateAvailable(version: info.version, changelog: info.changelog,
                                               url: info.downloadUrl)
                } else {
                    // NoUpdate → snackbar + 回 Idle
                    snackMessage = L10n.format("about_update_latest", info.version)
                    uiState = .idle
                }
            } catch {
                uiState = .failed(message: error.localizedDescription, version: "", changelog: "",
                                  url: "", isCheckFailure: true)
            }
        }
    }

    // ← startDownload: 下载 IPA;完成 → Installing(= iOS 提示侧载)
    private func startDownload(version: String, changelog: String, url: String) {
        let info = UpdateInfo(version: version, changelog: changelog, downloadUrl: url, isUpdateAvailable: true)
        uiState = .downloading(0)
        downloadTask = Task {
            do {
                let file = try await UpdateManager.downloadIpa(info) { progress in
                    uiState = .downloading(progress)
                }
                downloadedIpa = file
                uiState = .installing
            } catch is CancellationError {
                uiState = .updateAvailable(version: version, changelog: changelog, url: url)
            } catch {
                uiState = .failed(message: error.localizedDescription, version: version,
                                  changelog: changelog, url: url, isCheckFailure: false)
            }
        }
    }

    private func cancelDownload() {
        downloadTask?.cancel()
    }
}

// ← UpdateChangelogDialog
private struct UpdateChangelogDialog: View {
    @Environment(\.localWakeUpColors) private var colors
    let state: UpdateUiState
    let onDismiss: () -> Void
    let onDownload: (String, String, String) -> Void
    let onCancelDownload: () -> Void
    let onRetry: (String, String, String) -> Void

    var body: some View {
        let version = self.version
        let changelog = self.changelog
        let url = self.url
        let progress = self.progress
        let failMsg = self.failMsg

        VStack(alignment: .leading, spacing: 16) {
            Text(dialogTitle(version: version))
                .font(.system(size: 22, weight: .bold)) // ← Android titleLarge.copy(Bold) 22sp
                .foregroundColor(colors.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !failMsg.isEmpty {
                        Text(L10n.format("update_download_failed", failMsg))
                            .font(.system(size: 14))
                            .foregroundColor(colors.error)
                    }
                    if progress >= 0 {
                        VStack(alignment: .leading, spacing: 4) { // ← Android 进度条与百分比 Spacer(4)
                            ProgressView(value: Double(progress) / 100.0)
                                .tint(colors.primary)
                            Text(L10n.format("update_downloading", progress))
                                .font(.system(size: 12))
                                .foregroundColor(colors.onSurfaceVariant)
                        }
                    }
                    // ★ iOS 等价适配(平台差异表#2): 安装动作降级为提示重新侧载
                    if case .installing = state {
                        Text(L10n.format("update_ios_sideload_hint"))
                            .font(.system(size: 14))
                            .foregroundColor(colors.primary)
                    }
                    if !changelog.isEmpty {
                        // ← 1.0.51: changelog 按 Markdown 渲染(标题层级/圆点/粗体/链接)
                        MarkdownChangelog(markdown: changelog)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                switch state {
                case .updateAvailable:
                    Button(L10n.format("update_cancel"), action: onDismiss)
                        .foregroundColor(colors.onSurfaceVariant)
                    Button(L10n.format("update_download")) {
                        onDownload(version, changelog, url)
                    }
                    .foregroundColor(colors.primary)
                case .downloading:
                    Button(L10n.format("update_cancel"), action: onCancelDownload)
                        .foregroundColor(colors.primary)
                case .failed:
                    Button(L10n.format("update_cancel"), action: onDismiss)
                        .foregroundColor(colors.onSurfaceVariant)
                    Button(L10n.format("update_retry")) {
                        onRetry(version, changelog, url)
                    }
                    .foregroundColor(colors.primary)
                case .installing:
                    Button(L10n.format("ok"), action: onDismiss)
                        .foregroundColor(colors.primary)
                case .idle, .checking, .noUpdate:
                    EmptyView()
                }
            }
            .buttonStyle(SleepyButtonStyle())
            // ← M3 dialog 按钮 label = labelLarge 14 Medium(TextButton/Button 同字号)
            .font(.system(size: 14, weight: .medium))
        }
        .padding(24) // ← M3 AlertDialog dialogPadding 24dp
        .background(colors.surface)
    }

    private var version: String {
        switch state {
        case .updateAvailable(let v, _, _), .failed(_, let v, _, _, _): return v
        default: return ""
        }
    }
    private var changelog: String {
        switch state {
        case .updateAvailable(_, let c, _), .failed(_, _, let c, _, _): return c
        default: return ""
        }
    }
    private var url: String {
        switch state {
        case .updateAvailable(_, _, let u), .failed(_, _, _, let u, _): return u
        default: return ""
        }
    }
    private var progress: Int {
        if case .downloading(let p) = state { return p }
        return -1
    }
    private var failMsg: String {
        if case .failed(let m, _, _, _, _) = state { return m }
        return ""
    }

    private func dialogTitle(version: String) -> String {
        switch state {
        case .installing: return L10n.format("update_ios_sideload_title")
        case .downloading(let p): return L10n.format("update_downloading", p)
        default: return L10n.format("update_found_title", version)
        }
    }
}

// ← InfoCard 已迁移到 Sleepy/ui/component/SettingsCards.swift 共享

// ← UpdateBanner(1.0.51): primary 12% 底色横幅, 点击跳 Releases tag 页
private struct UpdateBanner: View {
    @Environment(\.localWakeUpColors) private var colors
    let version: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack") // ← Icons.Outlined.NewReleases 20dp
                    .font(.system(size: 20))
                    .foregroundColor(colors.primary)
                Text(L10n.format("about_update_available", "v\(version)"))
                    .font(.system(size: 14, weight: .semibold)) // ← bodyMedium SemiBold primary
                    .foregroundColor(colors.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right.square") // ← Icons.AutoMirrored.OpenInNew 18dp
                    .font(.system(size: 18))
                    .foregroundColor(colors.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(colors.primary.opacity(0.12))
            .cornerRadius(SleepyShapes.large) // ← clip(shapes.large) = 16dp
        }
        .buttonStyle(SleepyButtonStyle())
    }
}

// ← MarkdownChangelog(1.0.51): changelog 按 Markdown 渲染
//   标题: L1=titleLarge 22 Bold / L2=titleMedium 16 Bold / L3+=titleSmall 14 Bold, 上 10 下 2
//   圆点: "•" primary 12sp + 间距 8, 缩进 6, 行距 2; 段落行距 2; 链接 accent+下划线
private struct MarkdownChangelog: View {
    @Environment(\.localWakeUpColors) private var colors
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(MarkdownBlocks.parse(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlocks.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    bulletRow(item)
                }
            }
        case .paragraph(let text):
            Text(inlineText(text))
                .font(.system(size: 12)) // ← bodySmall 12sp
                .foregroundColor(colors.onSurfaceVariant)
                .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        // ← titleLarge 22 / titleMedium 16 / titleSmall 14, 均 Bold
        let size = level == 1 ? 22.0 : (level == 2 ? 16.0 : 14.0)
        Text(inlineText(text))
            .font(.system(size: size, weight: .bold))
            .foregroundColor(colors.onSurfaceVariant)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private func bulletRow(_ item: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("•")
                .font(.system(size: 12))
                .foregroundColor(colors.primary)
            Spacer().frame(width: 8)
            Text(inlineText(item))
                .font(.system(size: 12))
                .foregroundColor(colors.onSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 6)
        .padding(.vertical, 2)
    }

    /// ← inlineAnnotated: 链接 accent+下划线; 粗体/行内代码由 AttributedString(markdown:) 原生呈现
    private func inlineText(_ text: String) -> AttributedString {
        var attr = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in attr.runs where run.link != nil {
            attr[run.range].foregroundColor = colors.primary
            attr[run.range].underlineStyle = .single
        }
        return attr
    }
}
