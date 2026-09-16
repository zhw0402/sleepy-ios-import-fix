// SleepyApp.swift — ← SleepyApp.kt + MainActivity.kt
// iOS App 壳: 全局依赖初始化 + 主题 Provider + 4 Tab 底栏 + overlay 导航 + 深链。
//
// 平台映射:
//   - SleepyApp.onCreate(通知调度/小组件刷新) → AppDelegate.init + didFinishLaunching
//   - MainActivity.setContent + AppRoot → WindowGroup { AppRoot }
//   - 深链 EXTRA_COURSE_ID → URL scheme sleepy://course/<id>(平台差异表#4)
//   - pendingImportText(外部 json 打开) → onOpenURL sleepy://import?text=

import SwiftUI
import UIKit
import GRDB
import WidgetKit

@main
struct SleepyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .environmentObject(appDelegate.rootViewModel)
        }
    }
}

// ← SleepyApp(Application): 全局依赖 + 通知调度 + 小组件刷新
class AppDelegate: NSObject, UIApplicationDelegate {
    let database: AppDatabase
    let repository: ScheduleRepository
    let notificationScheduler: NotificationScheduler
    let rootViewModel: AppRootViewModel

    override init() {
        database = AppDatabase.getShared()
        // UI 测试种子钩子: -SLEEPY_UI_TEST_SEED 1 → 清库+注入确定性测试数据
        // (XCUITest 无法直接触 DB;真实建表/导课走 UI 流程另有专项测试)
        if ProcessInfo.processInfo.arguments.contains("-SLEEPY_UI_TEST_SEED") {
            SleepyUITestSeeder.seed(database: AppDatabase.getShared())
        }
        repository = ScheduleRepository(database)
        notificationScheduler = NotificationScheduler.shared
        rootViewModel = AppRootViewModel(repository: repository)
        super.init()
        // ← onCreate: 通知调度器接 repo;数据变更 → 刷 widget + 重排通知
        notificationScheduler.repositoryProvider = { [weak self] in self?.repository }
        repository.onDataChangedHook = { [weak self] in
            guard let self = self else { return }
            WidgetCenter.shared.reloadAllTimelines()
            self.notificationScheduler.scheduleAll()
        }
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // ← onCreate: 首启刷新小组件(WidgetUpdater.notifyDataChanged)
        WidgetCenter.shared.reloadAllTimelines()
        // 高刷新率:iOS 无公开刷率 API(原 HighRefreshRate 桩已删),ProMotion 上
        // 系统自动调度 120Hz,无需 app 侧动作(2026-09-10 原生化审计)。
        return true
    }
}

// ← AppRoot 状态机(overlay 导航 + 深链)
@MainActor
final class AppRootViewModel: ObservableObject {
    enum Tab: Hashable { case schedule, today, manage, mine }
    // ★ OverlayScreen: 根浮层容器(自绘 ZStack)驱动; 右滑转场 + 跟手侧滑返回
    //   一处适配所有页——新增 case 自动获得同一套手势/转场, 无需逐页挂 recognizer。
    //   GeneralSettingsScreen 内嵌 NavigationView 容纳 HolidaySettings 嵌套跳转,
    //   其原生 pop 识别器按 UIKit 独占规则优先于容器侧滑。
    enum OverlayScreen: String, Identifiable {
        case addCourse, allTables, editTable, theme, general, export, reminder, about, license
        // holiday 由 GeneralSettings 内部 sheet 呈现,不再出现在根 enum
        var id: String { rawValue }
    }

    @Published var currentTab: Tab = .schedule
    @Published var overlayScreen: OverlayScreen? = nil
    @Published var editingCourse: CourseEntity? = nil
    // ← Android b96c865b: 课表视图模式(周/网格)会话级真值, 与 currentTab 同级 —
    // tab 切换/overlay 都会整页移除 ScheduleScreen, 状态必须提层才存活; 初始化读启动默认
    @Published var scheduleViewMode: ViewMode = AppPrefs.shared.getStartView() == "cards" ? .cards : .full
    // ← rememberSaveable 导航参数(旋转恢复语义 — iOS 状态默认保留)
    @Published var editTableId: Int64? = nil
    @Published var pendingNewTableId: Int64? = nil
    @Published var previousDefaultTableId: Int64? = nil
    // 深链课程
    @Published var deepLinkCourse: CourseEntity? = nil
    // 语言切换重建 token(← Activity.recreate): L10n.didChange → 递增 → AppRoot 全树重建
    @Published var languageReload = 0
    // ★ v1.0.45 底栏 dock 样式: false=贴底, true=悬浮药丸
    //   ← Android v1.0.45 b0f8280;状态由 AppPrefs 持有, 监听 .didChange 自动反向同步
    @Published var navFloating: Bool = AppPrefs.shared.isNavDocked()

