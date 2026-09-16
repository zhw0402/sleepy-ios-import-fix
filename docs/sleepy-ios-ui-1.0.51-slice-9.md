# Slice 9: Theme alignment

## What

Aligned the shared iOS theme contract with Android 1.0.51:

- Default light `surface` now matches Android `background` (`#FEF7FF`).
- Default dark color roles now match `DarkScheme` from Android 1.0.51.
- Shared Swift M3 typography constants now use the Android baseline sizes for `displaySmall`, `headlineMedium`, and `titleLarge`.
- `SleepyShapes.extraLarge` now matches Android's 28dp `extraLarge` shape.
- Existing Spring, Ocean, Peach, and Slate presets were compared with Android `ThemePresets.kt` and left unchanged because they already match.

## Evidence

- Android sources: `app/src/main/java/com/lingion/sleepy/ui/theme/Theme.kt`, `ThemePresets.kt`, `app/src/main/res/values/colors.xml`
- iOS sources: `Sleepy/theme/Theme.swift`, `Sleepy/theme/ThemePresets.swift`
- `git diff --check`: passed
- Generic iOS build: `** BUILD SUCCEEDED **`

## Scope

Only `Sleepy/theme/Theme.swift` and the alignment documentation were changed for this slice. Existing custom theme behavior and unrelated worktree changes were preserved.
