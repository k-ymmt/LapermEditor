import Foundation
import Testing

@testable import LapermCore

private func newline(_ text: String, caret: Int) -> EditCommand? {
    EditingAssistant.newline(text: text as NSString, selection: NSRange(location: caret, length: 0))
}

// MARK: - リスト自動継続

@Test func continuesBulletList() {
    let command = newline("- item", caret: 6)
    #expect(command == EditCommand(
        replacementRange: NSRange(location: 6, length: 0),
        replacementString: "\n- ",
        selectedRange: NSRange(location: 9, length: 0)))
}

@Test func continuesEachBulletCharacter() {
    #expect(newline("* item", caret: 6)?.replacementString == "\n* ")
    #expect(newline("+ item", caret: 6)?.replacementString == "\n+ ")
}

@Test func continuesOrderedListWithIncrementedNumber() {
    #expect(newline("3. item", caret: 7)?.replacementString == "\n4. ")
    #expect(newline("9) item", caret: 7)?.replacementString == "\n10) ")
}

@Test func continuesTaskListUnchecked() {
    // チェック状態に関わらず未チェックで継続する
    #expect(newline("- [x] done", caret: 10)?.replacementString == "\n- [ ] ")
    #expect(newline("- [ ] todo", caret: 10)?.replacementString == "\n- [ ] ")
}

@Test func keepsIndentOnContinuation() {
    #expect(newline("  - child", caret: 9)?.replacementString == "\n  - ")
}

@Test func midLineEnterMovesTailToNewItem() {
    // カーソル以降のテキストは挿入されたマーカーの後ろに送られる
    let command = newline("- ab", caret: 3)
    #expect(command?.replacementRange == NSRange(location: 3, length: 0))
    #expect(command?.replacementString == "\n- ")
    #expect(command?.selectedRange == NSRange(location: 6, length: 0))
}

@Test func escapesListOnEmptyItem() {
    let command = newline("- item\n- ", caret: 9)
    #expect(command == EditCommand(
        replacementRange: NSRange(location: 7, length: 2),
        replacementString: "",
        selectedRange: NSRange(location: 7, length: 0)))
}

@Test func escapesIndentedEmptyItemEntirely() {
    // インデントを含む行内容全体を削除する(spec)
    let command = newline("- a\n  - ", caret: 8)
    #expect(command?.replacementRange == NSRange(location: 4, length: 4))
    #expect(command?.replacementString == "")
}

@Test func escapesEmptyTaskItem() {
    let command = newline("- [ ] ", caret: 6)
    #expect(command?.replacementRange == NSRange(location: 0, length: 6))
    #expect(command?.replacementString == "")
}

@Test func plainLineReturnsNil() {
    #expect(newline("plain", caret: 5) == nil)
}

@Test func caretBeforeMarkerContentReturnsNil() {
    // マーカーより前で Enter してもマーカーを分断しない
    #expect(newline("- item", caret: 1) == nil)
}

@Test func selectionReturnsNilForNewline() {
    #expect(EditingAssistant.newline(
        text: "- item", selection: NSRange(location: 0, length: 3)) == nil)
}

@Test func linkListItemIsNotTask() {
    // "[link](…)" の '[' をチェックボックス扱いしない → 通常のバレット継続
    #expect(newline("- [link](https://x)", caret: 19)?.replacementString == "\n- ")
}

private func indent(_ text: String, selection: NSRange) -> EditCommand? {
    EditingAssistant.indent(text: text as NSString, selection: selection)
}
private func outdent(_ text: String, selection: NSRange) -> EditCommand? {
    EditingAssistant.outdent(text: text as NSString, selection: selection)
}

private func insertion(_ text: String, selection: NSRange, typing: String) -> EditCommand? {
    EditingAssistant.insertion(text: text as NSString, selection: selection, typing: typing)
}

private func toggle(_ text: String, at offset: Int) -> EditCommand? {
    EditingAssistant.toggleCheckbox(text: text as NSString, at: offset)
}

// MARK: - チェックボックストグル

