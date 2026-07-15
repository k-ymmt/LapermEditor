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
