# TextKit2 Patterns & Idioms

Recurring implementation patterns for building custom text views with TextKit2. Code examples are derived from production implementations and represent proven approaches.

---

## 1. TextKit2 Stack Setup

### Minimal Custom Text View

```swift
final class CustomTextView: NSView, NSTextContent {
    var contentType: NSTextContentType? = nil

    private(set) var textLayoutManager: CustomTextLayoutManager!
    private(set) var textContentStorage: CustomTextContentStorage!
    private(set) var textContainer: NSTextContainer!

    /// Weak-to-weak map so fragment views are released when either key or value is deallocated.
    let fragmentViewMap = NSMapTable<NSTextLayoutFragment, NSView>.weakToWeakObjects()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTextKit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTextKit()
    }

    private func setupTextKit() {
        textContentStorage = CustomTextContentStorage()
        textLayoutManager = CustomTextLayoutManager()
        textContainer = NSTextContainer(size: CGSize(width: bounds.width, height: 0))
        textContainer.widthTracksTextView = true

        textContentStorage.addTextLayoutManager(textLayoutManager)
        textLayoutManager.textContainer = textContainer

        textLayoutManager.delegate = self
        textLayoutManager.textViewportLayoutController.delegate = self

        // Initial empty selection at document start
        textLayoutManager.textSelections = [
            NSTextSelection(range: NSTextRange(location: textContentStorage.documentRange.location)!,
                            affinity: .downstream,
                            granularity: .character)
        ]
    }
}
```

### Custom TextLayoutManager

Override `textSelections` with `didSet` to respond to selection changes (e.g., update insertion point timer, notify delegates):

```swift
final class CustomTextLayoutManager: NSTextLayoutManager {
    weak var selectionDelegate: SelectionChangeDelegate?

    override var textSelections: [NSTextSelection] {
        didSet {
            selectionDelegate?.didChangeSelections(textSelections)
        }
    }
}
```

### Custom TextContentStorage (FB9925647 Workaround)

`replaceContents(in:with:)` may not update the underlying `NSTextStorage` correctly. Override to access `textStorage` directly:

```swift
final class CustomTextContentStorage: NSTextContentStorage {
    override func replaceContents(in range: NSTextRange, with textElements: [NSTextElement]?) {
        guard let elementRange = range as? NSTextRange,
              let nsRange = NSRange(elementRange, in: self) else {
            super.replaceContents(in: range, with: textElements)
            return
        }

        let replacementString: NSAttributedString
        if let paragraphs = textElements as? [NSTextParagraph] {
            let combined = paragraphs.map { $0.attributedString.string }.joined()
            replacementString = NSAttributedString(string: combined)
        } else {
            replacementString = NSAttributedString(string: "")
        }

        textStorage?.replaceCharacters(in: nsRange, with: replacementString)
    }
}
```

---

## 2. Viewport Layout Cycle

The four delegate methods of `NSTextViewportLayoutControllerDelegate` drive the layout cycle:

### willLayout

Save currently visible fragment views before the layout pass so stale ones can be removed afterwards:

```swift
var lastUsedFragmentViews: Set<NSView> = []

func textViewportLayoutControllerWillLayout(
    _ textViewportLayoutController: NSTextViewportLayoutController
) {
    lastUsedFragmentViews = Set(fragmentViewMap.objectEnumerator()?.allObjects as? [NSView] ?? [])
}
```

### viewportBounds

Return the visible rect. Clamp negative origins caused by overscroll bounce to avoid layout artefacts:

```swift
func textViewportLayoutController(
    _ textViewportLayoutController: NSTextViewportLayoutController,
    viewportBoundsFor textLayoutManager: NSTextLayoutManager
) -> CGRect {
    var rect = visibleRect  // or scrollView.documentVisibleRect
    // Clamp negative origin from elastic overscroll
    rect.origin.x = max(rect.origin.x, 0)
    rect.origin.y = max(rect.origin.y, 0)
    return rect
}
```

### configureRenderingSurface

Cache and reuse fragment views. Pixel-align frames to avoid blurry rendering:

