# LapermEditor

A TextKit 2–based Markdown editor library for macOS and iOS, written in Swift 6.

## Features

- Live syntax highlighting driven by [swift-markdown](https://github.com/swiftlang/swift-markdown) (GFM: tables, task lists, strikethrough, autolinks)
- Incremental re-highlighting on edit
- Line-number gutter with heading fold markers
- Outline (heading) folding and outline change callbacks
- Inline image preview for image references
- Link detection with click / Cmd+tap opening and hover underlines
- Editing assistance (list continuation, indentation, task toggling)
- Customizable `MarkdownTheme`
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
            .foldingEnabled(true)
            .onOutlineChange { outline = $0 }
            .onOpenLink { url in
                // Return true when the link has been handled.
                false
            }
    }
}
```

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