    private var langObserver: NSObjectProtocol?
    private var prefsObserver: NSObjectProtocol?

    let scheduleViewModel: ScheduleViewModel

    init(repository: ScheduleRepository) {
        scheduleViewModel = ScheduleViewModel(
            repo: repository,
            onWidgetsNeedReload: { WidgetCenter.shared.reloadAllTimelines() })
        langObserver = NotificationCenter.default.addObserver(
            forName: L10n.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.languageReload += 1
        }
        // ★ v1.0.45: 用户在设置页改 nav dock 偏好 → AppPrefs 写盘 → UserDefaults 发 .didChange →
        //   这里刷新 navFloating → PillNavigationBar 下一帧切 dockStyle 重建。
        prefsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let floating = AppPrefs.shared.isNavDocked()
            if self.navFloating != floating { self.navFloating = floating }
        }
    }

    deinit {
        if let langObserver { NotificationCenter.default.removeObserver(langObserver) }
        if let prefsObserver { NotificationCenter.default.removeObserver(prefsObserver) }
    }

    // ← BackHandler: overlay 返回(pendingNewTable 丢弃链)
    func handleBack() {
        if let discardId = pendingNewTableId {
            let fallback = previousDefaultTableId
            pendingNewTableId = nil
            previousDefaultTableId = nil
            scheduleViewModel.discardNewTable(discardId, fallbackId: fallback)
            overlayScreen = nil
            editTableId = nil
        } else {
            overlayScreen = nil
            editingCourse = nil
            editTableId = nil
        }
    }

    // ← 新建空表(AllTables / Management 共用)
    func createNewTableThenEdit() {
        let previousId = scheduleViewModel.state.currentTable?.id
        // Select immediately so the editor has a synchronous currentTable while the
        // GRDB observation catches up; handleBack() still rolls it back if discarded.
        let newId = scheduleViewModel.createEmptyTable(commitSelection: true)
        previousDefaultTableId = previousId
        pendingNewTableId = newId
        editTableId = newId

        // A fullScreenCover(item:) cannot swap its active item in place. All Tables
        // is already presented when this callback fires, so close that cover first
        // and present the editor on the next run loop after its dismissal begins.
        if overlayScreen == .allTables {
            overlayScreen = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.pendingNewTableId == newId else { return }
                self.overlayScreen = .editTable
            }
        } else {
            overlayScreen = .editTable
        }
    }

    // ← 深链: sleepy://course/<id>
    func handleDeepLinkCourse(_ id: Int64) {
        if deepLinkCourse?.id == id { return }
        let repo = ScheduleRepository(AppDatabase.getShared())
        if let course = try? repo.getCourse(id) {
            deepLinkCourse = course
        }
    }
}

