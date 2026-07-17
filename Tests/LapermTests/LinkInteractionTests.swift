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
