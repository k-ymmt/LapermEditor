#if os(macOS)
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

// MARK: - 編集支援

@MainActor @Test func insertNewlineContinuesList() {
    let textView = MarkdownTextView()
    textView.string = "- item"
    textView.setSelectedRange(NSRange(location: 6, length: 0))
    textView.insertNewline(nil)
    #expect(textView.string == "- item\n- ")
    #expect(textView.selectedRange() == NSRange(location: 9, length: 0))
}

@MainActor @Test func insertNewlineRespectsDisabledOption() {
    let textView = MarkdownTextView()
    textView.editingOptions.continuesLists = false
    textView.string = "- item"
    textView.setSelectedRange(NSRange(location: 6, length: 0))
    textView.insertNewline(nil)
    #expect(textView.string == "- item\n")
}

@MainActor @Test func listContinuationUndoesInOneStep() {
    let textView = MarkdownTextView()
    let provider = UndoManagerProvider()
    textView.delegate = provider
    textView.string = "- item"
    textView.setSelectedRange(NSRange(location: 6, length: 0))
    textView.insertNewline(nil)
    #expect(textView.string == "- item\n- ")
    provider.manager.undo()
    #expect(textView.string == "- item")
}

@MainActor @Test func insertTabIndentsListItem() {
    let textView = MarkdownTextView()
    textView.string = "- item"
    textView.setSelectedRange(NSRange(location: 6, length: 0))
    textView.insertTab(nil)
    #expect(textView.string == "    - item")
}

@MainActor @Test func typingBacktickAutoCloses() {
    let textView = MarkdownTextView()
    textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(textView.string == "``")
    #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
}

@MainActor @Test func typingClosingBacktickTypesOver() {
    let textView = MarkdownTextView()
    textView.string = "``"
    textView.setSelectedRange(NSRange(location: 1, length: 0))
    textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(textView.string == "``")
    #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
}

@MainActor @Test func pairCompletionIsSkippedDuringMarkedText() {
    let textView = MarkdownTextView()
    textView.setMarkedText(
        "か", selectedRange: NSRange(location: 0, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
    textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
    // マークテキストが "`" に置換されるだけで自動閉じは走らない
    #expect(textView.string == "`")
}

@MainActor @Test func clickOnCheckboxTogglesState() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "- [ ] task"
    let point = midpoint(of: NSRange(location: 2, length: 3), in: textView)
    #expect(textView.toggleCheckbox(atPoint: point))
    #expect(textView.string == "- [x] task")
}

@MainActor @Test func clickOutsideCheckboxDoesNotToggle() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "- [ ] task"
    let point = midpoint(of: NSRange(location: 7, length: 3), in: textView)
    #expect(!textView.toggleCheckbox(atPoint: point))
    #expect(textView.string == "- [ ] task")
}

@MainActor @Test func backspaceBetweenEmptyPairDeletesBoth() {
    let textView = MarkdownTextView()
    textView.string = "()"
    textView.setSelectedRange(NSRange(location: 1, length: 0))
    textView.deleteBackward(nil)
    #expect(textView.string == "")
}

@MainActor @Test func backspacePairDeletionRespectsDisabledOption() {
    let textView = MarkdownTextView()
    textView.editingOptions.completesPairs = false
    textView.string = "()"
    textView.setSelectedRange(NSRange(location: 1, length: 0))
    textView.deleteBackward(nil)
    #expect(textView.string == ")")
}
#endif
