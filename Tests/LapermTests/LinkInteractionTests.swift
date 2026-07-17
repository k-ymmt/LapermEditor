import AppKit
import Testing
@testable import Laperm
@testable import LapermCore

@MainActor
private func makeTextView(_ markdown: String) -> MarkdownTextView {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = markdown
    textView.highlightAll()
    return textView
}

@MainActor @Test func commandClickOnLinkCallsOnOpenLink() {
    let textView = makeTextView("See [site](https://example.com/a).")
    var opened: URL?
    textView.onOpenLink = { opened = $0; return true }
    // "site" の中心をクリック
    let point = midpoint(of: NSRange(location: 5, length: 4), in: textView)
    #expect(textView.openLink(atPoint: point))
    #expect(opened == URL(string: "https://example.com/a"))
}

@MainActor @Test func clickOutsideLinkDoesNotOpen() {
    let textView = makeTextView("See [site](https://example.com/a).")
    var opened: URL?
    textView.onOpenLink = { opened = $0; return true }
    // "See" の中心をクリック
    let point = midpoint(of: NSRange(location: 0, length: 3), in: textView)
    #expect(!textView.openLink(atPoint: point))
    #expect(opened == nil)
}

@MainActor @Test func openLinkRespectsDisabledOption() {
    let textView = makeTextView("[site](https://example.com)")
    textView.linkOptions.opensOnCommandClick = false
    textView.onOpenLink = { _ in true }
    let point = midpoint(of: NSRange(location: 1, length: 4), in: textView)
    #expect(!textView.openLink(atPoint: point))
}

@MainActor @Test func bareURLIsClickable() {
    let textView = makeTextView("Go https://example.com/bare now")
    var opened: URL?
    textView.onOpenLink = { opened = $0; return true }
    let point = midpoint(of: NSRange(location: 3, length: 24), in: textView)
    #expect(textView.openLink(atPoint: point))
    #expect(opened == URL(string: "https://example.com/bare"))
}

@MainActor @Test func relativeLinkResolvesAgainstBaseURL() {
    let textView = makeTextView("[doc](notes/a.md)")
    textView.linkOptions.baseURL = URL(filePath: "/docs/", directoryHint: .isDirectory)
    var opened: URL?
    textView.onOpenLink = { opened = $0; return true }
    let point = midpoint(of: NSRange(location: 1, length: 3), in: textView)
    #expect(textView.openLink(atPoint: point))
    #expect(opened?.absoluteString == "file:///docs/notes/a.md")
}

@MainActor @Test func unresolvableLinkDoesNotOpen() {
    // 相対パスで baseURL なし → 解決不能 → 開かない(NSWorkspace へも渡らない)
    let textView = makeTextView("[doc](notes/a.md)")
    textView.onOpenLink = { _ in true }
    let point = midpoint(of: NSRange(location: 1, length: 3), in: textView)
    #expect(!textView.openLink(atPoint: point))
}

@MainActor @Test func hoverWithCommandOverLinkSetsHoveredRange() {
    let textView = makeTextView("See [site](https://example.com/a).")
    let point = midpoint(of: NSRange(location: 5, length: 4), in: textView)
    textView.refreshLinkHover(atPoint: point, commandHeld: true)
    let md = "See [site](https://example.com/a)."
    #expect(textView.debugHoveredLinkRange
        == (md as NSString).range(of: "[site](https://example.com/a)"))
}

@MainActor @Test func hoverWithoutCommandClearsHoveredRange() {
    let textView = makeTextView("See [site](https://example.com/a).")
    let point = midpoint(of: NSRange(location: 5, length: 4), in: textView)
    textView.refreshLinkHover(atPoint: point, commandHeld: true)
    textView.refreshLinkHover(atPoint: point, commandHeld: false)
    #expect(textView.debugHoveredLinkRange == nil)
}

@MainActor @Test func hoverAppliesAndRemovesUnderline() {
    // NSTextLayoutManager.addRenderingAttribute(.underlineStyle, ...) は実機の GUI 検証で
    // 描画に反映されないことが確認された(.backgroundColor 等は反映されるため下線特有の制約)。
    // そのため下線は LinkHoverOverlayView への矩形計算で表現しており、ここではその矩形群を検証する。
    let textView = makeTextView("See [site](https://example.com/a).")
    let point = midpoint(of: NSRange(location: 5, length: 4), in: textView)
    textView.refreshLinkHover(atPoint: point, commandHeld: true)
    #expect(!textView.debugLinkHoverUnderlineRects.isEmpty)
    textView.refreshLinkHover(atPoint: point, commandHeld: false)
    #expect(textView.debugLinkHoverUnderlineRects.isEmpty)
}

@MainActor @Test func mouseExitClearsHoverAndUnderline() {
    let textView = makeTextView("See [site](https://example.com/a).")
    let point = midpoint(of: NSRange(location: 5, length: 4), in: textView)
    textView.refreshLinkHover(atPoint: point, commandHeld: true)
    textView.clearLinkHoverOnExit()
    #expect(textView.debugHoveredLinkRange == nil)
    #expect(textView.debugLinkHoverUnderlineRects.isEmpty)
}

@MainActor @Test func textChangeClearsHoveredRange() {
    let textView = makeTextView("See [site](https://example.com/a).")
    let point = midpoint(of: NSRange(location: 5, length: 4), in: textView)
    textView.refreshLinkHover(atPoint: point, commandHeld: true)
    textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
    #expect(textView.debugHoveredLinkRange == nil)
}

@MainActor @Test func pasteURLOverSelectionLinkifies() {
    let textView = makeTextView("see docs here")
    textView.setSelectedRange(NSRange(location: 4, length: 4))
    #expect(textView.applyLinkifiedPaste("https://example.com"))
    #expect(textView.string == "see [docs](https://example.com) here")
}

@MainActor @Test func pasteURLWithoutSelectionFallsBack() {
    let textView = makeTextView("see docs here")
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(!textView.applyLinkifiedPaste("https://example.com"))
    #expect(textView.string == "see docs here")
}

@MainActor @Test func pasteLinkifyRespectsDisabledOption() {
    let textView = makeTextView("see docs here")
    textView.editingOptions.linkifiesPastedURL = false
    textView.setSelectedRange(NSRange(location: 4, length: 4))
    #expect(!textView.applyLinkifiedPaste("https://example.com"))
}

@MainActor @Test func pasteLinkifyUndoesInOneStep() {
    let textView = makeTextView("see docs here")
    let undoProvider = UndoManagerProvider()
    textView.delegate = undoProvider
    textView.setSelectedRange(NSRange(location: 4, length: 4))
    #expect(textView.applyLinkifiedPaste("https://example.com"))
    undoProvider.manager.undo()
    #expect(textView.string == "see docs here")
}
