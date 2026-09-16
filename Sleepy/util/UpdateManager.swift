// UpdateManager.swift — ← UpdateManager.kt
// 拉 GitHub/镜像 release 信息、下载 IPA、清理旧 IPA。不含 UI 状态。
//
// 平台差异表#2: Android REQUEST_INSTALL_PACKAGES 自装 APK →
// iOS 无自装;iOS 端 = 检查更新 + 展示 changelog + 下载 IPA 到本地(供 AltStore 侧载/隔空投送),
// 安装动作降级为「提示重新侧载」(由 UpdateChangelogDialog 移植体承担,见 SPEC 平台差异表)。

import Foundation
import Combine

enum UpdateManager {
    private static let GITHUB_API = "https://api.github.com/repos/lingion/sleepy-ios/releases/latest"
    private static let MIRROR_RELEASE = "https://gh.qdp.qzz.io/lingion/sleepy-ios/releases/latest"
    private static let MIRROR_PREFIX = "https://gh.qdp.qzz.io/lingion/sleepy-ios/releases/download/"

    /// 当前 App 版本(= Android BuildConfig.VERSION_NAME;iOS = CFBundleShortVersionString)
    static var currentVersionName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    /// 只拉 release 信息,不下载。GitHub 不通回退镜像。 ← fetchUpdateInfo
    static func fetchUpdateInfo() async throws -> UpdateInfo {
        // 主站
        if let json = try? await readText(GITHUB_API) {
            return parseReleaseJson(json, currentVersion: currentVersionName, abi: "ios")
        }
        // 镜像回退:正则取 tag,body 取不到
        let page = try await readText(MIRROR_RELEASE)
        guard let tag = firstMatch(of: #"/lingion/sleepy-ios/releases/tag/(v[0-9A-Za-z.+_-]+)"#, in: page) else {
            throw UpdateError.noVersionFound
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let url = "\(MIRROR_PREFIX)\(tag)/Sleepy.ipa"
        let isUpdate = VersionUtils.compare(version, currentVersionName) > 0
        return UpdateInfo(version: version, changelog: "", downloadUrl: url, isUpdateAvailable: isUpdate)
    }

    /// 下载 IPA 到 cachesDirectory,带进度回调(0-100)。cancel 时删半截文件。 ← downloadApk
    static func downloadIpa(_ info: UpdateInfo, onProgress: @escaping (Int) -> Void) async throws -> URL {
        guard !info.downloadUrl.isEmpty else { throw UpdateError.emptyDownload }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleepy-update-Sleepy.ipa")
        // ← conn.contentLengthLong(HEAD 先探)
        var request = URLRequest(url: URL(string: info.downloadUrl)!)
        var total = max(await contentLength(of: info.downloadUrl) ?? 1, 1)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse,
           let len = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), len > 0 {
            total = len
        }
        do {
            var data = Data()
            data.reserveCapacity(min(Int(total), 64 * 1024 * 1024))
            var downloaded = 0
            // ← while(true) { coroutineContext.ensureActive(); input.read(buf) }
            for try await b in bytes {
                try Task.checkCancellation()
                data.append(b)
                downloaded += 1
                onProgress(Int(min(Double(downloaded) * 100.0 / Double(total), 100.0)))
            }
            try data.write(to: target)
        } catch {
            // ← catch { target.delete(); throw }
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: target.path)
        let size = attrs?[.size] as? Int ?? 0
        if size == 0 { throw UpdateError.emptyDownload }
        return target
    }

    /// 启动时清理 cachesDirectory 中旧安装包。 ← cleanOldApk
    static func cleanOldIpa() {
        let dir = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.hasPrefix("sleepy-update-") {
            try? FileManager.default.removeItem(at: f)
        }
    }

    // ===== 网络底层 ← readText/request =====

