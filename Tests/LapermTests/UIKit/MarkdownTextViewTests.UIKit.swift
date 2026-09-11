#if canImport(UIKit)
import Testing
import UIKit
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
    textView.text = "# Title"
    textView.highlightAll()
    let font = textView.textContentStorage!.textStorage!
        .attribute(.font, at: 3, effectiveRange: nil) as? UIFont
    #expect(font == MarkdownTheme.default.style(for: .heading(level: 1))?.font)
}

@MainActor @Test func typingSchedulesHighlight() {
    let textView = MarkdownTextView()
    textView.text = "plain"
    textView.highlightAll()
    // 編集をシミュレート(didProcessEditing 経由で noteEdit される)
    textView.textContentStorage!.textStorage!
        .replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
    // 非同期スケジュールを待たず、直接 flush して差分適用を検証
    textView.highlightNow()
    let font = textView.textContentStorage!.textStorage!
        .attribute(.font, at: 4, effectiveRange: nil) as? UIFont
    #expect(font == MarkdownTheme.default.style(for: .heading(level: 1))?.font)
}

@MainActor @Test func settingThemeRehighlights() {
    let textView = MarkdownTextView()
    textView.text = "# Title"
    textView.highlightAll()
    var theme = MarkdownTheme.default
    theme.styles[.heading(level: 1)] = MarkdownTheme.Style(font: .systemFont(ofSize: 40, weight: .heavy))
    textView.theme = theme
    let font = textView.textContentStorage!.textStorage!
        .attribute(.font, at: 3, effectiveRange: nil) as? UIFont
    #expect(font?.pointSize == 40)
    #expect(textView.backgroundColor == theme.backgroundColor)
}

@MainActor @Test func defaultThemeUsesUIKitSemanticColors() {
    let theme = MarkdownTheme.default
    #expect(theme.bodyColor == .label)
    #expect(theme.backgroundColor == .systemBackground)
    #expect(theme.style(for: .link)?.foregroundColor == .link)
    // イタリック変換が UIFontDescriptor 経由で効いている
    #expect(theme.style(for: .emphasis)?.font?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true)
}

@MainActor @Test func lineNumbersInsetTextAndToggleOff() {
    let textView = MarkdownTextView()
    #expect(textView.showsLineNumbers)
    #expect(textView.textContainerInset.left == LineNumberGutterView.width)
    #expect(!textView.gutterView.isHidden)
    textView.showsLineNumbers = false
    #expect(textView.textContainerInset.left == 0)
    #expect(textView.gutterView.isHidden)
}

// MARK: - 編集支援

@MainActor @Test func insertNewlineContinuesList() {
    let textView = MarkdownTextView()
    textView.text = "- item"
    textView.selectedRange = NSRange(location: 6, length: 0)
    textView.insertText("\n")
    #expect(textView.text == "- item\n- ")
    #expect(textView.selectedRange == NSRange(location: 9, length: 0))
}

@MainActor @Test func insertNewlineRespectsDisabledOption() {
    let textView = MarkdownTextView()
    textView.editingOptions.continuesLists = false
    textView.text = "- item"
    textView.selectedRange = NSRange(location: 6, length: 0)
    textView.insertText("\n")
    #expect(textView.text == "- item\n")
}

@MainActor @Test func insertTabIndentsListItem() {
    let textView = MarkdownTextView()
    textView.text = "- item"
    textView.selectedRange = NSRange(location: 6, length: 0)
    textView.insertText("\t")
    #expect(textView.text == "    - item")
}

@MainActor @Test func backtabOutdentsListItem() {
    let textView = MarkdownTextView()
    textView.text = "    - item"
    textView.selectedRange = NSRange(location: 10, length: 0)
    // Shift+Tab は UIKeyCommand 経由。テストではその action を直接呼ぶ
    let command = textView.keyCommands?.first { $0.input == "\t" && $0.modifierFlags == .shift }
    #expect(command != nil)
    textView.perform(command!.action, with: nil)
    #expect(textView.text == "- item")
}

@MainActor @Test func typingBacktickAutoCloses() {
    let textView = MarkdownTextView()
    textView.insertText("`")
    #expect(textView.text == "``")
    #expect(textView.selectedRange == NSRange(location: 1, length: 0))
}

@MainActor @Test func typingClosingBacktickTypesOver() {
    let textView = MarkdownTextView()
    textView.text = "``"
    textView.selectedRange = NSRange(location: 1, length: 0)
    textView.insertText("`")
    #expect(textView.text == "``")
    #expect(textView.selectedRange == NSRange(location: 2, length: 0))
}

@MainActor @Test func pairCompletionIsSkippedDuringMarkedText() {
    let textView = MarkdownTextView()
    let window = hostInWindow(textView)
    defer { window.isHidden = true }
    textView.setMarkedText("か", selectedRange: NSRange(location: 0, length: 0))
    #expect(textView.markedTextRange != nil)
    textView.insertText("`")
    // マークテキストが "`" に置換されるだけで自動閉じは走らない
    #expect(textView.text == "`")
}

@MainActor @Test func backspaceBetweenEmptyPairDeletesBoth() {
    let textView = MarkdownTextView()
    textView.text = "()"
    textView.selectedRange = NSRange(location: 1, length: 0)
    textView.deleteBackward()
    #expect(textView.text == "")
}

@MainActor @Test func backspacePairDeletionRespectsDisabledOption() {
    let textView = MarkdownTextView()
    textView.editingOptions.completesPairs = false
    textView.text = "()"
    textView.selectedRange = NSRange(location: 1, length: 0)
    textView.deleteBackward()
    #expect(textView.text == ")")
}