// ← AppRoot composable
struct AppRoot: View {
    @EnvironmentObject var root: AppRootViewModel
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.localWakeUpColors) private var colors
    // ← themeMode/手动切主题联动
    @State private var themeMode: String = AppPrefs.shared.getThemeMode()
    @State private var themeKey: String = AppPrefs.shared.getThemeKey()
    @State private var jwImportActive = false
    // ★ iOS 16 sheet 冲突修复: ImportSheet 关闭动画中直接 present JwImportFlow
    //   会被 SwiftUI 丢弃(同一 runloop 两个 sheet 状态翻转)→ 延到 dismiss 完成。
    @State private var jwImportRequested = false

    var body: some View {
        // iOS 15 兼容(6s Plus 真机 = 15.8.8):此处仅作容器,无 NavigationLink 压栈,
        // 旧 API 行为等价(NavigationStack 是 iOS16+ API)。
        // ★ v7.10.17 6sp 空白修复 v2: NavigationView 即使 .navigationBarHidden(true)
        //   在 iOS 15.6 stack 风格仍预占约 88pt 透明 navbar 区域(.navigationBarHidden
        //   在 16+ 才稳定生效,15 上是 best-effort) → 所有页面顶栏上方 112pt 纯空白。
        //   AppRoot 没有 NavigationLink 需求 → 直接 root,不要 NavigationView 壳。
        //   JwImportFlow 内部仍保留 NavigationView(那里有真正的 nav stack 行为)。
        // ★ 键盘避让只在 tab 层忽略(旧 fullScreenCover 时代对整个 mainContent 忽略);
        //   浮层走自绘 ZStack 容器, 保留键盘避让 → AddCourse 输入框自动避开键盘。
        mainContent
        // ← Activity.recreate(): 语言切换 → L10n.didChange → languageReload+1 → 全树重建
        .id(root.languageReload)
        .modifier(SleepyThemeProvider(darkTheme: isDark, themeKey: themeKey))
        .preferredColorScheme(schemeOverride)
        .onOpenURL { url in
            handleDeepLink(url)
        }
        // ★ Xcode14/iOS16.4 模拟器: XCUIApplication.open(_:) 丢 URL(只 launch 不投递,
        //   SpringBoard 收不到 with-url 请求)→ UI 测试改由 app 内自触发
        //   UIApplication.open 走真实系统路由。真实用户路径 onOpenURL 不变。
        .onAppear {
            if let raw = ProcessInfo.processInfo.environment["SLEEPY_UI_TEST_OPENURL"],
               let url = URL(string: raw) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    UIApplication.shared.open(url)
                }
            }
            // ← SleepyApp.onCreate: 预加载当年+明年节假日数据(磁盘/网络)
            Task { await HolidayManager.preload() }
        }
        // 深链课程 → 编辑(← LaunchedEffect(deepLinkCourse?.id))
        .onChange(of: root.deepLinkCourse?.id) { courseId in
            if courseId != nil {
                root.editingCourse = root.deepLinkCourse
                root.deepLinkCourse = nil
            }
        }
        // pendingImportText → 自动切 Manage + 弹导入(← LaunchedEffect(pendingImportText))
        .onChange(of: PendingImportText.value) { text in
            if text != nil {
                root.currentTab = .manage
            }
        }
        .sheet(isPresented: $jwImportActive) {
            JwImportFlow {
                jwImportActive = false
            }
            // Sheet 是独立 presentation tree；显式注入主题，避免自定义颜色环境回落到 lightScheme。
            .modifier(SleepyThemeProvider(darkTheme: isDark, themeKey: themeKey))
            .preferredColorScheme(schemeOverride)
        }
        // ★ sheet 冲突修复续: ImportSheet dismiss 完成后(0.45s 动画)再 present JW 流程
        .onChange(of: jwImportRequested) { req in
            guard req else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if jwImportRequested {
                    jwImportActive = true
                    jwImportRequested = false
                }
            }
        }
    }

    // ← AppPrefs.isDarkMode(context, systemDark)
    private var isDark: Bool {
        AppPrefs.shared.isDarkMode(isSystemDark: systemScheme == .dark)
    }

    // ← Android isSystemInDarkTheme() 真跟随: system 模式传 nil(不强制覆盖)。
    //   preferredColorScheme 非 nil 会把 @Environment(\.colorScheme) 锁成被覆盖的值,
    //   导致控制中心切换深浅色时 app 永远不跟 → "跟随系统"是假的。nil = 原生跟随。
    private var schemeOverride: ColorScheme? {
        themeMode == AppPrefs.THEME_MODE_SYSTEM ? nil : (isDark ? .dark : .light)
    }

    @ViewBuilder
    private var mainContent: some View {
        // ★ 根浮层 = 自绘 ZStack 容器(PresentOverlay):
        //   - 所有 OverlayScreen 页共用一份右滑转场 + 跟手侧滑返回驱动
        //   - 状态机(handleBack/pendingNewTable 丢弃链/深链)时序不变
        //   - holiday 子页由 GeneralSettings 内部 NavigationView 承载,不再列根
        // ★ type-check: 浮层内容仍走单一 PresentOverlay ViewModifier, 子树独立推导
        tabs
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .modifier(PresentOverlay(
                isDark: isDark,
                themeKey: themeKey,
                overlayScreen: $root.overlayScreen,
                editingCourse: root.editingCourse,
                editTableId: root.editTableId,
                pendingNewTableId: root.pendingNewTableId,
                scheduleViewModel: root.scheduleViewModel,
                themeMode: themeMode,
                onDismiss: { root.overlayScreen = nil; root.editingCourse = nil },
                onBack: { root.handleBack() },
                onSavedAdd: {
                    root.overlayScreen = nil
                    root.editingCourse = nil
                    root.currentTab = .schedule
                },
                onSavedTable: {
                    root.overlayScreen = nil
                    root.editTableId = nil
                    root.pendingNewTableId = nil
                    root.previousDefaultTableId = nil
                },
                onDeletedTable: {
                    root.overlayScreen = nil
                    root.editTableId = nil
                    root.currentTab = .schedule
                },
                onCreateNewTable: { root.createNewTableThenEdit() },
                onOpenEditTable: { tableId in
                    root.editTableId = tableId
                    root.pendingNewTableId = nil
                    root.overlayScreen = .editTable
                },
                onThemeModeChange: { mode in
                    themeMode = mode
                    themeKey = AppPrefs.shared.getThemeKey()
                },
                // ← Android themeKeyFlow.collectAsState: 选主题色即时下发全树,
                //   不再等重进页面/重启(AppRoot.themeKey 是一次性 @State,必须回写)
                onThemeKeyChange: {
                    themeKey = AppPrefs.shared.getThemeKey()
                },
                onOpenLicense: { root.overlayScreen = .license }))
    }

    // ← Scaffold + PillNavigationBar + 4 Tab
    // ★ v2.7 dock 模式二态:
    //   - docked:  VStack(content + bar) → bar 贴底 76pt 占用下方(老行为)
    //   - floating: ZStack(alignment: .bottom) + content fillMaxSize 直通屏底 +
    //              bar 作为 overlay 浮在底部 12pt 上(背景延续,无空缺)。
    //              ← Android ff66ddd "dock 模式弃 Scaffold bottomBar 占位, Box overlay
    //                Align.BottomCenter 叠加; 内容 fillMaxSize 直通屏幕底" 1:1。
    //   scroll padding 补偿 floatingScrollBottomPadding pt(FAB 式滚动余量),
    //   保证最后一行课程不被悬浮 bar 遮住(Android 同位 LocalNavExtraBottomPadding)。
    private var tabs: some View {
        Group {
            if root.navFloating {
                floatingTabs
            } else {
                dockedTabs
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TabsCanvasBackground().ignoresSafeArea())
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    // 4 个 tab 的数据:共用于 docked / floating 两个分支,避免重复
    private var navItems: [PillNavItemData] {
        [
            PillNavItemData(id: "schedule", icon: "calendar",
                            label: L10n.format("tab_schedule"),
                            selected: root.currentTab == .schedule) { root.currentTab = .schedule },
            PillNavItemData(id: "today", icon: "doc.on.doc",
                            label: L10n.format("tab_today"),
                            selected: root.currentTab == .today) { root.currentTab = .today },
            PillNavItemData(id: "manage", icon: "gearshape",
                            label: L10n.format("tab_manage"),
                            selected: root.currentTab == .manage) { root.currentTab = .manage },
            PillNavItemData(id: "mine", icon: "person",
                            label: L10n.format("tab_mine"),
                            selected: root.currentTab == .mine) { root.currentTab = .mine },
        ]
    }

    // 当前 Tab 对应屏(ScheduleScreen / TodayScreen / ManagementPage / MineScreen)
    @ViewBuilder
    private var tabContent: some View {
        switch root.currentTab {
        case .schedule:
            ScheduleScreen(
                viewModel: root.scheduleViewModel,
                viewMode: $root.scheduleViewMode,
                onGoImport: { root.currentTab = .manage },
                onManualAdd: { root.overlayScreen = .addCourse },
                onCreateTable: { root.createNewTableThenEdit() },
                onEditCourse: { course in root.editingCourse = course })
        case .today:
            TodayScreen(viewModel: root.scheduleViewModel,
                        onEditCourse: { course in root.editingCourse = course })
        case .manage:
            ManagementPage(
                viewModel: root.scheduleViewModel,
                autoShowImportSheet: PendingImportText.value != nil,
                onJwImportRequested: { jwImportRequested = true },
                onCreateNewTableRequested: { root.createNewTableThenEdit() },
                onManualAdd: { root.overlayScreen = .addCourse },
                onEditCurrentTable: {
                    root.editTableId = nil
                    root.pendingNewTableId = nil
                    root.overlayScreen = .editTable
                },
                onExportRequested: { root.overlayScreen = .export },
                // ★ 导入完成链(← Android onImported: 关导入框+切课表 Tab;
                //   onOpenEditTable: 新导入表 → 打开表编辑页)
                onImported: {
                    // ← Android ce7f7924: 导入完成留在管理页(摘要卡就地刷新), 不再硬跳课表 Tab
                    PendingImportText.value = nil
                },
                onOpenEditTable: { tableId in
                    PendingImportText.value = nil
                    root.editTableId = tableId
                    root.pendingNewTableId = nil
                    root.overlayScreen = .editTable
                })
        case .mine:
            MineScreen(
                viewModel: root.scheduleViewModel,
                onOpenAllTables: { root.overlayScreen = .allTables },
                onOpenAppearance: { root.overlayScreen = .theme },
                onOpenGeneral: { root.overlayScreen = .general },
                onOpenExport: { root.overlayScreen = .export },
                onOpenReminder: { root.overlayScreen = .reminder },
                onOpenAbout: { root.overlayScreen = .about })
        }
    }

    // ★ docked 模式:bar 占用 76pt(老行为)
    private var dockedTabs: some View {
        VStack(spacing: 0) {
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PillNavigationBar(items: navItems, dockStyle: .docked)
        }
    }

    // ★ floating 模式:
    //   - ZStack overlay 让 bar 浮在内容之上,不占布局空间
    //   - ignoresSafeArea bottom 让内容背景直通屏幕底(无空缺)
    //   - 内容底部 padding = floatingScrollBottomPadding → FAB 式滚动余量,
    //     最后一节课不被悬浮 bar 遮挡(Android LocalNavExtraBottomPadding 同位)
    //   - bar alignment .bottom 自带 PillNavigationBar 内部 bottomFloat=12pt,
    //     浮在屏幕底 12pt 上(可视即"悬浮胶囊")
    //   - 同步把 floatingScrollBottomPadding 注入 .localNavExtraBottomPadding
    //     让 MineScreen/ManagementPage/TodayScreen/CourseTableView 自己读 →
    //     内部 padding(bottom, 16 + navExtra) 一字对齐 Android。
    private var floatingTabs: some View {
        ZStack(alignment: .bottom) {
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .bottom)
            PillNavigationBar(items: navItems, dockStyle: .floating)
        }
        .environment(\.localNavExtraBottomPadding, floatingScrollBottomPadding)
    }

    // FAB 式滚动余量 = capsuleHeight(64) + bottomFloat(12) + extra(12 视觉缓冲)
    // ← Android ff66ddd navHeight + fabPadding + WindowInsets.navigationBars
    private var floatingScrollBottomPadding: CGFloat {
        DockSpec.capsuleHeight + DockSpec.bottomFloat + 12
    }

    // ← handleDeepLinkIntent(平台差异表#4: Intent extras → URL scheme)
    private func handleDeepLink(_ url: URL) {
        // ★ 2026-09-16: 支持「用 Sleepy 打开文件」(Files/分享面板送来的 file:// URL)。
        //   旧实现第一行就是 guard url.scheme == "sleepy" → 文件打开被直接丢弃,
        //   表现为: 点文件选 Sleepy 打不开/导入无反应。
        if url.isFileURL {
            do {
                let text = try TextFileReader.read(url: url)
                PendingImportText.value = text
                root.currentTab = .manage
            } catch {
                let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                PendingImportFailure.value = detail
                root.currentTab = .manage
            }
            return
        }
        guard url.scheme == "sleepy" else { return }
        switch url.host {
        case "open":
            break   // widget 点击(sleepy://open) → 冷启/回前台即达
        case "course":
            if let id = Int64(url.lastPathComponent) {
                root.handleDeepLinkCourse(id)
            }
        case "import":
            // 分享扩展/其他 app 传文本: sleepy://import?text=...
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let text = comps.queryItems?.first(where: { $0.name == "text" })?.value {
                PendingImportText.value = text
                root.currentTab = .manage
            }
        default:
            break
        }
    }
}

