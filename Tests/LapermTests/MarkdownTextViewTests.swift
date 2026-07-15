import AppKit
import Testing
@testable import Laperm
@testable import LapermCore

@MainActor @Test func usesTextKit2Stack() {
    let textView = MarkdownTextView()
    // textLayoutManager プロパティで確認する(layoutManager には触れない — TextKit1 フォールバック防止)
    #expect(textView.textLayoutManager != nil)
    #expect(textView.textContentStorage != nil)
}

@MainActor @Test func highlightsInitialTextAfterHighlightAll() {
    let textView = MarkdownTextView()
    textView.string = "# Title"
    textView.highlightAll()
    let font = textView.textStorage!.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
    #expect(font == MarkdownTheme.default.style(for: .heading(level: 1))?.font)
}

@MainActor @Test func typingSchedulesHighlight() {
    let textView = MarkdownTextView()
    textView.string = "plain"
    textView.highlightAll()
    // 編集をシミュレート(didProcessEditing 経由で noteEdit される)
    textView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
    // 非同期スケジュールを待たず、直接 flush して差分適用を検証
    textView.highlightNow()
    let font = textView.textStorage!.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
    #expect(font == MarkdownTheme.default.style(for: .heading(level: 1))?.font)
}

@MainActor @Test func scrollableEditorGrowsBeyondClipHeight() {
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
    scrollView.layoutSubtreeIfNeeded()
    let textView = scrollView.documentView as! MarkdownTextView
    textView.string = Array(repeating: "line", count: 100).joined(separator: "\n")
    textView.highlightAll()
    textView.textLayoutManager!.ensureLayout(for: textView.textLayoutManager!.documentRange)
    textView.sizeToFit()
    // 文書がクリップ領域より高い場合、documentView が伸びないとスクロールできない
    #expect(textView.frame.height > 200)
}

@MainActor @Test func settingThemeRehighlights() {
    let textView = MarkdownTextView()
    textView.string = "# Title"
    textView.highlightAll()
    var theme = MarkdownTheme.default
    theme.styles[.heading(level: 1)] = MarkdownTheme.Style(font: .systemFont(ofSize: 40, weight: .heavy))
    textView.theme = theme
    let font = textView.textStorage!.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
    #expect(font?.pointSize == 40)
}
