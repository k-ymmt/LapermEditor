#if os(macOS)
import AppKit
import Testing
@testable import LapermEditor
@testable import LapermCore

@MainActor @Test func toggleEmphasisWrapsSelectionAndKeepsItSelected() {
    let textView = MarkdownTextView()
    textView.string = "hello world"
    textView.setSelectedRange(NSRange(location: 0, length: 5))
    #expect(textView.toggleEmphasis(.strong))
    #expect(textView.string == "**hello** world")
    #expect(textView.selectedRange() == NSRange(location: 2, length: 5))
    // もう一度で外れる
    #expect(textView.toggleEmphasis(.strong))
    #expect(textView.string == "hello world")
    #expect(textView.selectedRange() == NSRange(location: 0, length: 5))
}

@MainActor @Test func toggleEmphasisUsesWordAtCaret() {
    let textView = MarkdownTextView()
    textView.string = "hello world"
    textView.setSelectedRange(NSRange(location: 8, length: 0))
    #expect(textView.toggleEmphasis(.emphasis))
    #expect(textView.string == "hello *world*")
    #expect(textView.selectedRange() == NSRange(location: 9, length: 0))
}

@MainActor @Test func toggleEmphasisIsUndoableThroughTheProxy() {
    let textView = MarkdownTextView()
    let provider = UndoManagerProvider()
    textView.delegate = provider
    textView.string = "hello"
    let proxy = MarkdownEditorProxy()
    proxy.textView = textView
    #expect(!proxy.canUndo)
    #expect(proxy.toggleEmphasis(.strong))
    #expect(textView.string == "**hello**")
    #expect(proxy.canUndo)
    proxy.undo()
    #expect(textView.string == "hello")
    #expect(proxy.canRedo)
    proxy.redo()
    #expect(textView.string == "**hello**")
}

@MainActor @Test func toggleEmphasisIsSkippedDuringMarkedText() {
    let textView = MarkdownTextView()
    textView.string = ""
    textView.setMarkedText("か", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: 0, length: 0))
    #expect(!textView.toggleEmphasis(.strong))
    #expect(!textView.string.contains("*"))
}

@MainActor @Test func toggleEmphasisRefusesMultipleSelections() {
    let textView = MarkdownTextView()
    textView.string = "one two"
    textView.selectedRanges = [NSValue(range: NSRange(location: 0, length: 3)), NSValue(range: NSRange(location: 4, length: 3))]
    #expect(!textView.toggleEmphasis(.strong))
    #expect(textView.string == "one two")
    #expect(textView.selectedRanges.count == 2)
}

@MainActor @Test func toggleEmphasisUndoesSeparatelyFromSurroundingTyping() {
    let textView = MarkdownTextView()
    let provider = UndoManagerProvider()
    textView.delegate = provider
    textView.string = "hello"
    func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
    textView.setSelectedRange(NSRange(location: 5, length: 0))
    textView.insertText(" world", replacementRange: NSRange(location: 5, length: 0))
    settle()
    textView.setSelectedRange(NSRange(location: 6, length: 5))
    #expect(textView.toggleEmphasis(.strong))
    settle()
    #expect(textView.string == "hello **world**")
    textView.setSelectedRange(NSRange(location: 15, length: 0))
    textView.insertText("!", replacementRange: NSRange(location: 15, length: 0))
    settle()
    #expect(textView.string == "hello **world**!")

    provider.manager.undo()
    #expect(textView.string == "hello **world**")
    provider.manager.undo()
    #expect(textView.string == "hello world")
    provider.manager.undo()
    #expect(textView.string == "hello")
    provider.manager.redo()
    provider.manager.redo()
    #expect(textView.string == "hello **world**")
    withExtendedLifetime(provider) {}
}

@MainActor @Test func proxyWithoutTextViewIsInert() {
    let proxy = MarkdownEditorProxy()
    #expect(!proxy.toggleEmphasis(.strong))
    #expect(!proxy.canUndo)
    #expect(!proxy.canRedo)
    #expect(proxy.undoManager == nil)
    proxy.undo()
    proxy.redo()
}
#endif