// ★ v7.10.18 type-check v3: 9 个独立 PresentXxx ViewModifier, 每个只挂 1 个
//   presentation (.fullScreenCover 或 .sheet), 由 Group { EmptyView().modifier(...) }
//   在 mainContent 里链式挂载。每个 modifier 子树类型推导独立预算, 避免
//   "unable to type-check this expression in reasonable time"。
//   闭包走构造注入, AppRoot 显式传 root 派生值。

/// tabs 画布底色。★ 必须是独立子 View:AppRoot.colors 读的是
/// SleepyThemeProvider 之上的环境值(= WakeUpColorsKey.defaultValue = lightScheme),
/// 直接 `.background(colors.background)` 会让暗黑模式透出 #FEF7FF 白底
/// (切换控件行留白/卡片缝隙处可见)。子 View 在 provider 子树内解析 env → 主题正确。
private struct TabsCanvasBackground: View {
    @Environment(\.localWakeUpColors) private var colors

    var body: some View {
        colors.background
    }
}

private struct PresentOverlay: ViewModifier {
    let isDark: Bool
    let themeKey: String
    @Binding var overlayScreen: AppRootViewModel.OverlayScreen?
    let editingCourse: CourseEntity?
    let editTableId: Int64?
    let pendingNewTableId: Int64?
    let scheduleViewModel: ScheduleViewModel
    let themeMode: String
    let onDismiss: () -> Void
    let onBack: () -> Void
    let onSavedAdd: () -> Void
    let onSavedTable: () -> Void
    let onDeletedTable: () -> Void
    let onCreateNewTable: () -> Void
    let onOpenEditTable: (Int64) -> Void
    let onThemeModeChange: (String) -> Void
    let onThemeKeyChange: () -> Void
    let onOpenLicense: () -> Void