@MainActor @Test func tapOnCheckboxTogglesState() {
    let textView = makeLaidOutTextView("- [ ] task")
    let point = midpoint(of: NSRange(location: 2, length: 3), in: textView)
    #expect(textView.shouldInterceptTap(atPoint: point, modifiers: []))
    #expect(textView.toggleCheckbox(atPoint: point))
    #expect(textView.text == "- [x] task")
}

@MainActor @Test func tapOutsideCheckboxDoesNotToggle() {
    let textView = makeLaidOutTextView("- [ ] task")
    let point = midpoint(of: NSRange(location: 7, length: 3), in: textView)
    #expect(!textView.shouldInterceptTap(atPoint: point, modifiers: []))
    #expect(!textView.toggleCheckbox(atPoint: point))
    #expect(textView.text == "- [ ] task")
}

@MainActor @Test func checkboxTapRespectsDisabledOption() {
    let textView = makeLaidOutTextView("- [ ] task")
    textView.editingOptions.togglesCheckboxOnClick = false
    let point = midpoint(of: NSRange(location: 2, length: 3), in: textView)
    #expect(!textView.shouldInterceptTap(atPoint: point, modifiers: []))
}

// MARK: - perform

@MainActor @Test func performReplacesTextAndMovesSelection() {
    let textView = MarkdownTextView()
    textView.text = "hello"
    let done = textView.perform(EditCommand(
        replacementRange: NSRange(location: 0, length: 5),
        replacementString: "bye",
        selectedRange: NSRange(location: 3, length: 0)))
    #expect(done)
    #expect(textView.text == "bye")
    #expect(textView.selectedRange == NSRange(location: 3, length: 0))
}

@MainActor @Test func performIsUndoable() {
    let textView = MarkdownTextView()
    let window = hostInWindow(textView)
    defer { window.isHidden = true }
    textView.text = "hello"
    textView.perform(EditCommand(
        replacementRange: NSRange(location: 5, length: 0),
        replacementString: "!",
        selectedRange: NSRange(location: 6, length: 0)))
    #expect(textView.text == "hello!")
    #expect(textView.undoManager?.canUndo == true)
    textView.undoManager?.undo()
    #expect(textView.text == "hello")
}

@MainActor @Test func performRehighlights() {
    let textView = MarkdownTextView()
    textView.text = "Title"
    textView.highlightAll()
    textView.perform(EditCommand(
        replacementRange: NSRange(location: 0, length: 0),
        replacementString: "# ",
        selectedRange: NSRange(location: 2, length: 0)))
    textView.highlightNow()
    let font = textView.textContentStorage!.textStorage!
        .attribute(.font, at: 4, effectiveRange: nil) as? UIFont
    #expect(font == MarkdownTheme.default.style(for: .heading(level: 1))?.font)
}

@MainActor @Test func performRejectsOutOfRangeReplacement() {
    let textView = MarkdownTextView()
    textView.text = "ab"
    let done = textView.perform(EditCommand(
        replacementRange: NSRange(location: 1, length: 5),
        replacementString: "x",
        selectedRange: NSRange(location: 0, length: 0)))
    #expect(!done)
    #expect(textView.text == "ab")
}

@MainActor @Test func moveOnlyCommandJustMovesCaret() {
    let textView = MarkdownTextView()
    textView.text = "abc"
    let done = textView.perform(EditCommand(
        replacementRange: NSRange(location: 1, length: 0),
        replacementString: "",
        selectedRange: NSRange(location: 2, length: 0)))
    #expect(done)
    #expect(textView.text == "abc")
    #expect(textView.selectedRange == NSRange(location: 2, length: 0))
}

@MainActor @Test func performNotifiesDelegate() {
    // perform(replace 経由)は UITextView 標準の delegate 通知(textViewDidChange 等)に乗る
    final class Recorder: NSObject, UITextViewDelegate {
        var changes = 0
        var selections = 0
        func textViewDidChange(_ textView: UITextView) { changes += 1 }
        func textViewDidChangeSelection(_ textView: UITextView) { selections += 1 }
    }
    let textView = MarkdownTextView()
    let recorder = Recorder()
    textView.delegate = recorder
    #expect(textView.delegate === recorder)
    textView.text = "hello"
    textView.perform(EditCommand(
        replacementRange: NSRange(location: 5, length: 0),
        replacementString: "!",
        selectedRange: NSRange(location: 6, length: 0)))
    #expect(recorder.changes == 1)
    #expect(recorder.selections >= 1)
}
#endif

#if canImport(UIKit)
@MainActor @Test func longDocumentIsScrollable() {
    let textView = MarkdownTextView()
    textView.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
    textView.text = Array(repeating: "line", count: 200).joined(separator: "\n")
    textView.highlightAll()
    textView.layoutIfNeeded()
    textView.textLayoutManager!.ensureLayout(for: textView.textLayoutManager!.documentRange)
    textView.layoutIfNeeded()
    #expect(textView.isScrollEnabled)
    #expect(textView.contentSize.height > 200, "\(textView.contentSize)")
    textView.contentOffset = CGPoint(x: 0, y: 500)
    textView.layoutIfNeeded()
    #expect(textView.contentOffset.y == 500)
    // ガターは可視領域にピン留めされ、スクロール量を反映する
    #expect(textView.gutterView.frame.minY == 500)
    #expect(textView.gutterView.contentOffsetY == 500)
}
#endif
