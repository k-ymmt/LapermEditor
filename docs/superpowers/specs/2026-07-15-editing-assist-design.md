# 編集支援機能(リスト自動継続・チェックボックストグル・Tab インデント・ペア補完)Design

**Date:** 2026-07-15
**Status:** Approved

## Goal

`MarkdownTextView` に Markdown 編集を快適にする 4 つの編集支援機能を追加する:

1. **リスト自動継続** — Enter で次行にリストマーカーを自動挿入。空項目で Enter するとリストから脱出
2. **チェックボックストグル** — `[ ]` / `[x]` のクリックでチェック状態を切り替え
3. **Tab インデント** — Tab / Shift+Tab でリスト項目のネストレベルを上げ下げ
4. **ペア補完** — 選択範囲の囲い込みと、括弧系・バッククォートの自動閉じ

## Architecture

既存の「Core が判断し UI が適用する」2 層構造を踏襲する(採用案 A)。

- **LapermCore**: 新ファイル `EditingAssistant.swift`。編集判断を純粋関数として実装。swift-markdown には依存せず、行単位のテキスト走査のみで判断する。ハイライトパイプラインとは完全に独立
- **Laperm**: `MarkdownTextView` が `insertNewline` / `insertTab` / `insertBacktab` / `insertText(_:replacementRange:)` / `mouseDown` を薄くオーバーライドして Core に委譲し、返った `EditCommand` を undo 対応の経路で適用する

却下した代替案:

- **MarkdownTextView に直接実装** — テストが `@MainActor` + 実 NSTextView 必須になり遅い。ビューが肥大し、既存の分離方針に反する
- **NSTextViewDelegate ベースの外部コントローラ** — ライブラリが delegate スロットを占有し、利用側が delegate を使えなくなる

## Core API(LapermCore)

```swift
/// 編集操作の結果。UI 層がこれを undo 対応の経路で適用する
public struct EditCommand: Equatable, Sendable {
    public var replacementRange: NSRange   // 置換する範囲(現在のテキスト座標)
    public var replacementString: String
    public var selectedRange: NSRange      // 適用後の選択範囲(適用後座標)
}

/// 各編集イベントを判断する純粋関数群(状態を持たない)
public enum EditingAssistant {
    public static func newline(text: NSString, selection: NSRange) -> EditCommand?
    public static func indent(text: NSString, selection: NSRange) -> EditCommand?
    public static func outdent(text: NSString, selection: NSRange) -> EditCommand?
    public static func insertion(text: NSString, selection: NSRange, typing: String) -> EditCommand?
    public static func toggleCheckbox(text: NSString, at offset: Int) -> EditCommand?
}
```

**規約: 全関数は判断できないケース・対象外のケースですべて `nil` を返し、`nil` = NSTextView のデフォルト動作**とする。範囲は常に text 長に対して検証し、クラッシュ経路を作らない。

行の解析(インデント幅、`-` / `*` / `+` / `1.` / `1)` マーカー、`[ ]` / `[x]` チェックボックスの検出)は `EditingAssistant` 内部の private ヘルパー(`ListItemLine` 構造体の parse)として実装し、5 つの公開関数で共用する。

## 挙動仕様

### リスト自動継続(Enter)

- 対象はカーソル(選択なし)時のみ。選択ありの Enter はデフォルト動作
- カーソル行がリスト項目なら、カーソル位置に `"\n" + 同じインデント + マーカー` を挿入する
  - 順序付きリストは番号を +1(`3.` → `4.`。区切り文字 `.` / `)` は元の行に合わせる)
  - タスク項目はチェック状態に関わらず `- [ ] `(未チェック)で継続(バレット文字は元の行に合わせる)
  - 行の途中で Enter した場合、カーソル以降のテキストは新しいマーカーの後ろに送られる(挿入位置がカーソル位置なので自然にそうなる)
- **空項目脱出**: 行がマーカーだけ(本文が空)なら、行のマーカー部分を削除して空行にする
- 後続の番号の振り直しはやらない(YAGNI。番号が重複しても Markdown としては正しくレンダリングされる)

### チェックボックストグル(クリック)

- `mouseDown` でクリック位置を `characterIndexForInsertion(at:)` により文字オフセットへ変換(ここだけ UI 層)
- オフセットがタスク項目行の `[ ]` / `[x]` の 3 文字範囲内にあるときだけ、中央の 1 文字を置換(` ` → `x`、`x` / `X` → ` `)し、イベントを消費する(カーソルは動かさない)
- 範囲外なら通常のクリック(super に委譲)

### Tab インデント(Tab / Shift+Tab)

