// JwWebViewLoginScreen.swift — ← ui/screen/imports/JwWebViewLoginScreen.kt (515 行)
// 教务 WebView 登录页。
// Android WebView+JS 桥 → WKWebView + WKScriptMessageHandler:
//   - loadUrl("javascript:") → evaluateJavaScript(直接回调, 无需桥)
//   - addJavascriptInterface(__sleepyBridge) → WKScriptMessageHandler(name: "__sleepyBridge")
//   - SSL 自签 proceed → 不实现(WKWebView 默认拒绝;ATS 例外需 Info.plist, 保守不放开)
//   - 新窗(target=_blank/window.open) → NavUIDelegate.createWebViewWith 在当前
//     webview 内加载(Android WebView 默认语义); 无它教务卡片点不动(a.v.1.0.41)
//   - 桌面 UA 切换(#18) → TopBar 原生按钮: customUserAgent + reload
//     ← Android key(recreateKey) 销毁重建(UA 仅创建期可靠)
//   - 刷新 → TopBar 原生按钮 webView.reload(), 进度走 estimatedProgress KVO
// 抓 HTML: document.documentElement.outerHTML + iframe/frame 合并(同一份 JS)。
// wisedu(金智) 协议: WebView 内 fetch 课表 JSON(WISEDU_FETCH_JS 原文移植)。

import SwiftUI
import WebKit

// ← DESKTOP_USER_AGENT: Chrome 121 / Windows 10 桌面 UA — 无 Android/iPhone 词汇,
// 触发门户桌面版布局(UCAS SEP 等门户手机 UA 下无"个人课表"入口)
private let jwDesktopUserAgent =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " +
    "Chrome/121.0.0.0 Safari/537.36"

struct JwWebViewLoginScreen: View {
    // (WISEDU_FETCH_JS 定义在文件尾 WiseduFetchJs enum; 前置引用走 static)

    @Environment(\.localWakeUpColors) private var colors
    let school: JwSchoolInfo
    // termStartDate ← Android JwWebViewLoginScreen 第 4 回调参数: JSON 直连协议
    // (boya_pp 等) 从接口拿到的第一周周一, 供确认页开学日期预填; 无则空串
    let onHtmlCaptured: (String, JwSchoolInfo, [(Int, String, String)], String) -> Void
    let onDismiss: () -> Void

    @State private var progress: Double = 0
    @State private var webViewCoordinator: WebViewCoordinator? = nil
    @State private var snackMessage: String? = nil
    // ← desktopUa = remember { mutableStateOf(false) } — 默认手机 UA。
    // Android 本屏无持久化(纯会话态, 离开页面即重置), iOS @State 等价
    @State private var desktopUa = false