```swift
func textViewportLayoutController(
    _ textViewportLayoutController: NSTextViewportLayoutController,
    configureRenderingSurfaceFor textLayoutFragment: NSTextLayoutFragment
) {
    // Reuse existing view or create a new one
    let fragmentView: FragmentView
    if let existing = fragmentViewMap.object(forKey: textLayoutFragment) as? FragmentView {
        fragmentView = existing
    } else {
        fragmentView = FragmentView()
        fragmentViewMap.setObject(fragmentView, forKey: textLayoutFragment)
    }

    fragmentView.textLayoutFragment = textLayoutFragment

    // Pixel-align to prevent subpixel rendering
    let frame = textLayoutFragment.layoutFragmentFrame
    fragmentView.frame = backingAlignedRect(frame, options: .alignAllEdgesNearest)

    if fragmentView.superview == nil {
        contentView.addSubview(fragmentView)
    }
}
```

### didLayout

Remove stale views, ensure layout for the viewport range, and update content size:

```swift
func textViewportLayoutControllerDidLayout(
    _ textViewportLayoutController: NSTextViewportLayoutController
) {
    // Remove fragment views that are no longer in the viewport
    let currentViews = Set(fragmentViewMap.objectEnumerator()?.allObjects as? [NSView] ?? [])
    let staleViews = lastUsedFragmentViews.subtracting(currentViews)
    for view in staleViews {
        view.removeFromSuperview()
    }

    // Ensure layout for the viewport range
    if let viewportRange = textViewportLayoutController.viewportRange {
        textLayoutManager.ensureLayout(for: viewportRange)
    }

    updateContentSizeIfNeeded()
}
```

### Fragment View Caching

`NSMapTable.weakToWeakObjects()` automatically cleans up the mapping when either the layout fragment (key) or the view (value) is deallocated. This avoids retain cycles and stale references without manual bookkeeping.

### Layout Convergence Loop

TextKit2 may need multiple passes for the layout to stabilise. Run the layout in a bounded loop:

```swift
private func layoutViewport() {
    let maxIterations = 5
    var iteration = 0
    needsRelayout = true

    while needsRelayout && iteration < maxIterations {
        needsRelayout = false
        textLayoutManager.textViewportLayoutController.layoutViewport()
        iteration += 1
    }
}
```

Set `needsRelayout = true` inside `configureRenderingSurface` when a fragment's size changes after rendering.

---

## 3. Text Editing

### Basic Text Replacement with Undo

```swift
func replaceText(in range: NSTextRange, with string: String) {
    let previousText = textContent(in: range)

    textContentStorage.performEditingTransaction {
        textContentStorage.replaceContents(
            in: range,
            with: [NSTextParagraph(attributedString: NSAttributedString(string: string))]
        )
    }

    // Calculate the range that was inserted for undo
    let undoEnd = textLayoutManager.location(
        textContentStorage.documentRange.location,
        offsetBy: NSRange(range, in: textContentStorage)!.location + string.utf16.count
    )!
    let undoRange = NSTextRange(location: range.location, end: undoEnd)!

    undoManager?.registerUndo(withTarget: self) { target in
        target.replaceText(in: undoRange, with: previousText)
    }
}

private func textContent(in range: NSTextRange) -> String {
    var result = ""
    textContentStorage.enumerateTextElements(from: range.location,
                                              options: .none) { element in
        guard let paragraph = element as? NSTextParagraph,
              let elementRange = paragraph.elementRange else { return false }
        if elementRange.location >= range.endLocation { return false }
        result += paragraph.attributedString.string
        return true
    }
    return result
}
```

### CoalescingUndoManager

Groups rapid consecutive edits (e.g., typing) into a single undo operation:

```swift
final class CoalescingUndoManager: UndoManager {
    private var isCoalescing = false
    private var coalescingTimer: Timer?
    private let coalescingInterval: TimeInterval = 0.8

    override init() {
        super.init()
        groupsByEvent = false

        #if canImport(AppKit)
        runLoopModes = [.default, .eventTracking, .modalPanel]
        #else
        runLoopModes = [.default]
        #endif
    }

    func checkCoalescing() {
        coalescingTimer?.invalidate()
        if !isCoalescing {
            startCoalescing()
        }
        coalescingTimer = Timer.scheduledTimer(withTimeInterval: coalescingInterval,
                                               repeats: false) { [weak self] _ in
            self?.endCoalescing()
        }
    }

    private func startCoalescing() {
        guard !isCoalescing else { return }
        isCoalescing = true
        beginUndoGrouping()
    }

    private func endCoalescing() {
        guard isCoalescing else { return }
        isCoalescing = false
        coalescingTimer?.invalidate()
        coalescingTimer = nil
        endUndoGrouping()
    }

    override func undo() {
        endCoalescing()
        super.undo()
    }

    override func redo() {
        endCoalescing()
        super.redo()
    }
}
```

