// WidgetThemeModeTests.swift — 小组件深色跟随修复(2026 dark-mode bug)的纯逻辑链:
// themeMode 快照 → effectiveWidgetIsDark(渲染期环境色域覆盖) → resolveWidgetScheme。

import XCTest
@testable import Sleepy

final class WidgetThemeModeTests: XCTestCase {

    // system 模式 → 用渲染期环境色域(WidgetKit \.colorScheme), 不信快照
    func testSystemModeFollowsEnvironmentNotSnapshot() {
        XCTAssertTrue(effectiveWidgetIsDark(themeMode: AppPrefs.THEME_MODE_SYSTEM,
                                            snapshotIsDark: false, envScheme: .dark))
        XCTAssertFalse(effectiveWidgetIsDark(themeMode: AppPrefs.THEME_MODE_SYSTEM,
                                             snapshotIsDark: false, envScheme: .light))
        // 环境优先: 即便快照 isDark=true, system 模式下浅色环境仍应渲染浅色
        XCTAssertFalse(effectiveWidgetIsDark(themeMode: AppPrefs.THEME_MODE_SYSTEM,
                                             snapshotIsDark: true, envScheme: .light))
    }

    // 锁定 light/dark → 信快照 isDark(与系统外观无关)
    func testLockedModesTrustSnapshot() {
        XCTAssertFalse(effectiveWidgetIsDark(themeMode: AppPrefs.THEME_MODE_LIGHT,
                                             snapshotIsDark: false, envScheme: .dark))
        XCTAssertTrue(effectiveWidgetIsDark(themeMode: AppPrefs.THEME_MODE_DARK,
                                            snapshotIsDark: true, envScheme: .light))
    }

    // 旧快照(无 themeMode 字段=nil)→ 沿用快照 isDark, 不改变历史行为
    func testLegacySnapshotWithoutThemeModeKeepsOldBehavior() {
        XCTAssertEqual(effectiveWidgetIsDark(themeMode: nil,
                                             snapshotIsDark: false, envScheme: .dark), false)
        XCTAssertEqual(effectiveWidgetIsDark(themeMode: nil,
                                             snapshotIsDark: true, envScheme: .light), true)
    }

    // 默认主题模式=system; 快照应携带 themeMode 供渲染端判别
    func testDefaultThemeModePrefIsSystem() {
        let suite = UserDefaults(suiteName: "WidgetThemeModeTests")!
        suite.removeObject(forKey: AppPrefs.KEY_THEME_MODE)
        let prefs = AppPrefs(defaults: suite)
        XCTAssertEqual(prefs.getThemeMode(), AppPrefs.THEME_MODE_SYSTEM)
        suite.removePersistentDomain(forName: "WidgetThemeModeTests")
    }

    // resolver: 同一主题键, isDark 翻转必须给出不同 surfaceContainer(此前 bug 的直接表征)
    func testResolverDarkLightProduceDistinctSurfaces() {
        let light = resolveWidgetScheme(themeKey: ThemePresets.KEY_DEFAULT, isDark: false)
        let dark = resolveWidgetScheme(themeKey: ThemePresets.KEY_DEFAULT, isDark: true)
        XCTAssertNotEqual(light.surfaceContainer, dark.surfaceContainer)
        XCTAssertNotEqual(light.bg, dark.bg)
    }

    // system 主题键走 dynamicSystemScheme(dark:)
    func testSystemKeyFollowsDarkFlag() {
        let light = SleepyThemeProvider.dynamicSystemScheme(dark: false)
        let dark = SleepyThemeProvider.dynamicSystemScheme(dark: true)
        XCTAssertNotEqual(light.surfaceContainer, dark.surfaceContainer)
    }
}