    // ← AppRoot.schemeOverride 同源: system 模式 nil = 真跟随系统
    private var schemeOverride: ColorScheme? {
        themeMode == AppPrefs.THEME_MODE_SYSTEM ? nil : (isDark ? .dark : .light)
    }

    // 浮层容器状态: shownScreen 镜像 activeScreen(带转场生命周期),
    // dragX = 侧滑跟手位移, dismissSeq 防过期定时器串页。
    @State private var shownScreen: AppRootViewModel.OverlayScreen?
    @State private var dragX: CGFloat = 0
    @State private var dismissSeq = 0

    // ← 原 fullScreenCover(item:) get 闭包语义: 深链直接置 editingCourse 也能呈现 addCourse
    private var activeScreen: AppRootViewModel.OverlayScreen? {
        if overlayScreen != nil { return overlayScreen }
        return editingCourse == nil ? nil : .addCourse
    }

    func body(content: Content) -> some View {
        // ★ 系统性手势适配: 所有 overlay 页共用一个自绘容器, 右滑转场 + 跟手侧滑返回。
        //   不再逐页挂 recognizer——以后新增 OverlayScreen case 自动获得同一套手势。
        ZStack {
            content
            if let screen = shownScreen {
                overlayContent(screen)
                    .offset(x: dragX)
                    .transition(.move(edge: .trailing))
            }
        }
        .onChange(of: activeScreen) { syncPresentation($0) }
        .onAppear {
            // 语言切换 → .id(languageReload) 整树重建 → 本修饰器 @State 复位 nil,
            // 但 VM.overlayScreen 仍持页 → 不恢复会把用户弹回根页
            // (Android Activity.recreate 保留当前页, 此处对齐)
            if shownScreen == nil, let active = activeScreen { shownScreen = active }
        }
    }