---

## 4. Selection Management

### Setting Selections

```swift
// Single cursor (zero-width selection)
let location = textContentStorage.documentRange.location
textLayoutManager.textSelections = [
    NSTextSelection(range: NSTextRange(location: location)!,
                    affinity: .downstream,
                    granularity: .character)
]

// Text range selection
let start = textLayoutManager.location(documentRange.location, offsetBy: 5)!
let end = textLayoutManager.location(documentRange.location, offsetBy: 15)!
textLayoutManager.textSelections = [
    NSTextSelection(range: NSTextRange(location: start, end: end)!,
                    affinity: .downstream,
                    granularity: .character)
]

// Multiple cursors
textLayoutManager.textSelections = [
    NSTextSelection(range: rangeA, affinity: .downstream, granularity: .character),
    NSTextSelection(range: rangeB, affinity: .downstream, granularity: .character),
]
```

### Keyboard Navigation

Use `destinationSelection` to compute the new selection for a given direction and modifier:

```swift
func moveSelections(direction: NSTextSelectionNavigation.Direction,
                    destination: NSTextSelectionNavigation.Destination,
                    extending: Bool) {
    let navigator = textLayoutManager.textSelectionNavigation
    textLayoutManager.textSelections = textLayoutManager.textSelections.compactMap { selection in
        navigator.destinationSelection(
            for: selection,
            direction: direction,
            destination: destination,
            extending: extending,
            confined: false
        )
    }
}
```

**Arrow key mapping table:**

| Key Combo           | Direction  | Destination | Extending |
|----------------------|-----------|-------------|-----------|
| Left                 | .left     | .character  | false     |
| Right                | .right    | .character  | false     |
| Option+Left          | .left     | .word       | false     |
| Option+Right         | .right    | .word       | false     |
| Cmd+Left             | .left     | .line       | false     |
| Cmd+Right            | .right    | .line       | false     |
| Shift+Left           | .left     | .character  | true      |
| Shift+Right          | .right    | .character  | true      |
| Shift+Option+Left    | .left     | .word       | true      |
| Shift+Option+Right   | .right    | .word       | true      |
| Shift+Cmd+Left       | .left     | .line       | true      |
| Shift+Cmd+Right      | .right    | .line       | true      |
| Up                   | .up       | .character  | false     |
| Down                 | .down     | .character  | false     |

### Mouse / Touch Interactive Selection

```swift
func handleMouseDown(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
    let navigator = textLayoutManager.textSelectionNavigation
    let selections = navigator.textSelections(
        interactingAt: point,
        inContainerAt: textLayoutManager.documentRange.location,
        anchors: modifiers.contains(.shift) ? textLayoutManager.textSelections : [],
        modifiers: modifiers.contains(.command) ? .add : [],
        selecting: .character,
        bounds: .zero
    )
    textLayoutManager.textSelections = selections
}
```

### Typing Attributes Update

Enumerate attributes in reverse from the insertion point so that typing inherits attributes from the character before the cursor:

```swift
func typingAttributes(at location: NSTextLocation) -> [NSAttributedString.Key: Any] {
    var attrs: [NSAttributedString.Key: Any] = [:]
    textContentStorage.textStorage?.enumerateAttributes(
        in: NSRange(location: max(0, offset(of: location) - 1), length: 1),
        options: [.reverse]
    ) { attributes, _, _ in
        attrs = attributes
    }
    return attrs
}
```

---

## 5. Custom Rendering

### Custom Layout Fragment

Subclass `NSTextLayoutFragment` to apply custom line-height rendering. The offset formula corrects vertical centering when `lineHeightMultiple` is applied:

```swift
final class CustomLayoutFragment: NSTextLayoutFragment {
    var lineHeightMultiple: CGFloat = 1.0

    override func draw(at renderingOrigin: CGPoint, in ctx: CGContext) {
        for lineFragment in textLineFragments {
            // Offset to vertically center text within the expanded line height
            let offset = -(lineFragment.typographicBounds.height
                           * (lineHeightMultiple - 1.0) / 2.0)

            ctx.saveGState()
            let origin = CGPoint(
                x: renderingOrigin.x + lineFragment.typographicBounds.origin.x,
                y: renderingOrigin.y + lineFragment.typographicBounds.origin.y + offset
            )
            lineFragment.draw(at: origin, in: ctx)
            ctx.restoreGState()
        }
    }
}
```

