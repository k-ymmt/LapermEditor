# TextKit2 Known Issues & Workarounds

Documented TextKit2 bugs with Apple Feedback (FB) numbers and production-tested workarounds. These bugs may be fixed in future OS versions — use `#available` checks where appropriate.

---

## 1. FB9925647 — NSTextContentStorage.replaceContents Does Not Work

**Symptom:** Calling `replaceContents(in:with:)` on `NSTextContentStorage` silently fails to replace any text.

**Impact:** All text editing operations are broken when relying on the default implementation.

**Workaround:** Subclass `NSTextContentStorage` and override `replaceContents` to access the underlying `textStorage` directly.

```swift
class CustomTextContentStorage: NSTextContentStorage {
    override func replaceContents(in range: NSTextRange, with textElements: [NSTextElement]?) {
        guard let textStorage = textStorage else { return }
        assert(hasEditingTransaction, "Must be called within performEditingTransaction")

        let nsRange = NSRange(range, in: self)
        let replacement = textElements?
            .compactMap { ($0 as? NSTextParagraph)?.attributedString.string }
            .joined() ?? ""
        textStorage.replaceCharacters(in: nsRange, with: replacement)
    }
}
```

---

## 2. FB9925766 — NSTextSelectionNavigation.deletionRanges Incorrect for Word Deletion

**Symptom:** `deletionRanges(for:direction:destination:allowsDecomposition:)` returns incorrect ranges when `destination` is `.word`.

**Impact:** Option+Delete (word deletion) deletes the wrong text, often removing more or fewer characters than expected.

**Workaround:** Use `destinationSelection(for:direction:destination:extending:confined:)` with `extending: true` to compute the correct word range, then delete the resulting selection range.

```swift
func wordDeletionRange(
    for selection: NSTextSelection,
    direction: NSTextSelectionNavigation.Direction,
    using navigation: NSTextSelectionNavigation
) -> [NSTextRange] {
    // Do NOT use: navigation.deletionRanges(for:direction:destination:.word:...)
    // Instead, use destinationSelection with extending:true:
    let extended = navigation.destinationSelection(
        for: selection, direction: direction,
        destination: .word, extending: true, confined: false
    )
    return extended?.textRanges ?? []
}
```

---

## 3. FB15131180 — Extra Line Fragment Frame Miscalculated

**Symptom:** The `layoutFragmentFrame` of the extra line fragment (the empty trailing line after a final newline) has an incorrect frame — typically zero width or wrong origin.

**Impact:** Content size calculation, gutter alignment, and scrolling behavior are all affected, especially when the document ends with a newline.

**Workaround:** Compute typographic bounds manually via an extension on `NSTextLayoutFragment`, and use those bounds for content size and viewport calculations.

```swift
extension NSTextLayoutFragment {
    /// Typographic bounds computed from actual line fragments,
    /// bypassing the potentially incorrect layoutFragmentFrame.
    var safeTypographicBounds: CGRect {
        var result = CGRect.null
        for lineFragment in textLineFragments {
            let origin = lineFragment.typographicBounds.origin
            result = result.union(CGRect(
                x: layoutFragmentFrame.origin.x + origin.x,
                y: layoutFragmentFrame.origin.y + origin.y,
                width: lineFragment.typographicBounds.width,
                height: lineFragment.typographicBounds.height
            ))
        }
        return result
    }
}

// Content size computation using safeTypographicBounds:
func computeContentSize(layoutManager: NSTextLayoutManager) -> CGSize {
    var height: CGFloat = 0, width: CGFloat = 0
    layoutManager.enumerateTextLayoutFragments(
        from: layoutManager.documentRange.endLocation,
        options: [.reverse, .ensuresLayout]
    ) { fragment in
        let bounds = fragment.safeTypographicBounds
        height = max(height, bounds.maxY)
        width = max(width, bounds.maxX)
        return false // stop after last fragment
    }
    return CGSize(width: width, height: height)
}

// After editing, relocate viewport to keep content visually stable:
layoutManager.textViewportLayoutController.relocateViewport(to: editLocation)
```

---

## 4. FB21059465 — NSScrollView Horizontal Floating Subview Ignores Content Insets

**Symptom:** A floating subview anchored to the horizontal axis does not account for `contentInsets` when calculating its position.

