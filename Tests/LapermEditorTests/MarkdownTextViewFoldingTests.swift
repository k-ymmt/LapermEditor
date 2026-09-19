#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import LapermEditor
@testable import LapermCore

// テキスト: "# A\n"(0-3) "body1\n"(4-9) "body2\n"(10-15) "# B\n"(16-19) "after"(20-24)
private let sample = "# A\nbody1\nbody2\n# B\nafter"

@MainActor
private func makeTextView() -> MarkdownTextView {
    let textView = MarkdownTextView()
    textView.string = sample
    textView.highlightAll()
    return textView
}

@MainActor
private func enumeratedOffsets(_ textView: MarkdownTextView) -> [Int] {
    let contentManager = textView.textLayoutManager!.textContentManager!
    var offsets: [Int] = []
    contentManager.enumerateTextElements(from: contentManager.documentRange.location) {
        element in
        if let location = element.elementRange?.location {
            offsets.append(contentManager.offset(
                from: contentManager.documentRange.location, to: location))
        }
        return true
    }
    return offsets
}

@MainActor @Test func outlineIsAvailableAfterHighlightAll() {
    let textView = makeTextView()
    #expect(textView.outline.map(\.title) == ["A", "B"])
}

@MainActor @Test func foldHidesBodyAndKeepsHeading() {
    let textView = makeTextView()
    textView.fold(at: 0)
    #expect(textView.isFolded(at: 0))
    let offsets = enumeratedOffsets(textView)
    #expect(offsets.contains(0))
    #expect(!offsets.contains(4))
    #expect(!offsets.contains(10))
    #expect(offsets.contains(16))
}

@MainActor @Test func caretEnteringHiddenBodyAutoExpands() {
    let textView = makeTextView()
    textView.fold(at: 0)
    textView.setSelectedRange(NSRange(location: 6, length: 0))  // body1 内
    #expect(!textView.isFolded(at: 0))
}

@MainActor @Test func editInHiddenBodyAutoExpands() {
    let textView = makeTextView()
    textView.fold(at: 0)
    textView.textStorage!.replaceCharacters(
        in: NSRange(location: 6, length: 0), with: "x")
    #expect(!textView.isFolded(at: 0))
}

@MainActor @Test func headingRemovalUnfoldsAfterReparse() {
    let textView = makeTextView()
    textView.fold(at: 0)
    // "# " を消して見出しでなくす(見出し行内の編集なので即時は維持される)
    textView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 2), with: "")
    textView.highlightNow()  // 再パース → sync → 見出し消失で解除
    #expect(!textView.isFolded(at: 0))
    #expect(textView.outline.map(\.title) == ["B"])
}

@MainActor @Test func onOutlineChangeFiresOnActualChange() {
    let textView = MarkdownTextView()
    var received: [[String]] = []
    textView.onOutlineChange = { received.append($0.map(\.title)) }
    textView.string = sample
    textView.highlightAll()
    #expect(received == [["A", "B"]])
    textView.highlightAll()  // アウトライン不変 → 発火しない
    #expect(received.count == 1)
}

@MainActor @Test func disablingFoldingUnfoldsAllAndBlocksFold() {
    let textView = makeTextView()
    textView.fold(at: 0)
    textView.isFoldingEnabled = false
    #expect(!textView.isFolded(at: 0))
    textView.fold(at: 0)
    #expect(!textView.isFolded(at: 0))
    #expect(enumeratedOffsets(textView).contains(4))
}

@MainActor @Test func scrollToHeadingUnfoldsAncestors() {
    // "# A\n"(0-3) "## B\n"(4-8) "body\n"(9-13)
    let textView = MarkdownTextView()
    textView.string = "# A\n## B\nbody\n"
    textView.highlightAll()
    textView.fold(at: 0)  // A を折畳 → "## B" ごと隠れる
    textView.scrollToHeading(at: 4)
    #expect(!textView.isFolded(at: 0))
}

@MainActor @Test func outlineReflectsHeadingAddedDuringBackgroundParse() async {
    // 巨大文書相当をバックグラウンド経路に強制し、非同期フラッシュ完了後に
    // アウトラインが「次の編集を待たず」最新化されることを確認する
    // (Highlighter.onBackgroundFlushApplied → MarkdownTextView の再同期フック回帰確認)。
    let textView = MarkdownTextView()
    textView.string = "plain"
    textView.highlightAll()
    textView.markdownHighlighter.backgroundParseThreshold = .zero

    textView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
    textView.markdownHighlighter.noteEdit(
        editedRange: NSRange(location: 0, length: 2), changeInLength: 2)
    textView.markdownHighlighter.flushPendingHighlight(
        contentStorage: textView.textContentStorage!, layoutManager: textView.textLayoutManager!)

    #expect(textView.outline.isEmpty)  // 適用前はまだ古いプラン(見出しなし)のまま
    await textView.markdownHighlighter.activeBackgroundParse?.value
    // 次の編集を待たず、非同期フラッシュ完了の時点でアウトラインに新見出しが載る
    #expect(textView.outline.map(\.title) == ["plain"])
}

@MainActor @Test func performCommandStillWorksWhileFolded() {
    // 折畳が undo 経路の編集(perform)を妨げないこと
    let textView = makeTextView()
    textView.fold(at: 0)
    let done = textView.perform(EditCommand(
        replacementRange: NSRange(location: 20, length: 0),
        replacementString: "!",
        selectedRange: NSRange(location: 21, length: 0)))
    #expect(done)
    #expect(textView.string.contains("!"))
}

/// 本体内にキャレットがある状態で折り畳むと、キャレットは見出し行末(隠れない位置)へ退避する
@MainActor @Test func foldingWithCaretInsideBodyMovesCaretToHeadingLineEnd() {
    let textView = makeTextView()
    textView.setSelectedRange(NSRange(location: 12, length: 0))  // body2 内
    textView.fold(at: 0)
    #expect(textView.isFolded(at: 0))
    #expect(textView.selectedRange() == NSRange(location: 3, length: 0))  // "# A" の末尾
}

/// 本体と交差する選択も同様に退避する。本体の外にあるキャレットは動かさない
@MainActor @Test func foldingKeepsSelectionOutsideBodyUntouched() {
    let textView = makeTextView()
    textView.setSelectedRange(NSRange(location: 8, length: 10))  // body1 途中〜# B
    textView.toggleFold(at: 0)
    #expect(textView.selectedRange() == NSRange(location: 3, length: 0))

    textView.unfoldAll()
    textView.setSelectedRange(NSRange(location: 22, length: 0))  // after
    textView.fold(at: 0)
    #expect(textView.isFolded(at: 0))
    #expect(textView.selectedRange() == NSRange(location: 22, length: 0))
}
#endif

#if os(macOS)
@MainActor @Test func highlightAllOfLongTextKeepsFoldsUntilParseCompletes() async {
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    textView.string = "# A\n\nbody a\n\n# B\n\nbody b\n"
    textView.highlightAll()
    textView.fold(at: 0)
    #expect(textView.isFolded(at: 0))

    textView.engine.highlighter.backgroundParseLengthThreshold = 4
    textView.highlightAll()  // 文字は変わっていない: パース待ちの間も折りたたみは消えない
    #expect(textView.isFolded(at: 0))
    while let task = textView.engine.highlighter.activeBackgroundParse { await task.value }
    #expect(textView.isFolded(at: 0))
    #expect(textView.outline.count == 2)
}
#endif
