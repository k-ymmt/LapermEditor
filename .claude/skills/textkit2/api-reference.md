# TextKit2 API Reference

Detailed reference for the core TextKit2 types, their properties, methods, and usage notes.

## NSTextContentStorage / NSTextContentManager

**Role:** Backing store for text content. Manages the document's text and notifies layout managers of changes.

NSTextContentStorage is the concrete subclass of the abstract NSTextContentManager. It bridges to NSTextStorage internally and manages NSTextElement objects (paragraphs).

**Key Properties:**
- `documentRange: NSTextRange` — Range covering the entire document
- `primaryTextLayoutManager: NSTextLayoutManager?` — The primary layout manager
- `textStorage: NSTextStorage?` — The underlying NSTextStorage (NSTextContentStorage only)
- `hasEditingTransaction: Bool` — Whether currently inside a `performEditingTransaction` block

**Key Methods:**

```swift
// Batch edits with automatic change notification
contentStorage.performEditingTransaction {
    textStorage.replaceCharacters(in: range, with: newString)
}

// Replace content by range (NSTextContentManager)
contentManager.replaceContents(in: textRange, with: [NSTextParagraph(attributedString: attrStr)])

// Enumerate text elements (paragraphs)
contentStorage.enumerateTextElements(from: startLocation, options: []) { element in
    guard let paragraph = element as? NSTextParagraph else { return false }
    print(paragraph.attributedString.string)
    return true // continue enumeration
}

// Get attributed string for a range
let attrStr = contentStorage.attributedString(for: textElement)

// Location / offset arithmetic
let offset = contentStorage.offset(from: documentRange.location, to: someLocation)
let newLoc = contentStorage.location(documentRange.location, offsetBy: 5)
```

**EnumerationOptions:**
- `.reverse` — Enumerate backwards from the given location

**Usage Notes:**
- Always use `performEditingTransaction` for text modifications — it coalesces change notifications and ensures layout invalidation happens correctly.
- `replaceContents(in:with:)` has a known bug (FB9925647) where passing an empty array to delete text may not work correctly. Workaround: use `textStorage.replaceCharacters(in:with:)` inside a `performEditingTransaction`.
- Subclass NSTextContentStorage to customize content replacement by overriding `replaceContents(in:with:)`.
- One NSTextContentStorage can serve multiple NSTextLayoutManagers — useful for split-view editors showing the same document.

---

## NSTextLayoutManager

**Role:** The central coordinator for text layout. Connects content storage to a text container, manages selections, and provides access to layout results (fragments).

**Key Properties:**
- `documentRange: NSTextRange` — Full document range (delegates to content manager)
- `textContainer: NSTextContainer?` — The text container constraining layout
- `textContentManager: NSTextContentManager?` — The backing content manager
- `textViewportLayoutController: NSTextViewportLayoutController` — Viewport layout controller
- `textSelections: [NSTextSelection]` — Current text selections (read/write)
- `textSelectionNavigation: NSTextSelectionNavigation` — Navigation helper for selections
- `usageBoundsForTextContainer: CGRect` — Bounding rect of all laid-out text
- `insertionPointLocations: [CGPoint]` — Cursor positions for current selections
- `insertionPointSelections: [NSTextSelection]` — Zero-length selections at insertion points

**Key Methods:**

```swift
// Ensure text is laid out up to a given range
layoutManager.ensureLayout(for: range)

// Invalidate layout for a range (forces re-layout)
layoutManager.invalidateLayout(for: range)

// Enumerate layout fragments
layoutManager.enumerateTextLayoutFragments(
    from: location,
    options: [.ensuresLayout, .ensuresExtraLineFragment]
) { fragment in
    print(fragment.layoutFragmentFrame)
    return true // continue
}

// Get the frame for a text segment (e.g., selection rect)
let frame = layoutManager.textSegmentFrame(
    at: location,
    type: .selection
)

// Rendering attributes (transient, non-persistent styling)
layoutManager.addRenderingAttribute(.foregroundColor, value: NSColor.red, for: range)
layoutManager.removeRenderingAttribute(.foregroundColor, for: range)

// Enumerate rendering attributes
layoutManager.enumerateRenderingAttributes(from: location, reverse: false) { tlm, attrs, range in
    return true // continue
}
```