    var body: some View {
        VStack(spacing: 0) {
            // TopBar(校名 + 协议名)
            HStack {
                Button(action: onDismiss) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24))   // ← Android ArrowBack 默认 24dp regular
                        .foregroundColor(colors.onBackground)
                }
                .buttonStyle(SleepyButtonStyle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(school.name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(colors.onBackground)
                    Text(JwProtocol.displayName(school.type))
                        .font(.system(size: 12))
                        .foregroundColor(colors.onSurfaceVariant)
                }
                Spacer()
                // ← actions UA IconButton(#18): 部分门户手机 UA 下无"个人课表"入口。
                // 图标随状态切换: 手机 UA → Computer(点了变桌面), 桌面 UA → PhoneAndroid
                // (点了回手机); enabled = webViewRef != null
                Button(action: toggleDesktopUa) {
                    Image(systemName: uaToggleSymbol)
                        .font(.system(size: 24))   // ← M3 Icon 24dp
                        .frame(width: 40, height: 40)   // ← M3 IconButton 40×40
                        .foregroundColor(webViewCoordinator == nil
                            ? colors.onSurface.opacity(0.38)   // ← disabled: onSurface 38%
                            : colors.onBackground)   // ← actionIconContentColor
                }
                .buttonStyle(SleepyButtonStyle())
                .disabled(webViewCoordinator == nil)
                // ← contentDescription: jw_toggle_mobile_ua / jw_toggle_desktop_ua
                .accessibilityLabel(L10n.format(desktopUa ? "jw_toggle_mobile_ua"
                                                          : "jw_toggle_desktop_ua"))
                .accessibilityIdentifier("jw_toggle_ua")
                // ← actions 刷新 IconButton: webViewRef?.reload(); 刷新进度表现由
                // estimatedProgress KVO 驱动上方进度条(Android progress 1..99 同判)
                Button(action: { webViewCoordinator?.reload() }) {
                    Image(systemName: "arrow.clockwise")   // ← Icons.Outlined.Refresh
                        .font(.system(size: 24))
                        .frame(width: 40, height: 40)
                        .foregroundColor(webViewCoordinator == nil
                            ? colors.onSurface.opacity(0.38)
                            : colors.onBackground)
                }
                .buttonStyle(SleepyButtonStyle())
                .disabled(webViewCoordinator == nil)
                .accessibilityLabel(L10n.format("jw_refresh"))   // ← contentDescription
                .accessibilityIdentifier("jw_refresh")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(colors.background)

            ZStack(alignment: .top) {
                JwWebView(
                    url: school.url.isEmpty ? "https://www.baidu.com" : school.url,
                    onProgressChange: { p in progress = p },
                    onCoordinatorCreated: { coordinator in webViewCoordinator = coordinator },
                    onHtmlCaptured: { html in onHtmlCaptured(html, school, [], "") },
                    onWiseduResult: handleWiseduResult)

                if progress >= 1 && progress < 100 {
                    ProgressView(value: progress / 100)
                        .tint(colors.primary)
                        .frame(height: 3)
                        .padding(.top, 4)
                }
            }

            // CaptureBar
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.format("jw_after_login"))
                        .font(.system(size: 12))
                        .foregroundColor(colors.onSurfaceVariant)
                    Text(L10n.format("jw_nav_hint"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colors.onSurface)
                }
                Spacer()
                Button(action: capture) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 24))   // ← Android CheckCircle 默认 24dp
                        Text(L10n.format("jw_import_page"))
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(webViewCoordinator == nil
                        ? colors.onSurface.opacity(0.38)   // ← Android disabled: onSurface 38%
                        : colors.onPrimary)
                    .padding(.horizontal, 24)   // ← M3 Button ContentPadding 24/8 (高 40)
                    .padding(.vertical, 8)
                    .background(webViewCoordinator == nil
                        ? colors.onSurface.opacity(0.12)   // ← Android disabled: onSurface 12% 容器
                        : colors.primary)
                    .cornerRadius(SleepyShapes.extraLarge)
                }
                .buttonStyle(SleepyButtonStyle())
                .disabled(webViewCoordinator == nil)   // ← Android enabled = webViewRef != null
            }
            .padding(16)
            .background(colors.surface)
        }
        .overlay(alignment: .bottom) {
            if let msg = snackMessage {
                Text(msg)
                    .font(.system(size: 14)) // ← Android Snackbar bodyMedium 14
                    .foregroundColor(colors.onSurface)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(colors.surfaceContainerHighest)
                    .cornerRadius(8)
                    .padding(.bottom, 80)
                    .task(id: msg) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation { snackMessage = nil }
                    }
            }
        }
    }

    // ← Icons.Outlined.Computer / PhoneAndroid; "iphone" SF Symbol 需 iOS16, 低版本回退
    private var uaToggleSymbol: String {
        guard desktopUa else { return "desktopcomputer" }
        if #available(iOS 16.0, *) { return "iphone" }
        return "phone"
    }

    // ← actions UA IconButton onClick: desktopUa = !desktopUa; uaSwitchReload++。
    // Android 因 UA 仅创建期可靠而销毁重建 WebView(cookie 全局共享、当前 URL 保留);
    // iOS 等价 customUserAgent(对 reload/后续导航生效)+ reload — cookie 走默认共享
    // WKWebsiteDataStore。先设 UA 再 reload, 顺序不可反(← 创建期生效语义)
    private func toggleDesktopUa() {
        guard webViewCoordinator != nil else { return }
        desktopUa.toggle()
        webViewCoordinator?.applyDesktopUserAgent(desktopUa)
    }

    // ← CaptureBar onCapture
    private func capture() {
        guard let coordinator = webViewCoordinator else {
            snackMessage = L10n.format("jw_webview_not_ready")
            return
        }
        snackMessage = L10n.format("jw_fetching")
        // wisedu (金智): 课表数据在 JSON API, fetch 拿 JSON(结果走 JS 桥回调)
        if school.type == JwProtocol.TYPE_WISEDU {
            coordinator.evaluate(WiseduFetchJs.js)
            return
        }
        // CQU(重庆大学门户): 同走 JS 桥 fetch 四个 REST API, Bearer token 取自 localStorage
        if school.type == JwProtocol.TYPE_CQU {
            coordinator.evaluate(CquFetchJs.js)
            return
        }
        // 博雅研究生平台 (/pp/ 前端, 首校燕山大学研究生): term 列表取学期+开学日 →
        // setting/current 取节次时间 → 逐周 byStudent 全学期排课行
        if school.type == JwProtocol.TYPE_BOYA_PP {
            coordinator.evaluate(BoyaPpFetchJs.js)
            return
        }
        // 强智移动教务 SPA: 课表只在移动 JSON API 里 (token header 鉴权), 页面 HTML
        // 无课程数据。先相对路径 serverconfig.json (免鉴权) 发现 ApiUrl, 再带
        // sessionStorage.Token 逐周抓课表合并成 {weeks:[…]} 组合源。
        if school.type == JwProtocol.TYPE_QZ_APP {
            coordinator.evaluate(QzAppFetchJs.js)
            return
        }
        // 同步 evaluateJavascript 拿 HTML(iframe/frame 合并)
        let js = """
        (function() {
            try {
                var ifrs = document.getElementsByTagName('iframe');
                var iframeContent = '';
                for (var i = 0; i < ifrs.length; i++) {
                    try { iframeContent += ifrs[i].contentDocument.documentElement.outerHTML; } catch(e) {}
                }
                var frs = document.getElementsByTagName('frame');
                var frameContent = '';
                for (var i = 0; i < frs.length; i++) {
                    try { frameContent += frs[i].contentDocument.documentElement.outerHTML; } catch(e) {}
                }
                var html = (document.documentElement && document.documentElement.outerHTML) || '';
                JSON.stringify({ok:true, url:location.href, len:html.length+iframeContent.length+frameContent.length, html:html+iframeContent+frameContent});
            } catch(err) {
                JSON.stringify({ok:false, err:String(err)});
            }
        })();
        """
        coordinator.evaluate(js) { raw in
            guard let raw = raw, raw != "null", !raw.isEmpty,
                  let data = raw.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                snackMessage = L10n.format("jw_fetch_failed_no_response")
                return
            }
            guard (obj["ok"] as? Bool) == true,
                  let html = obj["html"] as? String, !html.isEmpty else {
                let err = (obj["err"] as? String) ?? ""
                snackMessage = L10n.format("jw_fetch_failed",
                                           err.isEmpty ? L10n.format("jw_page_not_loaded") : err)
                return
            }
            onHtmlCaptured(html, school, [], "")
        }
    }

    // ← handleWiseduResult: {ok:true,data:...} / {ok:false,err:...}
    private func handleWiseduResult(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            snackMessage = L10n.format("jw_fetch_format_error")
            return
        }
        if (obj["ok"] as? Bool) == true {
            guard let content = obj["data"] as? String, !content.isEmpty else {
                snackMessage = L10n.format("jw_fetch_failed_no_response")
                return
            }
            var periods: [(Int, String, String)] = []
            if let arr = obj["periods"] as? [[String: Any]] {
                for (i, p) in arr.enumerated() {
                    let node = (p["node"] as? NSNumber)?.intValue ?? (i + 1)
                    periods.append((node, p["start"] as? String ?? "", p["end"] as? String ?? ""))
                }
            }
            // 学期起始日: boya_pp 等 JSON 直连协议随 payload 回传 termBeginTime 前 10 位
            let termStartDate = (obj["startDate"] as? String) ?? ""
            onHtmlCaptured(content, school, periods, termStartDate)
        } else {
            let err = (obj["err"] as? String) ?? ""
            snackMessage = L10n.format("jw_fetch_failed",
                                       err.isEmpty ? L10n.format("jw_page_not_loaded") : err)
        }
    }
}