@Test func togglesUncheckedToChecked() {
    let command = toggle("- [ ] task", at: 3)
    #expect(command == EditCommand(
        replacementRange: NSRange(location: 3, length: 1),
        replacementString: "x",
        selectedRange: NSRange(location: 3, length: 1)))
}

@Test func togglesCheckedToUnchecked() {
    #expect(toggle("- [x] task", at: 2)?.replacementString == " ")
    #expect(toggle("- [X] task", at: 4)?.replacementString == " ")
}

@Test func togglesOnSecondLine() {
    let command = toggle("- [x] a\n- [ ] b", at: 11)
    #expect(command?.replacementRange == NSRange(location: 11, length: 1))
    #expect(command?.replacementString == "x")
}

@Test func offsetOutsideCheckboxReturnsNil() {
    #expect(toggle("- [ ] task", at: 0) == nil)  // バレット上
    #expect(toggle("- [ ] task", at: 7) == nil)  // 本文上
}

@Test func nonTaskLineReturnsNil() {
    #expect(toggle("- [link](https://x) a", at: 3) == nil)
    #expect(toggle("plain [ ] text", at: 7) == nil)
}

@Test func outOfBoundsOffsetReturnsNil() {
    #expect(toggle("- [ ]", at: 99) == nil)
}

// MARK: - Tab インデント

@Test func indentsListItemLineFromAnyCaretPosition() {
    let command = indent("- item", selection: NSRange(location: 4, length: 0))
    #expect(command == EditCommand(
        replacementRange: NSRange(location: 0, length: 6),
        replacementString: "    - item",
        selectedRange: NSRange(location: 8, length: 0)))
}

@Test func outdentRemovesUpToFourSpaces() {
    let command = outdent("    - item", selection: NSRange(location: 8, length: 0))
    #expect(command?.replacementString == "- item")
    #expect(command?.selectedRange == NSRange(location: 4, length: 0))
}

@Test func outdentRemovesFewerSpacesWhenShallow() {
    #expect(outdent("  - a", selection: NSRange(location: 4, length: 0))?.replacementString == "- a")
}

@Test func outdentAtColumnZeroReturnsNil() {
    #expect(outdent("- a", selection: NSRange(location: 2, length: 0)) == nil)
}

@Test func indentsAllSelectedListLines() {
    let command = indent("- a\n- b", selection: NSRange(location: 0, length: 7))
    #expect(command?.replacementString == "    - a\n    - b")
    #expect(command?.selectedRange == NSRange(location: 4, length: 11))
}

@Test func skipsNonListLinesInSelection() {
    let command = indent("- a\nplain\n- b", selection: NSRange(location: 0, length: 13))
    #expect(command?.replacementString == "    - a\nplain\n    - b")
}

@Test func indentOnPlainLineReturnsNil() {
    #expect(indent("plain", selection: NSRange(location: 3, length: 0)) == nil)
}

@Test func outdentOfFullySelectedIndentedLineClampsSelection() {
    // 選択が削除される空白の内側から始まっても、編集後テキスト長を超えない
    let command = outdent("    - a", selection: NSRange(location: 0, length: 7))
    #expect(command?.replacementString == "- a")
    #expect(command?.selectedRange == NSRange(location: 0, length: 3))
}

@Test func outdentSelectionStartingInsideRemovedWhitespaceStaysValid() {
    let command = outdent("    - a\n    - b\ntail", selection: NSRange(location: 1, length: 11))
    #expect(command?.replacementString == "- a\n- b\n")
    #expect(command?.selectedRange == NSRange(location: 0, length: 4))
}

// MARK: - ペア補完

@Test func wrapsSelectionWithAsterisk() {
    let command = insertion("bold text", selection: NSRange(location: 0, length: 4), typing: "*")
    #expect(command == EditCommand(
        replacementRange: NSRange(location: 0, length: 4),
        replacementString: "*bold*",
        selectedRange: NSRange(location: 1, length: 4)))
}