**EnumerationOptions for fragments:**
- `.ensuresLayout` — Triggers layout if not yet performed for the requested range
- `.ensuresExtraLineFragment` — Includes the extra line fragment at the end of the document
- `.reverse` — Enumerate fragments in reverse order

**SegmentType:**
- `.standard` — Typographic bounds of glyphs
- `.selection` — Selection highlight rect (may be wider)
- `.highlight` — Highlight rect

**Usage Notes:**
- Use `ensureLayout` sparingly — it forces synchronous layout which can be expensive for large documents.
- `textSelections` is read/write: assign new selections directly to update the selection state.
- Rendering attributes are transient — they are not stored in the text storage and are lost on re-layout. Use them for temporary highlights (search results, diagnostics).
- Subclass NSTextLayoutManager and override `textSelections` didSet to observe selection changes.

---

## NSTextViewportLayoutController

**Role:** Orchestrates viewport-based layout. Only lays out text that is visible in the current viewport, enabling efficient scrolling for large documents.

**Key Properties:**
- `viewportRange: NSTextRange?` — The text range currently visible in the viewport
- `viewportBounds: CGRect` — The visible rect of the viewport (typically from scroll view)
- `delegate: NSTextViewportLayoutControllerDelegate?` — Delegate for layout callbacks

**Key Methods:**

```swift
// Trigger a layout pass for the current viewport
viewportLayoutController.layoutViewport()

// Relocate viewport to a specific location (O(1) operation)
viewportLayoutController.relocateViewport(to: textLocation)
```

**Delegate Protocol (NSTextViewportLayoutControllerDelegate):**

```swift
// Called before layout begins — save current fragment views for later cleanup
func textViewportLayoutControllerWillLayout(
    _ controller: NSTextViewportLayoutController
)

// Return the visible rect for layout — account for gutters, insets, overscroll
func viewportBounds(
    for textViewportLayoutController: NSTextViewportLayoutController
) -> CGRect

// Called per-fragment — create or reuse a view for each layout fragment
func textViewportLayoutController(
    _ controller: NSTextViewportLayoutController,
    configureRenderingSurfaceFor textLayoutFragment: NSTextLayoutFragment
)

// Called after layout completes — remove stale views, update content size
func textViewportLayoutControllerDidLayout(
    _ controller: NSTextViewportLayoutController
)
```

**Usage Notes:**
- Call `layoutViewport()` from your view's layout cycle (e.g., `layout()` or `viewWillDraw()`), not in response to arbitrary events.
- `relocateViewport(to:)` is O(1) — use it for programmatic scrolling to a specific text location.
- `configureRenderingSurface(for:)` is called only for fragments visible in the viewport — add/reuse sublayers or subviews here.
- After `didLayout`, you may call `ensureLayout(for:)` on the layout manager for any additional range you need (e.g., line number gutter).

---

## NSTextLayoutFragment

**Role:** Layout output for a single text element (typically one paragraph). Contains the computed line fragments and their geometry.

**Key Properties:**
- `textElement: NSTextElement?` — The source text element (usually NSTextParagraph)
- `layoutFragmentFrame: CGRect` — Frame in the text container's coordinate space
- `textLineFragments: [NSTextLineFragment]` — The visual lines within this fragment
- `state: State` — Layout state: `.none`, `.estimatedUsageBounds`, `.calculatedUsageBounds`, `.layoutAvailable`
- `isExtraLineFragment: Bool` — Whether this is the extra line fragment at the document's end (iOS 17+ / macOS 14+)

**Key Methods:**

```swift
// Draw the fragment at a point in a graphics context
fragment.draw(at: point, in: context)
```

**NSTextLayoutManagerDelegate method for custom fragments:**

```swift
func textLayoutManager(
    _ textLayoutManager: NSTextLayoutManager,
    textLayoutFragmentFor location: NSTextLocation,
    in textElement: NSTextElement
) -> NSTextLayoutFragment {
    return MyCustomTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
}
```

**Usage Notes:**
- Subclass NSTextLayoutFragment to perform custom drawing (e.g., background highlights, block decorations). Override `draw(at:in:)`.
- `layoutFragmentFrame` for extra line fragments may report incorrect height in some OS versions — verify and adjust in your layout code.
- Check `state == .layoutAvailable` before relying on geometry — fragments with estimated bounds may not have final positions.