### Full-Line Background Color (e.g., Code Blocks)

To color the entire line width (not just behind text characters), draw a background rect in the fragment's `draw(at:in:)` **before** drawing text:

```swift
final class BlockBackgroundLayoutFragment: NSTextLayoutFragment {
    /// Position within a contiguous block (.first, .middle, .last, .single)
    enum BlockPosition { case single, first, middle, last }

    var backgroundStyle: (color: CGColor, position: BlockPosition)?

    override func draw(at point: CGPoint, in context: CGContext) {
        if let style = backgroundStyle {
            let rect = CGRect(
                x: point.x,
                y: point.y,
                width: layoutFragmentFrame.width,
                height: layoutFragmentFrame.height
            )

            // Optional: rounded corners on first/last lines of the block
            let cornerRadius: CGFloat = 4
            let corners: RectCorner = switch style.position {
            case .single: .allCorners
            case .first:  [.topLeft, .topRight]
            case .last:   [.bottomLeft, .bottomRight]
            case .middle: []
            }

            context.saveGState()
            let path = CGPath.make(roundedRect: rect, corners: corners, radius: cornerRadius)
            context.addPath(path)
            context.setFillColor(style.color)
            context.fillPath()
            context.restoreGState()
        }

        super.draw(at: point, in: context)
    }
}
```

### Registering Custom Layout Fragments

Return the custom fragment from `NSTextLayoutManagerDelegate`. Use this delegate method to set per-fragment properties (e.g., background style, line height) based on the text element's content or attributes:

```swift
extension CustomTextView: NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let fragment = BlockBackgroundLayoutFragment(
            textElement: textElement,
            range: textElement.elementRange
        )

        // Set background style based on content (e.g., Markdown code block)
        if let paragraph = textElement as? NSTextParagraph {
            fragment.backgroundStyle = codeBlockStyle(for: paragraph)
        }

        return fragment
    }

    /// Determine if a paragraph is inside a code block and its position
    private func codeBlockStyle(
        for paragraph: NSTextParagraph
    ) -> (color: CGColor, position: BlockBackgroundLayoutFragment.BlockPosition)? {
        // Query your Markdown parser or attribute storage to determine
        // whether this paragraph is inside a fenced code block (``` ... ```)
        // and its position (first/middle/last/single) within the block.
        // Return nil if not inside a code block.
        return nil
    }
}
```