**Impact:** Gutter (line number) views are offset incorrectly when content insets are applied to the scroll view.

**Workaround:** Manually adjust the floating subview's frame in `layout()` to compensate for content insets.

```swift
override func layout() {
    super.layout()

    if let gutterView = gutterView {
        var frame = gutterView.frame
        frame.origin.y = contentInsets.top
        frame.size.height = contentView.bounds.height
        gutterView.frame = frame
    }
}
```

---

## 5. Layout Fragment State Not Ready Before Draw

**Symptom:** `draw(at:in:)` is called on an `NSTextLayoutFragment` before its internal state reaches `.layoutAvailable`, resulting in no content to render.

**Impact:** Blank or partially rendered text in the view.

**Workaround:** Check the fragment's state before drawing and force layout if necessary.

```swift
extension NSTextLayoutFragment {
    func ensureLayout() {
        // state.rawValue < 2 means layout is not yet available
        if state.rawValue < 2 {
            // Trigger internal layout computation
            let layoutSelector = NSSelectorFromString("layout")
            if responds(to: layoutSelector) {
                perform(layoutSelector)
            }
        }
    }
}

// Usage in custom NSTextLayoutFragment subclass:
override func draw(at point: CGPoint, in context: CGContext) {
    ensureLayout()
    super.draw(at: point, in: context)
}
```

> **Note:** This relies on a private API (`layout()` selector). Monitor future SDK releases for a public equivalent and guard with `responds(to:)`.

---

## 6. Selection Duplication After replaceContents

**Symptom:** After calling `replaceContents`, the internal method `_fixSelectionAfterChangeInCharacterRange` produces duplicate `NSTextSelection` objects at the same position.

**Impact:** Multiple cursors appear at the same position, causing erratic editing behavior.

**Workaround:** Deduplicate selections after each editing transaction while preserving affinity, granularity, and typing attributes.

```swift
func deduplicateSelections(_ selections: [NSTextSelection]) -> [NSTextSelection] {
    var seen = Set<String>()
    return selections.filter { selection in
        let key = selection.textRanges.map { "\($0.location)–\($0.endLocation)" }.joined(separator: ",")
        return seen.insert(key).inserted
    }
}

// Apply after editing:
textLayoutManager.performEditingTransaction {
    textContentStorage.replaceContents(in: range, with: elements)
}
textLayoutManager.textSelections = deduplicateSelections(textLayoutManager.textSelections)
```

---

## 7. lineHeightMultiple Not Applied During Layout

**Symptom:** When `NSParagraphStyle.lineHeightMultiple` is set to a value greater than 1.0, text is top-aligned within the expanded line height instead of being vertically centered.

**Impact:** Line spacing appears visually incorrect — text clings to the top of each line rather than being centered.

**Workaround:** Apply a manual vertical offset in a custom `NSTextLayoutFragment` subclass's `draw` override.

**Formula:**

```
baselineOffset = -(lineHeight * (lineHeightMultiple - 1.0) / 2)
```

```swift
class CustomTextLayoutFragment: NSTextLayoutFragment {
    var lineHeightMultiple: CGFloat = 1.0

    override func draw(at point: CGPoint, in context: CGContext) {
        let baselineOffset = -(textLineFragments.first?.typographicBounds.height ?? 0)
            * (lineHeightMultiple - 1.0) / 2.0

        let adjustedPoint = CGPoint(
            x: point.x,
            y: point.y + baselineOffset
        )

        super.draw(at: adjustedPoint, in: context)
    }
}
```

> **Note:** Apply the same `baselineOffset` to gutter line number drawing so that line numbers remain aligned with their corresponding text lines.

---

## General Guidance

- **Version-check workarounds:** Wrap workaround code with `if #available(macOS ...)` checks so that fixes can be removed when Apple resolves the underlying bug.
- **Test on each new OS version:** Re-verify all workarounds after major macOS/iOS releases. Apple may fix these issues without notice.
- **File Feedback reports:** Always file Feedback Assistant reports with Apple. Reference the FB numbers above when following up.
- **performEditingTransaction is mandatory:** All mutations to text content must occur within `performEditingTransaction`. Editing outside a transaction leads to undefined behavior, crashes, or silently dropped changes.