    private func syncPresentation(_ active: AppRootViewModel.OverlayScreen?) {
        if let screen = active {
            guard shownScreen != screen else { return }
            if shownScreen == nil {
                // 打开: 右缘滑入(对齐安卓 Activity 转场方向)
                dragX = 0
                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { shownScreen = screen }
            } else {
                // 极端竞态: 未经过 nil 直接换页 → 无动画切换, 复位位移
                shownScreen = screen
                dragX = 0
            }
        } else if shownScreen != nil {
            // 关闭路径①: 程序化关闭(✕ 按钮/保存/删除) → 右滑出动画后移除
            if dragX > 60 {
                shownScreen = nil
                dragX = 0
            } else {
                animateOutThen(then: {})
            }
        }
    }

    /// 关闭路径②: 侧滑过阈值 → 页面跟手滑出全程, 动画结束才回调 onBack(保持
    /// handleBack/createNewTableThenEdit 的状态机时序不变)。
    private func commitGestureDismiss(_ then: @escaping () -> Void) {
        animateOutThen(then: then)
    }

    private func animateOutThen(then: @escaping () -> Void) {
        let width = UIScreen.main.bounds.width
        withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) { dragX = width + 60 }
        dismissSeq += 1
        let seq = dismissSeq
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            guard seq == dismissSeq else { return }
            shownScreen = nil
            dragX = 0
            then()
        }
    }


    @ViewBuilder
    private func overlayContent(_ screen: AppRootViewModel.OverlayScreen) -> some View {
        switch screen {
        case .addCourse:
            AddCourseScreen(
                viewModel: scheduleViewModel,
                onDismiss: onDismiss,
                onSaved: onSavedAdd,
                editingCourse: editingCourse)
                .themedOverlay(isDark: isDark, themeKey: themeKey, schemeOverride: schemeOverride)
                .edgeBackGesture(dragX: $dragX, onBack: onDismiss, onCommit: commitGestureDismiss)
        case .allTables:
            AllTablesScreen(
                viewModel: scheduleViewModel,
                onDismiss: onDismiss,
                onCreateNewTable: onCreateNewTable,
                onOpenEditTable: onOpenEditTable)
                .themedOverlay(isDark: isDark, themeKey: themeKey, schemeOverride: schemeOverride)
                .edgeBackGesture(dragX: $dragX, onBack: onDismiss, onCommit: commitGestureDismiss)
        case .editTable:
            EditTableScreen(
                viewModel: scheduleViewModel,
                tableId: editTableId,
                pendingNewTableId: pendingNewTableId,
                onDismiss: onBack,
                onDiscardPending: onBack,
                onSaved: onSavedTable,
                onDeleted: onDeletedTable)
                .themedOverlay(isDark: isDark, themeKey: themeKey, schemeOverride: schemeOverride)
                .edgeBackGesture(dragX: $dragX, onBack: onBack, onCommit: commitGestureDismiss)
        case .general:
            GeneralSettingsScreen(onDismiss: onDismiss)
                .themedOverlay(isDark: isDark, themeKey: themeKey, schemeOverride: schemeOverride)
                .edgeBackGesture(dragX: $dragX, onBack: onDismiss, onCommit: commitGestureDismiss)
        case .theme:
            AppearanceScreen(
                onDismiss: onDismiss,
                themeMode: themeMode,
                onThemeModeChange: onThemeModeChange,
                onThemeKeyChange: onThemeKeyChange)
                .themedOverlay(isDark: isDark, themeKey: themeKey, schemeOverride: schemeOverride)
                .edgeBackGesture(dragX: $dragX, onBack: onDismiss, onCommit: commitGestureDismiss)
        case .export:
            ExportScreen(viewModel: scheduleViewModel, onDismiss: onDismiss)
                .themedOverlay(isDark: isDark, themeKey: themeKey, schemeOverride: schemeOverride)
                .edgeBackGesture(dragX: $dragX, onBack: onDismiss, onCommit: commitGestureDismiss)
        case .reminder:
            ReminderScreen(onDismiss: onDismiss)
                .themedOverlay(isDark: isDark, themeKey: themeKey, schemeOverride: schemeOverride)
                .edgeBackGesture(dragX: $dragX, onBack: onDismiss, onCommit: commitGestureDismiss)
        case .about:
            AboutScreen(onDismiss: onDismiss, onOpenLicense: onOpenLicense)
                .themedOverlay(isDark: isDark, themeKey: themeKey, schemeOverride: schemeOverride)
                .edgeBackGesture(dragX: $dragX, onBack: onDismiss, onCommit: commitGestureDismiss)
        case .license:
            LicenseScreen(onDismiss: onDismiss)
                .themedOverlay(isDark: isDark, themeKey: themeKey, schemeOverride: schemeOverride)
                .edgeBackGesture(dragX: $dragX, onBack: onDismiss, onCommit: commitGestureDismiss)
        }
    }
}

