import AppKit
import Testing
@testable import Laperm
@testable import LapermCore

@MainActor @Test func performReplacesTextAndMovesSelection() {
    let textView = MarkdownTextView()
    textView.string = "hello"
    let done = textView.perform(EditCommand(
        replacementRange: NSRange(location: 0, length: 5),
        replacementString: "bye",
        selectedRange: NSRange(location: 3, length: 0)))
    #expect(done)
    #expect(textView.string == "bye")
    #expect(textView.selectedRange() == NSRange(location: 3, length: 0))
}

@MainActor @Test func performIsUndoable() {
    let textView = MarkdownTextView()
    let provider = UndoManagerProvider()
    textView.delegate = provider
    textView.string = "hello"
    textView.perform(EditCommand(
        replacementRange: NSRange(location: 5, length: 0),
        replacementString: "!",
        selectedRange: NSRange(location: 6, length: 0)))
    #expect(textView.string == "hello!")
    provider.manager.undo()
    #expect(textView.string == "hello")
}

@MainActor @Test func performRehighlights() {
    let textView = MarkdownTextView()
    textView.string = "Title"
    textView.highlightAll()
    textView.perform(EditCommand(
        replacementRange: NSRange(location: 0, length: 0),
        replacementString: "# ",
        selectedRange: NSRange(location: 2, length: 0)))
    textView.highlightNow()
    let font = textView.textStorage!.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
    #expect(font == MarkdownTheme.default.style(for: .heading(level: 1))?.font)
}

@MainActor @Test func performRejectsOutOfRangeReplacement() {
    let textView = MarkdownTextView()
    textView.string = "ab"
    let done = textView.perform(EditCommand(
        replacementRange: NSRange(location: 1, length: 5),
        replacementString: "x",
        selectedRange: NSRange(location: 0, length: 0)))
    #expect(!done)
    #expect(textView.string == "ab")
}

@MainActor @Test func performRejectsOutOfRangeSelection() {
    let textView = MarkdownTextView()
    textView.string = "ab"
    let done = textView.perform(EditCommand(
        replacementRange: NSRange(location: 0, length: 0),
        replacementString: "",
        selectedRange: NSRange(location: 99, length: 0)))
    #expect(!done)
}

@MainActor @Test func moveOnlyCommandJustMovesCaret() {
    let textView = MarkdownTextView()
    textView.string = "abc"
    let done = textView.perform(EditCommand(
        replacementRange: NSRange(location: 1, length: 0),
        replacementString: "",
        selectedRange: NSRange(location: 2, length: 0)))
    #expect(done)
    #expect(textView.string == "abc")
    #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
}
