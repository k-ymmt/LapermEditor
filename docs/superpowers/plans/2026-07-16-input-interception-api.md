# 入力インターセプト API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ライブラリ利用者が Vim モードのようなモーダル編集を外側から実装できる、汎用の入力インターセプト API(キー横取り・カーソル形状・テキスト操作ヘルパー・SwiftUI 対応)を追加する。

**Architecture:** 既存の 2 層構造を踏襲する。純粋な値型・計算(`KeyInput` / `TextMotions`)は `LapermCore`、AppKit 依存(`keyDown` 横取り・カーソルオーバーレイ・`perform`)は `Laperm` の `MarkdownTextView`。検証用の簡易 Vim デモを Example アプリに追加する。

**Tech Stack:** Swift 6(`ApproachableConcurrency`)、TextKit 2、Swift Testing(`@Test` / `#expect`)、SwiftUI(`NSViewRepresentable`)

**Spec:** `docs/superpowers/specs/2026-07-16-input-interception-design.md`

## Global Constraints

- プラットフォームは macOS 27+ / Swift 6(`swiftLanguageModes: [.v6]`)。ビュー層のコードは `@MainActor`
- **`MarkdownTextView` とその利用側は `layoutManager` プロパティに絶対にアクセスしない**(TextKit1 フォールバックで全壊する)。`textLayoutManager` を使う
- テストは常に全体実行: `swift test`(`--filter` はこの環境で効かない。全体でも ~0.5s)
- コミットは main に直接行う(ブランチは切らない)
- コミットメッセージ末尾は以下の形式:
  ```
  Task context: 入力インターセプト API(Vim モード実装可能化) (docs/superpowers/specs/2026-07-16-input-interception-design.md)

  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01KKBTtzv3UxhX8vTPruvGJc
  ```
- コード内コメントは既存スタイルに合わせて日本語
- Example アプリのビルド確認: `xcodebuild -project Example/Example.xcodeproj -scheme ExampleMacOS build`(プロジェクトは file system synchronized groups を使うため、ファイルをディレクトリに置くだけで登録される)

---

### Task 1: KeyInput 値型と NSEvent 変換

**Files:**
- Create: `Sources/LapermCore/KeyInput.swift`
- Create: `Sources/Laperm/KeyInput+NSEvent.swift`
- Create: `Tests/LapermTests/TestSupport.swift`(テスト共用ヘルパー。後続タスクも共有物をここに追加する)
- Test: `Tests/LapermTests/KeyInputConversionTests.swift`

**Interfaces:**
- Consumes: なし
- Produces:
  - `LapermCore` に `public struct KeyInput: Equatable, Sendable`(`key: Key`, `modifiers: Modifiers`、`init(key:modifiers:)`)。`Key` は `case character(Character), escape, return, tab, backspace, forwardDelete, up, down, left, right, pageUp, pageDown, home, end`。`Modifiers` は `OptionSet`(`.shift .control .option .command`)
  - `LapermCore` に `public enum KeyInputResult: Equatable, Sendable { case handled, passthrough }`
  - `Laperm` に `extension KeyInput { init?(event: NSEvent) }`(internal)

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermTests/TestSupport.swift`(テスト共用ヘルパー。private にしないこと — 後続タスクのテストも使う):

```swift
import AppKit

/// keyDown 系イベントを合成する(テスト共用。context は現行 SDK で nil 固定)
@MainActor
func keyEvent(
    _ characters: String, ignoringModifiers: String? = nil,
    modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0,
    type: NSEvent.EventType = .keyDown
) -> NSEvent {
    NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: 0, context: nil, characters: characters,
        charactersIgnoringModifiers: ignoringModifiers ?? characters,
        isARepeat: false, keyCode: keyCode)!
}
```

`Tests/LapermTests/KeyInputConversionTests.swift`:

```swift
import AppKit
import Testing
@testable import Laperm
@testable import LapermCore

@MainActor @Test func convertsPlainCharacter() {
    let input = KeyInput(event: keyEvent("a"))
    #expect(input == KeyInput(key: .character("a")))
}

@MainActor @Test func convertsShiftedCharacterWithModifier() {
    let input = KeyInput(event: keyEvent("A", ignoringModifiers: "A", modifiers: .shift))
    #expect(input == KeyInput(key: .character("A"), modifiers: .shift))
}

@MainActor @Test func convertsControlCharacterFromIgnoringModifiers() {
    // Ctrl+A: characters は制御文字だが charactersIgnoringModifiers は "a"
    let input = KeyInput(event: keyEvent("\u{01}", ignoringModifiers: "a", modifiers: .control))
    #expect(input == KeyInput(key: .character("a"), modifiers: .control))
}

@MainActor @Test func convertsEscape() {
    let input = KeyInput(event: keyEvent("\u{1B}", keyCode: 53))
    #expect(input == KeyInput(key: .escape))
}

@MainActor @Test func convertsArrowKeys() {
    #expect(KeyInput(event: keyEvent("\u{F700}", keyCode: 126)) == KeyInput(key: .up))
    #expect(KeyInput(event: keyEvent("\u{F701}", keyCode: 125)) == KeyInput(key: .down))
    #expect(KeyInput(event: keyEvent("\u{F702}", keyCode: 123)) == KeyInput(key: .left))
    #expect(KeyInput(event: keyEvent("\u{F703}", keyCode: 124)) == KeyInput(key: .right))
}

@MainActor @Test func convertsBackTabToShiftTab() {
    // Shift+Tab は charactersIgnoringModifiers が back-tab 文字(0x19)になる
    let input = KeyInput(event: keyEvent("\u{19}", modifiers: .shift, keyCode: 48))
    #expect(input == KeyInput(key: .tab, modifiers: .shift))
}

@MainActor @Test func convertsReturnBackspaceForwardDelete() {
    #expect(KeyInput(event: keyEvent("\r", keyCode: 36)) == KeyInput(key: .return))
    #expect(KeyInput(event: keyEvent("\u{7F}", keyCode: 51)) == KeyInput(key: .backspace))
    #expect(KeyInput(event: keyEvent("\u{F728}", keyCode: 117)) == KeyInput(key: .forwardDelete))
}