// MARK: - 新窗拦截(← Android WebView 默认"当前页打开新窗"语义)

/// WKUIDelegate: 拦截 target="_blank" / window.open, 在当前 webview 内加载。
/// 无此 delegate 时 WKWebView 静默丢弃新窗请求 → 教务卡片点不动。
/// shared 单例: 每个 JwWebViewLoginScreen 建新 coordinator, 但 delegate 行为无状态。
final class NavUIDelegate: NSObject, WKUIDelegate {
    static let shared = NavUIDelegate()

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        // 非 http(s)(如 about:blank / javascript:)不接管, 返回 nil 丢弃
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        // 在当前 webview 内加载(对齐 Android WebView 默认行为)
        webView.load(URLRequest(url: url))
        return nil
    }
}

// MARK: - WKWebView 包装 ← JwWebView

/// WKWebView 协调器(← WebView + WebViewClient + WebChromeClient + JS 桥)
final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var webView: WKWebView?
    private let onProgressChange: (Double) -> Void
    private let onHtmlCaptured: (String) -> Void
    private let onWiseduResult: (String) -> Void
    private var progressObserver: NSKeyValueObservation?

    init(onProgressChange: @escaping (Double) -> Void,
         onHtmlCaptured: @escaping (String) -> Void,
         onWiseduResult: @escaping (String) -> Void) {
        self.onProgressChange = onProgressChange
        self.onHtmlCaptured = onHtmlCaptured
        self.onWiseduResult = onWiseduResult
        super.init()
    }

    func makeWebView(url: URL) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKPreferences()
        prefs.javaScriptCanOpenWindowsAutomatically = true
        config.preferences = prefs
        // ← addJavascriptInterface(__sleepyBridge) → ScriptMessageHandler
        config.userContentController.add(self, name: "__sleepyBridge")

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        // ★ 教务系统功能卡片大量使用 target="_blank" / window.open。
        //   Android WebView 默认在当前 WebView 内打开新窗; WKWebView 无 UIDelegate
        //   时静默丢弃新窗请求 → 用户卡在教务中间页点卡片无反应(a.v.1.0.41 修复)。
        //   NavUIDelegate 拦截 createWebViewWith, 在当前 webview 内加载新窗 URL。
        wv.uiDelegate = NavUIDelegate.shared
        // ← settings: domStorage WKWebView 默认开; 缩放手势
        wv.allowsBackForwardNavigationGestures = true

        // estimatedProgress KVO(← onProgressChanged)
        progressObserver = wv.observe(\.estimatedProgress, options: .new) { [weak self] _, change in
            DispatchQueue.main.async {
                self?.onProgressChange((change.newValue ?? 0) * 100)
            }
        }
        wv.load(URLRequest(url: url))
        webView = wv
        return wv
    }

    func evaluate(_ js: String, completion: ((String?) -> Void)? = nil) {
        webView?.evaluateJavaScript(js) { result, _ in
            completion?(result as? String)
        }
    }

    // ← Android UA 切换 = key(recreateKey) 销毁重建 (userAgentString 仅创建期可靠)。
    // WKWebView 的 customUserAgent 设置后对 reload/后续导航即生效, set + reload 等价;
    // 传 nil 恢复默认手机 UA(← Android 重建时不设 userAgentString)
    func applyDesktopUserAgent(_ desktop: Bool) {
        guard let wv = webView else { return }
        wv.customUserAgent = desktop ? jwDesktopUserAgent : nil
        wv.reload()
    }

    // ← actions 刷新 IconButton onClick: webViewRef?.reload()
    func reload() {
        webView?.reload()
    }

    // ← @JavascriptInterface onWiseduResult
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "__sleepyBridge" else { return }
        if let body = message.body as? [String: Any],
           let json = body["json"] as? String {
            DispatchQueue.main.async { self.onWiseduResult(json) }
        }
    }
}

