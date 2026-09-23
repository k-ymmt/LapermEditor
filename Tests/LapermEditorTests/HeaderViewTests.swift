#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import LapermEditor

/// ヘッダ(本文の上に置くサブビュー)は本文を `textContainerInset.height` だけ下げ、テキストコンテナと同じ
/// 左右位置(余白 + lineFragmentPadding)に置かれる。
@MainActor @Test func headerInsetsTheTextAndAlignsWithTheContainer() {
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    textView.margins = .readable
    textView.showsLineNumbers = false
    scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    scrollView.layoutSubtreeIfNeeded()
    #expect(textView.textContainerInset == NSSize(width: 20, height: 0))

    let header = NSView()
    textView.headerHeight = 50
    #expect(textView.textContainerInset.height == 0, "the height alone does nothing without a header view")
    textView.headerView = header
    #expect(header.superview === textView)
    #expect(textView.textContainerInset == NSSize(width: 20, height: 50))
    #expect(textView.textContainerOrigin.y == 50, "the text starts below the header")
    textView.layoutSubtreeIfNeeded()
    let padding = textView.textContainer!.lineFragmentPadding
    #expect(header.frame == NSRect(x: 20 + padding, y: 0, width: 400 - 2 * (20 + padding), height: 50))

    // 幅が変わっても余白に追従する: (1024 − 40 × 17) / 2 = 172(bodyFont 17pt)
    var theme = textView.theme
    theme.bodyFont = .systemFont(ofSize: 17)
    textView.theme = theme
    scrollView.frame = NSRect(x: 0, y: 0, width: 1024, height: 300)
    scrollView.layoutSubtreeIfNeeded()
    #expect(textView.textContainerInset == NSSize(width: 172, height: 50), "the margin update keeps the header inset")
    #expect(header.frame.minX == 172 + padding)
    #expect(header.frame.width == 680 - 2 * padding)

    // 高さの変更と取り外し
    textView.headerHeight = 30
    #expect(textView.textContainerInset.height == 30)
    textView.headerView = nil
    #expect(header.superview == nil)
    #expect(textView.textContainerInset == NSSize(width: 172, height: 0))
}

/// NSTextView は子要素を公開しないので、ヘッダを accessibility の子として返す(XCUITest / 支援技術向け)。
/// NSControl は自身を無視してセルを要素にするので、要素そのものである NSView で確かめる。
@MainActor @Test func headerIsExposedAsAnAccessibilityChild() {
    let textView = MarkdownTextView()
    let header = NSView()
    header.setAccessibilityElement(true)
    header.setAccessibilityRole(.group)
    #expect((textView.accessibilityChildren() ?? []).isEmpty)
    textView.headerView = header
    let children = textView.accessibilityChildren() ?? []
    #expect(children.contains { ($0 as AnyObject) === header })
    textView.headerView = nil
    #expect((textView.accessibilityChildren() ?? []).isEmpty)
}

/// 幅追従を切ったテキストコンテナでは、ヘッダの幅はビュー幅ではなくコンテナの幅(行のパディングを除く)に合わせる。
@MainActor @Test func headerWidthFollowsANonTrackingContainer() {
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    textView.showsLineNumbers = false
    scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    scrollView.layoutSubtreeIfNeeded()
    let container = textView.textContainer!
    container.widthTracksTextView = false
    container.size = NSSize(width: 200, height: container.size.height)
    let header = NSView()
    textView.headerView = header
    textView.headerHeight = 40
    textView.layoutSubtreeIfNeeded()
    let padding = container.lineFragmentPadding
    #expect(header.frame.minX == padding)
    #expect(header.frame.width == 200 - 2 * padding, "\(header.frame)")
}

@MainActor @Test func headerHeightIsSanitized() {
    let textView = MarkdownTextView()
    textView.headerView = NSView()
    textView.headerHeight = -10
    #expect(textView.textContainerInset.height == 0)
    textView.headerHeight = .infinity
    #expect(textView.textContainerInset.height == 0)
    textView.headerHeight = .nan
    #expect(textView.textContainerInset.height == 0)
}

/// `.headerView(height:_:)` は SwiftUI ビューを NSHostingView に載せてテキストビューへ付け、再適用では
/// 同じホストを使い回し、外すと消える。
@MainActor @Test func editorViewInstallsTheHeader() {
    let textView = MarkdownTextView()
    let coordinator = MarkdownEditorView.Coordinator(text: .constant(""))
    MarkdownEditorView(text: .constant("")).headerView(height: 40) { Text("title") }
        .applyHeader(to: textView, coordinator: coordinator)
    let host = try! #require(coordinator.headerHost)
    #expect(textView.headerView === host)
    #expect(textView.headerHeight == 40)
    #expect(textView.textContainerInset.height == 40)
    #expect(host.translatesAutoresizingMaskIntoConstraints, "the text view sets the frame")

    MarkdownEditorView(text: .constant("")).headerView(height: 48) { Text("other") }
        .applyHeader(to: textView, coordinator: coordinator)
    #expect(coordinator.headerHost === host, "re-applying reuses the host")
    #expect(textView.headerHeight == 48)

    MarkdownEditorView(text: .constant("")).applyHeader(to: textView, coordinator: coordinator)
    #expect(coordinator.headerHost == nil)
    #expect(textView.headerView == nil)
    #expect(textView.textContainerInset.height == 0)
}
#endif
