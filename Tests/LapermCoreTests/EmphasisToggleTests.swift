import Foundation
import Testing

@testable import LapermCore

private func toggle(_ text: String, _ location: Int, _ length: Int = 0, _ style: EmphasisStyle = .strong) -> EditCommand? {
    EditingAssistant.toggleEmphasis(text: text as NSString, selection: NSRange(location: location, length: length), style: style)
}

/// コマンドを適用した結果の文字列(検証用)
private func applied(_ text: String, _ command: EditCommand?) -> String? {
    guard let command else { return nil }
    return (text as NSString).replacingCharacters(in: command.replacementRange, with: command.replacementString)
}

// MARK: - 選択あり

@Test func wrapsSelectionInStrong() {
    let command = toggle("hello world", 0, 5)
    #expect(command == EditCommand(
        replacementRange: NSRange(location: 0, length: 5),
        replacementString: "**hello**",
        selectedRange: NSRange(location: 2, length: 5)))
}

@Test func wrapsSelectionInEmphasisWithAsterisk() {
    let command = toggle("hello world", 6, 5, .emphasis)
    #expect(applied("hello world", command) == "hello *world*")
    #expect(command?.selectedRange == NSRange(location: 7, length: 5))
}

@Test func unwrapsSelectionThatIncludesMarkers() {
    let command = toggle("**hello** world", 0, 9)
    #expect(applied("**hello** world", command) == "hello world")
    #expect(command?.selectedRange == NSRange(location: 0, length: 5))
}

@Test func unwrapsSelectionInsideMarkers() {
    let command = toggle("say **hello** world", 6, 5)
    #expect(applied("say **hello** world", command) == "say hello world")
    #expect(command?.selectedRange == NSRange(location: 4, length: 5))
}

@Test func recognizesUnderscoreMarkersWhenUnwrapping() {
    #expect(applied("__hello__", toggle("__hello__", 2, 5)) == "hello")
    #expect(applied("_hello_", toggle("_hello_", 1, 5, .emphasis)) == "hello")
    #expect(applied("__hello__", toggle("__hello__", 0, 9)) == "hello")
}

@Test func mixedMarkerCharactersDoNotCountAsWrapped() {
    // "*hello_" は強調ではないので、囲む
    #expect(applied("*hello_", toggle("*hello_", 1, 5, .emphasis)) == "**hello*_")
}

@Test func emphasisOnStrongTextWrapsAgain() {
    // ** はボールドであってイタリックではない
    let command = toggle("**hello**", 2, 5, .emphasis)
    #expect(applied("**hello**", command) == "***hello***")
    #expect(command?.selectedRange == NSRange(location: 3, length: 5))
}

@Test func strongOnStrongEmphasisTextRemovesOnlyStrong() {
    let command = toggle("***hello***", 3, 5)
    #expect(applied("***hello***", command) == "*hello*")
    #expect(command?.selectedRange == NSRange(location: 1, length: 5))
}

@Test func emphasisOnStrongEmphasisTextRemovesOnlyEmphasis() {
    #expect(applied("***hello***", toggle("***hello***", 3, 5, .emphasis)) == "**hello**")
    #expect(applied("***hello***", toggle("***hello***", 0, 11, .emphasis)) == "**hello**")
}

@Test func strongOnEmphasisTextWrapsAgain() {
    #expect(applied("*hello*", toggle("*hello*", 1, 5)) == "***hello***")
}

@Test func trimsWhitespaceAroundSelection() {
    let command = toggle("hello world", 0, 6)
    #expect(applied("hello world", command) == "**hello** world")
    #expect(command?.selectedRange == NSRange(location: 2, length: 5))
    #expect(applied(" hi ", toggle(" hi ", 0, 4)) == " **hi** ")
}

@Test func whitespaceOnlySelectionInsertsEmptyMarkersAtItsStart() {
    let command = toggle("a  b", 1, 2)
    #expect(applied("a  b", command) == "a****  b")
    #expect(command?.selectedRange == NSRange(location: 3, length: 0))
}

@Test func multiWordSelectionIsWrappedAsOne() {
    #expect(applied("hello big world", toggle("hello big world", 0, 9)) == "**hello big** world")
}

// MARK: - カーソルのみ