When code block ranges change (e.g., user types `` ``` ``), invalidate layout to regenerate fragments:

```swift
textLayoutManager.invalidateLayout(for: affectedRange)
```

---

## 6. Scrolling & Performance

### Content Size Calculation

Enumerate from the end of the document in reverse with `.ensuresLayout` to get the total content height:

```swift
func updateContentSizeIfNeeded() {
    var contentHeight: CGFloat = 0

    textLayoutManager.enumerateTextLayoutFragments(
        from: textContentStorage.documentRange.endLocation,
        options: [.reverse, .ensuresLayout, .ensuresExtraLineFragment]
    ) { fragment in
        contentHeight = fragment.layoutFragmentFrame.maxY
        return false  // stop after the last fragment
    }

    let newSize = CGSize(width: bounds.width, height: max(contentHeight, visibleRect.height))
    if frame.size != newSize {
        setFrameSize(newSize)
    }
}
```

### Jump Scrolling with relocateViewport

For scrolling to a distant location (e.g., "Go to line N"), use `relocateViewport` to avoid laying out the entire document:

```swift
func scrollToLocation(_ targetLocation: NSTextLocation) {
    let viewportController = textLayoutManager.textViewportLayoutController

    // Check if target is already in the viewport
    if let viewportRange = viewportController.viewportRange,
       viewportRange.contains(targetLocation) {
        // Already visible - just scroll to it
        scrollToVisibleLocation(targetLocation)
        return
    }

    // Relocate the viewport to the target, then lay out
    viewportController.relocateViewport(to: targetLocation)
    layoutViewport()

    // Now the fragment is laid out; scroll to it
    scrollToVisibleLocation(targetLocation)
}

private func scrollToVisibleLocation(_ location: NSTextLocation) {
    let range = NSTextRange(location: location)!
    if let segmentFrame = textLayoutManager.textSegmentFrame(
        in: range,
        type: .standard
    ) {
        scrollToVisible(segmentFrame)
    }
}
```

### Pixel Alignment

Prevent blurry rendering by aligning frames to the backing store pixel grid:

```swift
// macOS: use NSView's built-in method
let alignedFrame = backingAlignedRect(frame, options: .alignAllEdgesNearest)

// Cross-platform extension
extension CGRect {
    func pixelAligned(scaleFactor: CGFloat) -> CGRect {
        CGRect(
            x: (origin.x * scaleFactor).rounded(.down) / scaleFactor,
            y: (origin.y * scaleFactor).rounded(.down) / scaleFactor,
            width: (width * scaleFactor).rounded(.up) / scaleFactor,
            height: (height * scaleFactor).rounded(.up) / scaleFactor
        )
    }
}
```

---

## 7. Line Numbers / Gutter

### Enumerating Lines and Baselines

Walk layout fragments to count lines, extract baselines, and draw line numbers:

```swift
func drawLineNumbers(in dirtyRect: CGRect, gutterWidth: CGFloat) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    var lineNumber = 1

    textLayoutManager.enumerateTextLayoutFragments(
        from: textContentStorage.documentRange.location,
        options: [.ensuresLayout]
    ) { fragment in
        let fragmentFrame = fragment.layoutFragmentFrame

        // Skip fragments outside the dirty rect
        guard fragmentFrame.maxY >= dirtyRect.minY else {
            lineNumber += 1
            return true
        }
        guard fragmentFrame.minY <= dirtyRect.maxY else {
            return false
        }

        // Get baseline from the first character position
        let baseline = fragment.textLineFragments.first
            .map { $0.typographicBounds.origin.y + $0.glyphOrigin.y }
            ?? 0

        // Apply lineHeightMultiple baseline offset if needed
        let baselineOffset = fragment.textLineFragments.first.map {
            $0.typographicBounds.height * (lineHeightMultiple - 1.0) / 2.0
        } ?? 0

        drawLineNumber(
            lineNumber,
            at: fragmentFrame.origin.y + baseline + baselineOffset,
            in: ctx,
            gutterWidth: gutterWidth
        )

        lineNumber += 1
        return true
    }
}
```

### Drawing with CTLine

Use Core Text directly for efficient, right-aligned line number rendering:

```swift
private func drawLineNumber(_ number: Int,
                            at baselineY: CGFloat,
                            in ctx: CGContext,
                            gutterWidth: CGFloat) {
    let string = NSAttributedString(
        string: "\(number)",
        attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
    )
    let line = CTLineCreateWithAttributedString(string)

    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))

    // Right-align within gutter, with padding
    let xPos = gutterWidth - lineWidth - 8.0

    ctx.saveGState()
    ctx.textPosition = CGPoint(x: xPos, y: baselineY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}
```

---

## 8. Cross-Platform Patterns

### macOS isFlipped

TextKit2 expects a top-left coordinate origin. On macOS, override `isFlipped`:

```swift
#if canImport(AppKit)
final class CustomTextView: NSView {
    override var isFlipped: Bool { true }
}
#endif
```

### Conditional Compilation

Use `canImport` for platform-specific code paths:

```swift
#if canImport(AppKit)
import AppKit
typealias PlatformView = NSView
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#elseif canImport(UIKit)
import UIKit
typealias PlatformView = UIView
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#endif
```

### UndoManager RunLoop Modes

On macOS, the undo manager must handle events during event tracking (e.g., mouse drags) and modal panels:

```swift
#if canImport(AppKit)
undoManager.runLoopModes = [.default, .eventTracking, .modalPanel]
#else
undoManager.runLoopModes = [.default]
#endif
```

### Pixel Alignment (Platform-Aware)

```swift
func alignToPixels(_ rect: CGRect) -> CGRect {
    #if canImport(AppKit)
    return backingAlignedRect(rect, options: .alignAllEdgesNearest)
    #else
    let scale = traitCollection.displayScale
    return rect.pixelAligned(scaleFactor: scale)
    #endif
}
```
