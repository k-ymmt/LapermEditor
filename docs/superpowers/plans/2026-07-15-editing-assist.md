# 編集支援機能(リスト自動継続・チェックボックストグル・Tab インデント・ペア補完)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `MarkdownTextView` にリスト自動継続・チェックボックスクリックトグル・Tab インデント・ペア補完の 4 つの編集支援を追加する。

**Architecture:** 編集判断を純粋関数 `EditingAssistant`(LapermCore)として実装し、`MarkdownTextView`(Laperm)は `insertNewline` / `insertTab` / `insertBacktab` / `insertText` / `mouseDown` を薄くオーバーライドして委譲、返った `EditCommand` を undo 対応の経路で適用する。判断は行単位のテキスト走査のみで行い、swift-markdown にもハイライトパイプラインにも依存しない。

**Tech Stack:** Swift 6 / SwiftPM / TextKit 2(macOS 27+)/ Swift Testing

**Spec:** `docs/superpowers/specs/2026-07-15-editing-assist-design.md`

## Global Constraints

- 対象 OS: macOS 27+。外部依存は `apple/swift-markdown` のみ(追加禁止。本機能はそれすら使わない)
- 全 Core 関数は「判断できない・対象外 = `nil` を返す(→ NSTextView デフォルト動作)」の規約。範囲は常に text 長に対して検証し、クラッシュ経路を作らない
- コメントは既存コードに合わせて日本語で書く
- 各タスク末尾で `swift test` 全体を実行し、全テスト通過(既存 85 = Core 47 + UI 38、+ 追加分)を確認してからコミット
- コミットメッセージ末尾に以下を含める(ユーザー CLAUDE.md の規約):
  ```
  Task context: 編集支援機能 (docs/superpowers/specs/2026-07-15-editing-assist-design.md)

  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01KKBTtzv3UxhX8vTPruvGJc
  ```

## 挙動仕様の要点(spec より)