- カーソル行(または選択範囲に含まれる行のいずれか)がリスト項目のときだけ発動。リスト行が 1 つもなければデフォルト動作(通常の Tab 挿入)
- カーソルが行のどこにあっても行頭を操作する(Obsidian 方式)
  - Tab: 行頭にスペース 4 個を挿入
  - Shift+Tab: 行頭から最大 4 個のスペースを削除
- 複数行選択時は選択に含まれる**リスト項目行すべて**を一括で上げ下げし、選択範囲を維持する
- インデント単位はスペース 4 固定(`1. ` 等の番号付きマーカー幅でもネストが常に成立する値)

### ペア補完(文字入力)

対象文字: 囲い込みは `*` `_` `` ` `` `~` `[` `(` の 6 種、自動閉じは `` ` `` `[` `(` の 3 種(`*` `_` `~` は日本語の文章中で誤発火しやすいため自動閉じ対象外)。

- **囲い込み**: 選択ありで対象文字を入力 → 選択範囲を `[` → `]`、`(` → `)`、他は同字で囲み、**内側のテキストを選択したまま**にする(続けて `*` を打てば `**bold**` になる)
- **自動閉じ**: 選択なしで `` ` `` `[` `(` を入力 → 閉じ側を自動挿入しカーソルを間に置く。抑制ヒューリスティックは持たない(常に自動閉じ)
- **タイプオーバー**: カーソル直後が `` ` `` `]` `)` で同じ文字を入力 → 挿入せずカーソルだけ進める
- Backspace でのペア一括削除はやらない(YAGNI)
- IME 変換中(marked text あり)はすべて素通し。入力文字列がちょうど対象 1 文字のときだけ発動する

## UI 統合(Laperm)

```swift
public struct EditingOptions: Equatable, Sendable {
    public var continuesLists: Bool
    public var togglesCheckboxOnClick: Bool
    public var indentsListItems: Bool
    public var completesPairs: Bool
    // init は全プロパティにデフォルト true
}
```

- `MarkdownTextView` に `public var editingOptions: EditingOptions = .init()` を追加
- 各オーバーライドは「オプション OFF またはコマンドが nil なら super」の 2 行ガード + 適用、という薄い形にする
  - `insertNewline(_:)` → `EditingAssistant.newline`
  - `insertTab(_:)` / `insertBacktab(_:)` → `indent` / `outdent`
  - `insertText(_:replacementRange:)` → `insertion`(`hasMarkedText()` なら即 super)
  - `mouseDown(with:)` → 座標を文字オフセットへ変換して `toggleCheckbox`。テスト容易性のため中身は internal メソッド `toggleCheckbox(atPoint:)` に切り出す

**適用経路(undo 統合)**: 共通ヘルパー `apply(_ command: EditCommand) -> Bool` を 1 つ用意する:

```swift
guard shouldChangeText(in: command.replacementRange, replacementString: command.replacementString) else { return false }
textStorage.replaceCharacters(in: command.replacementRange, with: command.replacementString)
didChangeText()
setSelectedRange(command.selectedRange)
```

`shouldChangeText` / `didChangeText` を通すことで NSTextView 標準の undo にそのまま乗り、既存の `NSTextStorageDelegate` 経由で再ハイライトも自動で走る(追加の連携コードは不要)。

## エラー処理

- Core の全関数は範囲を text 長に対して検証し、判断できないケースはすべて `nil`(= デフォルト動作)に倒す
- `apply` が false(delegate 拒否)の場合も安全にデフォルト動作へフォールバックする

## テスト戦略

- **Core(`Tests/LapermCoreTests/EditingAssistantTests.swift`)**: 純粋関数なので網羅的に。各機能 5〜10 ケース:
  - 継続: `-` / `*` / `+` / 順序付き(`.` と `)`)/ タスクの各マーカー、空項目脱出、行途中 Enter、インデント付き行、選択あり(nil)、非リスト行(nil)
  - インデント: ネスト行の indent / outdent、行頭スペース 4 未満の outdent、複数行選択、非リスト行(nil)
  - ペア補完: 6 種の囲い込み、3 種の自動閉じ、タイプオーバー、対象外文字(nil)、複数文字入力(nil)
  - トグル: `[ ]` → `[x]`、`[x]` / `[X]` → `[ ]`、範囲外オフセット(nil)、チェックボックスなしリスト行(nil)
- **UI(`Tests/LapermTests/MarkdownTextViewTests.swift` に追加)**: 統合を数ケースだけ — `insertNewline` でマーカーが入ること、オプション OFF で入らないこと、undo で 1 ステップ戻ること、IME マークテキスト中はペア補完しないこと、`toggleCheckbox(atPoint:)` でトグルされること

## スコープ外(明示)

- 順序付きリストの番号振り直し
- Backspace でのペア一括削除
- 自動閉じの抑制ヒューリスティック(直後が英数字なら閉じない等)
- blockquote(`>`)の自動継続
- インデント単位のカスタマイズ
