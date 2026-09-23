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
    focused paragraphs; a first-responder change dirties only the markers inside the selection's paragraphs,
    so select-all plus focus toggles never regenerate marker-free lines), marker changes and the mode toggle
    (a full-document dirty range) are applied by
    `MarkdownEditorEngine.regenerateParagraphs`, which posts `textStorage.edited(.editedAttributes)` once per
    affected paragraph — `recordEditAction` does NOT make `NSTextContentStorage` rebuild a cached paragraph,
    and the delegate is held weakly (keep a strong reference in tests). Regeneration is deferred while IME
    marked text exists. `HighlightMapper` limits blockquote `>` markers per line to the quote depth so code
    inside a quote keeps its literal `>`.
  - Front Matter (Laperm ADR 0016): `LapermCore/FrontMatter.swift` recognises an Obsidian-style block (line 1 is
    exactly `---`, closed by a `---` line; BOM tolerated, no `...`, no leading blank line) and reads a YAML subset
    (`key: value`, `key: [a, b]`, `key:` + `- item` lines, quotes, `#` comments; anything else becomes a raw row).
    `MarkdownParser` blanks the block (spaces, newlines kept, UTF-16 length unchanged) before handing the text to
    swift-markdown so `---` is not a Setext underline / thematic break, then adds `.frontMatter` (block),
    `.frontMatterKey` and `.syntaxMarker` (fences, NOT concealable) spans and `HighlightPlan.frontMatter`.
    `FrontMatterController` (shared) collapses the block in Live Preview into a key / value table
    (`FrontMatterTableLayout` computes rows, chips for lists, raw rows in the code font; `FrontMatterTableRenderer`
    draws; `FrontMatterTableView.AppKit/UIKit` is a non-hit-testing overlay placed from the viewport layout pass
    via `MarkdownEditorEngine.frontMatterTableEntry(for:)`): the opening `---` paragraph gets a display paragraph
    whose characters carry the 1e-6pt font and whose `paragraphSpacing` reserves the table height
    (`BlockFragmentProvider.collapsedFrontMatterReservation`), the other block paragraphs are excluded from
    enumeration (`EditorContentStorageDelegate.shouldEnumerate`, same mechanism as folding). Focus is per block:
    the block is expanded (Source look, `CodeBlockFragment` filled with `frontMatterBackgroundColor`) while the
    text view is first responder and a selection starts at or before the closing fence's line end; zero
    properties never collapse. Toggling regenerates the block with `recordEditAction` + `invalidateLayout` and the
    opening paragraph additionally with `edited(.editedAttributes)` (`recordEditAction` reuses cached paragraphs).
    A click / tap on the table (`MarkdownTextView.expandFrontMatter(atPoint:)`, from `mouseDown` / the tap
    gesture; on iOS `shouldInterceptTap` claims touches over the table so UITextView's own tap does not re-place
    the caret in the expanded layout) puts the caret at the end of that property's line. The controller computes
    a desired `Presentation` from its inputs and moves it to the presented one only when `canPresent()` is true
    (the engine returns false during IME marked text, so enumeration / reservation / display paragraph never
    disagree); an edit touching the block marks the model stale (expanded, no table clicks) until the next parse;
    the table layout is cached by (front matter, width, appearance). The text storage is never changed.
  - Header view (shared API, platform hosting): `.headerView(height:_:)` on `MarkdownEditorView` (or
    `MarkdownTextView.headerView` / `headerHeight`) puts a SwiftUI view above the text *inside the scrolled
    content* (Laperm shows the note title there, Obsidian-style). The text view hosts it (`NSHostingView` /
    `UIHostingController` with `sizingOptions = []`, kept on the coordinator and reused on updates), pushes the
    text down by the fixed height (`textContainerInset.height` on AppKit — symmetric, so the same space appears
    below the text — and `textContainerInset.top` on UIKit, restored to the UITextView default when removed)
    and places the header at the text container's horizontal position (margins + `lineFragmentPadding`) in
    `layout()` / `layoutSubviews()`. On UIKit `gestureRecognizerShouldBegin` refuses the text view's own
    recognizers (caret placement, edit tap, hover) over the header so its controls receive the touch; the scroll
    pan and pinch still begin there. On UIKit the host is set through `headerViewController`, which the text view
    adds as a child of the nearest view controller while it is in a window (SwiftUI `@FocusState` / keyboard focus
    needs the view-controller hierarchy) and detaches when it leaves the window or is replaced. On AppKit the
    text view returns the header in `accessibilityChildren()` (an AXTextArea hides its subviews otherwise), so
    XCUITest and assistive technologies can reach its controls. Programmatic `@FocusState` focus inside the
    AppKit host does not work (a click does). The header does not inherit the SwiftUI environment of the host view.
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
