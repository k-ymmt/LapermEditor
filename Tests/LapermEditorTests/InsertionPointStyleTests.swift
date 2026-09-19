#if os(macOS)
import AppKit
import Testing
@testable import LapermEditor
@testable import LapermCore

@MainActor
private func overlay(in textView: MarkdownTextView) -> InsertionPointOverlayView? {
    textView.subviews.compactMap { $0 as? InsertionPointOverlayView }.first
}

@MainActor @Test func defaultStyleHasNoOverlay() {
    let textView = MarkdownTextView()
    textView.string = "abc"
    #expect(textView.insertionPointStyle == .bar)
    #expect(overlay(in: textView) == nil)
}

@MainActor @Test func blockStyleShowsOverlayCoveringCharacter() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "abc"
    textView.setSelectedRange(NSRange(location: 1, length: 0))
    textView.insertionPointStyle = .block
    let view = overlay(in: textView)
    #expect(view != nil)
    // "b" のグリフ中心を覆っている
    let mid = midpoint(of: NSRange(location: 1, length: 1), in: textView)
    #expect(view?.frame.contains(mid) == true)
}

@MainActor @Test func overlayFollowsSelectionChanges() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "abcdef"
    textView.insertionPointStyle = .block
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    let xAtStart = overlay(in: textView)!.frame.minX
    textView.setSelectedRange(NSRange(location: 4, length: 0))
    #expect(overlay(in: textView)!.frame.minX > xAtStart)
}

@MainActor @Test func overlayHasWidthAtLineEndAndEmptyDocument() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "ab"
    textView.setSelectedRange(NSRange(location: 2, length: 0))  // 行末
    textView.insertionPointStyle = .block
    #expect((overlay(in: textView)?.frame.width ?? 0) > 0)

    textView.string = ""
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    #expect((overlay(in: textView)?.frame.width ?? 0) > 0)
}

@MainActor @Test func underlineStyleAlsoShowsOverlay() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "abc"
    textView.setSelectedRange(NSRange(location: 1, length: 0))
    textView.insertionPointStyle = .underline
    let view = overlay(in: textView)
    #expect(view != nil)
    #expect(view?.style == .underline)
}

@MainActor @Test func selectionHidesOverlay() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "abc"
    textView.insertionPointStyle = .block
    textView.setSelectedRange(NSRange(location: 0, length: 2))
    #expect(overlay(in: textView) == nil)
}

@MainActor @Test func revertingToBarRemovesOverlayAndRestoresColor() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "abc"
    let originalColor = textView.insertionPointColor
    textView.insertionPointStyle = .block
    #expect(textView.insertionPointColor == .clear)  // システムのバーを消す
    textView.insertionPointStyle = .bar
    #expect(overlay(in: textView) == nil)
    #expect(textView.insertionPointColor == originalColor)
}

@MainActor @Test func editingKeepsOverlayOnCaret() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "ab"
    textView.insertionPointStyle = .block
    textView.setSelectedRange(NSRange(location: 2, length: 0))
    textView.insertText("c", replacementRange: NSRange(location: NSNotFound, length: 0))
    let view = overlay(in: textView)
    #expect(view != nil)
    let mid = midpoint(of: NSRange(location: 2, length: 1), in: textView)
    // 挿入後のカーソル(offset 3 = "c" の後ろ)より左にある "c" は覆わない —
    // オーバーレイは行末キャレット位置("c" の右)にある
    #expect((view?.frame.minX ?? 0) >= mid.x)
}
#endif