private extension View {
    func themedOverlay(isDark: Bool, themeKey: String, schemeOverride: ColorScheme?) -> some View {
        modifier(SleepyThemeProvider(darkTheme: isDark, themeKey: themeKey))
            .preferredColorScheme(schemeOverride)
    }
}
// ★ 系统性侧滑返回驱动: 一个 UIKit 边缘 pan 识别器桥接 SwiftUI 容器位移。
//   页面跟手移动、可取消;内层 UINavigationController(HolidaySettings)的
//   原生 pop 识别器按 UIKit 独占规则优先, 本识别器自动失败, 无双重返回。
private struct OverlayBackDriver: UIViewControllerRepresentable {
    let onProgress: (CGFloat) -> Void
    let onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> EdgeBackDriverVC {
        EdgeBackDriverVC(onProgress: onProgress, onFinish: onFinish)
    }

    func updateUIViewController(_ controller: EdgeBackDriverVC, context: Context) {
        controller.onProgress = onProgress
        controller.onFinish = onFinish
    }
}

private final class EdgeBackDriverVC: UIViewController, UIGestureRecognizerDelegate {
    var onProgress: (CGFloat) -> Void
    var onFinish: (Bool) -> Void
    private weak var installedView: UIView?
    private var committed = false

    init(onProgress: @escaping (CGFloat) -> Void, onFinish: @escaping (Bool) -> Void) {
        self.onProgress = onProgress
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        committed = false
        installRecognizerIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        installedView?.gestureRecognizers?.removeAll(where: { $0.delegate === self })
        installedView = nil
    }

