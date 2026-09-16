# PATCHES.md — 相对上游 lingion/sleepy-ios 的本地修复

上游: https://github.com/lingion/sleepy-ios (作者 lingion, 版本基线 a.v.1.0.43 / master @ 2026-09-16)
本分支目的: **修「从文件导入」在真机上对所有文件都失败的问题**。

## 问题定位(读上游源码得出)

上游 `Sleepy/ui/screen/imports/ImportSheet.swift` 里文件导入只有这么一段:

```swift
.fileImporter(isPresented: $showFilePicker,
              allowedContentTypes: [.json, .plainText, .text, .html, .data],
              allowsMultipleSelection: false) { result in
    case .success(let urls):
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        let text = try String(contentsOf: url, encoding: .utf8)
```

三条硬伤, 任意一条都会让**所有**文件都只报一句「读取失败」:

1. **security-scoped 授权失败被静默忽略** —— `startAccessingSecurityScopedResource()` 的返回值没有校验,
   授权失败时照样去读 → 抛错。
2. **不落地拷贝** —— `.fileImporter` 默认 not-copy 语义; 文件在 iCloud 云盘且本地未下载(占位文件)时,
   直接 `String(contentsOf:)` 必失败(应走 `NSFileCoordinator` 或 `asCopy: true`)。
3. **只按 UTF-8 解码** —— 中国教务系统导出的 CSV/ICS、Excel「另存为 CSV」绝大多数是 GBK/GB18030,
   严格 UTF-8 解码必抛错。

另外 `SleepyApp.swift` 的 `handleDeepLink` 第一行是 `guard url.scheme == "sleepy" else { return }`,
→ **文件打开路径(file://)被整体丢弃**, 而 Info.plist 又只声明了 `public.json`,
所以「用 Sleepy 打开 CSV/ICS」既不会出现在 Files 的打开方式里, 出现了也没反应。

## 本次改动

| 文件 | 改动 |
|---|---|
| `Sleepy/util/TextFileReader.swift` | **新增**。取字节走 `NSFileCoordinator`(iCloud 占位文件强制下载)+ 兜底; 认编码走 魔数判别 → BOM → UTF-8 → UTF-16 → GB18030/GB2312/Big5 → Latin-1; xlsx/docx/pdf 直接给出「请另存为 CSV」的可执行提示。只依赖 Foundation, 可编入 widget target。 |
| `Sleepy/ui/component/SystemDocumentPicker.swift` | **新增**。UIKit 直驱 `UIDocumentPickerViewController(forOpeningContentTypes:asCopy: true)`, 自己找 keyWindow 顶层 VC 来 present。绕开 SwiftUI `.fileImporter` 的 sheet 嵌套与授权问题; 回调三态明确(选中/取消/失败)。放 `ui/` 下故不编入 widget。 |
| `Sleepy/ui/screen/imports/ImportSheet.swift` | 删除 `.fileImporter` 块与 `showFilePicker` 状态; 「从文件导入」改为调用 `presentFilePicker()`; `onAppear` 里消费外部打开失败的提示; 文件末尾追加 `PendingImportFailure` + `presentFilePicker()` / `consumePickedFile()`(`@State` 是 private, 只能同文件扩展)。 |
| `Sleepy/SleepyApp.swift` | `handleDeepLink` 支持 `file://`(读文本 → 走既有 `PendingImportText` 导入流程; 失败 → `PendingImportFailure` 弹提示)。 |
| `Sleepy/Info.plist` + `project.yml` | `CFBundleDocumentTypes` 补 `public.text` / `public.plain-text` / `public.comma-separated-values-text` / `public.html` / `com.apple.ical.ics`, 让 Files「用 Sleepy 打开」对 CSV/ICS/TXT/HTML 可见。 |
| `project.yml` | SwiftPM 依赖地址由作者自建镜像 `gh.qdp.qzz.io` 改回官方 `github.com`(CI runner 上镜像不可达); 其余不动。 |
| `.github/workflows/build-ipa.yml` | **新增**。macOS runner: `xcodegen generate` → `xcodebuild archive`(无签名, `SWIFT_VERSION=5.0` 覆盖) → 打包 `Sleepy-unsigned.ipa` → 上传 artifact。 |

## 未改动 / 已知边界

- 未实现 Excel(`.xlsx`)解析 —— 上游 iOS 版本来就没有; 现在会明确提示「另存为 CSV」而不是含糊报错。
  (上游 Android/Web 版有 Excel 解析, 如需可后续移植。)
- 新增的用户可见文案是中文硬编码(错误原因片段), 未走 5 语言 L10N 表 —— 只影响出错时的提示语,
  正常流程文案仍来自 `L10n`。如需全语言, 后续补 `Localizable.strings` 键即可。
- 其余业务逻辑(解析器、教务直连、入库、小组件)与上游一致, 未改动。

## 构建

CI: 见 `.github/workflows/build-ipa.yml`(仓库 Actions 页手动 Run workflow, 或 push 到 main 自动触发)。
本地(需 Mac + Xcode + xcodegen): `./scripts/build-ipa.sh`。