@MainActor @Test func rejectsKeyUpAndFunctionKeys() {
    #expect(KeyInput(event: keyEvent("a", type: .keyUp)) == nil)
    // F1(0xF704)は対象外
    #expect(KeyInput(event: keyEvent("\u{F704}", keyCode: 122)) == nil)
}
```

- [ ] **Step 2: テストが失敗する(コンパイルエラーになる)ことを確認**

Run: `swift test`
Expected: FAIL — `cannot find 'KeyInput' in scope` などのコンパイルエラー

- [ ] **Step 3: KeyInput 値型を実装**

`Sources/LapermCore/KeyInput.swift`:

```swift
import Foundation

/// AppKit 非依存のキー入力表現。
/// character は Shift 適用済み("A" は character("A") + shift)。
public struct KeyInput: Equatable, Sendable {
    public enum Key: Equatable, Sendable {
        case character(Character)
        case escape
        case `return`
        case tab
        case backspace
        case forwardDelete
        case up, down, left, right
        case pageUp, pageDown, home, end
    }

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public let key: Key
    public let modifiers: Modifiers

    public init(key: Key, modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// インターセプタの応答。
public enum KeyInputResult: Equatable, Sendable {
    /// イベントを消費する。テキストビューには渡さない
    case handled
    /// 通常の処理(IME・挿入・キーバインディング)へ流す
    case passthrough
}
```

- [ ] **Step 4: NSEvent → KeyInput 変換を実装**

`Sources/Laperm/KeyInput+NSEvent.swift`:

```swift
import AppKit
import LapermCore

extension KeyInput {
    /// keyDown イベントから生成する。表現できないイベント(keyDown 以外、
    /// ファンクションキー等)は nil を返し、呼び出し側はデフォルト処理に流す。
    init?(event: NSEvent) {
        guard event.type == .keyDown,
            let chars = event.charactersIgnoringModifiers,
            let scalar = chars.unicodeScalars.first
        else { return nil }
        var modifiers = Modifiers()
        let flags = event.modifierFlags
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }

        let key: Key
        switch scalar.value {
        case 0x1B: key = .escape
        case 0x0D, 0x03: key = .return  // Return / テンキー Enter
        case 0x09: key = .tab
        case 0x19:  // Shift+Tab は back-tab 文字になる
            key = .tab
            modifiers.insert(.shift)
        case 0x7F: key = .backspace
        case 0xF728: key = .forwardDelete
        case 0xF700: key = .up
        case 0xF701: key = .down
        case 0xF702: key = .left
        case 0xF703: key = .right
        case 0xF72C: key = .pageUp
        case 0xF72D: key = .pageDown
        case 0xF729: key = .home
        case 0xF72B: key = .end
        case 0xF704...0xF7FF: return nil  // その他のファンクションキーは対象外
        default:
            // 印字可能文字。Ctrl 押下時も charactersIgnoringModifiers は元の文字を返す
            guard chars.count == 1 else { return nil }
            key = .character(Character(chars))
        }
        self.init(key: key, modifiers: modifiers)
    }
}
```

- [ ] **Step 5: テストが通ることを確認**

Run: `swift test`
Expected: PASS(全テスト)

- [ ] **Step 6: コミット**

```bash
git add Sources/LapermCore/KeyInput.swift Sources/Laperm/KeyInput+NSEvent.swift Tests/LapermTests/TestSupport.swift Tests/LapermTests/KeyInputConversionTests.swift
git commit -m "feat(core): add KeyInput value type with NSEvent conversion"
```

(Global Constraints のコミットメッセージ末尾形式を付けること。以降のコミットも同様)

---

### Task 2: keyDown インターセプト(TextInputInterceptor)

**Files:**
- Create: `Sources/Laperm/TextInputInterceptor.swift`
- Modify: `Sources/Laperm/MarkdownTextView.swift`(プロパティ追加 + `keyDown` オーバーライド)
- Test: `Tests/LapermTests/InputInterceptionTests.swift`

**Interfaces:**
- Consumes: Task 1 の `KeyInput`, `KeyInputResult`, `KeyInput.init?(event:)`
- Produces:
  - `public protocol TextInputInterceptor: AnyObject`(`@MainActor`)— `func textView(_ textView: MarkdownTextView, handle input: KeyInput) -> KeyInputResult`
  - `MarkdownTextView.inputInterceptor: (any TextInputInterceptor)?`(public, weak)
  - `MarkdownTextView.interceptsKeyDown(_ event: NSEvent) -> Bool`(internal、テスト用の継ぎ目)

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermTests/InputInterceptionTests.swift`:

```swift
import AppKit
import Testing
@testable import Laperm
@testable import LapermCore

@MainActor
private final class RecordingInterceptor: TextInputInterceptor {
    var received: [KeyInput] = []
    var result: KeyInputResult = .passthrough
    func textView(_ textView: MarkdownTextView, handle input: KeyInput) -> KeyInputResult {
        received.append(input)
        return result
    }
}

@MainActor @Test func handledResultConsumesKeyDown() {
    let textView = MarkdownTextView()
    let interceptor = RecordingInterceptor()
    interceptor.result = .handled
    textView.inputInterceptor = interceptor
    textView.keyDown(with: keyEvent("a"))
    #expect(textView.string == "")  // 挿入されない
    #expect(interceptor.received == [KeyInput(key: .character("a"))])
}

@MainActor @Test func passthroughDoesNotIntercept() {
    let textView = MarkdownTextView()
    let interceptor = RecordingInterceptor()
    interceptor.result = .passthrough
    textView.inputInterceptor = interceptor
    #expect(!textView.interceptsKeyDown(keyEvent("a")))
    #expect(interceptor.received.count == 1)  // 呼ばれた上で通過
}

@MainActor @Test func noInterceptorMeansNoInterception() {
    let textView = MarkdownTextView()
    #expect(!textView.interceptsKeyDown(keyEvent("a")))
}

@MainActor @Test func markedTextBypassesInterceptor() {
    let textView = MarkdownTextView()
    let interceptor = RecordingInterceptor()
    interceptor.result = .handled
    textView.inputInterceptor = interceptor
    textView.setMarkedText(
        "か", selectedRange: NSRange(location: 0, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(!textView.interceptsKeyDown(keyEvent("a")))
    #expect(interceptor.received.isEmpty)  // IME 変換中は呼ばれない
}

@MainActor @Test func interceptorIsHeldWeakly() {
    let textView = MarkdownTextView()
    var interceptor: RecordingInterceptor? = RecordingInterceptor()
    textView.inputInterceptor = interceptor
    interceptor = nil
    #expect(textView.inputInterceptor == nil)
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: FAIL — `cannot find type 'TextInputInterceptor' in scope`

- [ ] **Step 3: プロトコルとインターセプト経路を実装**

`Sources/Laperm/TextInputInterceptor.swift`:

```swift
import AppKit
import LapermCore

/// キー入力をテキストビューの処理前に横取りするインターセプタ。
/// handled を返すとイベントは消費され、テキスト挿入・編集支援・
/// キーバインディング処理のいずれにも到達しない。
/// MarkdownTextView は weak 保持するため、利用側がインターセプタの所有権を持つこと。
@MainActor
public protocol TextInputInterceptor: AnyObject {
    func textView(_ textView: MarkdownTextView, handle input: KeyInput) -> KeyInputResult
}
```

`Sources/Laperm/MarkdownTextView.swift` — `editingOptions` プロパティの直後に追加:

```swift
    /// キー入力のインターセプタ(weak 保持)。Vim モード等のモーダル編集の実装点。
    /// IME 変換中(marked text)は変換セッションを優先し、呼ばれない。
    public weak var inputInterceptor: (any TextInputInterceptor)?
```

`// MARK: - 編集支援` セクションの直前に追加:

```swift
    // MARK: - 入力インターセプト

    public override func keyDown(with event: NSEvent) {
        if interceptsKeyDown(event) { return }
        super.keyDown(with: event)
    }

    /// keyDown をインターセプタが消費すべきなら true。
    /// mouseDown / toggleCheckbox と同様、テストから直接呼べるよう分離してある。
    func interceptsKeyDown(_ event: NSEvent) -> Bool {
        guard let interceptor = inputInterceptor,
            !hasMarkedText(),
            let input = KeyInput(event: event)
        else { return false }
        return interceptor.textView(self, handle: input) == .handled
    }
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: PASS(全テスト)

- [ ] **Step 5: コミット**

```bash
git add Sources/Laperm/TextInputInterceptor.swift Sources/Laperm/MarkdownTextView.swift Tests/LapermTests/InputInterceptionTests.swift
git commit -m "feat: add TextInputInterceptor hook to MarkdownTextView"
```

---

### Task 3: perform(EditCommand) の公開

**Files:**
- Modify: `Sources/Laperm/MarkdownTextView.swift`(private `apply(_:)` を public `perform(_:)` に改名・検証追加。既存呼び出し 6 箇所も改名)
- Modify: `Tests/LapermTests/TestSupport.swift`(`UndoManagerProvider` を移設)
- Modify: `Tests/LapermTests/MarkdownTextViewTests.swift`(private `UndoManagerProvider` を削除して共有版を使う)
- Test: `Tests/LapermTests/PerformCommandTests.swift`

**Interfaces:**
- Consumes: `LapermCore.EditCommand`(既存: `replacementRange: NSRange`, `replacementString: String`, `selectedRange: NSRange`)
- Produces: `MarkdownTextView.perform(_ command: EditCommand) -> Bool`(public, `@discardableResult`)

- [ ] **Step 1: 失敗するテストを書く**

まず `Tests/LapermTests/MarkdownTextViewTests.swift` の private `UndoManagerProvider`(`/// NSTextView は window か delegate から...` のコメントごと)を `Tests/LapermTests/TestSupport.swift` へ移設し、`private` を外して internal にする(利用側の `MarkdownTextViewTests.swift` はクラス名そのままで共有版を参照する)。

`Tests/LapermTests/PerformCommandTests.swift`:

```swift
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
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: FAIL — `'perform' is inaccessible`(または未定義)エラー

- [ ] **Step 3: apply を perform に改名して公開・検証を追加**

`Sources/Laperm/MarkdownTextView.swift` の既存 `private func apply(_ command: EditCommand) -> Bool` を以下に置き換える:

```swift
    /// EditCommand を undo 対応の経路で適用する。
    /// shouldChangeText / didChangeText を通すことで NSTextView 標準の undo に乗り、
    /// 既存の NSTextStorageDelegate 経由で再ハイライトも自動で走る。
    /// 範囲が文書外のコマンドは適用せず false を返す。
    @discardableResult
    public func perform(_ command: EditCommand) -> Bool {
        let length = (string as NSString).length
        guard command.replacementRange.location != NSNotFound,
            NSMaxRange(command.replacementRange) <= length
        else { return false }
        // 適用後の文書長で selectedRange を検証(範囲外だと NSTextView が例外を投げる)
        let newLength = length - command.replacementRange.length
            + (command.replacementString as NSString).length
        guard command.selectedRange.location != NSNotFound,
            NSMaxRange(command.selectedRange) <= newLength
        else { return false }
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

同ファイル内の `apply(command)` 呼び出し(`insertNewline` / `insertTab` / `insertBacktab` / `insertText` / `deleteBackward` / `toggleCheckbox` の 6 箇所)をすべて `perform(command)` に改名する。

- [ ] **Step 4: テストが通ることを確認(既存テスト含む)**

Run: `swift test`
Expected: PASS(全テスト。既存の編集支援テストも改名の影響を受けず通ること)

- [ ] **Step 5: コミット**

```bash
git add Sources/Laperm/MarkdownTextView.swift Tests/LapermTests/TestSupport.swift Tests/LapermTests/MarkdownTextViewTests.swift Tests/LapermTests/PerformCommandTests.swift
git commit -m "feat: expose undo-aware perform(EditCommand) on MarkdownTextView"
```

---

### Task 4: TextMotions(カーソル移動の純粋関数)

**Files:**
- Create: `Sources/LapermCore/TextMotions.swift`
- Test: `Tests/LapermCoreTests/TextMotionsTests.swift`

**Interfaces:**
- Consumes: なし(Foundation のみ)
- Produces: `public enum TextMotions` の static 関数群(すべて UTF-16 オフセット):
  - `lineStart(text: NSString, at: Int) -> Int`
  - `lineEnd(text: NSString, at: Int) -> Int`(改行文字の手前)
  - `lineUp(text: NSString, at: Int, preferredColumn: Int) -> Int`
  - `lineDown(text: NSString, at: Int, preferredColumn: Int) -> Int`
  - `wordForward(text: NSString, at: Int) -> Int`
  - `wordBackward(text: NSString, at: Int) -> Int`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermCoreTests/TextMotionsTests.swift`:

```swift
import Foundation
import Testing
@testable import LapermCore

// テキスト: "hello\nhi\nworld"
//            0-4  5  6-7 8  9-13
private let sample = "hello\nhi\nworld" as NSString

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
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: FAIL — `cannot find 'TextMotions' in scope`

- [ ] **Step 3: TextMotions を実装**

`Sources/LapermCore/TextMotions.swift`:

```swift
import Foundation

/// カーソル移動計算の純粋関数群。offset と戻り値はすべて UTF-16 単位。
/// 戻り値は常に合成文字境界(サロゲートペア・結合文字の途中に落ちない)。
/// Vim ライクなモーダル編集の部品として使える汎用計算で、パーサーには依存しない。
public enum TextMotions {
    /// offset を含む行の行頭
    public static func lineStart(text: NSString, at offset: Int) -> Int {
        var start = 0
        text.getLineStart(
            &start, end: nil, contentsEnd: nil,
            for: NSRange(location: clamp(offset, to: text), length: 0))
        return start
    }

    /// offset を含む行の行末(改行文字の手前)
    public static func lineEnd(text: NSString, at offset: Int) -> Int {
        var contentsEnd = 0
        text.getLineStart(
            nil, end: nil, contentsEnd: &contentsEnd,
            for: NSRange(location: clamp(offset, to: text), length: 0))
        return contentsEnd
    }

    /// 1 行上の preferredColumn 列へ(行が短ければ行末)。先頭行なら現在位置のまま
    public static func lineUp(text: NSString, at offset: Int, preferredColumn: Int) -> Int {
        let start = lineStart(text: text, at: offset)
        guard start > 0 else { return clamp(offset, to: text) }
        return position(inLineContaining: start - 1, column: preferredColumn, text: text)
    }

    /// 1 行下の preferredColumn 列へ(行が短ければ行末)。最終行なら現在位置のまま
    public static func lineDown(text: NSString, at offset: Int, preferredColumn: Int) -> Int {
        var end = 0
        var contentsEnd = 0
        text.getLineStart(
            nil, end: &end, contentsEnd: &contentsEnd,
            for: NSRange(location: clamp(offset, to: text), length: 0))
        guard end > contentsEnd else { return clamp(offset, to: text) }  // 次の行がない
        return position(inLineContaining: end, column: preferredColumn, text: text)
    }

    /// 次の単語頭へ(Vim の w 相当)。文書末ならその場に留まる
    public static func wordForward(text: NSString, at offset: Int) -> Int {
        var i = clamp(offset, to: text)
        guard i < text.length else { return i }
        let startClass = characterClass(text, at: i)
        if startClass != .whitespace {
            while i < text.length, characterClass(text, at: i) == startClass {
                i = NSMaxRange(text.rangeOfComposedCharacterSequence(at: i))
            }
        }
        while i < text.length, characterClass(text, at: i) == .whitespace {
            i = NSMaxRange(text.rangeOfComposedCharacterSequence(at: i))
        }
        return i
    }

    /// 前の単語頭へ(Vim の b 相当)。文書頭ならその場に留まる
    public static func wordBackward(text: NSString, at offset: Int) -> Int {
        var i = clamp(offset, to: text)
        guard i > 0 else { return i }
        i = text.rangeOfComposedCharacterSequence(at: i - 1).location
        while i > 0, characterClass(text, at: i) == .whitespace {
            i = text.rangeOfComposedCharacterSequence(at: i - 1).location
        }
        guard characterClass(text, at: i) != .whitespace else { return i }  // 文書頭まで空白
        let cls = characterClass(text, at: i)
        while i > 0 {
            let prev = text.rangeOfComposedCharacterSequence(at: i - 1).location
            guard characterClass(text, at: prev) == cls else { break }
            i = prev
        }
        return i
    }

    // MARK: - 内部

    private enum CharacterClass { case whitespace, word, symbol }

    /// 単語構成文字は英数字(Unicode 全般。CJK を含む)+ アンダースコア。
    /// それ以外の非空白は記号クラス。改行は空白クラス
    private static func characterClass(_ text: NSString, at offset: Int) -> CharacterClass {
        let range = text.rangeOfComposedCharacterSequence(at: offset)
        guard let scalar = text.substring(with: range).unicodeScalars.first else {
            return .symbol
        }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return .whitespace }
        if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" { return .word }
        return .symbol
    }

    /// lineOffset を含む行の column 列(UTF-16)。行末にクランプし、合成文字境界に丸める
    private static func position(
        inLineContaining lineOffset: Int, column: Int, text: NSString
    ) -> Int {
        var start = 0
        var contentsEnd = 0
        text.getLineStart(
            &start, end: nil, contentsEnd: &contentsEnd,
            for: NSRange(location: lineOffset, length: 0))
        let target = min(start + max(column, 0), contentsEnd)
        guard target < text.length, target > start else { return target }
        return text.rangeOfComposedCharacterSequence(at: target).location
    }

    private static func clamp(_ offset: Int, to text: NSString) -> Int {
        min(max(offset, 0), text.length)
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: PASS(全テスト)

- [ ] **Step 5: コミット**

```bash
git add Sources/LapermCore/TextMotions.swift Tests/LapermCoreTests/TextMotionsTests.swift
git commit -m "feat(core): add TextMotions pure cursor-motion helpers"
```

---

### Task 5: InsertionPointStyle とカーソルオーバーレイ

**Files:**
- Create: `Sources/Laperm/InsertionPointStyle.swift`
- Create: `Sources/Laperm/InsertionPointOverlayView.swift`
- Modify: `Sources/Laperm/MarkdownTextView.swift`(プロパティ・オーバーレイ更新・オーバーライド追加)
- Modify: `Tests/LapermTests/TestSupport.swift`(`midpoint(of:in:)` を移設)
- Modify: `Tests/LapermTests/MarkdownTextViewTests.swift`(private `midpoint` を削除して共有版を使う)
- Test: `Tests/LapermTests/InsertionPointStyleTests.swift`

**Interfaces:**
- Consumes: Task 4 の `TextMotions.lineEnd(text:at:)`
- Produces:
  - `public enum InsertionPointStyle: Equatable, Sendable { case bar, block, underline }`
  - `MarkdownTextView.insertionPointStyle: InsertionPointStyle`(public、デフォルト `.bar`)
  - `InsertionPointOverlayView`(internal、テストが subviews から検出する)

**既知の制約(スペック承認済みの簡略化):** オーバーレイはフォーカス(first responder)状態を見ない。非フォーカス時もブロックカーソルが表示されるが、v1 の許容範囲とする。

- [ ] **Step 1: 失敗するテストを書く**

まず `Tests/LapermTests/MarkdownTextViewTests.swift` の private `midpoint(of:in:)`(`/// characterRange の表示フレーム中心点...` のコメントごと)を `Tests/LapermTests/TestSupport.swift` へ移設し、`private` を外して internal にする(`TestSupport.swift` に `@testable import Laperm` の追加が必要になる)。

`Tests/LapermTests/InsertionPointStyleTests.swift`:

```swift
import AppKit
import Testing
@testable import Laperm
@testable import LapermCore

@MainActor
private func overlay(in textView: MarkdownTextView) -> InsertionPointOverlayView? {
    textView.subviews.compactMap { $0 as? InsertionPointOverlayView }.first
}

@MainActor @Test func defaultStyleHasNoOverlay() {
    let textView = MarkdownTextView()
    textView.string = "abc"
    #expect(textView.insertionPointStyle == .bar)
    #expect(overlay(in: textView) == nil)
}

@MainActor @Test func blockStyleShowsOverlayCoveringCharacter() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "abc"
    textView.setSelectedRange(NSRange(location: 1, length: 0))
    textView.insertionPointStyle = .block
    let view = overlay(in: textView)
    #expect(view != nil)
    // "b" のグリフ中心を覆っている
    let mid = midpoint(of: NSRange(location: 1, length: 1), in: textView)
    #expect(view?.frame.contains(mid) == true)
}

@MainActor @Test func overlayFollowsSelectionChanges() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "abcdef"
    textView.insertionPointStyle = .block
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    let xAtStart = overlay(in: textView)!.frame.minX
    textView.setSelectedRange(NSRange(location: 4, length: 0))
    #expect(overlay(in: textView)!.frame.minX > xAtStart)
}

@MainActor @Test func overlayHasWidthAtLineEndAndEmptyDocument() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "ab"
    textView.setSelectedRange(NSRange(location: 2, length: 0))  // 行末
    textView.insertionPointStyle = .block
    #expect((overlay(in: textView)?.frame.width ?? 0) > 0)

    textView.string = ""
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    #expect((overlay(in: textView)?.frame.width ?? 0) > 0)
}

@MainActor @Test func underlineStyleAlsoShowsOverlay() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "abc"
    textView.setSelectedRange(NSRange(location: 1, length: 0))
    textView.insertionPointStyle = .underline
    let view = overlay(in: textView)
    #expect(view != nil)
    #expect(view?.style == .underline)
}

@MainActor @Test func selectionHidesOverlay() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "abc"
    textView.insertionPointStyle = .block
    textView.setSelectedRange(NSRange(location: 0, length: 2))
    #expect(overlay(in: textView) == nil)
}

@MainActor @Test func revertingToBarRemovesOverlayAndRestoresColor() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "abc"
    let originalColor = textView.insertionPointColor
    textView.insertionPointStyle = .block
    #expect(textView.insertionPointColor == .clear)  // システムのバーを消す
    textView.insertionPointStyle = .bar
    #expect(overlay(in: textView) == nil)
    #expect(textView.insertionPointColor == originalColor)
}

@MainActor @Test func editingKeepsOverlayOnCaret() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "ab"
    textView.insertionPointStyle = .block
    textView.setSelectedRange(NSRange(location: 2, length: 0))
    textView.insertText("c", replacementRange: NSRange(location: NSNotFound, length: 0))
    let view = overlay(in: textView)
    #expect(view != nil)
    let mid = midpoint(of: NSRange(location: 2, length: 1), in: textView)
    // 挿入後のカーソル(offset 3 = "c" の後ろ)より左にある "c" は覆わない —
    // オーバーレイは行末キャレット位置("c" の右)にある
    #expect((view?.frame.minX ?? 0) >= mid.x)
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: FAIL — `cannot find 'InsertionPointOverlayView' in scope` 等

- [ ] **Step 3: スタイル型とオーバーレイビューを実装**

`Sources/Laperm/InsertionPointStyle.swift`:

```swift
/// カーソル(挿入ポイント)の形状。
public enum InsertionPointStyle: Equatable, Sendable {
    /// 標準の縦棒
    case bar
    /// 文字を覆う半透明の矩形(Vim normal モード等)
    case block
    /// 文字下のアンダーライン(Vim replace モード等)
    case underline
}
```

`Sources/Laperm/InsertionPointOverlayView.swift`:

```swift
import AppKit

/// bar 以外のカーソル形状を描く軽量オーバーレイ。ヒットテスト対象外。
final class InsertionPointOverlayView: NSView {
    var style: InsertionPointStyle = .bar { didSet { needsDisplay = true } }
    var color: NSColor = .textInsertionPointColor { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .bar:
            break
        case .block:
            // 半透明にして下の文字が読めるようにする
            color.withAlphaComponent(0.4).setFill()
            bounds.fill()
        case .underline:
            color.setFill()
            NSRect(x: 0, y: bounds.maxY - 2, width: bounds.width, height: 2).fill()
        }
    }
}
```

- [ ] **Step 4: MarkdownTextView にスタイルプロパティと更新経路を実装**

`Sources/Laperm/MarkdownTextView.swift` — プロパティ群(`inputInterceptor` の後ろ)に追加:

```swift
    /// カーソル形状。bar 以外ではシステムの挿入ポイントを消してオーバーレイで描く。
    /// 注意: 現状オーバーレイはフォーカス状態を見ない(非フォーカスでも表示される)
    public var insertionPointStyle: InsertionPointStyle = .bar {
        didSet {
            guard insertionPointStyle != oldValue else { return }
            // システムのインジケータ(NSTextInsertionIndicator)はサブビュー構成に
            // 依存しないよう色で消し、bar に戻すとき元色を復元する
            if insertionPointStyle == .bar {
                if let color = barInsertionPointColor { insertionPointColor = color }
                barInsertionPointColor = nil
            } else if barInsertionPointColor == nil {
                barInsertionPointColor = insertionPointColor
                insertionPointColor = .clear
            }
            updateInsertionPointOverlay()
        }
    }
    private var barInsertionPointColor: NSColor?
    private let insertionPointOverlay = InsertionPointOverlayView()
```

`// MARK: - 入力インターセプト` セクションの後ろに追加:

```swift
    // MARK: - カーソル形状

    public override func setSelectedRanges(
        _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateInsertionPointOverlay()
    }

    public override func didChangeText() {
        super.didChangeText()
        updateInsertionPointOverlay()
    }

    public override func layout() {
        super.layout()
        updateInsertionPointOverlay()
    }

    private func updateInsertionPointOverlay() {
        guard insertionPointStyle != .bar,
            selectedRange().length == 0,
            let frame = caretOverlayFrame()
        else {
            insertionPointOverlay.removeFromSuperview()
            return
        }
        if insertionPointOverlay.superview !== self {
            addSubview(insertionPointOverlay)
        }
        insertionPointOverlay.style = insertionPointStyle
        insertionPointOverlay.color = barInsertionPointColor ?? .textInsertionPointColor
        insertionPointOverlay.frame = frame
        insertionPointOverlay.needsDisplay = true
    }

    /// カーソル位置の文字を覆う矩形(textView 座標)。行末・空行では等幅 1 文字ぶんの幅。
    private func caretOverlayFrame() -> NSRect? {
        guard let layoutManager = textLayoutManager,
            let contentManager = layoutManager.textContentManager
        else { return nil }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let text = string as NSString
        let caret = selectedRange().location
        guard caret != NSNotFound, caret <= text.length else { return nil }
        var characterRange = NSRange(location: caret, length: 0)
        if caret < TextMotions.lineEnd(text: text, at: caret) {
            characterRange = text.rangeOfComposedCharacterSequence(at: caret)
        }
        guard let start = contentManager.location(
                contentManager.documentRange.location, offsetBy: characterRange.location),
            let end = contentManager.location(start, offsetBy: characterRange.length),
            let textRange = NSTextRange(location: start, end: end)
        else { return nil }
        var segmentFrame = CGRect.null
        layoutManager.enumerateTextSegments(
            in: textRange, type: .standard, options: [.rangeNotRequired]
        ) { _, frame, _, _ in
            segmentFrame = frame
            return false
        }
        guard !segmentFrame.isNull else { return nil }
        var frame = segmentFrame
        if frame.width < 1 {
            // キャレットのみ(行末・空行)は等幅 1 文字ぶんの幅を与える
            frame.size.width = ("M" as NSString)
                .size(withAttributes: [.font: theme.bodyFont]).width
        }
        let origin = textContainerOrigin
        return NSRect(
            x: frame.minX + origin.x, y: frame.minY + origin.y,
            width: frame.width, height: frame.height)
    }
```

さらに、プログラムでの文字列差し替え(`string` 代入 → `highlightAll()`)にも追従させるため、既存の `highlightAll()` と `highlightNow()` の末尾(`updateBlockDecorations()` の直後)に 1 行ずつ追加する:

```swift
        updateInsertionPointOverlay()
```

- [ ] **Step 5: テストが通ることを確認**

Run: `swift test`
Expected: PASS(全テスト)

- [ ] **Step 6: コミット**

```bash
git add Sources/Laperm/InsertionPointStyle.swift Sources/Laperm/InsertionPointOverlayView.swift Sources/Laperm/MarkdownTextView.swift Tests/LapermTests/TestSupport.swift Tests/LapermTests/MarkdownTextViewTests.swift Tests/LapermTests/InsertionPointStyleTests.swift
git commit -m "feat: add insertionPointStyle (bar/block/underline) with overlay rendering"
```

---

### Task 6: SwiftUI モディファイア

**Files:**
- Modify: `Sources/Laperm/MarkdownEditorView.swift`
- Test: `Tests/LapermTests/MarkdownEditorViewTests.swift`(追記)

**Interfaces:**
- Consumes: Task 2 の `TextInputInterceptor` / `MarkdownTextView.inputInterceptor`、Task 5 の `InsertionPointStyle` / `MarkdownTextView.insertionPointStyle`
- Produces:
  - `MarkdownEditorView.inputInterceptor(_ interceptor: (any TextInputInterceptor)?) -> MarkdownEditorView`
  - `MarkdownEditorView.insertionPointStyle(_ style: InsertionPointStyle) -> MarkdownEditorView`
  - `MarkdownEditorView.apply(to textView: MarkdownTextView)`(internal、make/update 共通の反映処理でテストの継ぎ目)

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermTests/MarkdownEditorViewTests.swift` の末尾に追記:

```swift
@MainActor private final class NullInterceptor: TextInputInterceptor {
    func textView(_ textView: MarkdownTextView, handle input: LapermCore.KeyInput)
        -> LapermCore.KeyInputResult
    { .passthrough }
}

@MainActor @Test func modifiersApplyInterceptorAndCursorStyle() {
    var text = ""
    let binding = Binding(get: { text }, set: { text = $0 })
    let interceptor = NullInterceptor()
    let view = MarkdownEditorView(text: binding)
        .inputInterceptor(interceptor)
        .insertionPointStyle(.block)

    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    view.apply(to: textView)
    #expect(textView.inputInterceptor === interceptor)
    #expect(textView.insertionPointStyle == .block)
}

@MainActor @Test func defaultModifiersLeaveTextViewUntouched() {
    var text = ""
    let binding = Binding(get: { text }, set: { text = $0 })
    let view = MarkdownEditorView(text: binding)

    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    view.apply(to: textView)
    #expect(textView.inputInterceptor == nil)
    #expect(textView.insertionPointStyle == .bar)
}
```

ファイル先頭の import に `import LapermCore` が無ければ `@testable import LapermCore` を追加する。

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: FAIL — `value of type 'MarkdownEditorView' has no member 'inputInterceptor'`

- [ ] **Step 3: モディファイアを実装**

`Sources/Laperm/MarkdownEditorView.swift`:

プロパティ(`private var showsLineNumbers = true` の後ろ)に追加:

```swift
    private var inputInterceptor: (any TextInputInterceptor)?
    private var insertionPointStyle: InsertionPointStyle = .bar
```

`showsLineNumbers(_:)` の後ろにモディファイアを追加:

```swift
    /// キー入力のインターセプタを設定する。MarkdownTextView 側は weak 保持のため、
    /// 呼び出し側がインターセプタの所有権を持つこと(@State 等)。
    public func inputInterceptor(_ interceptor: (any TextInputInterceptor)?) -> MarkdownEditorView {
        var copy = self
        copy.inputInterceptor = interceptor
        return copy
    }

