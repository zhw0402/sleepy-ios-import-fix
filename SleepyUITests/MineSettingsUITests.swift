// MineSettingsUITests.swift — G5+ 我的页设置全交互面测试
// 覆盖: Mine 刷新小组件按钮(带 snackbar) + AllTables(切表/编辑入口/新建) +
//       Appearance(系统主题卡 + 3 态模式分段 + 预设网格) + General(5 张设置卡
//       展开收起 + 每卡内选项/开关 + 周可见日 7 行 + 语言 5 项) + Export(3 格式) +
//       Reminder(总开关 + 子开关 + 时间选择) + About(检查更新按钮)。

import XCTest

final class MineSettingsUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-SLEEPY_UI_TEST_SEED"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["pill_schedule"].waitForExistence(timeout: 10))
        app.descendants(matching: .any)["pill_mine"].tap()
        XCTAssertTrue(app.staticTexts["Me"].waitForExistence(timeout: 5))
    }

    override func tearDownWithError() throws {
        app.terminate()   // 隔离: 每用例杀进程重启, 防跨用例状态串扰
    }

    /// 自适应下滑直到元素在视口内(元素全量物化, exists≠可见; 不可见时 tap
    /// 落点出屏丢失 — 2026-09 基线腐化根因; 页面高度随版本变, 固定次数不可靠)
    @discardableResult
    private func scrollUntil(_ element: XCUIElement, maxSwipes: Int = 6) -> Bool {
        let screenH = app.windows.firstMatch.frame.height
        func visible() -> Bool {
            guard element.exists else { return false }
            let f = element.frame
            return f.minY >= 0 && f.maxY <= screenH
        }
        for _ in 0...maxSwipes {
            if visible() { return true }
            app.swipeUp()
        }
        return visible()
    }

    // MARK: 刷新小组件按钮 + snackbar 反馈

    func testRefreshWidgetsButtonShowsSnackbar() {
        let refreshBtn = app.descendants(matching: .any)["mine_refresh_widgets"]
        XCTAssertTrue(refreshBtn.waitForExistence(timeout: 3))
        refreshBtn.tap()
        // snackbar 2 秒
        XCTAssertTrue(app.staticTexts["All widgets refreshed"].waitForExistence(timeout: 3),
                      "点刷新应弹 snackbar")
    }

    // MARK: All Schedules — 切表 / 编辑入口 / 新建按钮

    /// a.v.1.0.41 热区回归: 点行内"空白区"(右端 Spacer 区, 离图标/文字最远)也应触发。
    /// 用户报障 = 点行色块不响应只有图标/文字才触发(SleepyButtonStyle 修复)。
    /// 代表行 2 条: mine_all_tables(普通导航) + mine_export(第二行, 验证同卡多行互不串扰)
    func testAllTablesRowBlankAreaTriggersNav() {
        let row = app.descendants(matching: .any)["mine_all_tables"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        // dx=0.92 → 行右端 8% 处: 文字在左侧, 此处为纯空白色块区
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["All Schedules"].waitForExistence(timeout: 5),
                      "点'所有课表'行右端空白区应跳转(SleepyButtonStyle 整行热区)")
    }

    func testExportRowBlankAreaTriggersNav() {
        let row = app.descendants(matching: .any)["mine_export"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Export Schedule"].waitForExistence(timeout: 5),
                      "点'导出'行右端空白区应跳转到导出页")
    }

    func testAllTablesSwitchAndEdit() {
        app.descendants(matching: .any)["mine_all_tables"].tap()
        XCTAssertTrue(app.staticTexts["All Schedules"].waitForExistence(timeout: 5))
        // 种子表"我的课表"为当前(checkmark)
        XCTAssertTrue(app.staticTexts["我的课表"].firstMatch.exists, "列表应有种子表")
        // 新建按钮存在
        XCTAssertTrue(app.staticTexts["New Schedule"].firstMatch.exists)
        // 表行的编辑齿轮(图标按钮)。锚点用 identifier: 6541178 起齿轮加了
        // accessibilityLabel("Settings"), SF Symbol 默认 "gear" 标签被覆盖 → label 匹配失效
        let gear = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'table_edit_'")).firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 3), "表行应有编辑齿轮")
    }

    func testAllTablesNewButtonOpensEditor() {
        app.descendants(matching: .any)["mine_all_tables"].tap()
        XCTAssertTrue(app.staticTexts["All Schedules"].waitForExistence(timeout: 5))
        app.staticTexts["New Schedule"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Edit Schedule"].waitForExistence(timeout: 5),
                      "新建应进表编辑页")
    }

    // MARK: Appearance — 3 态模式分段切换

    func testAppearanceModeSegmented() {
        app.descendants(matching: .any)["mine_appearance"].tap()
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 5))

        let light = app.descendants(matching: .any)["theme_mode_light"]
        let dark = app.descendants(matching: .any)["theme_mode_dark"]
        let auto = app.descendants(matching: .any)["theme_mode_system"]
        XCTAssertTrue(light.waitForExistence(timeout: 3), "Light 模式按钮应存在")
        XCTAssertTrue(dark.exists, "Dark 模式按钮应存在")
        XCTAssertTrue(auto.exists, "Auto 模式按钮应存在")

        // 切 Dark → 立即生效不崩
        dark.tap()
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 3), "切深色不应崩")
        // 切回 Light
        light.tap()
        // 切 Auto
        auto.tap()
        XCTAssertTrue(app.staticTexts["Appearance"].exists)
    }

    // MARK: Appearance — 预设主题网格(至少一个预设可点)

    func testAppearancePresetGrid() {
        app.descendants(matching: .any)["mine_appearance"].tap()
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 5))
        app.swipeUp()
        // 预设网格(2 列 N 个)— 任一预设按钮可点不崩
        let presets = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'theme' OR label CONTAINS 'Wake'")).firstMatch
        if presets.exists {
            presets.tap()
            XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 3))
        }
        // 无论预设如何, 页面不崩
        XCTAssertTrue(app.staticTexts["Appearance"].exists)
    }

    // MARK: General — 设置卡交互(平卡选项即时点选; 卡已原生化: Time Display/
    //       Grid sub-info = SettingsFlatCard 分段控件, 选项常显不可折叠 →
    //       旧"展开/收起"语义过时, 段选项以 button 形式暴露而非 staticText)

    func testGeneralCardsExpandCollapse() {
        app.descendants(matching: .any)["mine_general"].tap()
        XCTAssertTrue(app.staticTexts["General"].waitForExistence(timeout: 5))

        // Time Display 卡: 分段控件两选项
        XCTAssertTrue(scrollUntil(app.buttons["Show as periods"].firstMatch),
                      "Time Display 卡应有 periods 段选项")
        XCTAssertTrue(app.buttons["Show as times"].exists)

        // 点选 times 段 → 切回 periods 段
        app.buttons["Show as times"].firstMatch.tap()
        app.buttons["Show as periods"].firstMatch.tap()

        // Grid card sub-info 卡(同为平卡): Room / Teacher / None 三段
        XCTAssertTrue(scrollUntil(app.buttons["Room"].firstMatch),
                      "副信息卡应有 Room 段选项")
        XCTAssertTrue(app.buttons["Teacher"].firstMatch.exists)
        XCTAssertTrue(app.buttons["None"].firstMatch.exists)
        // 三选项轮点
        app.buttons["Room"].firstMatch.tap()
        app.buttons["Teacher"].firstMatch.tap()
        app.buttons["None"].firstMatch.tap()
    }

    // MARK: General — Visible Days 7 行开关

    func testGeneralVisibleDaysToggles() {
        app.descendants(matching: .any)["mine_general"].tap()
        XCTAssertTrue(app.staticTexts["General"].waitForExistence(timeout: 5))
        app.swipeUp()
        let daysCard = app.staticTexts["Visible Days"].firstMatch
        XCTAssertTrue(daysCard.waitForExistence(timeout: 3))
        daysCard.tap()
        // 7 行日选择(至少 Monday 行出现)
        let monday = app.staticTexts["Monday"].firstMatch
        if monday.waitForExistence(timeout: 3) {
            monday.tap()   // 关周一 → 再点开
            monday.tap()
        }
        XCTAssertTrue(app.staticTexts["Visible Days"].exists, "操作后卡不崩")
    }

    // MARK: General — Show dates / colorless 开关

    func testGeneralToggles() {
        app.descendants(matching: .any)["mine_general"].tap()
        XCTAssertTrue(app.staticTexts["General"].waitForExistence(timeout: 5))

        // "课表显示日期"行在 Home display 卡内(折叠态不渲染)→ 先展开该卡
        let pillCard = app.buttons["Home display"].firstMatch
        XCTAssertTrue(scrollUntil(pillCard, maxSwipes: 8))
        pillCard.tap()
        let showDateCard = app.staticTexts["Show dates on schedule"].firstMatch
        XCTAssertTrue(scrollUntil(showDateCard, maxSwipes: 8))
        showDateCard.tap()
        // Toggle switch(switch 元素)
        let sw = app.switches.firstMatch
        if sw.waitForExistence(timeout: 2) {
            sw.tap()
            sw.tap()   // 开→关→开
        }
        XCTAssertTrue(app.staticTexts["Show dates on schedule"].exists)
    }

    // MARK: General — Widget 设置组(widgetcolorless/separator/vertPunct)

    func testGeneralWidgetSection() {
        app.descendants(matching: .any)["mine_general"].tap()
        XCTAssertTrue(app.staticTexts["General"].waitForExistence(timeout: 5))
        app.swipeUp()
        app.swipeUp()
        app.swipeUp()
        let widgetCard = app.staticTexts["Widget settings"].firstMatch
        if widgetCard.waitForExistence(timeout: 3) {
            widgetCard.tap()
            XCTAssertTrue(app.staticTexts["Uniform widget course colors"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.staticTexts["Week view separator"].exists)
            // 展开状态点第一个选项卡的 switch
            let sw = app.switches.firstMatch
            if sw.exists { sw.tap() }
        }
    }

    // MARK: General — 语言 5 项切换(切 en → ja → 切回 zh 简体)

    func testGeneralLanguageSwitch() {
        app.descendants(matching: .any)["mine_general"].tap()
        XCTAssertTrue(app.staticTexts["General"].waitForExistence(timeout: 5))
        let english = app.buttons["English"].firstMatch
        XCTAssertTrue(scrollUntil(english, maxSwipes: 8), "语言列表应有 English")
        english.tap()
        // 切日语验证多语切换
        let japanese = app.buttons["日本語"].firstMatch
        XCTAssertTrue(scrollUntil(japanese, maxSwipes: 8))
        japanese.tap()
        // ★ 收尾必须切回 en: applyLanguage 持久化 AppPrefs 且优先于 -AppleLanguages
        //   启动参数 → 留 zh 会污染后续所有用例(TableSwitch 等英文断言全挂)
        let englishAgain = app.buttons["English"].firstMatch
        XCTAssertTrue(scrollUntil(englishAgain, maxSwipes: 8))
        englishAgain.tap()
    }

    // ★ 语言切换即时生效(修复前 L10n 固定 Bundle.main → 只写 prefs 不刷 UI):
    //   启动 en(种子已清残留语言)→ 切 "简体中文" → 页面立即变中文。
    //   全树重建(← Activity.recreate)保留 VM 状态 → 仍在 General overlay, 标题
    //   "General"→"通用" 即时变化;语言项标签是硬编码原生名, 不随语言变可再定位。
    func testLanguageSwitchAppliesImmediately() {
        app.descendants(matching: .any)["mine_general"].tap()
        XCTAssertTrue(app.staticTexts["General"].waitForExistence(timeout: 5))
        let zh = app.buttons["简体中文"].firstMatch
        XCTAssertTrue(scrollUntil(zh, maxSwipes: 8), "语言列表应有 简体中文")
        zh.tap()

        // 整树重建后仍在 General overlay — 标题应立即是 "通用"(即时生效, 无需重启)
        XCTAssertTrue(app.staticTexts["通用"].waitForExistence(timeout: 5),
                      "切简体中文后 General 页标题应立即变 通用(即时生效)")
        // 恢复英文环境(与其他用例的英文断言隔离)
        let english = app.buttons["English"].firstMatch
        XCTAssertTrue(scrollUntil(english, maxSwipes: 8))
        english.tap()
        XCTAssertTrue(app.staticTexts["General"].waitForExistence(timeout: 5),
                      "切回 English 后应立即变回 General")
    }

    // ★ 节假日入口(← Android General 页 holiday 入口卡): 点击进二级页, 返回回 General
    func testHolidayEntryOpensHolidayScreen() {
        app.descendants(matching: .any)["mine_general"].tap()
        XCTAssertTrue(app.staticTexts["General"].waitForExistence(timeout: 5))
        let entry = app.descendants(matching: .any)["settings_holiday_entry"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "General 页应有节假日入口卡")
        // issue#26 别名开关折叠进 pill 卡后 General 页整体变矮, 固定 swipeUp 会把入口
        // 划出视口上沿(tap 落空)→ 按需双向滚动把入口送进可视区再点
        let screenH = app.frame.height
        for _ in 0..<4 {
            let f = entry.frame
            if f.minY > 80 && f.maxY < screenH - 80 { break }
            if f.minY <= 80 { app.swipeDown() } else { app.swipeUp() }
        }
        entry.tap()
        // 二级页标题 "Holidays & Make-up Days"
        let title = app.staticTexts["Holidays & Make-up Days"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "点入口应打开节假日设置页")
        // 返回(← Android onBack = overlayScreen = null) → 回主界面, Mine tab 仍在
        app.buttons["topbar_back"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["mine_general"].waitForExistence(timeout: 5),
                      "返回后应回主界面(Mine tab)")
    }

    // MARK: Export — 3 格式行存在

    func testExportScreenThreeFormats() {
        app.descendants(matching: .any)["mine_export"].tap()
        XCTAssertTrue(app.staticTexts["Export Schedule"].waitForExistence(timeout: 5))
        // 3 个格式行(标题 L10n export_json/share/ics)
        let jsonRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'JSON'")).firstMatch
        XCTAssertTrue(jsonRow.waitForExistence(timeout: 3), "JSON 导出行应存在")
        let icsRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'ICS Calendar'")).firstMatch
        XCTAssertTrue(icsRow.exists, "ICS 导出行应存在")
    }

    // MARK: Reminder — 总开关 + 子开关 + 时间行

    func testReminderScreenToggles() {
        // ★ Reminder 深度场景(权限允许/拒绝/时间保存取消/子卡显隐)已迁至
        //   ReminderPermissionUITests(幂等+identifier 版)。此处保留冒烟:
        //   页可达 + master 幂等开 + 操作后不崩。
        app.descendants(matching: .any)["mine_reminder"].tap()
        XCTAssertTrue(app.staticTexts["Reminders"].waitForExistence(timeout: 5))

        let masterSwitch = app.descendants(matching: .any)["reminder_master_toggle"]
        XCTAssertTrue(masterSwitch.waitForExistence(timeout: 3), "总开关应在")
        if (masterSwitch.value as? String) != "1" {
            masterSwitch.tap()
            // 若 notDetermined 会弹权限窗 — 点 Allow 使开关生效(幂等)
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let allowBtn = springboard.alerts.firstMatch.buttons.matching(
                NSPredicate(format: "label == 'Allow' OR label == '好'")).firstMatch
            if allowBtn.waitForExistence(timeout: 4) { allowBtn.tap() }
        }
        XCTAssertTrue((masterSwitch.value as? String) == "1", "master 应为开")
        XCTAssertTrue(app.staticTexts["Reminders"].exists, "提醒页操作后不崩")
    }

    // MARK: About — 检查更新按钮(点击进入 checking 态, 网络失败回落不崩)

    func testAboutCheckUpdateButton() {
        app.descendants(matching: .any)["mine_about"].tap()
        XCTAssertTrue(app.staticTexts["About"].waitForExistence(timeout: 5))

        let checkBtn = app.descendants(matching: .any)["about_check_update"]
        XCTAssertTrue(checkBtn.waitForExistence(timeout: 3))
        checkBtn.tap()
        // 进入 checking(可能很快过去, 只要页面不崩)
        XCTAssertTrue(app.staticTexts["About"].waitForExistence(timeout: 3),
                      "检查更新不应崩溃")
    }
}