@Test func caretInsideWordWrapsTheWord() {
    let command = toggle("hello world", 2)
    #expect(applied("hello world", command) == "**hello** world")
    #expect(command?.selectedRange == NSRange(location: 4, length: 0))
}

@Test func caretAtWordEdgesWrapsTheWord() {
    #expect(applied("hello", toggle("hello", 5)) == "**hello**")
    #expect(toggle("hello", 5)?.selectedRange == NSRange(location: 7, length: 0))
    #expect(applied("hello", toggle("hello", 0)) == "**hello**")
    #expect(toggle("hello", 0)?.selectedRange == NSRange(location: 2, length: 0))
}

@Test func caretAfterWordBeforeSpaceWrapsThePrecedingWord() {
    #expect(applied("hello world", toggle("hello world", 5)) == "**hello** world")
}

@Test func caretInsideWrappedWordUnwrapsAndKeepsRelativeCaret() {
    let command = toggle("**hello**", 4)
    #expect(applied("**hello**", command) == "hello")
    #expect(command?.selectedRange == NSRange(location: 2, length: 0))
}

@Test func caretInsideWrappedWordDoesNotUnwrapOtherStyle() {
    #expect(applied("**hello**", toggle("**hello**", 4, 0, .emphasis)) == "***hello***")
    #expect(applied("*hello*", toggle("*hello*", 3)) == "***hello***")
}

@Test func caretWithoutWordInsertsEmptyMarkers() {
    let command = toggle("a  b", 2)
    #expect(command == EditCommand(
        replacementRange: NSRange(location: 2, length: 0),
        replacementString: "****",
        selectedRange: NSRange(location: 4, length: 0)))
    #expect(toggle("", 0, 0, .emphasis) == EditCommand(
        replacementRange: NSRange(location: 0, length: 0),
        replacementString: "**",
        selectedRange: NSRange(location: 1, length: 0)))
}

@Test func caretBetweenEmptyMarkersRemovesThem() {
    let command = toggle("a **** b", 4)
    #expect(applied("a **** b", command) == "a  b")
    #expect(command?.selectedRange == NSRange(location: 2, length: 0))
    #expect(applied("**", toggle("**", 1, 0, .emphasis)) == "")
}

@Test func evenMarkerRunsAreNotItalic() {
    // **** は strong の入れ子であってイタリックではない
    #expect(applied("****x****", toggle("****x****", 5, 0, .emphasis)) == "*****x*****")
    #expect(applied("****x****", toggle("****x****", 5)) == "**x**")
    #expect(applied("*****x*****", toggle("*****x*****", 6, 0, .emphasis)) == "****x****")
}

// MARK: - 解除を確証できないときは何もしない

@Test func intrawordUnderscoresAreNotEmphasis() {
    let command = toggle("foo_bar_baz", 4, 3, .emphasis)
    #expect(applied("foo_bar_baz", command) == "foo_*bar*_baz")
    #expect(applied("foo__bar__baz", toggle("foo__bar__baz", 5, 3)) == "foo__**bar**__baz")
    // 選択にアンダースコアを含めても語内なら外さない
    #expect(applied("foo_bar_baz", toggle("foo_bar_baz", 3, 5, .emphasis)) == "foo*_bar_*baz")
    // 語境界のアンダースコアは強調
    #expect(applied("a _bar_ b", toggle("a _bar_ b", 3, 3, .emphasis)) == "a bar b")
    // 単語の途中のカーソルは snake_case 全体を囲む
    #expect(applied("foo_bar_baz", toggle("foo_bar_baz", 5)) == "**foo_bar_baz**")
}

@Test func selectionSpanningSeparateEmphasisSpansIsLeftAlone() {
    #expect(toggle("**one** and **two**", 0, 19) == nil)
    #expect(toggle("**one** and **two**", 2, 15) == nil)  // one** and **two
    #expect(toggle("*a* and *b*", 0, 11, .emphasis) == nil)
    #expect(toggle("hello *world*", 0, 13, .emphasis) == nil)
    // 別のスタイルのマーカーは邪魔にならない
    #expect(applied("hello *world*", toggle("hello *world*", 0, 13)) == "**hello *world***")
    #expect(applied("a **x** b", toggle("a **x** b", 0, 9, .emphasis)) == "*a **x** b*")
}