@Test func wrapsSelectionWithMatchingBracket() {
    #expect(insertion("text", selection: NSRange(location: 0, length: 4), typing: "[")?
        .replacementString == "[text]")
    #expect(insertion("text", selection: NSRange(location: 0, length: 4), typing: "(")?
        .replacementString == "(text)")
}

@Test func wrapsSelectionWithAllDelimiters() {
    for delimiter in ["*", "_", "`", "~"] {
        let command = insertion("x", selection: NSRange(location: 0, length: 1), typing: delimiter)
        #expect(command?.replacementString == "\(delimiter)x\(delimiter)")
    }
}

@Test func autoClosesBacktickBracketParen() {
    for (opening, closing) in [("`", "`"), ("[", "]"), ("(", ")")] {
        let command = insertion("", selection: NSRange(location: 0, length: 0), typing: opening)
        #expect(command?.replacementString == opening + closing)
        #expect(command?.selectedRange == NSRange(location: 1, length: 0))
    }
}

@Test func doesNotAutoCloseEmphasisCharacters() {
    // * _ ~ は日本語の文章中で誤発火しやすいため自動閉じ対象外(spec)
    for character in ["*", "_", "~"] {
        #expect(insertion("", selection: NSRange(location: 0, length: 0), typing: character) == nil)
    }
}

@Test func typesOverExistingClosingCharacter() {
    let command = insertion("()", selection: NSRange(location: 1, length: 0), typing: ")")
    #expect(command == EditCommand(
        replacementRange: NSRange(location: 1, length: 0),
        replacementString: "",
        selectedRange: NSRange(location: 2, length: 0)))
}

@Test func plainCharacterReturnsNil() {
    #expect(insertion("", selection: NSRange(location: 0, length: 0), typing: "a") == nil)
    #expect(insertion("", selection: NSRange(location: 0, length: 0), typing: "ab") == nil)
}

// MARK: - 空ペア削除

private func deleteBackward(_ text: String, selection: NSRange) -> EditCommand? {
    EditingAssistant.deleteBackward(text: text as NSString, selection: selection)
}

@Test func backspaceDeletesEmptyPair() {
    let command = deleteBackward("()", selection: NSRange(location: 1, length: 0))
    #expect(command == EditCommand(
        replacementRange: NSRange(location: 0, length: 2),
        replacementString: "",
        selectedRange: NSRange(location: 0, length: 0)))
}

@Test func backspaceDeletesEachAutoClosingPair() {
    #expect(deleteBackward("[]", selection: NSRange(location: 1, length: 0))?.replacementRange
        == NSRange(location: 0, length: 2))
    #expect(deleteBackward("``", selection: NSRange(location: 1, length: 0))?.replacementRange
        == NSRange(location: 0, length: 2))
}

@Test func backspaceDeletesEmptyPairMidText() {
    let command = deleteBackward("a()b", selection: NSRange(location: 2, length: 0))
    #expect(command?.replacementRange == NSRange(location: 1, length: 2))
    #expect(command?.selectedRange == NSRange(location: 1, length: 0))
}

@Test func backspaceKeepsNonEmptyPair() {
    // 中身のあるペアは通常の 1 文字削除に任せる
    #expect(deleteBackward("(x)", selection: NSRange(location: 1, length: 0)) == nil)
}

@Test func backspaceIgnoresWrapOnlyDelimiters() {
    // * などの囲い込み専用文字は自動閉じされないので対象外
    #expect(deleteBackward("**", selection: NSRange(location: 1, length: 0)) == nil)
    #expect(deleteBackward("~~", selection: NSRange(location: 1, length: 0)) == nil)
}

@Test func backspaceEdgeCasesReturnNil() {
    // 選択あり・行頭・末尾・不一致ペアはすべて通常動作
    #expect(deleteBackward("()", selection: NSRange(location: 0, length: 2)) == nil)
    #expect(deleteBackward("()", selection: NSRange(location: 0, length: 0)) == nil)
    #expect(deleteBackward("()", selection: NSRange(location: 2, length: 0)) == nil)
    #expect(deleteBackward("(]", selection: NSRange(location: 1, length: 0)) == nil)
}