    private func installRecognizerIfNeeded() {
        guard installedView == nil else { return }
        let hostView: UIView = parent?.view ?? self.view
        let recognizer = UIPanGestureRecognizer(target: self,
                                                action: #selector(handleEdgePan(_:)))
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        hostView.addGestureRecognizer(recognizer)
        installedView = hostView
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        let point = touch.location(in: gestureRecognizer.view)
        return point.x <= 30
    }

    // 独占: 内层原生 pop(HolidaySettings)先 begin 则本识别器失败, 避免双重返回
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    @objc private func handleEdgePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .changed:
            guard !committed else { return }
            onProgress(recognizer.translation(in: recognizer.view).x)
        case .ended:
            guard !committed else { return }
            let translation = recognizer.translation(in: recognizer.view)
            let velocity = recognizer.velocity(in: recognizer.view)
            let width = max(recognizer.view?.bounds.width ?? 1, 1)
            let commit = translation.x / width > 0.25 || velocity.x > 600
            committed = commit
            onFinish(commit)
        case .cancelled, .failed:
            if !committed { onFinish(false) }
        default:
            break
        }
    }
}

private extension View {
    /// 浮层页统一接入: 跟手位移写入容器 dragX, 过阈值由容器滑出后回调 onBack。
    func edgeBackGesture(dragX: Binding<CGFloat>,
                         onBack: @escaping () -> Void,
                         onCommit: @escaping (@escaping () -> Void) -> Void) -> some View {
        overlay {
            OverlayBackDriver(
                onProgress: { translation in
                    guard translation > 0 else { return }
                    dragX.wrappedValue = translation
                },
                onFinish: { commit in
                    if commit {
                        onCommit(onBack)
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                            dragX.wrappedValue = 0
                        }
                    }
                })
                .allowsHitTesting(false)
        }
    }
}
