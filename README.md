# LapermEditor

A TextKit 2–based Markdown editor library for macOS and iOS, written in Swift 6.

## Features

- Live syntax highlighting driven by [swift-markdown](https://github.com/swiftlang/swift-markdown) (GFM: tables, task lists, strikethrough, autolinks)
- Incremental re-highlighting on edit
- Live Preview (`.livePreviewEnabled(true)` / `isLivePreviewEnabled`): syntax markers (heading `#`, emphasis / strikethrough / inline-code delimiters, link and image brackets, blockquote `>`) are drawn with (practically) zero width on every line except the ones the caret or selection touches; while the editor is not first responder (keyboard dismissed on iOS, another view focused on macOS) every line hides them, so an unfocused note reads like a rendered page. The text storage is never changed — copying still yields plain Markdown. Code fences, task checkboxes and table pipes stay visible.
- Line-number gutter with heading fold markers
- Outline (heading) folding and outline change callbacks
- Inline image preview for image references
- Link detection with click / Cmd+tap opening and hover underlines
- Editing assistance (list continuation, indentation, task toggling)
- Block decorations: code blocks as one full-width rounded box with vertical padding (`MarkdownTheme.codeBlockVerticalPadding`; a code block that starts at the very first paragraph gets no top padding because TextKit ignores `paragraphSpacingBefore` there), blockquote bars, thematic-break rules, table backgrounds
- Customizable `MarkdownTheme`, including `lineSpacing` (extra points between lines, applied as the paragraph style's `lineSpacing`; TextKit 2 puts it above every line except the document's first, and block decorations keep it outside the box)
- macOS only: `TextInputInterceptor` for Vim-style key handling and `InsertionPointStyle` (block / bar cursors)

## Requirements

- Swift 6.4 toolchain / Xcode 27
- macOS 27+ or iOS 27+

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/k-ymmt/LapermEditor.git", branch: "main"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "LapermEditor", package: "LapermEditor"),
        ]
    ),
]
```

Two library products are available:

| Product | Contents |
| --- | --- |
| `LapermEditor` | SwiftUI `MarkdownEditorView`, `MarkdownTextView` (NSTextView / UITextView), gutter, overlays |
| `LapermCore` | Foundation-only parser, highlight model, folding state, editing assistant |

## Usage

```swift
import LapermEditor
import SwiftUI

struct ContentView: View {
    @State private var text = "# Hello\n\nSome *Markdown*."
    @State private var outline: [OutlineItem] = []

    var body: some View {
        MarkdownEditorView(text: $text)
            .showsLineNumbers(true)
            .editorMargins(.readable)
            .foldingEnabled(true)
            .livePreviewEnabled(true)
            .editingOptions(EditingOptions(completesPairs: false))
            .onOutlineChange { outline = $0 }
            .onOpenLink { url in
                // Return true when the link has been handled.
                false
            }
            // iOS: the text view insets its own content for the keyboard (and its
            // inputAccessoryView), so stop SwiftUI from shrinking the editor as well.
            .ignoresSafeArea(.keyboard)
    }
}
```

On iOS, `.keyboardAccessory { ... }` puts a SwiftUI view above the keyboard, and
`.adjustsContentInsetForKeyboard(false)` hands keyboard avoidance back to SwiftUI (drop the
`.ignoresSafeArea(.keyboard)` in that case).

## Example apps

`Example/Example.xcodeproj` contains `ExampleMacOS` (with a Vim-mode demo) and `ExampleiOS` schemes.

## Tests

```bash
swift test
```

iOS tests run on the simulator:

```bash
xcodebuild test -scheme LapermEditor-Package -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0'
```
