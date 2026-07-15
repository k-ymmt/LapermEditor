# 入力インターセプト API(Vim モード実装可能化)Design

**Date:** 2026-07-16
**Status:** Approved

## Goal

ライブラリ利用者が Vim モードのようなモーダル編集を **ライブラリの外側で** 実装できる、汎用の入力インターセプト API を提供する:

1. **キーイベントの横取り** — キー入力をテキスト挿入前に受け取り、消費(handled)または通過(passthrough)を選べる
2. **カーソル形状の変更** — bar / block / underline を切り替えられる(Vim の normal / replace モード表現)
3. **テキスト操作ヘルパー** — undo 対応の `EditCommand` 適用口の公開と、純粋関数のカーソル移動計算
4. **SwiftUI ラッパー対応** — `MarkdownEditorView` からもインターセプタとカーソル形状を設定できる

Vim 特化の部品(モード状態管理、キーマップ解決)はライブラリでは提供しない。Emacs 風キーバインドなど他のモーダル/非モーダル拡張にも使える汎用レイヤーに留める。

検証として Example アプリに簡易 Vim モード実装(デモ)を含め、API が実際に Vim モードを組めることを証明する。

## Architecture

既存の「Core が判断し UI が適用する」2 層構造を踏襲する(採用案 A)。

- **LapermCore**: 新ファイル `KeyInput.swift`(キー入力の値型)と `TextMotions.swift`(カーソル移動の純粋関数)。AppKit 非依存で、利用者の Vim ステートマシンも AppKit 非依存でテストできるようになる
- **Laperm**: `MarkdownTextView` が `keyDown(with:)` をオーバーライドし、`NSEvent` → `KeyInput` 変換とインターセプタ呼び出しを行う。カーソル形状はオーバーレイビューで実現

却下した代替案:

- **案 B: NSEvent 直接デリゲート** — 実装は最小だが、利用者のキーマップ処理が `keyCode` / `charactersIgnoringModifiers` の解釈まみれになり、テストに NSEvent 合成が必要で体験が悪い
- **案 C: セレクタレベル(`doCommand(by:)`)のフック** — normal モードの `j` が `insertText:` に化けてから届くため、「文字を挿入せずコマンド解釈する」という Vim の根幹が素直に書けない

## Core API(LapermCore)

### KeyInput

```swift
/// AppKit 非依存のキー入力表現
public struct KeyInput: Equatable, Sendable {
    public enum Key: Equatable, Sendable {
        case character(Character)   // 印字可能文字。Shift 適用済み("A" は character("A") + shift)
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
        public static let shift: Modifiers
        public static let control: Modifiers
        public static let option: Modifiers
        public static let command: Modifiers
    }

    public let key: Key
    public let modifiers: Modifiers

    public init(key: Key, modifiers: Modifiers = [])
}

/// インターセプタの応答
public enum KeyInputResult: Sendable {
    case handled       // イベントを消費。テキストビューには渡さない
    case passthrough   // 通常の処理(IME・挿入・キーバインディング)へ流す
}
```

- `character` は `charactersIgnoringModifiers` ベースで Shift 適用済みの文字を持つ(`A` は `character("A")` + `.shift`)。Control / Option / Command は文字を変形させず修飾フラグとして渡す
- スペースは `character(" ")` として扱う(専用ケースは設けない)

### TextMotions

```swift
/// カーソル移動計算の純粋関数群。offset / 戻り値はすべて UTF-16 単位
public enum TextMotions {
    /// offset を含む行の行頭 offset
    public static func lineStart(text: NSString, at offset: Int) -> Int
    /// offset を含む行の行末 offset(改行文字の手前)
    public static func lineEnd(text: NSString, at offset: Int) -> Int
    /// 1 行上の同列(preferredColumn)へ。先頭行なら現在 offset を返す
    public static func lineUp(text: NSString, at offset: Int, preferredColumn: Int) -> Int
    /// 1 行下の同列(preferredColumn)へ。最終行なら現在 offset を返す
    public static func lineDown(text: NSString, at offset: Int, preferredColumn: Int) -> Int
    /// 次の単語頭へ(Vim の w 相当)。文書末ならその場に留まる
    public static func wordForward(text: NSString, at offset: Int) -> Int
    /// 前の単語頭へ(Vim の b 相当)。文書頭ならその場に留まる
    public static func wordBackward(text: NSString, at offset: Int) -> Int
}
```

