# Laperm

TextKit2-based Markdown editor library for macOS (Swift 6, macOS 27+).

## Platforms

- `LapermCore` (parser / highlight model, Foundation-only) supports macOS 27+ and iOS 27+.
- `LapermEditor` (UI layer) supports macOS 27+ (AppKit) and iOS 27+ (UIKit).
  - `Sources/LapermEditor/*.swift`: shared code. `MarkdownEditorEngine` holds the highlight / folding /
    image-preview logic and talks to the view through the `MarkdownEditorHost` protocol.
    `Platform.swift` defines `PlatformFont` / `PlatformColor` / `PlatformImage` (NSFont/UIFont etc.)
    used by the public `MarkdownTheme` API.
  - `Sources/LapermEditor/AppKit/`: `MarkdownTextView: NSTextView`, ruler gutter, overlays, and the
    macOS-only `TextInputInterceptor` (Vim) / `InsertionPointStyle` APIs.
  - `Sources/LapermEditor/UIKit/`: `MarkdownTextView: UITextView`, gutter as a viewport-pinned subview
    (text is inset via `textContainerInset.left`), overlays. Links open via the long-press edit menu
    ("Open Link", localized in `Resources/Localizable.xcstrings`) or Cmd+tap; Cmd+hover underlines
    on iPad pointer. No input interceptor / insertion point style on iOS.
  - Platform-specific files carry a `.AppKit.swift` / `.UIKit.swift` suffix because Xcode rejects
    two source files with the same basename in one target.
- Tests: `Tests/LapermEditorTests/*.swift` are macOS (`#if os(macOS)`); `Tests/LapermEditorTests/UIKit/` are iOS
  (`#if canImport(UIKit)`). Run iOS tests with:
  `xcodebuild test -scheme Laperm-Package -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0'`
- Example apps: `ExampleMacOS` and `ExampleiOS` schemes in `Example/Example.xcodeproj`.

## Verification

- **iOS GUI verification uses XCUITest on the simulator**: `ExampleiOSUITests` launches `ExampleiOS`,
  synthesizes taps / typing / long-press, asserts on the text view's value, and saves screenshots
  to `$LAPERM_SCREENSHOT_DIR` (read them to confirm rendering). Run with:
  `TEST_RUNNER_LAPERM_SCREENSHOT_DIR=/path/to/dir xcodebuild test -project Example/Example.xcodeproj -scheme ExampleiOS -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0'`
  The app writes uncaught ObjC exceptions to `$LAPERM_CRASH_LOG` when that env var is set (the UI test sets it).
- **macOS GUI verification MUST use computer use**: launch the real app, drive it with synthesized keyboard/mouse input, and confirm results with screenshots. Follow the project skill `verifying-macos-gui` (`.claude/skills/verifying-macos-gui/SKILL.md`). Unit tests and a successful build alone do NOT count as end-to-end verification for user-visible behavior.