---

## NSTextLineFragment

**Role:** Represents a single visual line within a layout fragment. Provides glyph-level geometry for hit testing and cursor positioning.

**Key Properties:**
- `attributedString: NSAttributedString` — The attributed string for this line
- `characterRange: NSRange` — Character range within the parent fragment's text
- `typographicBounds: CGRect` — The typographic bounding rect of the line
- `glyphOrigin: CGPoint` — Origin point for glyph drawing
- `isExtraLineFragment: Bool` — Whether this is the extra line fragment (iOS 17+ / macOS 14+)

**Key Methods:**

```swift
// Get the x-position for a character index (for cursor drawing)
let xPos = lineFragment.locationForCharacter(at: characterIndex)

// Get character index from a point (for hit testing)
let charIndex = lineFragment.characterIndex(for: point)

// Get fraction through glyph at a point (for precise cursor placement)
let fraction = lineFragment.fractionOfDistanceThroughGlyph(for: point)

// Draw the line fragment at a point in a context
lineFragment.draw(at: point, in: context)

// Get the NSTextRange for this line fragment
let textRange = lineFragment.textRange(in: textLayoutFragment)
```

**Usage Notes:**
- `typographicBounds` is relative to the parent NSTextLayoutFragment's origin — add `layoutFragmentFrame.origin` to get coordinates in the text container.
- Use `locationForCharacter(at:)` combined with `typographicBounds` to position the cursor (insertion point) accurately.

---

## NSTextSelection

**Role:** Represents a text selection with one or more ranges, affinity (upstream/downstream), and granularity (character/word/line/paragraph).

**Key Properties:**
- `textRanges: [NSTextRange]` — The selected ranges (supports multiple/discontinuous)
- `affinity: NSTextSelection.Affinity` — `.upstream` or `.downstream`
- `granularity: NSTextSelection.Granularity` — `.character`, `.word`, `.line`, `.sentence`, `.paragraph`
- `anchorPositionOffset: CGFloat` — Horizontal offset for vertical navigation (up/down arrow)
- `isLogical: Bool` — Whether the selection follows logical or visual order
- `typingAttributes: [NSAttributedString.Key: Any]` — Attributes applied to newly typed text

**Initialization:**

```swift
// Simple insertion point
let insertion = NSTextSelection(location: textLocation, affinity: .downstream)

// Selection with a range
let selection = NSTextSelection(range: textRange, affinity: .downstream, granularity: .character)

// Multiple ranges (rectangular/column selection)
let multiSelection = NSTextSelection(textRanges, affinity: .downstream, granularity: .character)
```

**Usage Notes:**
- Always update typing attributes after changing selections.
- Use `.downstream` affinity for most cases; `.upstream` matters at line-wrapping boundaries.
- `anchorPositionOffset` preserves the horizontal position during vertical arrow key movement.
- For multiple cursors, create multiple NSTextSelection objects in the `textSelections` array.

---

## NSTextSelectionNavigation

**Role:** Computes new selections based on user interactions — arrow keys, mouse clicks, word double-clicks, deletion gestures. Does not mutate state directly; returns new selection objects.

**Key Methods:**

```swift
// Compute destination selection for a navigation direction
let newSelections = navigation.destinationSelection(
    for: textSelection,
    direction: .forward,   // .forward, .backward, .up, .down, .left, .right
    destination: .word,    // .character, .word, .line, .sentence, .paragraph, .container, .document
    extending: false       // true for shift-arrow selection extension
)

// Compute ranges to delete for a deletion direction
let rangesToDelete = navigation.deletionRanges(
    for: textSelection,
    direction: .forward,
    destination: .character,
    allowsDecomposition: false
)

// Compute selections for mouse/touch interaction (handles click count)
let selections = navigation.textSelections(
    interactingAt: point,
    inContainerAt: containerLocation,
    anchors: existingSelections,
    modifiers: [],         // .extend, .visual
    selecting: false,      // true while dragging
    bounds: containerBounds
)

// Compute selection for a specific granularity (e.g., double-click word selection)
let wordSelection = navigation.textSelection(
    for: .word,
    enclosing: textSelection
)
```