    /// カーソル形状を設定する。
    public func insertionPointStyle(_ style: InsertionPointStyle) -> MarkdownEditorView {
        var copy = self
        copy.insertionPointStyle = style
        return copy
    }

    /// make / update 共通の反映処理(テストの継ぎ目)
    func apply(to textView: MarkdownTextView) {
        textView.inputInterceptor = inputInterceptor
        textView.insertionPointStyle = insertionPointStyle
    }
```

`makeNSView` の `textView.showsLineNumbers = showsLineNumbers` の直後に追加:

```swift
        apply(to: textView)
```

`updateNSView` の `textView.showsLineNumbers = showsLineNumbers` の直後に追加:

```swift
        apply(to: textView)
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: PASS(全テスト)

- [ ] **Step 5: コミット**

```bash
git add Sources/Laperm/MarkdownEditorView.swift Tests/LapermTests/MarkdownEditorViewTests.swift
git commit -m "feat(ui): add inputInterceptor / insertionPointStyle modifiers to MarkdownEditorView"
```

---

### Task 7: Example の簡易 Vim デモ

**Files:**
- Create: `Example/ExampleMacOS/VimEngine.swift`
- Create: `Example/ExampleMacOS/VimController.swift`
- Modify: `Example/ExampleMacOS/ContentView.swift`

**Interfaces:**
- Consumes: `KeyInput` / `KeyInputResult` / `TextMotions` / `EditCommand`(LapermCore)、`TextInputInterceptor` / `MarkdownTextView.perform` / `InsertionPointStyle` / SwiftUI モディファイア(Laperm)
- Produces: Example 内部のみ(`VimEngine`, `VimController`)。ライブラリ本体には含めない

Xcode プロジェクトは file system synchronized groups を使うため、`Example/ExampleMacOS/` にファイルを置くだけでターゲットに入る。

- [ ] **Step 1: VimEngine(純粋ステートマシン)を実装**

`Example/ExampleMacOS/VimEngine.swift`:

```swift
import Foundation
import LapermCore

/// 最小限の Vim ステートマシン(入力インターセプト API のリファレンス実装)。
/// KeyInput と文書状態から実行すべきアクションを純粋に計算する。AppKit 非依存。
struct VimEngine {
    enum Mode: Equatable {
        case normal
        case insert
    }

    enum Action: Equatable {
        case move(to: Int)      // カーソル移動(UTF-16 offset)
        case edit(EditCommand)  // undo 対応の編集
        case none               // 消費するが何もしない(モード切替・d 待ちなど)
        case passthrough        // 通常のテキスト入力処理へ
    }

    private(set) var mode: Mode = .normal
    private var pendingDelete = false  // "d" の 1 打目を受けた状態
    private var preferredColumn: Int?  // j / k の列記憶

    mutating func handle(_ input: KeyInput, text: NSString, selection: NSRange) -> Action {
        switch mode {
        case .insert:
            if input.key == .escape {
                mode = .normal
                return .none
            }
            return .passthrough
        case .normal:
            return handleNormal(input, text: text, selection: selection)
        }
    }

    private mutating func handleNormal(
        _ input: KeyInput, text: NSString, selection: NSRange
    ) -> Action {
        let caret = min(selection.location, text.length)
        // Cmd / Ctrl 付きはアプリ・システムのショートカットに任せる
        guard input.modifiers.isDisjoint(with: [.command, .control]) else {
            pendingDelete = false
            return .passthrough
        }
        guard case .character(let char) = input.key else {
            pendingDelete = false
            return input.key == .escape ? .none : .passthrough
        }
        if pendingDelete {
            pendingDelete = false
            return char == "d" ? deleteLine(text: text, caret: caret) : .none
        }
        if char != "j" && char != "k" { preferredColumn = nil }
        switch char {
        case "h":
            let lineStart = TextMotions.lineStart(text: text, at: caret)
            guard caret > lineStart else { return .none }
            return .move(to: text.rangeOfComposedCharacterSequence(at: caret - 1).location)
        case "l":
            guard caret < TextMotions.lineEnd(text: text, at: caret) else { return .none }
            return .move(to: NSMaxRange(text.rangeOfComposedCharacterSequence(at: caret)))
        case "j", "k":
            let column = preferredColumn
                ?? (caret - TextMotions.lineStart(text: text, at: caret))
            preferredColumn = column
            let target = char == "j"
                ? TextMotions.lineDown(text: text, at: caret, preferredColumn: column)
                : TextMotions.lineUp(text: text, at: caret, preferredColumn: column)
            return .move(to: target)
        case "0":
            return .move(to: TextMotions.lineStart(text: text, at: caret))
        case "$":
            return .move(to: TextMotions.lineEnd(text: text, at: caret))
        case "w":
            return .move(to: TextMotions.wordForward(text: text, at: caret))
        case "b":
            return .move(to: TextMotions.wordBackward(text: text, at: caret))
        case "x":
            guard caret < TextMotions.lineEnd(text: text, at: caret) else { return .none }
            let range = text.rangeOfComposedCharacterSequence(at: caret)
            return .edit(EditCommand(
                replacementRange: range, replacementString: "",
                selectedRange: NSRange(location: range.location, length: 0)))
        case "d":
            pendingDelete = true
            return .none
        case "i":
            mode = .insert
            return .none
        case "a":
            mode = .insert
            guard caret < TextMotions.lineEnd(text: text, at: caret) else { return .none }
            return .move(to: NSMaxRange(text.rangeOfComposedCharacterSequence(at: caret)))
        case "o":
            mode = .insert
            let lineEnd = TextMotions.lineEnd(text: text, at: caret)
            return .edit(EditCommand(
                replacementRange: NSRange(location: lineEnd, length: 0),
                replacementString: "\n",
                selectedRange: NSRange(location: lineEnd + 1, length: 0)))
        case "O":
            mode = .insert
            let lineStart = TextMotions.lineStart(text: text, at: caret)
            return .edit(EditCommand(
                replacementRange: NSRange(location: lineStart, length: 0),
                replacementString: "\n",
                selectedRange: NSRange(location: lineStart, length: 0)))
        default:
            return .none  // normal モードでは未対応キーも文字挿入させない
        }
    }

    private func deleteLine(text: NSString, caret: Int) -> Action {
        let lineRange = text.lineRange(for: NSRange(location: caret, length: 0))
        let newCaret = min(lineRange.location, text.length - lineRange.length)
        return .edit(EditCommand(
            replacementRange: lineRange, replacementString: "",
            selectedRange: NSRange(location: max(newCaret, 0), length: 0)))
    }
}
```

- [ ] **Step 2: VimController(インターセプタ)を実装**

`Example/ExampleMacOS/VimController.swift`:

```swift
import AppKit
import Laperm
import Observation

/// VimEngine と MarkdownTextView をつなぐインターセプタ。
/// MarkdownTextView 側は weak 保持のため、ContentView が @State で所有する。
@Observable @MainActor
final class VimController: TextInputInterceptor {
    var isEnabled = false {
        didSet {
            guard !isEnabled else { return }
            engine = VimEngine()  // OFF で normal に戻す
            mode = engine.mode
        }
    }
    private(set) var mode: VimEngine.Mode = .normal
    @ObservationIgnored private var engine = VimEngine()

    var insertionPointStyle: InsertionPointStyle {
        isEnabled && mode == .normal ? .block : .bar
    }

    var statusText: String? {
        guard isEnabled else { return nil }
        return mode == .normal ? "NORMAL" : "INSERT"
    }

    func textView(_ textView: MarkdownTextView, handle input: KeyInput) -> KeyInputResult {
        guard isEnabled else { return .passthrough }
        let action = engine.handle(
            input, text: textView.string as NSString, selection: textView.selectedRange())
        mode = engine.mode
        switch action {
        case .passthrough:
            return .passthrough
        case .none:
            return .handled
        case .move(let offset):
            let range = NSRange(location: offset, length: 0)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            return .handled
        case .edit(let command):
            textView.perform(command)
            textView.scrollRangeToVisible(textView.selectedRange())
            return .handled
        }
    }
}
```

- [ ] **Step 3: ContentView に配線**

`Example/ExampleMacOS/ContentView.swift` を修正する。

`@State private var useAlternateTheme = false` の後ろに追加:

```swift
    @State private var vim = VimController()
```

`body` を以下に置き換える:

```swift
    var body: some View {
        MarkdownEditorView(text: $text, theme: useAlternateTheme ? Self.alternateTheme : .default)
            .showsLineNumbers(showsLineNumbers)
            .inputInterceptor(vim.isEnabled ? vim : nil)
            .insertionPointStyle(vim.insertionPointStyle)
            .frame(minWidth: 640, minHeight: 480)
            .toolbar {
                ToolbarItem {
                    Toggle("行番号", isOn: $showsLineNumbers)
                }
                ToolbarItem {
                    Toggle("テーマ", isOn: $useAlternateTheme)
                }
                ToolbarItem {
                    Toggle("Vim", isOn: $vim.isEnabled)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let status = vim.statusText {
                    Text(status)
                        .font(.system(.caption, design: .monospaced).bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.bar)
                }
            }
    }
```

`sampleDocument` の「## 編集支援」セクション末尾(`- Tab / Shift+Tab で...` の行の後)に 1 行追加:

```
    - ツールバーの Vim トグルで簡易 Vim モード(hjkl / w b / 0 $ / x dd / i a o O / Esc)
```

- [ ] **Step 4: Example をビルドして確認**

Run: `xcodebuild -project Example/Example.xcodeproj -scheme ExampleMacOS build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: 全テストを実行**

Run: `swift test`
Expected: PASS(全テスト)

- [ ] **Step 6: 手動スモークテスト(実行者へ: アプリを起動できる環境なら実施、できなければユーザーに依頼)**

Example を起動し、Vim トグルを ON にして確認:

1. カーソルが半透明ブロックになり、ステータスバーに NORMAL と出る
2. `hjkl` で移動する(`j`/`k` は長い行 → 短い行 → 長い行で列が復元される)
3. `w` / `b` / `0` / `$` で単語・行内移動する
4. `x` で 1 文字、`dd` で 1 行消え、Cmd+Z で戻る
5. `i` で INSERT になりバーカーソルで通常入力できる(日本語 IME 含む)。`Esc` で NORMAL に戻る
6. `o` / `O` で行が開いて INSERT になる
7. Vim トグル OFF で完全に通常動作へ戻る

- [ ] **Step 7: コミット**

```bash
git add Example/ExampleMacOS/VimEngine.swift Example/ExampleMacOS/VimController.swift Example/ExampleMacOS/ContentView.swift
git commit -m "feat(example): add minimal Vim mode demo using input interception API"
```
