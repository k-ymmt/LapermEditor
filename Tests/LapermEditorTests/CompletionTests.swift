#if os(macOS)
import AppKit
import Testing
@testable import LapermEditor
@testable import LapermCore

// Completion(Laperm ADR 0047): `[[` を打つと Provider の候補がパネルに出て、キーとクリックで確定する。

/// 候補を固定で持ち、問い合わせを記録する Provider。タイトルの前方一致で絞る(本物の絞り込みは Laperm 側)。
@MainActor
final class StubCompletionProvider: CompletionProvider {
    var notes: [CompletionItem] = [
        CompletionItem(title: "Wiki", detail: "", insertionText: "Wiki"),
        CompletionItem(title: "Welcome", detail: "", insertionText: "Welcome"),
        CompletionItem(title: "Memo", detail: "Sub", insertionText: "Sub/Memo"),
    ]
    var headings: [CompletionItem] = [CompletionItem(title: "Second", detail: "H2", insertionText: "Second")]
    var tags: [CompletionItem] = [CompletionItem(title: "swift", insertionText: "swift")]
    private(set) var queries: [CompletionQuery] = []

    func completions(for query: CompletionQuery) -> [CompletionItem] {
        queries.append(query)
        let typed = query.text.trimmingCharacters(in: .whitespaces).lowercased()
        let source: [CompletionItem]
        switch query.kind {
        case .noteTitle: source = notes
        case .heading: source = headings
        case .tag: source = tags
        }
        return source.filter { typed.isEmpty || $0.title.lowercased().hasPrefix(typed) }
    }
}

@MainActor
private func makeTextView(_ markdown: String = "", provider: StubCompletionProvider? = StubCompletionProvider(), inWindow: Bool = false) -> MarkdownTextView {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = markdown
    textView.highlightAll()
    textView.completionProvider = provider
    if inWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = textView
        window.orderFront(nil)
        window.makeFirstResponder(textView)
    }
    textView.setSelectedRange(NSRange(location: (markdown as NSString).length, length: 0))
    return textView
}