- `preferredColumn` は Vim の縦移動時の列記憶用。列の保持自体は利用者側の状態(ライブラリは計算のみ)
- 列は UTF-16 単位で数える。移動先の行が短い場合は行末にクランプする
- 単語境界は Vim の `w` / `b` 相当のシンプルな規則: 「英数字とアンダースコアの連続」「それ以外の非空白記号の連続」をそれぞれ 1 単語とし、空白はスキップする。詳細挙動はテストで固定する
- サロゲートペア(絵文字等)の途中に落ちる offset を返さないこと(境界に丸める)

## View API(Laperm)

### インターセプタ

```swift
@MainActor
public protocol TextInputInterceptor: AnyObject {
    /// キー入力ごとに呼ばれる。handled を返すとイベントは消費される
    func textView(_ textView: MarkdownTextView, handle input: KeyInput) -> KeyInputResult
}

// MarkdownTextView に追加
public weak var inputInterceptor: (any TextInputInterceptor)?
```

`keyDown(with:)` の処理フロー:

1. `hasMarkedText()`(IME 変換中)なら無条件で `super` へ — 変換セッションを壊さない
2. `NSEvent` → `KeyInput` へ変換。変換不能なイベント(修飾キー単独、ファンクションキー等)は `super` へ
3. `inputInterceptor` に渡し、`.handled` なら終了、`.passthrough`(または未設定)なら `super.keyDown` へ

### カーソル形状

```swift
public enum InsertionPointStyle: Equatable, Sendable {
    case bar        // 標準の縦棒(デフォルト)
    case block      // 文字を覆う半透明の矩形(Vim normal モード用)
    case underline  // 文字下のアンダーライン(Vim replace モード用)
}

// MarkdownTextView に追加
public var insertionPointStyle: InsertionPointStyle { get set }  // デフォルト .bar
```

実装方針:

- macOS 14+ の NSTextView はカーソル描画に `NSTextInsertionIndicator`(サブビュー)を使うため、`drawInsertionPoint` オーバーライドは効かない。`block` / `underline` 時はシステムインジケータを隠し、自前のオーバーレイビューを配置する
- オーバーレイの位置とサイズは `NSTextLayoutManager` のカレット座標(カーソル位置の文字のフラグメント矩形)から求める。行末・空行では等幅 1 文字ぶんの幅とする
- `block` は半透明塗り(下の文字が読める)。色はテーマの insertionPointColor 系に従う
- スタイル変更・選択位置変更・レイアウト変更のたびにオーバーレイを追従させる(モード切替のたびに呼ばれる想定)
- 選択範囲があるとき(length > 0)はオーバーレイを表示しない(通常の選択ハイライトに任せる)

### テキスト操作の適用口

```swift
// MarkdownTextView に追加(既存 private apply(_:) の公開版)
@discardableResult
public func perform(_ command: EditCommand) -> Bool
```

- `shouldChangeText` / `didChangeText` を通すため、undo と再ハイライトが自動で乗る
- `shouldChangeText` が false の場合は `false` を返す(例外・状態破壊なし)
- 適用前に `replacementRange` を文書長で検証し、範囲外なら `false` を返す(`NSTextStorage` の例外を避ける)
- 置換なし(`replacementRange.length == 0` かつ `replacementString.isEmpty`)は選択範囲の移動のみ行う(既存 apply と同じ)

