import Foundation
import Testing
@testable import LapermCore

// テキスト: "hello\nhi\nworld"
//            0-4  5  6-7 8  9-13
private nonisolated(unsafe) let sample = "hello\nhi\nworld" as NSString

@Test func lineStartAndEnd() {
    #expect(TextMotions.lineStart(text: sample, at: 7) == 6)
    #expect(TextMotions.lineEnd(text: sample, at: 7) == 8)   // 改行の手前
    #expect(TextMotions.lineStart(text: sample, at: 0) == 0)
    #expect(TextMotions.lineEnd(text: sample, at: 13) == 14)  // 最終行(改行なし)
}

@Test func lineUpClampsToShortLine() {
    // "world" の列 4 から上へ → "hi" は 2 文字なので行末(8)にクランプ
    #expect(TextMotions.lineUp(text: sample, at: 13, preferredColumn: 4) == 8)
}

@Test func lineDownRestoresPreferredColumn() {
    // "hi" 行から列 4 指定で下へ → "world" の列 4(offset 13)
    #expect(TextMotions.lineDown(text: sample, at: 6, preferredColumn: 4) == 13)
}

@Test func lineUpAtFirstLineStaysPut() {
    #expect(TextMotions.lineUp(text: sample, at: 2, preferredColumn: 2) == 2)
}

@Test func lineDownAtLastLineStaysPut() {
    #expect(TextMotions.lineDown(text: sample, at: 10, preferredColumn: 1) == 10)
}

@Test func lineDownIntoTrailingEmptyLine() {
    // 末尾改行の後ろは空の最終行として扱う
    let text = "ab\n" as NSString
    #expect(TextMotions.lineDown(text: text, at: 1, preferredColumn: 1) == 3)
}

@Test func verticalMotionRoundsToComposedCharacterBoundary() {
    // "xx\na🎉b": 🎉 は UTF-16 で 2 単位(offset 4-5)。列 2 は絵文字の途中 → 先頭に丸める
    let text = "xx\na🎉b" as NSString
    #expect(TextMotions.lineDown(text: text, at: 0, preferredColumn: 2) == 4)
}

@Test func wordForwardStopsAtSymbolRun() {
    // "foo, bar": 単語 → 記号 → 空白 → 単語
    let text = "foo, bar" as NSString
    #expect(TextMotions.wordForward(text: text, at: 0) == 3)   // "," へ
    #expect(TextMotions.wordForward(text: text, at: 3) == 5)   // "bar" へ
}

@Test func wordForwardAtDocumentEndStaysPut() {
    let text = "foo" as NSString
    #expect(TextMotions.wordForward(text: text, at: 3) == 3)
}

@Test func wordForwardCrossesNewline() {
    let text = "foo\nbar" as NSString
    #expect(TextMotions.wordForward(text: text, at: 0) == 4)
}

@Test func wordBackwardToWordStart() {
    let text = "foo bar" as NSString
    #expect(TextMotions.wordBackward(text: text, at: 6) == 4)  // "bar" 内 → "bar" 頭
    #expect(TextMotions.wordBackward(text: text, at: 4) == 0)  // "bar" 頭 → "foo" 頭
    #expect(TextMotions.wordBackward(text: text, at: 0) == 0)  // 文書頭
}

@Test func japaneseTextFormsWordRuns() {
    // CJK 文字は alphanumerics に含まれ、連続で 1 単語になる
    let text = "日本語 abc" as NSString
    #expect(TextMotions.wordForward(text: text, at: 0) == 4)
}

@Test func underscoreIsWordCharacter() {
    let text = "foo_bar baz" as NSString
    #expect(TextMotions.wordForward(text: text, at: 0) == 8)
}

@Test func lineMotionsSnapMidCharacterOffsetsToComposedBoundary() {
    let text = "😀" as NSString  // サロゲートペア(UTF-16 で 2 単位)
    #expect(TextMotions.lineUp(text: text, at: 1, preferredColumn: 0) == 0)
    #expect(TextMotions.lineDown(text: text, at: 1, preferredColumn: 0) == 0)
}
