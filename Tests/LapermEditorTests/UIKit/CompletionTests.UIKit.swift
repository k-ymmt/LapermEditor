#if canImport(UIKit)
import Testing
import UIKit
@testable import LapermEditor
@testable import LapermCore

// Completion(Laperm ADR 0047)の iOS: 一覧の状態は `CompletionListState` に出て(キーボードアクセサリの段が読む)、タップで
// 確定する。iPad のハードウェアキーボードでは ↑↓ / Return / Tab / Esc が UIKeyCommand として効く。

@MainActor
private final class StubProvider: CompletionProvider {
    let notes = [
        CompletionItem(title: "Wiki", detail: "", insertionText: "Wiki"),
        CompletionItem(title: "Welcome", detail: "", insertionText: "Welcome"),
    ]
    private(set) var queries: [CompletionQuery] = []

    func completions(for query: CompletionQuery) -> [CompletionItem] {
        queries.append(query)
        let typed = query.text.lowercased()
        return notes.filter { typed.isEmpty || $0.title.lowercased().hasPrefix(typed) }
    }
}

@MainActor
private func makeTextView(_ markdown: String = "") -> (MarkdownTextView, StubProvider, CompletionListState) {
    let textView = makeLaidOutTextView(markdown)
    let provider = StubProvider()
    let state = CompletionListState()
    textView.completionProvider = provider
    textView.completionList = state
    textView.selectedRange = NSRange(location: (markdown as NSString).length, length: 0)
    return (textView, provider, state)
}

@MainActor @Test func typingPublishesTheCandidatesAndTapCommits() {
    let (textView, provider, state) = makeTextView("See ")
    textView.insertText("[")
    textView.insertText("[")
    #expect(textView.text == "See [[]]")
    #expect(state.items.count == 2)
    textView.insertText("W")
    textView.insertText("e")
    #expect(provider.queries.last?.text == "We")
    #expect(state.items.map(\.title) == ["Welcome"])
    state.choose(state.items[0])
    #expect(textView.text == "See [[Welcome]]")
    #expect(textView.selectedRange == NSRange(location: 15, length: 0))
    #expect(!state.isActive)
}

@MainActor @Test func hardwareKeyCommandsExistOnlyWhileTheListIsOpen() {
    let (textView, _, state) = makeTextView()
    let before = textView.keyCommands?.count ?? 0
    textView.insertText("[")
    textView.insertText("[")
    #expect(state.isActive)
    let commands = textView.keyCommands ?? []
    #expect(commands.count == before + 5)
    let inputs = Set(commands.suffix(5).compactMap(\.input))
    #expect(inputs == [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, "\r", "\t", UIKeyCommand.inputEscape])
    let allPrioritized = commands.suffix(5).allSatisfy { $0.wantsPriorityOverSystemBehavior }
    #expect(allPrioritized)
    // ↓ で選択が進み、Return で確定(セレクタを直接呼ぶ)
    let down = commands.first { $0.input == UIKeyCommand.inputDownArrow }!
    _ = textView.perform(down.action, with: nil)
    #expect(state.selectedIndex == 1)
    let commit = commands.first { $0.input == "\r" }!
    _ = textView.perform(commit.action, with: nil)
    #expect(textView.text == "[[Welcome]]")
    #expect((textView.keyCommands?.count ?? 0) == before)
}

@MainActor @Test func escapeDismissesAndCaretMovesClose() {
    let (textView, provider, state) = makeTextView()
    textView.insertText("[")
    textView.insertText("[")
    let escape = (textView.keyCommands ?? []).first { $0.input == UIKeyCommand.inputEscape }!
    _ = textView.perform(escape.action, with: nil)
    #expect(!state.isActive)
    let asked = provider.queries.count
    textView.insertText("W")
    #expect(!state.isActive)
    #expect(provider.queries.count == asked)
    // 外へ出て戻ると記憶は消える
    textView.selectedRange = NSRange(location: 0, length: 0)
    textView.selectedRange = NSRange(location: 3, length: 0)
    textView.insertText("e")
    #expect(state.isActive)
    textView.selectedRange = NSRange(location: 0, length: 0)
    #expect(!state.isActive)
}

@MainActor @Test func markedTextFiltersAndDeleteRefreshes() {
    let (textView, provider, state) = makeTextView()
    textView.insertText("[")
    textView.insertText("[")
    textView.setMarkedText("Wi", selectedRange: NSRange(location: 2, length: 0))
    #expect(provider.queries.last?.text == "Wi")
    #expect(state.items.map(\.title) == ["Wiki"])
    // 変換中はハードウェアキーのコマンドを出さない(IME のもの)
    #expect(!(textView.keyCommands ?? []).contains { $0.input == "\r" })
    textView.unmarkText()
    #expect(textView.text == "[[Wi]]")
    #expect(state.items.map(\.title) == ["Wiki"])
    textView.deleteBackward()
    #expect(provider.queries.last?.text == "W")
    #expect(state.items.count == 2)
}

@MainActor @Test func programmaticEditsAndResigningClose() {
    let (textView, provider, state) = makeTextView()
    textView.perform(EditCommand(replacementRange: NSRange(location: 0, length: 0), replacementString: "[[W", selectedRange: NSRange(location: 3, length: 0)))
    #expect(!state.isActive)
    #expect(provider.queries.isEmpty)
    textView.insertText("e")
    #expect(state.isActive)
    let window = hostInWindow(textView)
    textView.insertText("l")
    #expect(state.isActive)
    _ = textView.resignFirstResponder()
    #expect(!state.isActive)
    window.isHidden = true
}

@MainActor @Test func markedTextWithASelectedSegmentStillFilters() {
    let (textView, provider, state) = makeTextView()
    textView.insertText("[")
    textView.insertText("[")
    textView.setMarkedText("We", selectedRange: NSRange(location: 0, length: 2))
    #expect(provider.queries.last?.text == "We")
    #expect(state.items.map(\.title) == ["Welcome"])
}

@MainActor @Test func oneListStateServesSeveralTextViews() {
    let (a, _, state) = makeTextView()
    let b = makeLaidOutTextView("")
    b.completionProvider = a.completionProvider
    b.completionList = state
    a.insertText("[")
    a.insertText("[")
    #expect(state.items.count == 2)
    b.selectedRange = NSRange(location: 0, length: 0)
    #expect(state.isActive)
    b.insertText("[")
    b.insertText("[")
    b.insertText("W")
    b.insertText("e")
    #expect(state.items.map(\.title) == ["Welcome"])
    state.choose(state.items[0])
    #expect(b.text == "[[Welcome]]")
    #expect(a.text == "[[]]")
    #expect(!state.isActive)
}
#endif
