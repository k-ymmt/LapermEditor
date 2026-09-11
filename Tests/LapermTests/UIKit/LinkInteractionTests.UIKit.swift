#if canImport(UIKit)
import SwiftUI
import Testing
import UIKit
@testable import Laperm
@testable import LapermCore

@MainActor @Test func commandTapOnLinkCallsOnOpenLink() {
    let textView = makeLaidOutTextView("See [site](https://example.com/a).")
    var opened: URL?
    textView.onOpenLink = { opened = $0; return true }
    let point = midpoint(of: NSRange(location: 5, length: 4), in: textView)
    #expect(textView.shouldInterceptTap(atPoint: point, modifiers: .command))
    #expect(textView.openLink(atPoint: point))
    #expect(opened == URL(string: "https://example.com/a"))
}

@MainActor @Test func plainTapOnLinkIsNotIntercepted() {
    // 通常タップはキャレット移動(UITextView 標準)に流す
    let textView = makeLaidOutTextView("See [site](https://example.com/a).")
    let point = midpoint(of: NSRange(location: 5, length: 4), in: textView)
    #expect(!textView.shouldInterceptTap(atPoint: point, modifiers: []))
}

@MainActor @Test func tapOutsideLinkDoesNotOpen() {
    let textView = makeLaidOutTextView("See [site](https://example.com/a).")
    var opened: URL?
    textView.onOpenLink = { opened = $0; return true }
    let point = midpoint(of: NSRange(location: 0, length: 3), in: textView)
    #expect(!textView.openLink(atPoint: point))
    #expect(opened == nil)
}

@MainActor @Test func openLinkRespectsDisabledOption() {
    let textView = makeLaidOutTextView("[site](https://example.com)")
    textView.linkOptions.opensOnCommandClick = false
    textView.onOpenLink = { _ in true }
    let point = midpoint(of: NSRange(location: 1, length: 4), in: textView)
    #expect(!textView.openLink(atPoint: point))
    #expect(!textView.openLink(at: 2))
}

@MainActor @Test func openLinkAtOffsetForEditMenu() {
    // 長押しメニュー「リンクを開く」はキャレット位置(オフセット)で開く
    let textView = makeLaidOutTextView("See [site](https://example.com/a).")
    var opened: URL?
    textView.onOpenLink = { opened = $0; return true }
    #expect(textView.openLink(at: 6))
    #expect(opened == URL(string: "https://example.com/a"))
    #expect(!textView.openLink(at: 1))
}

@MainActor @Test func relativeLinkResolvesAgainstBaseURL() {
    let textView = makeLaidOutTextView("[doc](notes/a.md)")
    textView.linkOptions.baseURL = URL(filePath: "/docs/", directoryHint: .isDirectory)
    var opened: URL?
    textView.onOpenLink = { opened = $0; return true }
    let point = midpoint(of: NSRange(location: 1, length: 3), in: textView)
    #expect(textView.openLink(atPoint: point))
    #expect(opened?.absoluteString == "file:///docs/notes/a.md")
}

@MainActor @Test func commandTapBelowLinkLineDoesNotOpen() {
    let textView = makeLaidOutTextView("[site](https://example.com)", height: 2000)
    var opened: URL?
    textView.onOpenLink = { opened = $0; return true }
    var point = midpoint(of: NSRange(location: 1, length: 4), in: textView)
    point.y += 100
    #expect(!textView.openLink(atPoint: point))
    #expect(opened == nil)
}

@MainActor @Test func hoverWithCommandOverLinkSetsHoveredRangeAndUnderline() {
    let md = "See [site](https://example.com/a)."
    let textView = makeLaidOutTextView(md)
    let point = midpoint(of: NSRange(location: 5, length: 4), in: textView)
    textView.refreshLinkHover(atPoint: point, commandHeld: true)
    #expect(textView.debugHoveredLinkRange
        == (md as NSString).range(of: "[site](https://example.com/a)"))
    #expect(!textView.debugLinkHoverUnderlineRects.isEmpty)
    textView.refreshLinkHover(atPoint: point, commandHeld: false)
    #expect(textView.debugHoveredLinkRange == nil)
    #expect(textView.debugLinkHoverUnderlineRects.isEmpty)
}

@MainActor @Test func hoverPointOutsideBoundsClearsHover() {
    let textView = makeLaidOutTextView("See [site](https://example.com/a).")
    let point = midpoint(of: NSRange(location: 5, length: 4), in: textView)
    textView.refreshLinkHover(atPoint: point, commandHeld: true)
    #expect(textView.debugHoveredLinkRange != nil)
    textView.refreshLinkHover(atPoint: CGPoint(x: -100, y: -100), commandHeld: true)
    #expect(textView.debugHoveredLinkRange == nil)
}

@MainActor @Test func textChangeClearsHoveredRange() {
    let textView = makeLaidOutTextView("See [site](https://example.com/a).")
    let point = midpoint(of: NSRange(location: 5, length: 4), in: textView)
    textView.refreshLinkHover(atPoint: point, commandHeld: true)
    textView.selectedRange = NSRange(location: 0, length: 0)
    textView.insertText("x")
    #expect(textView.debugHoveredLinkRange == nil)
}

@MainActor @Test func pasteURLOverSelectionLinkifies() {
    let textView = makeLaidOutTextView("see docs here")
    textView.selectedRange = NSRange(location: 4, length: 4)
    #expect(textView.applyLinkifiedPaste("https://example.com"))
    #expect(textView.text == "see [docs](https://example.com) here")
}

@MainActor @Test func pasteURLWithoutSelectionFallsBack() {
    let textView = makeLaidOutTextView("see docs here")
    textView.selectedRange = NSRange(location: 0, length: 0)
    #expect(!textView.applyLinkifiedPaste("https://example.com"))
    #expect(textView.text == "see docs here")
}

@MainActor @Test func pasteLinkifyUndoesInOneStep() {
    let textView = makeLaidOutTextView("see docs here")
    let window = hostInWindow(textView)
    defer { window.isHidden = true }
    textView.selectedRange = NSRange(location: 4, length: 4)
    #expect(textView.applyLinkifiedPaste("https://example.com"))
    textView.undoManager?.undo()
    #expect(textView.text == "see docs here")
}

@MainActor @Test func editMenuAddsOpenLinkOnlyOnLinks() {
    let textView = makeLaidOutTextView("See [site](https://example.com/a).")
    let suggested: [UIMenuElement] = [UIAction(title: "Copy") { _ in }]
    let onLink = textView.editMenu(forTextIn: NSRange(location: 6, length: 0), suggestedActions: suggested)
    #expect(onLink.children.count == 2)
    #expect(onLink.children.first?.title == String(localized: "Open Link", bundle: .module))
    let offLink = textView.editMenu(forTextIn: NSRange(location: 1, length: 0), suggestedActions: suggested)
    #expect(offLink.children.count == 1)
    textView.linkOptions.opensOnCommandClick = false
    #expect(textView.editMenu(forTextIn: NSRange(location: 6, length: 0), suggestedActions: suggested).children.count == 1)
}

@MainActor @Test func coordinatorProvidesLinkEditMenu() {
    let coordinator = MarkdownEditorView(text: .constant("")).makeCoordinator()
    let textView = makeLaidOutTextView("[site](https://example.com)")
    let menu = coordinator.textView(textView, editMenuForTextIn: NSRange(location: 2, length: 0), suggestedActions: [])
    #expect(menu?.children.count == 1)
}
#endif