@Test func selectionInsideCodeSpanIsLeftAlone() {
    #expect(toggle("`**x**`", 3, 1) == nil)
    #expect(toggle("see `code` and `more`", 16, 4) == nil)
    // 閉じたコードスパンの後は通常どおり
    #expect(applied("`code` word", toggle("`code` word", 8)) == "`code` **word**")
}

@Test func selectionAcrossBlankLineIsLeftAlone() {
    #expect(toggle("a\n\nb", 0, 4) == nil)
    #expect(toggle("a\n  \nb", 0, 6) == nil)
    #expect(toggle("a\r\n\r\nb", 0, 6) == nil)
    // 単一の改行はまたげる
    #expect(applied("a\nb", toggle("a\nb", 0, 3)) == "**a\nb**")
}

@Test func rejectsInvalidRanges() {
    let text = "ab"
    #expect(EditingAssistant.toggleEmphasis(text: text as NSString, selection: NSRange(location: -1, length: 0), style: .strong) == nil)
    #expect(EditingAssistant.toggleEmphasis(text: text as NSString, selection: NSRange(location: 0, length: -1), style: .strong) == nil)
    #expect(EditingAssistant.toggleEmphasis(text: text as NSString, selection: NSRange(location: 1, length: Int.max), style: .strong) == nil)
    #expect(EditingAssistant.toggleEmphasis(text: text as NSString, selection: NSRange(location: NSNotFound, length: 0), style: .strong) == nil)
}

@Test func surrogatePairsAreNeverSplit() {
    // サロゲートペアの途中のカーソルは文字の頭へ丸める(絵文字は単語ではないので空マーカー)
    let command = toggle("😀", 1)
    #expect(applied("😀", command) == "****😀")
    #expect(command?.selectedRange == NSRange(location: 2, length: 0))
    // 選択の端が途中なら文字ごと含める
    #expect(applied("😀a", toggle("😀a", 1, 1)) == "**😀**a")
    #expect(applied("a😀", toggle("a😀", 0, 2)) == "**a😀**")
    #expect(applied("😀 x", toggle("😀 x", 2)) == "😀**** x")
}

@Test func caretBetweenEmptyStrongMarkersWithEmphasisWrapsAgain() {
    #expect(applied("****", toggle("****", 2, 0, .emphasis)) == "*****" + "*")
}

@Test func caretOnPunctuationInsertsEmptyMarkers() {
    // 記号は単語ではない
    #expect(applied("a.b", toggle("a.b", 2)) == "a.**b**")  // 隣接する単語 "b" を優先
    #expect(applied("(.)", toggle("(.)", 1)) == "(****.)")
}

@Test func cjkRunCountsAsOneWord() {
    let text = "これは テスト です"
    let command = toggle(text, 5)
    #expect(applied(text, command) == "これは **テスト** です")
}

@Test func composedCharactersStayIntact() {
    let text = "e\u{301}a" // é (合成) + a
    let command = toggle(text, 1)
    #expect(applied(text, command) == "**\(text)**")
    // 結合文字の途中にあったカーソルは文字の頭(0)として扱い、マーカーの直後へ
    #expect(command?.selectedRange == NSRange(location: 2, length: 0))
}

@Test func rejectsOutOfRangeSelection() {
    #expect(toggle("ab", 1, 5) == nil)
    #expect(toggle("ab", 3) == nil)
}

@Test func markerHelpers() {
    #expect(EmphasisStyle.strong.marker == "**")
    #expect(EmphasisStyle.emphasis.marker == "*")
    #expect(EmphasisStyle.strong.matches(runLength: 2))
    #expect(!EmphasisStyle.strong.matches(runLength: 1))
    #expect(EmphasisStyle.emphasis.matches(runLength: 1))
    #expect(!EmphasisStyle.emphasis.matches(runLength: 2))
    #expect(EmphasisStyle.emphasis.matches(runLength: 3))
    #expect(!EmphasisStyle.emphasis.matches(runLength: 4))
    #expect(EmphasisStyle.strong.matches(runLength: 4))
}

@Test func wordRangeRoundsToComposedCharacters() {
    #expect(TextMotions.wordRange(text: "😀", at: 1) == NSRange(location: 0, length: 0))
    #expect(TextMotions.wordRange(text: "a😀b", at: 2) == NSRange(location: 0, length: 1))
    #expect(TextMotions.wordRange(text: "ab", at: 5) == NSRange(location: 0, length: 2))
}