**Usage Notes:**
- `deletionRanges` with `.word` destination may return incorrect ranges near punctuation in some OS versions — verify edge cases.
- `textSelections(interactingAt:...)` handles single-click, double-click (word), and triple-click (paragraph) based on the `anchors` parameter.
- After modifying selections via navigation, update `typingAttributes` on the new selection to match the attributes at the insertion point.

---

## NSTextRange / NSTextLocation

**Role:** Abstract location model for TextKit2. Unlike NSRange (integer offset), NSTextLocation is a protocol that allows opaque, implementation-defined positions.

**NSTextRange Properties:**
- `location: NSTextLocation` — Start of the range (inclusive)
- `endLocation: NSTextLocation` — End of the range (exclusive)
- `isEmpty: Bool` — Whether the range is empty (location == endLocation)

**NSTextRange Methods:**

```swift
// Create a range from two locations
let range = NSTextRange(location: start, end: end)

// Create a zero-length range (insertion point)
let point = NSTextRange(location: loc)

// Check containment
range.contains(location)
range.contains(otherRange)

// Check intersection
range.intersects(otherRange)
let intersection = range.intersection(otherRange) // NSTextRange?
```

**Location arithmetic via NSTextContentManager:**

```swift
// Offset between two locations
let offset = contentManager.offset(from: loc1, to: loc2)

// Location offset by integer
let newLoc = contentManager.location(loc1, offsetBy: 5)
```

**Conversion to NSRange:**

```swift
// NSTextRange -> NSRange (via NSTextContentStorage)
let nsRange = NSRange(
    contentStorage.offset(from: contentStorage.documentRange.location, to: textRange.location) ..< 
    contentStorage.offset(from: contentStorage.documentRange.location, to: textRange.endLocation)
)

// NSRange -> NSTextRange
if let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: nsRange.location),
   let end = contentStorage.location(start, offsetBy: nsRange.length) {
    let textRange = NSTextRange(location: start, end: end)
}
```

**Usage Notes:**
- `NSTextLocation` is a protocol, not a concrete type — you cannot create instances directly. Use locations obtained from NSTextContentManager, NSTextRange, or NSTextLayoutManager.
- Use NSTextContentManager methods (`offset(from:to:)`, `location(_:offsetBy:)`) for all location arithmetic — do not assume integer offsets.
- `endLocation` is exclusive — a range from location 0 to location 5 covers characters 0 through 4.

---

## NSTextElement / NSTextParagraph

**Role:** Content model. NSTextElement is the abstract base; NSTextParagraph is the concrete subclass representing a paragraph of attributed text (delimited by paragraph separators).

**NSTextElement Properties:**
- `elementRange: NSTextRange?` — The range of this element in the document
- `textContentManager: NSTextContentManager?` — The owning content manager

**NSTextParagraph Properties:**
- `attributedString: NSAttributedString` — The paragraph's attributed text (including paragraph separator)
- `paragraphContentRange: NSTextRange?` — Range of the content (excluding paragraph separator)
- `paragraphSeparatorRange: NSTextRange?` — Range of the paragraph separator character(s)

**Creating for replacement:**

```swift
// Create a paragraph element for inserting into the document
let paragraph = NSTextParagraph(attributedString: NSAttributedString(
    string: "New paragraph text\n",
    attributes: [.font: NSFont.systemFont(ofSize: 14)]
))

contentStorage.performEditingTransaction {
    contentStorage.replaceContents(in: targetRange, with: [paragraph])
}
```

**Enumerating elements:**

```swift
// Walk all paragraphs in the document
contentStorage.enumerateTextElements(from: contentStorage.documentRange.location) { element in
    guard let paragraph = element as? NSTextParagraph else { return true }
    
    let text = paragraph.attributedString.string
    let contentRange = paragraph.paragraphContentRange
    let separatorRange = paragraph.paragraphSeparatorRange
    
    print("Content: \(text), range: \(String(describing: contentRange))")
    return true // continue enumeration
}
```

**Usage Notes:**
- Each paragraph typically maps to one NSTextLayoutFragment after layout.
- When replacing content, wrap attributed strings in NSTextParagraph — passing raw NSAttributedString to `replaceContents(in:with:)` is not supported.
- Paragraph separators (`\n`, `\r\n`, Unicode paragraph/line separators) are part of the preceding paragraph's element, accessible via `paragraphSeparatorRange`.