## SwiftUI API(MarkdownEditorView)

既存の `showsLineNumbers(_:)` と同じモディファイアパターン:

```swift
public func inputInterceptor(_ interceptor: (any TextInputInterceptor)?) -> MarkdownEditorView
public func insertionPointStyle(_ style: InsertionPointStyle) -> MarkdownEditorView
```

- `makeNSView` / `updateNSView` で `MarkdownTextView` に反映する
- モード切替でカーソル形状を変える利用者は、`@Observable` コントローラにモードを持たせ `insertionPointStyle(vim.mode == .normal ? .block : .bar)` と宣言的に書ける(`updateNSView` 経由で即時反映)
- インターセプタは `weak` 保持。利用者側が所有権を持つことをドキュメントコメントに明記する

## Edge Cases

| ケース | 挙動 |
|---|---|
| IME 変換中(marked text) | インターセプタを呼ばず `super` へ。変換確定後のキーから再びインターセプト対象 |
| `.handled` を返した場合 | イベント完全消費。`editingOptions` の編集支援(ペア補完等)にも到達しない |
| `.passthrough` を返した場合 | 既存動作と完全に同一(insertNewline / insertTab 等の編集支援も従来どおり動く) |
| インターセプタ未設定(nil) | 従来と完全に同一動作。既存利用者への影響ゼロ |
| Cmd 付きキー | メニューのキーイコライバレントが先に処理するため通常は届かない。届いたものだけインターセプタに渡る(仕様として明記) |
| マウスクリックによる選択・移動 | インターセプト対象外。カーソル位置変化に追従したい利用者は `NSTextViewDelegate` の選択変更通知を使う(新 API は作らない) |

## Example: 簡易 Vim デモ

API の実用性検証を兼ねたリファレンス実装として Example アプリに追加する(ライブラリ本体には含めない):

- **`VimEngine`**(純粋ロジック): `KeyInput` とドキュメント状態(text / selection)を受け取り、`EditCommand` またはカーソル移動を返すステートマシン。AppKit 非依存で書けること自体が API 設計の検証になる
- **`VimController`**(`@Observable`): `VimEngine` を保持し `TextInputInterceptor` を実装。モードに応じた `InsertionPointStyle` を公開する
- **`ContentView`**: Vim モードの ON/OFF トグルを追加し、`inputInterceptor` / `insertionPointStyle` モディファイアで接続。画面下部にモード表示(NORMAL / INSERT)を出す

サポートするコマンド(最小限):

| コマンド | 動作 |
|---|---|
| `h` `j` `k` `l` | 左・下・上・右移動(`j` / `k` は列記憶付き) |
| `0` `$` | 行頭・行末 |
| `w` `b` | 単語移動 |
| `x` | カーソル位置の 1 文字削除 |
| `dd` | 行削除 |
| `i` `a` `o` `O` | insert モードへ(その場 / 直後 / 下に行追加 / 上に行追加) |
| `Esc` | normal モードへ復帰 |

## Testing

| 対象 | 場所 | 内容 |
|---|---|---|
| `TextMotions` | LapermCoreTests | 行頭・行末・縦移動の列記憶・単語境界を、空行・行末・絵文字(サロゲートペア)含みで固定 |
| NSEvent → `KeyInput` 変換 | LapermTests | 合成 NSEvent で文字・修飾キー・特殊キー(Esc / 矢印 / Tab 等)の変換を検証 |
| インターセプト経路 | LapermTests | `.handled` で文書が変化しない / `.passthrough` で通常挿入される / marked text 中は呼ばれない |
| `perform(_:)` | LapermTests | undo で戻る・範囲外コマンドが `false` を返す・再ハイライトが走る |
| カーソル形状 | LapermTests | スタイル切替でオーバーレイの表示状態と位置が期待どおりか |

Example の `VimEngine` はテストターゲットを持たないため、手動確認で十分な範囲(上記コマンド一覧)に留める。