@MainActor
private func type(_ text: String, into textView: MarkdownTextView) {
    for character in text {
        textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}

@MainActor @Test func typingDoubleBracketOpensTheListWithEveryCandidate() {
    let provider = StubCompletionProvider()
    let textView = makeTextView(provider: provider)
    type("[[", into: textView)
    // completesPairs: `[[]]` の中にキャレット
    #expect(textView.string == "[[]]")
    #expect(textView.completion.session?.items.count == 3)
    #expect(provider.queries.last?.kind == .noteTitle)
    #expect(provider.queries.last?.text == "")
    #expect(textView.completion.session?.selectedIndex == 0)
}

@MainActor @Test func typingFiltersAndReturnCommitsTheWikiLink() {
    let provider = StubCompletionProvider()
    let textView = makeTextView("See ", provider: provider)
    type("[[W", into: textView)
    #expect(provider.queries.last?.text == "W")
    #expect(textView.completion.session?.items.map(\.title) == ["Wiki", "Welcome"])
    textView.keyDown(with: keyEvent("\r"))
    #expect(textView.string == "See [[Wiki]]")
    #expect(textView.selectedRange() == NSRange(location: 12, length: 0))
    #expect(textView.completion.session == nil)
    // 確定の直後に `#` / `|` の一覧は連鎖しない
    #expect(textView.completion.session == nil)
}

@MainActor @Test func tabCommitsAndArrowsMoveTheSelection() {
    let textView = makeTextView()
    type("[[", into: textView)
    textView.keyDown(with: keyEvent("\u{F701}"))  // ↓
    #expect(textView.completion.session?.selectedIndex == 1)
    textView.keyDown(with: keyEvent("\u{F700}"))  // ↑
    #expect(textView.completion.session?.selectedIndex == 0)
    textView.keyDown(with: keyEvent("\u{F700}"))  // ↑ は末尾へ回る
    #expect(textView.completion.session?.selectedIndex == 2)
    textView.keyDown(with: keyEvent("\t"))
    // 解決で負ける Note はパスで入る
    #expect(textView.string == "[[Sub/Memo]]")
    #expect(textView.selectedRange().location == 12)
}

@MainActor @Test func closingBracketsAreAddedWhenPairCompletionIsOff() {
    let textView = makeTextView()
    textView.editingOptions.completesPairs = false
    type("[[We", into: textView)
    textView.keyDown(with: keyEvent("\r"))
    #expect(textView.string == "[[Welcome]]")
    #expect(textView.selectedRange() == NSRange(location: 11, length: 0))
}

@MainActor @Test func escapeDismissesUntilTheTriggerIsLeft() {
    let provider = StubCompletionProvider()
    let textView = makeTextView(provider: provider)
    type("[[W", into: textView)
    textView.keyDown(with: keyEvent("\u{1B}"))
    #expect(textView.completion.session == nil)
    #expect(textView.string == "[[W]]")  // Esc は消費され、本文は変わらない
    let asked = provider.queries.count
    // 同じ `[[` の中で打ち続けても開かない
    type("e", into: textView)
    #expect(textView.completion.session == nil)
    #expect(provider.queries.count == asked)
    // `[[` を消して打ち直せば開く
    textView.deleteBackward(nil)
    textView.deleteBackward(nil)
    textView.deleteBackward(nil)
    #expect(textView.string == "[]")
    textView.deleteBackward(nil)
    #expect(textView.string == "")
    type("[[", into: textView)
    #expect(textView.completion.session?.items.count == 3)
}

@MainActor @Test func escapeThenLeavingByCaretReopensAtANewTrigger() {
    let textView = makeTextView("x ")
    type("[[", into: textView)
    textView.keyDown(with: keyEvent("\u{1B}"))
    // キャレットが外へ出る(先頭へ)と記憶は消え、次の `[[` では開く
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    type("[[", into: textView)
    #expect(textView.completion.session != nil)
    #expect(textView.completion.session?.query.anchor == 0)
}

@MainActor @Test func caretMovesAndArrowKeysCloseTheList() {
    let textView = makeTextView()
    type("[[W", into: textView)
    #expect(textView.completion.session != nil)
    // ← は閉じてテキストビューに流れる(キャレットが動く)
    textView.keyDown(with: keyEvent("\u{F702}"))
    #expect(textView.completion.session == nil)
    #expect(textView.selectedRange().location == 2)
    // 打ち足せば(同じ `[[` の中)また開く: Esc ではないので記憶しない
    type("W", into: textView)
    #expect(textView.string == "[[WW]]")
    #expect(textView.completion.session != nil)
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(textView.completion.session == nil)
}

@MainActor @Test func pasteAndProgrammaticEditsDoNotOpenTheList() {
    let provider = StubCompletionProvider()
    let textView = makeTextView(provider: provider)
    textView.perform(EditCommand(replacementRange: NSRange(location: 0, length: 0), replacementString: "[[Wi", selectedRange: NSRange(location: 4, length: 0)))
    #expect(textView.completion.session == nil)
    #expect(provider.queries.isEmpty)
    // 開いている一覧は打鍵以外の本文の変化で閉じる
    type("k", into: textView)
    #expect(textView.completion.session != nil)
    textView.perform(EditCommand(replacementRange: NSRange(location: 0, length: 0), replacementString: "x", selectedRange: NSRange(location: 1, length: 0)))
    #expect(textView.completion.session == nil)
}

@MainActor @Test func aliasPipeAndNoCandidatesCloseTheList() {
    let provider = StubCompletionProvider()
    let textView = makeTextView(provider: provider)
    type("[[W", into: textView)
    type("|", into: textView)
    #expect(textView.completion.session == nil)
    textView.string = ""
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    type("[[Zzz", into: textView)
    #expect(textView.completion.session == nil)
    #expect(provider.queries.last?.text == "Zzz")
}

@MainActor @Test func headingAndTagQueriesReachTheProvider() {
    let provider = StubCompletionProvider()
    let textView = makeTextView(provider: provider)
    type("[[Welcome#S", into: textView)
    #expect(provider.queries.last?.kind == .heading(note: "Welcome"))
    #expect(provider.queries.last?.text == "S")
    textView.keyDown(with: keyEvent("\r"))
    #expect(textView.string == "[[Welcome#Second]]")

    textView.string = "---\ntags: [\n---\n"
    textView.highlightAll()
    textView.setSelectedRange(NSRange(location: 11, length: 0))
    type("s", into: textView)
    #expect(provider.queries.last?.kind == .tag)
    #expect(provider.queries.last?.text == "s")
    textView.keyDown(with: keyEvent("\r"))
    #expect(textView.string == "---\ntags: [swift\n---\n")
}

@MainActor @Test func noListInsideInlineCodeOrWhenDisabled() {
    let provider = StubCompletionProvider()
    let textView = makeTextView("`", provider: provider)
    type("[[W", into: textView)
    #expect(textView.completion.session == nil)
    #expect(provider.queries.isEmpty)

    let disabled = makeTextView(provider: provider)
    disabled.completionOptions = CompletionOptions(isEnabled: false)
    type("[[W", into: disabled)
    #expect(disabled.completion.session == nil)
    #expect(provider.queries.isEmpty)
    // 開いている最中に無効にすると閉じる
    disabled.completionOptions = CompletionOptions(isEnabled: true)
    type("e", into: disabled)
    #expect(disabled.completion.session != nil)
    disabled.completionOptions = CompletionOptions(isEnabled: false)
    #expect(disabled.completion.session == nil)
}

@MainActor @Test func markedTextFiltersTheListAndKeysGoToTheIME() {
    let provider = StubCompletionProvider()
    let textView = makeTextView(provider: provider)
    type("[[", into: textView)
    textView.setMarkedText("We", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(textView.hasMarkedText())
    #expect(provider.queries.last?.text == "We")
    #expect(textView.completion.session?.items.map(\.title) == ["Welcome"])
    // 変換中の Return は IME のもの(消費しない)
    #expect(!textView.handlesCompletionKey(keyEvent("\r")))
    // クリック / タップでの確定は変換中でも受け、未確定の文字ごと置き換える
    #expect(textView.commitCompletion())
    #expect(!textView.hasMarkedText())
    #expect(textView.string == "[[Welcome]]")
}

@MainActor @Test func listStatePublishesTheItemsAndChooseCommits() {
    let textView = makeTextView()
    let state = CompletionListState()
    textView.completionList = state
    #expect(!state.isActive)
    type("[[W", into: textView)
    #expect(state.items.map(\.title) == ["Wiki", "Welcome"])
    #expect(state.selectedIndex == 0)
    textView.keyDown(with: keyEvent("\u{F701}"))
    #expect(state.selectedIndex == 1)
    state.choose(state.items[1])
    #expect(textView.string == "[[Welcome]]")
    #expect(state.items.isEmpty)
    // 付け替えると古い状態は空になる
    type("[[", into: textView)
    #expect(state.isActive)
    textView.completionList = nil
    #expect(!state.isActive)
}

@MainActor @Test func panelShowsUnderTheCaretAndClosesWithTheList() {
    let textView = makeTextView("Line one\nSee ", inWindow: true)
    type("[[W", into: textView)
    #expect(textView.debugCompletionPanelIsVisible)
    let panel = textView.debugCompletionPanel as! CompletionPanel
    #expect(panel.items.count == 2)
    #expect(panel.parent === textView.window)
    #expect(panel.frame.width >= CompletionPanel.minimumWidth)
    // 打ちかけの文字の左端(`[[` の直後)の下
    let anchor = textView.firstRect(forCharacterRange: NSRange(location: 15, length: 0), actualRange: nil)
    // ウィンドウの位置は整数に丸められる
    #expect(abs(panel.frame.minX - (anchor.minX - CompletionCellView.horizontalInset)) < 1)
    #expect(panel.frame.maxY <= anchor.minY)
    textView.keyDown(with: keyEvent("\u{F701}"))
    #expect(panel.selectedRow == 1)
    // クリックで確定
    panel.onSelect?(1)
    #expect(textView.string == "Line one\nSee [[Welcome]]")
    #expect(!textView.debugCompletionPanelIsVisible)
    #expect(panel.parent == nil)
    textView.window?.orderOut(nil)
}

@MainActor @Test func scrollingAndLosingFocusCloseThePanel() {
    let textView = makeTextView(inWindow: true)
    type("[[", into: textView)
    #expect(textView.debugCompletionPanelIsVisible)
    #expect(textView.window?.makeFirstResponder(nil) == true)
    #expect(textView.completion.session == nil)
    #expect(!textView.debugCompletionPanelIsVisible)
    textView.window?.orderOut(nil)
}

@MainActor @Test func panelSizeAndPlacement() {
    let short = (0..<3).map { CompletionItem(title: "n\($0)", detail: "", insertionText: "n\($0)") }
    let size = CompletionPanel.size(for: short)
    #expect(size.width == CompletionPanel.minimumWidth)
    #expect(size.height == 3 * CompletionPanel.rowHeight + 2 * CompletionPanel.contentPadding)
    let many = (0..<20).map { CompletionItem(title: "n\($0)", detail: "", insertionText: "n\($0)") }
    #expect(CompletionPanel.size(for: many).height == 8 * CompletionPanel.rowHeight + 2 * CompletionPanel.contentPadding)
    let wide = [CompletionItem(title: String(repeating: "wide ", count: 60), detail: "", insertionText: "x")]
    #expect(CompletionPanel.size(for: wide).width == CompletionPanel.maximumWidth)

    let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
    let panelSize = NSSize(width: 240, height: 100)
    let caret = NSRect(x: 300, y: 400, width: 1, height: 20)
    let below = CompletionPanel.frame(size: panelSize, anchorRect: caret, visibleFrame: screen)
    #expect(below.maxY == caret.minY - CompletionPanel.caretGap)
    #expect(below.minX == caret.minX - CompletionCellView.horizontalInset)
    // 下に余地が無ければ上
    let low = NSRect(x: 300, y: 50, width: 1, height: 20)
    let above = CompletionPanel.frame(size: panelSize, anchorRect: low, visibleFrame: screen)
    #expect(above.minY == low.maxY + CompletionPanel.caretGap)
    // 右端は画面の中に収める
    let right = NSRect(x: 950, y: 400, width: 1, height: 20)
    #expect(CompletionPanel.frame(size: panelSize, anchorRect: right, visibleFrame: screen).maxX == screen.maxX)
}
#endif
