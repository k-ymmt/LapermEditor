---
name: textkit2
description: TextKit2 architecture guide and API reference for building custom text views. Use when working with NSTextLayoutManager, NSTextContentStorage, NSTextViewportLayoutController, or NSTextLayoutFragment.
paths: "**/*.swift"
---

# TextKit2 Architecture Guide

Reference for building custom text views using Apple's TextKit2 framework on macOS (AppKit) and iOS (UIKit).

## TextKit2 Object Graph

```
NSTextContentStorage (content model, backing store)
  └─ NSTextLayoutManager (layout engine, one per view)
      ├─ NSTextContainer (defines layout bounds)
      ├─ NSTextViewportLayoutController (viewport-based rendering)
      │   └─ NSTextLayoutFragment[] (laid-out paragraph fragments)
      │       └─ NSTextLineFragment[] (individual visual lines after wrapping)
      ├─ NSTextSelection[] (current selection state)
      └─ NSTextSelectionNavigation (selection movement/deletion logic)
```

**Key relationships:**
- One NSTextContentStorage can have multiple NSTextLayoutManagers (e.g., split view)
- NSTextViewportLayoutController drives lazy, viewport-scoped layout — only visible content is laid out
- Each NSTextLayoutFragment corresponds to one NSTextElement (typically a paragraph)
- A fragment contains one or more NSTextLineFragments (one per visual line after word wrapping)
- NSTextSelectionNavigation handles arrow keys, word movement, line selection, and deletion ranges

## Initialization Pattern

TextKit2 objects must be created and wired in a specific order:

```swift
// 1. Create content storage (or subclass for custom behavior)
let textContentStorage = NSTextContentStorage()

// 2. Create layout manager (or subclass)
let textLayoutManager = NSTextLayoutManager()

// 3. Create and assign text container
let textContainer = NSTextContainer()
textLayoutManager.textContainer = textContainer

// 4. Connect content storage to layout manager
textContentStorage.addTextLayoutManager(textLayoutManager)
textContentStorage.primaryTextLayoutManager = textLayoutManager

// 5. Set delegates
textLayoutManager.delegate = self                                // NSTextLayoutManagerDelegate
textLayoutManager.textViewportLayoutController.delegate = self   // NSTextViewportLayoutControllerDelegate
```

**Critical:** The connection order matters. Setting `textContainer` before adding the layout manager to the content storage ensures proper initialization.

## Architecture Decision: NSTextView vs Custom View

### Option 1: Subclass NSTextView (simplest)
- Built-in text input, selection, scrolling, accessibility
- Good for rich text editors with standard behavior
- Limited control over layout and rendering

### Option 2: Custom NSView/UIView + TextKit2 (full control)
- Required for: code editors, custom rendering, non-standard line heights, custom gutters
- Must implement text input protocols manually:
  - macOS: `NSTextInputClient` protocol
  - iOS: `UITextInput` protocol
- Must conform to `NSTextContent` protocol
- Must manage scrolling, selection rendering, cursor display manually
- Significant more work, but full control over every aspect

**Recommendation:** For anything beyond a basic rich text editor, use a custom view. TextKit2's viewport-based architecture is designed to work well with custom views.

## Viewport-Based Layout Model

TextKit2's fundamental difference from TextKit1:

| Aspect | TextKit1 | TextKit2 |
|--------|----------|----------|
| Layout scope | Entire document upfront | Only visible viewport |
| Layout trigger | Text changes | Viewport changes (scroll, resize) |
| Fragment lifecycle | Persistent | Created/recycled on demand |
| Performance | Degrades with document size | Constant regardless of size |

**The layout cycle:**

1. `textViewportLayoutControllerWillLayout()` — Prepare for layout pass
2. `viewportBounds(for:)` — Return the visible rect (account for gutters, insets)
3. `configureRenderingSurfaceFor:` — Called per-fragment, create/reuse fragment views
4. `textViewportLayoutControllerDidLayout()` — Cleanup stale views, update content size

**Layout convergence:** A single `layoutViewport()` call may not be sufficient if layout changes trigger further changes. Use a convergence loop:

```swift
func layoutViewport() {
    var iterations = 5
    while iterations > 0 {
        needsRelayout = false
        textLayoutManager.textViewportLayoutController.layoutViewport()
        if !needsRelayout { break }
        iterations -= 1
    }
}
```

## Cross-Platform Considerations

### Shared APIs (AppKit & UIKit)
All core TextKit2 types work on both platforms:
- NSTextContentStorage, NSTextLayoutManager, NSTextContainer
- NSTextViewportLayoutController, NSTextLayoutFragment, NSTextLineFragment
- NSTextSelection, NSTextSelectionNavigation
- NSTextRange, NSTextLocation, NSTextElement, NSTextParagraph

### Platform Differences

| Aspect | macOS (AppKit) | iOS (UIKit) |
|--------|---------------|-------------|
| Text input protocol | NSTextInputClient | UITextInput |
| Content protocol | NSTextContent | NSTextContent |
| Coordinate system | Bottom-left (use `isFlipped = true`) | Top-left |
| Position type | NSTextLocation (direct) | UITextPosition (needs bridge) |
| Range type | NSTextRange (direct) | UITextRange (needs bridge) |
| Scroll view | NSScrollView + NSClipView | UIScrollView |
| Undo manager | UndoManager (runLoopModes differ) | UndoManager |

### UIKit Text Position Bridging

For UIKit, bridge NSTextLocation/NSTextRange to UITextPosition/UITextRange:

```swift
class TextPosition: UITextPosition {
    let location: NSTextLocation
    init(_ location: NSTextLocation) { self.location = location }
}

class TextRange: UITextRange {
    let textRange: NSTextRange
    override var start: UITextPosition { TextPosition(textRange.location) }
    override var end: UITextPosition { TextPosition(textRange.endLocation) }
    override var isEmpty: Bool { textRange.isEmpty }
    init(_ textRange: NSTextRange) { self.textRange = textRange }
}
```

## Editing Model

All text modifications must occur inside `performEditingTransaction`:

```swift
textContentManager.performEditingTransaction {
    textContentManager.replaceContents(
        in: textRange,
        with: [NSTextParagraph(attributedString: replacementString)]
    )
}
```

This ensures atomic updates and proper notification sequencing. Never modify text outside a transaction — it leads to undefined behavior and layout corruption.

## Support Files

- **[API Reference](api-reference.md)** — Detailed properties, methods, and usage notes for each TextKit2 type
- **[Patterns & Idioms](patterns-and-idioms.md)** — Implementation patterns with code examples: viewport layout, editing, selection, rendering, scrolling, gutter, cross-platform
- **[Known Issues](known-issues.md)** — Documented TextKit2 bugs (with Apple Feedback numbers) and production-tested workarounds
