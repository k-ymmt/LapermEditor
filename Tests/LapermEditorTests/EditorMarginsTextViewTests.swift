#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import LapermEditor

@MainActor @Test func readableMarginsInsetTheTextContainerSymmetrically() {
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    let textView = scrollView.documentView as! MarkdownTextView
    scrollView.layoutSubtreeIfNeeded()
    #expect(textView.textContainerInset == .zero)
    textView.margins = .readable
    // ルーラー(44pt)を除いた幅(356pt)は最大幅に届かないので最小余白 20pt(上下は変えない)
    #expect(textView.textContainerInset == NSSize(width: 20, height: 0))
    #expect(textView.textContainer?.size.width == textView.frame.width - 40)
}

@MainActor @Test func readableMarginsCenterTheTextWhenTheViewGrows() {
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    var theme = textView.theme
    theme.bodyFont = .systemFont(ofSize: 17)
    textView.theme = theme
    textView.margins = .readable
    textView.showsLineNumbers = false
    scrollView.frame = NSRect(x: 0, y: 0, width: 1024, height: 300)
    scrollView.layoutSubtreeIfNeeded()
    // ビュー幅の変化(setFrameSize)で中央寄せし直す: (1024 − 40 × 17) / 2
    #expect(textView.frame.width == 1024)
    #expect(textView.textContainerInset.width == 172)
    #expect(textView.textContainer?.size.width == 680)
    // 14pt なら 560pt 幅
    theme.bodyFont = .systemFont(ofSize: 14)
    textView.theme = theme
    #expect(textView.textContainerInset.width == 232)
}

@MainActor @Test func editorViewAppliesMargins() {
    let view = MarkdownEditorView(text: .constant("")).editorMargins(.readable)
    let textView = MarkdownTextView()
    view.apply(to: textView)
    #expect(textView.margins == .readable)
    MarkdownEditorView(text: .constant("")).apply(to: textView)
    #expect(textView.margins == .none)
}
#endif