struct JwWebView: UIViewRepresentable {
    let url: String
    let onProgressChange: (Double) -> Void
    let onCoordinatorCreated: (WebViewCoordinator) -> Void
    let onHtmlCaptured: (String) -> Void
    let onWiseduResult: (String) -> Void

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(onProgressChange: onProgressChange,
                           onHtmlCaptured: onHtmlCaptured,
                           onWiseduResult: onWiseduResult)
    }

    func makeUIView(context: Context) -> WKWebView {
        let wv = context.coordinator.makeWebView(
            url: URL(string: url) ?? URL(string: "https://www.baidu.com")!)
        // ★ coordinator 回传必须脱离 view-update 事务: makeUIView 在渲染事务内,
        //   同步写父视图 @State 会被 SwiftUI 丢弃 → capture() 永远拿到 nil,
        //   真机点"导入本页"必弹 "WebView 未就绪"(2026-09-04 6sp 真机实测)
        DispatchQueue.main.async { self.onCoordinatorCreated(context.coordinator) }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - WISEDU_FETCH_JS(逐行移植, 桥回调改 WKScriptMessage postMessage)

enum WiseduFetchJs {
    static let js = """
    (function(){
      try {
        if (location.hostname.indexOf('jwgl.hrbeu.edu.cn') < 0) {
          window.webkit.messageHandlers.__sleepyBridge.postMessage({json:JSON.stringify({ok:false, err:'请先登录并进入教务系统(jwgl.hrbeu.edu.cn)再点导入'})});
          return;
        }
        fetch('/jwapp/sys/wdkb/*default/index.do', {credentials:'include'})
        .then(function(){
          return fetch('/jwapp/sys/wdkb/modules/jshkcb/dqxnxq.do', {
            method:'POST',
            headers:{'X-Requested-With':'XMLHttpRequest'},
            credentials:'include'
          });
        })
        .then(function(r){ return r.json(); })
        .then(function(d){
          var rows = [];
          try { rows = d.datas.dqxnxq.rows || []; } catch(e) {}

          var xnxq = '';
          var selects = document.querySelectorAll('select');
          for (var i = 0; i < selects.length && !xnxq; i++) {
            var selected = selects[i].options && selects[i].options[selects[i].selectedIndex];
            var candidates = selected ? [selected.value, selected.textContent || ''] : [];
            for (var j = 0; j < candidates.length; j++) {
              var match = candidates[j].match(/20[0-9]{2}-20[0-9]{2}-[12]/);
              if (match && rows.some(function(row) { return String(row.DM || '') === match[0]; })) {
                xnxq = match[0];
                break;
              }
            }
          }
          if (!xnxq) {
            var active = document.querySelectorAll('.selected,.active,[aria-selected="true"]');
            for (var k = 0; k < active.length && !xnxq; k++) {
              var activeText = active[k].value || active[k].textContent || '';
              var activeMatch = activeText.match(/20[0-9]{2}-20[0-9]{2}-[12]/);
              if (activeMatch && rows.some(function(row) { return String(row.DM || '') === activeMatch[0]; })) {
                xnxq = activeMatch[0];
              }
            }
          }
          if (!xnxq) {
            var termNode = document.querySelector('[data-elem="XNXQMC"]');
            var termText = termNode ? (termNode.textContent || '') : '';
            var termMatch = termText.match(/(20[0-9]{2})-(20[0-9]{2})\\s*学年\\s*([12])\\s*学期/);
            if (termMatch) {
              var termDm = termMatch[1] + '-' + termMatch[2] + '-' + termMatch[3];
              xnxq = termDm;
            }
          }
          if (!xnxq) {
            var current = rows.find(function(row) {
              return row.DM && (row.SFDQ === '1' || row.SFDQ === 1 || row.CURRENT === '1' || row.current === true);
            });
            xnxq = current ? String(current.DM) : '';
          }
          if (!xnxq) throw new Error('无法识别当前选中的学期，请先在教务页面选择学期后再点导入');
          return fetch('/jwapp/sys/wdkb/modules/xskcb/xskcb.do', {
            method:'POST',
            headers:{'Content-Type':'application/x-www-form-urlencoded','X-Requested-With':'XMLHttpRequest'},
            body:'XNXQDM='+encodeURIComponent(xnxq),
            credentials:'include'
          }).then(function(r){ return r.text().then(function(txt){
            return {xnxq:xnxq, txt:txt};
          });});
        })
        .then(function(o){
          var periods = [];
          try {
            var nodes = document.querySelectorAll('[class*="jc"],[class*="jcdm"],[class*="jcbz"],[id*="node"],[id*="jc"]');
            var seen = {};
            for (var i = 0; i < nodes.length; i++) {
              var txt = (nodes[i].innerText || nodes[i].textContent || '').trim();
              var m = txt.match(/^([0-9]{1,2})[:\\s]+([0-2]?[0-9]:[0-5][0-9])[~～-]([0-2]?[0-9]:[0-5][0-9])$/);
              if (m && !seen[m[1]]) {
                seen[m[1]] = true;
                periods.push({node:parseInt(m[1],10), start:m[2], end:m[3]});
              }
            }
            if (periods.length === 0) {
              var allText = document.body.innerText || '';
              var re = /([0-9]{1,2})[:\\s]\\s*([0-2]?[0-9]:[0-5][0-9])[~～-]([0-2]?[0-9]:[0-5][0-9])/g;
              var mm;
              while ((mm = re.exec(allText)) !== null) {
                var n = parseInt(mm[1], 10);
                if (n >= 1 && n <= 20 && !seen[n]) {
                  seen[n] = true;
                  periods.push({node:n, start:mm[2], end:mm[3]});
                }
              }
            }
            periods.sort(function(a,b){ return a.node - b.node; });
          } catch(e) { periods = []; }
          window.webkit.messageHandlers.__sleepyBridge.postMessage({json:JSON.stringify({
            ok:true,
            data:o.txt,
            xnxq:o.xnxq,
            periods:periods
          })});
        })
        .catch(function(e){
          window.webkit.messageHandlers.__sleepyBridge.postMessage({json:JSON.stringify({ok:false, err:String(e)})});
        });
      } catch(err) {
        window.webkit.messageHandlers.__sleepyBridge.postMessage({json:JSON.stringify({ok:false, err:String(err)})});
      }
    })();
    """
}

// MARK: - CQU_FETCH_JS(← JwWebViewLoginScreen.kt CQU_FETCH_JS 原文移植, 桥回调改 WKScriptMessage postMessage)
//
// 重庆大学门户(my.cqu.edu.cn): localStorage 取 Bearer token → 串
// session/info-detail + my-table-detail + time-pattern 三接口, 学号取自 .trigger-user-name
// (复用 __sleepyBridge 回调通道, payload 同 wisedu {ok, data, periods})。
// 已知: 2026-06 起统一身份认证需动态验证码双因素, WebView 人工登录不受影响。

enum CquFetchJs {
    static let js = """
    (function(){
      try {
        if (location.hostname.indexOf('cqu.edu.cn') < 0) {
          window.webkit.messageHandlers.__sleepyBridge.postMessage({json:JSON.stringify({ok:false, err:'请先登录并进入重庆大学门户后再点导入'})});
          return;
        }
        var token = '';
        try { token = (localStorage.getItem('cqu_edu_ACCESS_TOKEN') || '').replaceAll('"', ''); } catch(e) {}
        if (!token) {
          window.webkit.messageHandlers.__sleepyBridge.postMessage({json:JSON.stringify({ok:false, err:'未取到登录凭据，请先登录 my.cqu.edu.cn 再点导入'})});
          return;
        }
        var studentId = '';
        try {
          var el = document.querySelector('.trigger-user-name');
          var m = el ? (el.innerText || '').match(/\\[(.*?)\\]/) : null;
          studentId = m ? m[1] : '';
        } catch(e) {}
        if (!studentId) {
          window.webkit.messageHandlers.__sleepyBridge.postMessage({json:JSON.stringify({ok:false, err:'页面上未找到学号，请确认已登录门户首页'})});
          return;
        }
        var auth = {credentials:'include', headers:{'Content-Type':'application/json', 'Authorization':'Bearer ' + token}};
        fetch('/api/resourceapi/session/info-detail', auth)
        .then(function(r){
          if (!r.ok) throw new Error('获取学期信息失败 HTTP ' + r.status);
          return r.json();
        })
        .then(function(session){
          var termId = session.curSessionId;
          if (!termId) throw new Error('学期信息里没有 curSessionId');
          var body = Object.assign({}, auth, {method:'POST', body: JSON.stringify([studentId])});
          return fetch('/api/timetable/class/timetable/student/my-table-detail?sessionId=' + encodeURIComponent(termId), body);
        })
        .then(function(r){
          if (!r.ok) throw new Error('获取课表失败 HTTP ' + r.status + '（登录态可能过期，请刷新重登）');
          return r.text();
        })
        .then(function(txt){
          var periods = [];
          return fetch('/api/workspace/time-pattern/session-time-pattern', auth)
          .then(function(r){ return r.ok ? r.json() : null; })
          .then(function(tp){
            try {
              var vos = (tp && tp.data && tp.data.classPeriodVOS) || [];
              for (var i = 0; i < vos.length; i++) {
                var v = vos[i];
                periods.push({
                  node: v.periodOrder || (i + 1),
                  start: v.startTime || '',
                  end: v.endTime || ''
                });
              }
              periods.sort(function(a,b){ return a.node - b.node; });
            } catch(e) { periods = []; }
            window.webkit.messageHandlers.__sleepyBridge.postMessage({json:JSON.stringify({ok:true, data:txt, periods:periods})});
          });
        })
        .catch(function(e){
          window.webkit.messageHandlers.__sleepyBridge.postMessage({json:JSON.stringify({ok:false, err:String(e)})});
        });
      } catch(err) {
        window.webkit.messageHandlers.__sleepyBridge.postMessage({json:JSON.stringify({ok:false, err:String(err)})});
      }
    })();
    """
}


// MARK: - BOYA_PP_FETCH_JS(← JwWebViewLoginScreen.kt BOYA_PP_FETCH_JS 原文移植, 桥回调改 WKScriptMessage postMessage)
//
// 博雅研究生平台 (/pp/ 前端, 首校燕山大学研究生 yjsxt.ysu.edu.cn): currentUser 取当前
// 学期名 → microForm/term 定学期 (termBeginTime/weekEnd 在此) → setting/current 取
// lessonConfig 节次时间 → 逐周 byStudent 并发拉全学期排课行合并成 {term, rows}。
// 实测不带 whichWeek 的 byStudent 只回不完整子集, 必须按 weekEnd 逐周抓; 单周偶发失败
// 静默跳过, 但 401 登录失效必须中止 (否则以部分数据伪装完整课表)。
// payload 额外带 startDate (termBeginTime 前 10 位) → 确认页开学日期预填。

enum BoyaPpFetchJs {
    static let js = """
    (function(){
      try {
        // 入口是燕大 CAS (cer.ysu.edu.cn), 登录后回调落到 yjsxt.ysu.edu.cn —
        // 只在平台域放行, CAS 页上点导入给出明确提示而非 404 请求
        if (location.hostname.indexOf('yjsxt.ysu.edu.cn') < 0 && location.pathname.indexOf('/pp/') < 0) {
          window.webkit.messageHandlers.__sleepyBridge.postMessage({json:JSON.stringify({ok:false, err:'请先完成统一身份认证登录并进入研究生平台后再点导入'})});
          return;
        }
        var hdrs = {'Protocol-Type': location.protocol.replace(/:/g, '')};
        try {
          var m = document.cookie.match(/(?:^|;\\s*)token=([^;]+)/);
          var tk = m ? decodeURIComponent(m[1]) : '';
          if (!tk) {
            var raw = sessionStorage.getItem('ROOT:APPSTORE');
            if (raw) { var j = JSON.parse(raw); if (j && j.token) tk = j.token; }
          }
          if (tk) hdrs['token'] = tk;
        } catch(e) {}
        var get = function(url){
          return fetch(url, {credentials:'include', headers:hdrs}).then(function(r){
            if (r.status === 401) throw new Error('登录态已失效，请重新登录研究生平台后再点导入');
            if (!r.ok) throw new Error('接口请求失败 HTTP ' + r.status);
            return r.json();
          }).then(function(j){
            if (!j || (j.code !== 200 && j.code !== '200')) {
              throw new Error((j && j.message) ? j.message : '接口返回异常');
            }
            return j.data;
          });
        };
        get('/api/login/currentUser')
        .then(function(u){ return (u && u.termName) ? String(u.termName) : ''; })
        .catch(function(){ return ''; })
        .then(function(termName){
          return get('/api/microForm/term').then(function(terms){
            var list = terms || [];
            var cur = null;
            for (var i = 0; i < list.length; i++) {
              if (termName && list[i].termName === termName) { cur = list[i]; break; }
              if (!termName && String(list[i].currentTerm) === '是') { cur = list[i]; }
            }
            if (!cur || !cur.termName) throw new Error('未找到当前学期，请确认已进入本学期课表页');
            return cur;
          });
        })
        .then(function(term){
          var T = term.termName;
          var periodsP = get('/api/schedule/class/setting/current?yearTerm=' + encodeURIComponent(T))
          .then(function(cfg){
            var periods = [];
            try {
              var lc = (cfg && cfg.lessonConfig) || [];
              for (var i = 0; i < lc.length; i++) {
                var t = lc[i].lessonTime || [];
                periods.push({
                  node: lc[i].lessonNumber || (i + 1),
                  start: String(t[0] || '').slice(11, 16),
                  end: String(t[1] || '').slice(11, 16)
                });
              }
              periods.sort(function(a, b){ return a.node - b.node; });
            } catch(e) { periods = []; }
            return periods;
          }).catch(function(){ return []; });
          // 总周数: weekEnd 优先 ("19"), 兜底按起止日推算, 再兜底 30
          var maxWeek = parseInt(term.weekEnd, 10);
          if (!(maxWeek >= 1 && maxWeek <= 30)) {
            try {
              var ms = new Date(term.termEndTime) - new Date(term.termBeginTime);
              maxWeek = Math.ceil(ms / (7 * 24 * 3600 * 1000));
            } catch(e) { maxWeek = 0; }
            if (!(maxWeek >= 1 && maxWeek <= 30)) maxWeek = 30;
          }
          var weekReqs = [];
          for (var w = 1; w <= maxWeek; w++) {
            weekReqs.push(
              get('/api/schedule/table/byStudent?page=0&size=500&whichWeek=' + w +
                  '&yearTerm=' + encodeURIComponent(T))
              .then(function(rows){ return rows || []; })
              .catch(function(e){
                // 单周偶发失败不致命, 静默跳过; 但 401 登录失效必须中止 —
                // 否则会以部分数据伪装成完整课表
                if (e && String(e.message || '').indexOf('登录态已失效') >= 0) throw e;
                return [];
              })
            );
          }
          return Promise.all([Promise.all(weekReqs), periodsP]).then(function(rs){
            var rows = [];
            for (var k = 0; k < rs[0].length; k++) rows = rows.concat(rs[0][k]);
            if (!rows.length) throw new Error('课表为空：请先在研究生平台"我的课表"页确认本学期已有课程');
            window.webkit.messageHandlers.__sleepyBridge.postMessage({json:JSON.stringify({
              ok: true,
              data: JSON.stringify({term: T, rows: rows}),
              periods: rs[1],
              startDate: String(term.termBeginTime || '').slice(0, 10)
            })});
          });
        })
        .catch(function(e){
          window.webkit.messageHandlers.__sleepyBridge.postMessage({json:JSON.stringify({ok:false, err:String(e && e.message || e)})});
        });
      } catch(err) {
        window.webkit.messageHandlers.__sleepyBridge.postMessage({json:JSON.stringify({ok:false, err:String(err)})});
      }
    })();
    """
}


// MARK: - QZ_APP_FETCH_JS(← JwWebViewLoginScreen.kt QZ_APP_FETCH_JS 原文移植, 桥回调改 WKScriptMessage postMessage)
//
// 强智移动教务 SPA (type=qz_app): 课表只在移动 JSON API 里 (token header 鉴权), 页面
// HTML 无课程数据。相对路径 serverconfig.json 免鉴权发现 ApiUrl (各校部署根可不同,
// 先试当前目录再试 /dist/serverconfig.json, 禁硬编码) → sessionStorage.Token 作 token
// 头请求。课表端点一次只回一周 (week= 空 = 当前教学周, data 恒单元素), 只抓当前周会把
// 仅在后续周出现的课整门丢掉 — 先 POST /teachingWeek 取周数列表, 再并行逐周 POST
// curriculum?week=w&kbjcmsid=, 合并成 {weeks:[<单次响应>…]} 组合源 (与燕大 boya_pp
// 逐周方案同构)。401 一律中止 (禁以部分数据伪装完整课表), 单周失败静默跳过。
// JS 只做 fetch 与传输层状态路由, 协议字段解码全部在 JwQzAppParser (跨语言 invariant)。

enum QzAppFetchJs {
static let js = """
    (function(){
      try {
        var post = function(obj){
          window.webkit.messageHandlers.__sleepyBridge.postMessage({json:JSON.stringify(obj)});
        };
        var token = '';
        try { token = sessionStorage.getItem('Token') || ''; } catch(e) {}
        if (!token) {
          post({ok:false, err:'未取到登录令牌: 请先登录移动教务后再点导入'});
          return;
        }
        var getCfg = function(url){
          return fetch(url, {credentials:'include'})
            .then(function(r){
              if (!r.ok) { throw new Error('serverconfig.json HTTP ' + r.status); }
              return r.json();
            });
        };
        getCfg('serverconfig.json')
          .catch(function(){
            return getCfg('/dist/serverconfig.json');
          })
          .then(function(cfg){
            var apiUrl = String(cfg.ApiUrl || '').replace(/\\/+$/,'');
            if (!apiUrl) { throw new Error('serverconfig.json 缺 ApiUrl'); }
            return apiUrl;
          })
          .then(function(apiUrl){
            var call = function(path){
              return fetch(apiUrl + path, {
                method:'POST',
                credentials:'include',
                headers: { 'token': token }
              }).then(function(r){ return r.text(); });
            };
            // 课表端点一次只回一周 (week= 空 = 当前教学周, data 单元素);
            // 只抓当前周会丢掉仅在后续周出现的课 — 先取 teachingWeek 周数列表,
            // 再并行逐周拉取合并 (与燕大 boya_pp 逐周方案同构)
            return call('/teachingWeek').then(function(twText){
              var weekNums = [];
              try {
                var tw = JSON.parse(twText);
                if (tw && tw.code != '401' && tw.data && tw.data.length) {
                  for (var i = 0; i < tw.data.length; i++) {
                    var n = parseInt(tw.data[i].week, 10);
                    if (n >= 1 && n <= 30) weekNums.push(n);
                  }
                }
              } catch(e) {}
              if (!weekNums.length) weekNums = [1];
              var expired = false;
              var reqs = weekNums.map(function(w){
                return call('/student/curriculum?week=' + w + '&kbjcmsid=')
                  .then(function(text){
                    try { if (JSON.parse(text).code == '401') expired = true; } catch(e) {}
                    return text;
                  })
                  .catch(function(){ return null; });
              });
              return Promise.all(reqs).then(function(texts){
                if (expired) {
                  post({ok:false, err:'登录已过期: 请重新登录后再点导入'});
                  return;
                }
                var ok = texts.filter(function(t){ return t !== null; });
                if (!ok.length) {
                  post({ok:false, err:'课表接口无响应: 请确认已登录并进入课表页'});
                  return;
                }
                post({ok:true, data: JSON.stringify({weeks: ok.map(function(t){
                  try { return JSON.parse(t); } catch(e) { return null; }
                }).filter(function(j){ return j !== null; })})});
              });
            });
          })
          .catch(function(e){
            post({ok:false, err:String(e && e.message || e)});
          });
      } catch(err) {
        window.webkit.messageHandlers.__sleepyBridge.postMessage({json:JSON.stringify({ok:false, err:String(err)})});
      }
    })()
    """
}