    private static func readText(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw UpdateError.http(-1) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Sleepy/\(currentVersionName)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json,text/html,*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateError.http(http.statusCode)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func contentLength(of urlString: String) async -> Int? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse,
           let len = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), len > 0 {
            return len
        }
        return nil
    }

    /// ← Regex(...).find(page)?.groupValues?.get(1)
    private static func firstMatch(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    enum UpdateError: LocalizedError {
        case noVersionFound   // ← error_no_version_found
        case emptyDownload    // ← error_empty_download
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .noVersionFound: return L10n.t("error_no_version_found")
            case .emptyDownload: return L10n.t("error_empty_download")
            case .http(let code): return "HTTP \(code)"
            }
        }
    }
}


// ===== 1.0.51 移植: Markdown changelog 块级解析 ← util/MarkdownBlocks.kt =====

enum MarkdownBlocks {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case bullet(items: [String])
        case paragraph(text: String)
    }

    private static let headingRegex = try! NSRegularExpression(pattern: "^(#{1,6})\\s+(.*)$")
    private static let bulletRegex = try! NSRegularExpression(pattern: "^[-*+]\\s+(.*)$")

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var listItems: [String] = []
        var paragraphLines: [String] = []
        func flushList() {
            if !listItems.isEmpty { blocks.append(.bullet(items: listItems)); listItems = [] }
        }
        func flushParagraph() {
            if !paragraphLines.isEmpty {
                blocks.append(.paragraph(text: paragraphLines.joined(separator: " ")))
                paragraphLines = []
            }
        }
        for rawLine in markdown.components(separatedBy: .newlines) {
            let t = rawLine.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {                       // 空行 = 块边界
                flushList(); flushParagraph()
            } else if let g = captureGroups(headingRegex, t), g.count >= 2 {
                flushList(); flushParagraph()
                blocks.append(.heading(level: g[0].count, text: g[1]))
            } else if let item = captureGroups(bulletRegex, t)?.first {
                flushParagraph()
                listItems.append(item)
            } else {
                flushList()
                paragraphLines.append(t)
            }
        }
        flushList(); flushParagraph()
        return blocks
    }

    /// 正则捕获组(不含整串匹配), 无匹配返回 nil
    private static func captureGroups(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
    }
}

// ===== 1.0.51 移植: 自动检查更新开关持久化 ← AppPrefs.setUpdateCheckEnabled =====
// key 与 Android 完全一致; 未设置时默认开(← getBoolean(KEY_UPDATE_CHECK_ENABLED, true))

enum UpdateCheckPrefs {
    private static let key = "update_check_enabled"

    static var isEnabled: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: key) == nil ? true : d.bool(forKey: key)
    }

    static func setEnabled(_ v: Bool) {
        UserDefaults.standard.set(v, forKey: key)
    }
}

// ===== 1.0.51 移植: 冷启动检查更新 ← util/UpdateNotifier.kt =====
// 语义同 Android: 关开关→直接返回(不占一次性名额); 在途或已缓存→跳过(进程内只查一次);
// 失败静默(cache 保持 nil, 下次可再查); 关开关清缓存→横幅/高亮立即消失并取消在途请求。
// Android 在 MainActivity.onCreate 触发, iOS 无法改 App 入口, 由 AboutScreen.task 触发。

final class UpdateNotifier: ObservableObject {
    static let shared = UpdateNotifier()

    @Published private(set) var updateAvailable: UpdateInfo?
    private var inFlight: Task<Void, Never>?

    func maybeCheckOnStart() {
        guard UpdateCheckPrefs.isEnabled else { return }
        guard updateAvailable == nil, inFlight == nil else { return }
        inFlight = Task {
            do {
                let info = try await UpdateManager.fetchUpdateInfo()
                await MainActor.run {
                    self.inFlight = nil
                    if info.isUpdateAvailable { self.updateAvailable = info }
                }
            } catch {
                // 失败静默 ← runCatching { }: 用户没要求弹错
                await MainActor.run { self.inFlight = nil }
            }
        }
    }

    /// 用户在「关于」底部 Toggle 关闭后清空缓存, 立即消失横幅/高亮 ← clearCache()
    func clearCache() {
        inFlight?.cancel()
        inFlight = nil
        updateAvailable = nil
    }
}