- リスト継続: カーソル(選択なし)時のみ。順序付きは番号 +1(区切り `.` / `)` 維持)、タスクは常に `[ ] `(未チェック)で継続。空項目 Enter はインデント含め行内容全体を削除。番号振り直しはしない
- トグル: `[ ]` / `[x]` の 3 文字上のクリックのみ。同長 1 文字置換なので UI 層は適用前の選択を復元する
- インデント: リスト項目行のみ対象、カーソル位置は行内どこでも可。単位はスペース 4 固定。複数行選択は選択内のリスト行すべて
- ペア補完: 囲い込みは `*` `_` `` ` `` `~` `[` `(`、自動閉じは `` ` `` `[` `(` のみ。タイプオーバーあり。IME 変換中は素通し

---

### Task 1: Core — EditCommand とリスト自動継続

**Files:**
- Create: `Sources/LapermCore/EditingAssistant.swift`
- Create: `Tests/LapermCoreTests/EditingAssistantTests.swift`

**Interfaces:**
- Consumes: なし(Foundation のみ)
- Produces:
  - `public struct EditCommand: Equatable, Sendable`(`replacementRange: NSRange`, `replacementString: String`, `selectedRange: NSRange`、memberwise 相当の public init)— Task 2〜5 が使用
  - `public enum EditingAssistant` + `public static func newline(text: NSString, selection: NSRange) -> EditCommand?` — Task 5 が使用
  - internal `struct ListItemLine`(`indent: String`, `continuationMarker: String`, `checkboxLocation: Int?`, `contentStart: Int`, `static func parse(text: NSString, lineRange: NSRange) -> ListItemLine?`)— Task 2/4 が使用

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermCoreTests/EditingAssistantTests.swift` を新規作成:

```swift
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
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter EditingAssistantTests 2>&1 | tail -5`
Expected: コンパイルエラー(`EditingAssistant` / `EditCommand` 未定義)

- [ ] **Step 3: 実装**

`Sources/LapermCore/EditingAssistant.swift` を新規作成:

```swift
import Foundation

/// 編集操作の結果。UI 層がこれを undo 対応の経路で適用する。
/// replacementRange は現在のテキスト座標、selectedRange は適用後座標。
public struct EditCommand: Equatable, Sendable {
    public var replacementRange: NSRange
    public var replacementString: String
    public var selectedRange: NSRange

    public init(replacementRange: NSRange, replacementString: String, selectedRange: NSRange) {
        self.replacementRange = replacementRange
        self.replacementString = replacementString
        self.selectedRange = selectedRange
    }
}

/// 編集支援の判断を行う純粋関数群(状態を持たない)。
/// 全関数は「判断できない・対象外 = nil(→ 呼び出し側はデフォルト動作)」の規約。
/// 判断は行単位のテキスト走査のみで行い、パーサーには依存しない。
public enum EditingAssistant {
    /// Enter: リスト自動継続。空項目ならリストから脱出(行内容全体を削除)
    public static func newline(text: NSString, selection: NSRange) -> EditCommand? {
        guard selection.length == 0, selection.location <= text.length else { return nil }
        let lineRange = text.lineRange(for: NSRange(location: selection.location, length: 0))
        guard let item = ListItemLine.parse(text: text, lineRange: lineRange) else { return nil }
        var contentsEnd = 0
        text.getLineStart(
            nil, end: nil, contentsEnd: &contentsEnd,
            for: NSRange(location: lineRange.location, length: 0))
        // マーカーより前にカーソルがあるときはデフォルト動作(マーカーを分断しない)
        guard selection.location >= item.contentStart else { return nil }
        // 空項目脱出: 本文が空ならインデントごと行内容を削除して空行にする
        if item.contentStart >= contentsEnd {
            return EditCommand(
                replacementRange: NSRange(
                    location: lineRange.location, length: contentsEnd - lineRange.location),
                replacementString: "",
                selectedRange: NSRange(location: lineRange.location, length: 0))
        }
        let inserted = "\n" + item.indent + item.continuationMarker
        return EditCommand(
            replacementRange: NSRange(location: selection.location, length: 0),
            replacementString: inserted,
            selectedRange: NSRange(
                location: selection.location + (inserted as NSString).length, length: 0))
    }
}

/// リスト項目行の解析結果。行頭のインデント・マーカー・チェックボックスを走査で検出する。
struct ListItemLine {
    /// 行頭の空白(スペース/タブ)
    var indent: String
    /// 継続時に次行へ挿入するマーカー("- " / "4. " / "- [ ] " など、末尾スペース込み)
    var continuationMarker: String
    /// チェックボックス "[ ]" / "[x]" / "[X]" の文書内オフセット(タスク項目のみ)
    var checkboxLocation: Int?
    /// 本文開始オフセット(マーカーと後続スペースの直後、文書座標)
    var contentStart: Int

    static func parse(text: NSString, lineRange: NSRange) -> ListItemLine? {
        var contentsEnd = 0
        text.getLineStart(
            nil, end: nil, contentsEnd: &contentsEnd,
            for: NSRange(location: lineRange.location, length: 0))
        let space = unichar(UnicodeScalar(" ").value)
        let tab = unichar(UnicodeScalar("\t").value)
        var i = lineRange.location
        while i < contentsEnd, text.character(at: i) == space || text.character(at: i) == tab {
            i += 1
        }
        let indent = text.substring(
            with: NSRange(location: lineRange.location, length: i - lineRange.location))
        guard i < contentsEnd else { return nil }

        // マーカー: "-" / "*" / "+" または "数字列." / "数字列)"
        let markerText: String
        let bullets: Set<unichar> = [
            unichar(UnicodeScalar("-").value),
            unichar(UnicodeScalar("*").value),
            unichar(UnicodeScalar("+").value),
        ]
        if bullets.contains(text.character(at: i)) {
            markerText = String(UnicodeScalar(text.character(at: i))!)
            i += 1
        } else if isDigit(text.character(at: i)) {
            var j = i
            var number = 0
            while j < contentsEnd, isDigit(text.character(at: j)) {
                number = number * 10 + Int(text.character(at: j) - 48)
                j += 1
            }
            // 桁数の異常な数字列はリストとして扱わない(オーバーフロー防止)
            guard j - i <= 9, j < contentsEnd else { return nil }
            let delimiter = text.character(at: j)
            guard delimiter == unichar(UnicodeScalar(".").value)
                || delimiter == unichar(UnicodeScalar(")").value) else { return nil }
            // 継続マーカーは番号 +1(区切り文字は元の行に合わせる)
            markerText = "\(number + 1)\(String(UnicodeScalar(delimiter)!))"
            i = j + 1
        } else {
            return nil
        }

        // マーカー直後に少なくとも 1 個のスペースが必要
        guard i < contentsEnd, text.character(at: i) == space else { return nil }
        while i < contentsEnd, text.character(at: i) == space { i += 1 }

        // チェックボックス "[ ]" / "[x]" / "[X]"(直後がスペースまたは行末のときのみ)
        var checkboxLocation: Int?
        var continuation = markerText + " "
        if i + 3 <= contentsEnd,
            text.character(at: i) == unichar(UnicodeScalar("[").value),
            text.character(at: i + 2) == unichar(UnicodeScalar("]").value) {
            let state = text.character(at: i + 1)
            let isState = state == space
                || state == unichar(UnicodeScalar("x").value)
                || state == unichar(UnicodeScalar("X").value)
            let followedBySpaceOrEnd = i + 3 == contentsEnd || text.character(at: i + 3) == space
            if isState && followedBySpaceOrEnd {
                checkboxLocation = i
                // タスクはチェック状態に関わらず未チェックで継続する
                continuation += "[ ] "
                i += 3
                while i < contentsEnd, text.character(at: i) == space { i += 1 }
            }
        }
        return ListItemLine(
            indent: indent,
            continuationMarker: continuation,
            checkboxLocation: checkboxLocation,
            contentStart: i)
    }

    private static func isDigit(_ character: unichar) -> Bool {
        character >= 48 && character <= 57
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter EditingAssistantTests 2>&1 | tail -5`
Expected: PASS(13 テスト)

- [ ] **Step 5: 全テスト実行**

Run: `swift test 2>&1 | grep "Test run"`
Expected: 全テスト PASS(Core 60 + UI 38)

- [ ] **Step 6: コミット**

```bash
git add Sources/LapermCore Tests/LapermCoreTests
git commit -m "feat(core): add EditingAssistant with list continuation on newline"
```
(末尾に Global Constraints のトレーラーを付ける)

---

### Task 2: Core — Tab インデント

**Files:**
- Modify: `Sources/LapermCore/EditingAssistant.swift`
- Test: `Tests/LapermCoreTests/EditingAssistantTests.swift`

**Interfaces:**
- Consumes: `ListItemLine.parse(text:lineRange:)`、`EditCommand`(Task 1)
- Produces: `EditingAssistant.indent(text: NSString, selection: NSRange) -> EditCommand?`、`EditingAssistant.outdent(text: NSString, selection: NSRange) -> EditCommand?` — Task 5 が使用

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermCoreTests/EditingAssistantTests.swift` に追加:

```swift
private func indent(_ text: String, selection: NSRange) -> EditCommand? {
    EditingAssistant.indent(text: text as NSString, selection: selection)
}
private func outdent(_ text: String, selection: NSRange) -> EditCommand? {
    EditingAssistant.outdent(text: text as NSString, selection: selection)
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
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter EditingAssistantTests 2>&1 | tail -5`
Expected: コンパイルエラー(`indent` / `outdent` 未定義)

- [ ] **Step 3: 実装**

`EditingAssistant.swift` の `enum EditingAssistant` 内(`newline` の後)に追加:

```swift
    /// インデント単位(スペース 4。番号付きマーカー幅でもネストが常に成立する値)
    private static let indentUnit = "    "

    /// Tab: 選択範囲(またはカーソル行)内のリスト項目行を 1 段深くする
    public static func indent(text: NSString, selection: NSRange) -> EditCommand? {
        changeIndent(text: text, selection: selection, removing: false)
    }

    /// Shift+Tab: 選択範囲(またはカーソル行)内のリスト項目行を 1 段浅くする
    public static func outdent(text: NSString, selection: NSRange) -> EditCommand? {
        changeIndent(text: text, selection: selection, removing: true)
    }

    private static func changeIndent(
        text: NSString, selection: NSRange, removing: Bool
    ) -> EditCommand? {
        guard NSMaxRange(selection) <= text.length else { return nil }
        let linesRange = text.lineRange(for: selection)
        var rebuilt = ""
        var firstDelta: Int?
        var totalDelta = 0
        var foundListLine = false
        var location = linesRange.location
        while location < NSMaxRange(linesRange) {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            var line = text.substring(with: lineRange)
            var delta = 0
            if ListItemLine.parse(text: text, lineRange: lineRange) != nil {
                foundListLine = true
                if removing {
                    // 行頭から最大 indentUnit 分のスペースを削除
                    let removable = line.prefix(indentUnit.count).prefix(while: { $0 == " " }).count
                    if removable > 0 {
                        line.removeFirst(removable)
                        delta = -removable
                    }
                } else {
                    line = indentUnit + line
                    delta = indentUnit.count
                }
            }
            rebuilt += line
            if firstDelta == nil { firstDelta = delta }
            totalDelta += delta
            location = NSMaxRange(lineRange)
        }
        guard foundListLine, totalDelta != 0 else { return nil }
        // 選択範囲の維持: 先頭行の増減分だけ開始位置をずらし、残りは長さに反映する
        let first = firstDelta ?? 0
        let newLocation = max(linesRange.location, selection.location + first)
        let newLength = max(0, selection.length + totalDelta - first)
        return EditCommand(
            replacementRange: linesRange,
            replacementString: rebuilt,
            selectedRange: NSRange(location: newLocation, length: newLength))
    }
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter EditingAssistantTests 2>&1 | tail -5`
Expected: PASS(20 テスト)

- [ ] **Step 5: 全テスト実行**

Run: `swift test 2>&1 | grep "Test run"`
Expected: 全テスト PASS(Core 67 + UI 38)

- [ ] **Step 6: コミット**

```bash
git add Sources/LapermCore Tests/LapermCoreTests
git commit -m "feat(core): add list item indent/outdent for Tab handling"
```
(末尾に Global Constraints のトレーラーを付ける)

---

### Task 3: Core — ペア補完

**Files:**
- Modify: `Sources/LapermCore/EditingAssistant.swift`
- Test: `Tests/LapermCoreTests/EditingAssistantTests.swift`

**Interfaces:**
- Consumes: `EditCommand`(Task 1)
- Produces: `EditingAssistant.insertion(text: NSString, selection: NSRange, typing: String) -> EditCommand?` — Task 5 が使用。**タイプオーバー時は `replacementRange.length == 0` かつ `replacementString == ""` の「選択移動のみ」コマンドを返す**(UI 層はこの形を置換なしで適用する)

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermCoreTests/EditingAssistantTests.swift` に追加:

```swift
private func insertion(_ text: String, selection: NSRange, typing: String) -> EditCommand? {
    EditingAssistant.insertion(text: text as NSString, selection: selection, typing: typing)
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
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter EditingAssistantTests 2>&1 | tail -5`
Expected: コンパイルエラー(`insertion` 未定義)

- [ ] **Step 3: 実装**

`EditingAssistant.swift` の `enum EditingAssistant` 内に追加:

```swift
    /// 囲い込み対象(開き文字 → 閉じ文字)
    private static let wrapPairs: [Character: Character] = [
        "*": "*", "_": "_", "`": "`", "~": "~", "[": "]", "(": ")",
    ]
    /// 自動閉じ対象(強調記号は日本語の文章中で誤発火しやすいため除外)
    private static let autoClosing: Set<Character> = ["`", "[", "("]
    /// タイプオーバー対象の閉じ文字
    private static let closers: Set<Character> = ["`", "]", ")"]

    /// 文字入力: ペア補完(囲い込み・自動閉じ・タイプオーバー)。
    /// タイプオーバーは「置換なし・選択移動のみ」のコマンドを返す。
    public static func insertion(
        text: NSString, selection: NSRange, typing: String
    ) -> EditCommand? {
        guard NSMaxRange(selection) <= text.length,
            typing.count == 1, let character = typing.first else { return nil }
        // 囲い込み: 選択範囲をペアで囲み、内側のテキストを選択したままにする
        if selection.length > 0 {
            guard let closing = wrapPairs[character] else { return nil }
            let selected = text.substring(with: selection)
            return EditCommand(
                replacementRange: selection,
                replacementString: "\(character)\(selected)\(closing)",
                selectedRange: NSRange(location: selection.location + 1, length: selection.length))
        }
        // タイプオーバー: カーソル直後が同じ閉じ文字ならカーソルだけ進める
        // (closers 通過後なので character は必ず ASCII — asciiValue は非 nil)
        if closers.contains(character), selection.location < text.length,
            text.character(at: selection.location) == unichar(character.asciiValue!) {
            return EditCommand(
                replacementRange: NSRange(location: selection.location, length: 0),
                replacementString: "",
                selectedRange: NSRange(location: selection.location + 1, length: 0))
        }
        // 自動閉じ: 閉じ側を挿入してカーソルを間に置く
        if autoClosing.contains(character), let closing = wrapPairs[character] {
            return EditCommand(
                replacementRange: selection,
                replacementString: "\(character)\(closing)",
                selectedRange: NSRange(location: selection.location + 1, length: 0))
        }
        return nil
    }
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter EditingAssistantTests 2>&1 | tail -5`
Expected: PASS(27 テスト)

- [ ] **Step 5: 全テスト実行**

Run: `swift test 2>&1 | grep "Test run"`
Expected: 全テスト PASS(Core 74 + UI 38)

- [ ] **Step 6: コミット**

```bash
git add Sources/LapermCore Tests/LapermCoreTests
git commit -m "feat(core): add pair completion (wrap, auto-close, type-over)"
```
(末尾に Global Constraints のトレーラーを付ける)

---

### Task 4: Core — チェックボックストグル

**Files:**
- Modify: `Sources/LapermCore/EditingAssistant.swift`
- Test: `Tests/LapermCoreTests/EditingAssistantTests.swift`

**Interfaces:**
- Consumes: `ListItemLine.parse(text:lineRange:)`(Task 1。`checkboxLocation` を使用)
- Produces: `EditingAssistant.toggleCheckbox(text: NSString, at offset: Int) -> EditCommand?` — Task 5 が使用。置換は常に同長 1 文字(状態文字のみ)

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermCoreTests/EditingAssistantTests.swift` に追加:

```swift
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
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter EditingAssistantTests 2>&1 | tail -5`
Expected: コンパイルエラー(`toggleCheckbox` 未定義)

- [ ] **Step 3: 実装**

`EditingAssistant.swift` の `enum EditingAssistant` 内に追加:

```swift
    /// クリック: offset がタスク項目のチェックボックス "[ ]" / "[x]" の 3 文字上に
    /// あるときだけ状態文字 1 文字を置換するコマンドを返す。
    /// 置換は同長 1 文字なので、UI 層は適用前の選択範囲をそのまま復元できる。
    public static func toggleCheckbox(text: NSString, at offset: Int) -> EditCommand? {
        guard offset >= 0, offset <= text.length else { return nil }
        let lineRange = text.lineRange(for: NSRange(location: offset, length: 0))
        guard let item = ListItemLine.parse(text: text, lineRange: lineRange),
            let boxLocation = item.checkboxLocation,
            offset >= boxLocation, offset < boxLocation + 3 else { return nil }
        let stateLocation = boxLocation + 1
        let state = text.character(at: stateLocation)
        let isChecked = state == unichar(UnicodeScalar("x").value)
            || state == unichar(UnicodeScalar("X").value)
        return EditCommand(
            replacementRange: NSRange(location: stateLocation, length: 1),
            replacementString: isChecked ? " " : "x",
            selectedRange: NSRange(location: stateLocation, length: 1))
    }
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter EditingAssistantTests 2>&1 | tail -5`
Expected: PASS(33 テスト)

- [ ] **Step 5: 全テスト実行**

Run: `swift test 2>&1 | grep "Test run"`
Expected: 全テスト PASS(Core 80 + UI 38)

- [ ] **Step 6: コミット**

```bash
git add Sources/LapermCore Tests/LapermCoreTests
git commit -m "feat(core): add checkbox toggle command for click handling"
```
(末尾に Global Constraints のトレーラーを付ける)

---

### Task 5: UI — EditingOptions と MarkdownTextView 統合

**Files:**
- Create: `Sources/Laperm/EditingOptions.swift`
- Modify: `Sources/Laperm/MarkdownTextView.swift`(`scrollableMarkdownEditor` の後、`NSTextStorageDelegate` extension の前にオーバーライド群を追加)
- Test: `Tests/LapermTests/MarkdownTextViewTests.swift`

**Interfaces:**
- Consumes: `EditingAssistant.newline / indent / outdent / insertion / toggleCheckbox`、`EditCommand`(Task 1〜4)
- Produces:
  - `public struct EditingOptions`(`continuesLists` / `togglesCheckboxOnClick` / `indentsListItems` / `completesPairs`、全デフォルト true)
  - `MarkdownTextView.editingOptions: EditingOptions`(public var)
  - `MarkdownTextView.toggleCheckbox(atPoint:) -> Bool`(internal。テストが使用)

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermTests/MarkdownTextViewTests.swift` の末尾に追加:

```swift
// MARK: - 編集支援

/// NSTextView は window か delegate から undoManager を取るため、テストでは delegate で供給する
@MainActor private final class UndoManagerProvider: NSObject, NSTextViewDelegate {
    let manager = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}

/// characterRange の表示フレーム中心点(textView 座標)を求める
@MainActor
private func midpoint(of characterRange: NSRange, in textView: MarkdownTextView) -> NSPoint {
    let layoutManager = textView.textLayoutManager!
    let contentManager = layoutManager.textContentManager!
    layoutManager.ensureLayout(for: layoutManager.documentRange)
    let start = contentManager.location(
        contentManager.documentRange.location, offsetBy: characterRange.location)!
    let end = contentManager.location(start, offsetBy: characterRange.length)!
    let textRange = NSTextRange(location: start, end: end)!
    var frame = CGRect.zero
    layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) {
        _, segmentFrame, _, _ in
        frame = segmentFrame
        return false
    }
    let origin = textView.textContainerOrigin
    return NSPoint(x: frame.midX + origin.x, y: frame.midY + origin.y)
}

@MainActor @Test func insertNewlineContinuesList() {
    let textView = MarkdownTextView()
    textView.string = "- item"
    textView.setSelectedRange(NSRange(location: 6, length: 0))
    textView.insertNewline(nil)
    #expect(textView.string == "- item\n- ")
    #expect(textView.selectedRange() == NSRange(location: 9, length: 0))
}

@MainActor @Test func insertNewlineRespectsDisabledOption() {
    let textView = MarkdownTextView()
    textView.editingOptions.continuesLists = false
    textView.string = "- item"
    textView.setSelectedRange(NSRange(location: 6, length: 0))
    textView.insertNewline(nil)
    #expect(textView.string == "- item\n")
}

@MainActor @Test func listContinuationUndoesInOneStep() {
    let textView = MarkdownTextView()
    let provider = UndoManagerProvider()
    textView.delegate = provider
    textView.string = "- item"
    textView.setSelectedRange(NSRange(location: 6, length: 0))
    textView.insertNewline(nil)
    #expect(textView.string == "- item\n- ")
    provider.manager.undo()
    #expect(textView.string == "- item")
}

@MainActor @Test func insertTabIndentsListItem() {
    let textView = MarkdownTextView()
    textView.string = "- item"
    textView.setSelectedRange(NSRange(location: 6, length: 0))
    textView.insertTab(nil)
    #expect(textView.string == "    - item")
}

@MainActor @Test func typingBacktickAutoCloses() {
    let textView = MarkdownTextView()
    textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(textView.string == "``")
    #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
}

@MainActor @Test func typingClosingBacktickTypesOver() {
    let textView = MarkdownTextView()
    textView.string = "``"
    textView.setSelectedRange(NSRange(location: 1, length: 0))
    textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(textView.string == "``")
    #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
}

@MainActor @Test func pairCompletionIsSkippedDuringMarkedText() {
    let textView = MarkdownTextView()
    textView.setMarkedText(
        "か", selectedRange: NSRange(location: 0, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
    textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
    // マークテキストが "`" に置換されるだけで自動閉じは走らない
    #expect(textView.string == "`")
}

@MainActor @Test func clickOnCheckboxTogglesState() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "- [ ] task"
    let point = midpoint(of: NSRange(location: 2, length: 3), in: textView)
    #expect(textView.toggleCheckbox(atPoint: point))
    #expect(textView.string == "- [x] task")
}

@MainActor @Test func clickOutsideCheckboxDoesNotToggle() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "- [ ] task"
    let point = midpoint(of: NSRange(location: 7, length: 3), in: textView)
    #expect(!textView.toggleCheckbox(atPoint: point))
    #expect(textView.string == "- [ ] task")
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter MarkdownTextViewTests 2>&1 | tail -5`
Expected: コンパイルエラー(`editingOptions` / `toggleCheckbox(atPoint:)` 未定義)

- [ ] **Step 3: EditingOptions を実装**

`Sources/Laperm/EditingOptions.swift` を新規作成:

```swift
/// 編集支援機能の個別 ON/OFF 設定。デフォルトは全機能有効。
public struct EditingOptions: Equatable, Sendable {
    /// Enter でリスト項目を自動継続する(空項目では脱出)
    public var continuesLists: Bool
    /// チェックボックスのクリックでチェック状態を切り替える
    public var togglesCheckboxOnClick: Bool
    /// Tab / Shift+Tab でリスト項目のネストレベルを上げ下げする
    public var indentsListItems: Bool
    /// 選択範囲の囲い込みと括弧系・バッククォートの自動閉じ
    public var completesPairs: Bool

    public init(
        continuesLists: Bool = true,
        togglesCheckboxOnClick: Bool = true,
        indentsListItems: Bool = true,
        completesPairs: Bool = true
    ) {
        self.continuesLists = continuesLists
        self.togglesCheckboxOnClick = togglesCheckboxOnClick
        self.indentsListItems = indentsListItems
        self.completesPairs = completesPairs
    }
}
```

- [ ] **Step 4: MarkdownTextView に統合を実装**

`Sources/Laperm/MarkdownTextView.swift` に追加。

(a) プロパティ(`showsLineNumbers` の後):

```swift
    /// 編集支援機能の設定(デフォルト全 ON)
    public var editingOptions = EditingOptions()
```

(b) オーバーライド群(`scrollableMarkdownEditor` の後、クラス末尾):

```swift
    // MARK: - 編集支援

    public override func insertNewline(_ sender: Any?) {
        if editingOptions.continuesLists,
            let command = EditingAssistant.newline(
                text: string as NSString, selection: selectedRange()),
            apply(command) {
            return
        }
        super.insertNewline(sender)
    }

    public override func insertTab(_ sender: Any?) {
        if editingOptions.indentsListItems,
            let command = EditingAssistant.indent(
                text: string as NSString, selection: selectedRange()),
            apply(command) {
            return
        }
        super.insertTab(sender)
    }

    public override func insertBacktab(_ sender: Any?) {
        if editingOptions.indentsListItems,
            let command = EditingAssistant.outdent(
                text: string as NSString, selection: selectedRange()),
            apply(command) {
            return
        }
        super.insertBacktab(sender)
    }

    public override func insertText(_ insertString: Any, replacementRange: NSRange) {
        // IME 変換中・属性付き文字列・置換指定付きの挿入(IME 確定等)は対象外
        if editingOptions.completesPairs, !hasMarkedText(),
            replacementRange.location == NSNotFound,
            let typed = insertString as? String,
            let command = EditingAssistant.insertion(
                text: string as NSString, selection: selectedRange(), typing: typed),
            apply(command) {
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    public override func mouseDown(with event: NSEvent) {
        if editingOptions.togglesCheckboxOnClick,
            event.clickCount == 1,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
            toggleCheckbox(atPoint: convert(event.locationInWindow, from: nil)) {
            return
        }
        super.mouseDown(with: event)
    }

    /// point(ビュー座標)のクリックでチェックボックスをトグルする。トグルしたら true。
    /// mouseDown から分離してあるのはテストで座標を直接渡せるようにするため。
    func toggleCheckbox(atPoint point: NSPoint) -> Bool {
        let offset = characterIndexForInsertion(at: point)
        guard let command = EditingAssistant.toggleCheckbox(
            text: string as NSString, at: offset) else { return false }
        // 同長 1 文字の置換なので選択座標はずれない — 適用前の選択を復元する
        let selectionBefore = selectedRanges
        guard apply(command) else { return false }
        selectedRanges = selectionBefore
        return true
    }

    /// EditCommand を undo 対応の経路で適用する。
    /// shouldChangeText / didChangeText を通すことで NSTextView 標準の undo に乗り、
    /// 既存の NSTextStorageDelegate 経由で再ハイライトも自動で走る。
    private func apply(_ command: EditCommand) -> Bool {
        // 純粋なカーソル移動(タイプオーバー)は置換なしで選択だけ動かす
        if command.replacementRange.length == 0, command.replacementString.isEmpty {
            setSelectedRange(command.selectedRange)
            return true
        }
        guard shouldChangeText(
                in: command.replacementRange, replacementString: command.replacementString),
            let textStorage else { return false }
        textStorage.replaceCharacters(
            in: command.replacementRange, with: command.replacementString)
        didChangeText()
        setSelectedRange(command.selectedRange)
        return true
    }
```

- [ ] **Step 5: テストが通ることを確認**

Run: `swift test --filter MarkdownTextViewTests 2>&1 | tail -5`
Expected: PASS(既存 5 + 追加 9)

注: `clickOnCheckboxTogglesState` が座標変換で不安定な場合は、`midpoint` ヘルパーの `textContainerOrigin` 加算が二重・不足になっていないかを最初に疑うこと(`characterIndexForInsertion(at:)` はビュー座標を受け取る)。

- [ ] **Step 6: 全テスト実行**

Run: `swift test 2>&1 | grep "Test run"`
Expected: 全テスト PASS(Core 80 + UI 47)

- [ ] **Step 7: コミット**

```bash
git add Sources/Laperm Tests/LapermTests
git commit -m "feat(ui): wire editing assistance into MarkdownTextView with EditingOptions"
```
(末尾に Global Constraints のトレーラーを付ける)

---

### Task 6: Example 更新と最終検証

**Files:**
- Modify: `Example/ExampleMacOS/ContentView.swift`(`sampleDocument`)

**Interfaces:**
- Consumes: Task 1〜5 の全機能
- Produces: なし(目視確認用)

- [ ] **Step 1: サンプル文書に編集支援セクションを追加**

`ContentView.swift` の `sampleDocument` 内、`| \`インラインコード\` | あり |` の行と `日本語も絵文字 🎉 も正しくハイライトされます。` の行の間に挿入:

```swift
    ## 編集支援

    - リスト行末で Enter → 次項目を自動継続(空項目で Enter すると脱出)
    - [ ] このチェックボックスはクリックでトグルできます
    - Tab / Shift+Tab でネスト変更、テキストを選択して `*` などを入力すると囲い込み

```

- [ ] **Step 2: パッケージ全テスト + Example ビルド**

Run: `swift test 2>&1 | grep "Test run"`
Expected: 全テスト PASS(Core 80 + UI 47)

Run: `xcodebuild -project Example/Example.xcodeproj -scheme ExampleMacOS build 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`(スキーム名が違う場合は `xcodebuild -project Example/Example.xcodeproj -list` で確認する)

- [ ] **Step 3: 目視確認(実行者が可能な場合)**

ExampleMacOS を起動し、以下を確認する:
- リスト行末で Enter → マーカーが自動挿入される。空項目で Enter → マーカーが消える
- チェックボックスのクリックでトグルされ、チェック済み本文が淡色になる(既存 GFM ハイライトとの連動)
- Tab / Shift+Tab でリスト項目のインデントが変わる
- 選択して `*` で囲い込み、`` ` `` で自動閉じ、日本語 IME 変換が乱れないこと
- Cmd+Z で各操作が 1 ステップで戻ること

- [ ] **Step 4: コミット**

```bash
git add Example/ExampleMacOS/ContentView.swift
git commit -m "feat(example): showcase editing assistance in sample document"
```
(末尾に Global Constraints のトレーラーを付ける)
