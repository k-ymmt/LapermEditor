# LapermEditor

TextKit2-based Markdown editor library for macOS (Swift 6, macOS 27+).

## Platforms

- `LapermCore` (parser / highlight model, Foundation-only) supports macOS 27+ and iOS 27+.
- `LapermEditor` (UI layer) supports macOS 27+ (AppKit) and iOS 27+ (UIKit).
  - `Sources/LapermEditor/*.swift`: shared code. `MarkdownEditorEngine` holds the highlight / folding /
    image-preview logic and talks to the view through the `MarkdownEditorHost` protocol.
    `Platform.swift` defines `PlatformFont` / `PlatformColor` / `PlatformImage` (NSFont/UIFont etc.)
    used by the public `MarkdownTheme` API.
  - `LivePreviewConcealer` (shared): Live Preview hides `HighlightPlan.concealableMarkers` (a subset of the
    `.syntaxMarker` spans, produced by `HighlightMapper`) on every paragraph the caret / selection does
    not touch, and on every paragraph while the text view is not first responder (both text views feed
    `becomeFirstResponder` / `resignFirstResponder` / window moves into `MarkdownEditorEngine.editorFocusDidChange`;
    a headless concealer defaults to "focused"). Dismissing the keyboard on iOS or clicking the sidebar on
    macOS therefore gives a pure reading view; a window merely losing key status does not. It never touches the text storage: `EditorContentStorageDelegate.textContentStorage(_:textParagraphWith:)`
    returns a display `NSTextParagraph` whose marker characters carry a 1e-6pt font (TextKit 2 ignores
    `.expansion`; the advance still scales with size, so 0.01pt left ~390pt for a 100k-character URL), a
    paragraph whose visible characters are all markers gets `minimumLineHeight` from the markers' own fonts
    (the newline's font does not count in normal line-height computation), and a hidden tab (`#\tTitle`)
    zeroes the paragraph's `defaultTabInterval`. Focus changes (only the symmetric difference of the old / new
    focused paragraphs), marker changes and the mode toggle (a full-document dirty range) are applied by
    `MarkdownEditorEngine.regenerateParagraphs`, which posts `textStorage.edited(.editedAttributes)` once per
    affected paragraph — `recordEditAction` does NOT make `NSTextContentStorage` rebuild a cached paragraph,
    and the delegate is held weakly (keep a strong reference in tests). Regeneration is deferred while IME
    marked text exists. `HighlightMapper` limits blockquote `>` markers per line to the quote depth so code
    inside a quote keeps its literal `>`.
  - `Sources/LapermEditor/AppKit/`: `MarkdownTextView: NSTextView`, ruler gutter, overlays, and the
    macOS-only `TextInputInterceptor` (Vim) / `InsertionPointStyle` APIs.
  - `EditorMargins` (shared): horizontal margins as a pure `horizontalInsets(viewWidth:gutterWidth:fontSize:)`
    rule (minimum per side + maximum text width in ems, centered, rounded up to whole points so the
    minimum holds and the maximum is not exceeded; non-finite values count as no margin). The AppKit
    view applies `symmetricHorizontalInset` (the smaller side, so a margin wider than half the view
    still leaves a positive container width) via `textContainerInset` from `setFrameSize`; the UIKit
    view folds the gutter width into `textContainerInset.left` and recomputes in `layoutSubviews`
    before `super` (UITextView sizes the container from the inset in that pass). Toggling
    `showsLineNumbers` on a wide view leaves the insets unchanged, so the UIKit view re-runs the
    viewport layout on the next pass to refill the gutter.
  - `Sources/LapermEditor/UIKit/`: `MarkdownTextView: UITextView`, gutter as a viewport-pinned subview
    (text is inset via `textContainerInset.left`), overlays. Links open via the long-press edit menu
    ("Open Link", localized in `Resources/Localizable.xcstrings`) or Cmd+tap; Cmd+hover underlines
    on iPad pointer. No input interceptor / insertion point style on iOS.
    The text view adds its own `contentInset.bottom` for a docked keyboard (including the
    `inputAccessoryView`; floating / split keyboards and keyboards on another screen are ignored)
    from the keyboard frame notifications, on top of whatever inset the host set, so SwiftUI hosts
    apply `.ignoresSafeArea(.keyboard)` to the editor instead of letting it shrink;
    `adjustsContentInsetForKeyboard = false` (or the `.adjustsContentInsetForKeyboard(false)`
    modifier) opts out. A view added while the keyboard is up catches up from a per-screen cache.
    When the new inset would hide the caret, the reveal scroll sets `contentOffset` inside the same
    keyboard animation block as the inset (never `scrollRangeToVisible`, whose own timer-driven
    animation lags the keyboard and re-lays out every frame); while that animation runs,
    `viewportBounds(for:)` and the gutter frame add the traversed range so the departing text and
    line numbers stay rendered. The visible area subtracts the whole post-keyboard
    `adjustedContentInset.bottom` (host inset + safe area + keyboard). A caret more than one view
    height away is jumped to without animation instead of laying out everything in between.
  - Platform-specific files carry a `.AppKit.swift` / `.UIKit.swift` suffix because Xcode rejects
    two source files with the same basename in one target.
- Tests: `Tests/LapermEditorTests/*.swift` are macOS (`#if os(macOS)`); `Tests/LapermEditorTests/UIKit/` are iOS
  (`#if canImport(UIKit)`). Run iOS tests with:
  `xcodebuild test -scheme LapermEditor-Package -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0'`
- Example apps: `ExampleMacOS` and `ExampleiOS` schemes in `Example/Example.xcodeproj`.

## Verification

- **iOS GUI verification uses XCUITest on the simulator**: `ExampleiOSUITests` launches `ExampleiOS`,
  synthesizes taps / typing / long-press, asserts on the text view's value, and saves screenshots
  to `$LAPERM_SCREENSHOT_DIR` (read them to confirm rendering). Run with:
  `TEST_RUNNER_LAPERM_SCREENSHOT_DIR=/path/to/dir xcodebuild test -project Example/Example.xcodeproj -scheme ExampleiOS -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0'`
  The app writes uncaught ObjC exceptions to `$LAPERM_CRASH_LOG` when that env var is set (the UI test sets it).
- **macOS GUI verification MUST use computer use**: launch the real app, drive it with synthesized keyboard/mouse input, and confirm results with screenshots. Follow the project skill `verifying-macos-gui` (`.claude/skills/verifying-macos-gui/SKILL.md`). Unit tests and a successful build alone do NOT count as end-to-end verification for user-visible behavior.
