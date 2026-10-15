#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import LapermEditor

// Link Preview(Laperm ADR 0046)の iOS: カードの上のタッチは自分のタップが受け取り、書いた URL を開く。長押しのメニューの
// 「編集」で URL の末尾にキャレットが置かれて展開する。

// "# T\n"(0-3) "\n"(4) "https://a.example/post"(5-26) "\n"(27) "\n"(28) "after"(29-33)
private let sample = "# T\n\nhttps://a.example/post\n\nafter"
private let sampleURL = URL(string: "https://a.example/post")!

@MainActor
private final class FixedLinkPreviewProvider: LinkPreviewProvider {
    private(set) var requested: [URL] = []
    @MainActor func linkPreview(for url: URL) async -> LinkPreview? {
        requested.append(url)
        return LinkPreview(title: "A post", description: "What the post says", siteName: "A Example")
    }
}

@MainActor
private func settle(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<500 {
        if condition() { return }
        await Task.yield()
    }
    if !condition() { Issue.record("the condition never held", sourceLocation: sourceLocation) }
}

@MainActor @Test func linkPreviewCollapsesIntoACardThatOpensOnTapAndExpandsFromTheMenu() async throws {
    let textView = makeLaidOutTextView(sample)
    let window = hostInWindow(textView)
    defer { withExtendedLifetime(window) {} }
    let provider = FixedLinkPreviewProvider()
    textView.linkPreviewProvider = provider
    textView.isLivePreviewEnabled = true
    textView.selectedRange = NSRange(location: 31, length: 0)  // after
    await settle { textView.linkPreviewController.isCollapsed(linkPreviewAt: 5) }
    #expect(provider.requested == [sampleURL])
    textView.layoutIfNeeded()
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    let entry = try #require(textView.debugLinkPreviewEntries.first)
    #expect(entry.location == 5)
    #expect(entry.frame.minX == textView.editorTextContainerOrigin.x + textView.textContainer.lineFragmentPadding)
    #expect(entry.frame.width == min(560, textView.imageContainerWidth))
    #expect(entry.layout.preview.title == "A post")

    // カードの上のタッチは自分のタップが受け取り、書いた URL を onOpenLink に渡す(展開しない)
    var opened: [URL] = []
    textView.onOpenLink = { opened.append($0); return true }
    let onCard = CGPoint(x: entry.frame.midX, y: entry.frame.midY)
    #expect(textView.shouldInterceptTap(atPoint: onCard, modifiers: []))
    let hit = try #require(textView.linkHit(atPoint: onCard))
    #expect(hit.target == .url(destination: "https://a.example/post"))
    #expect(hit.isRendered)
    #expect(textView.tapRenderedLink(atPoint: onCard))
    #expect(opened == [sampleURL])
    #expect(textView.linkPreviewController.collapsedLocations == [5])
    // Cmd+タップもカードで当てて開く
    #expect(textView.shouldInterceptTap(atPoint: onCard, modifiers: .command))
    #expect(textView.openLink(atPoint: onCard))
    #expect(opened == [sampleURL, sampleURL])

    // 長押しのメニュー: Open Link / Copy Link / Edit。Edit で URL の末尾にキャレットが置かれ、展開する
    let menu = textView.linkMenu(for: hit)
    #expect(menu.children.map(\.title) == [LinkMenuTitle.open, LinkMenuTitle.copy, LinkMenuTitle.edit])
    textView.beginEditing(at: hit.editCaret)
    #expect(textView.selectedRange == NSRange(location: 27, length: 0))
    #expect(textView.linkPreviewController.collapsedLocations.isEmpty)
    textView.layoutIfNeeded()
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    #expect(textView.debugLinkPreviewEntries.isEmpty)
    #expect(textView.text == sample, "the card never rewrites the text")

    // キーボードを閉じる(first responder でなくなる)と折りたたむ
    textView.resignFirstResponder()
    #expect(textView.linkPreviewController.collapsedLocations == [5])
    // 設定で無効
    textView.linkPreviewOptions = LinkPreviewOptions(isEnabled: false)
    #expect(textView.linkPreviewController.collapsedLocations.isEmpty)
    #expect(!textView.shouldInterceptTap(atPoint: onCard, modifiers: []))
}
#endif
