# 見出しアウトライン / セクション折りたたみ Design

**Date:** 2026-07-16
**Status:** Approved

## Goal

見出しベースのドキュメントナビゲーションを提供する:

1. **アウトライン提供 API** — 文書の見出しツリー(フラット配列 + level)を外部(サイドバー等)へ提供し、変化時に通知する
2. **セクション折りたたみ** — 見出しセクションの本体を非表示にできる。行番号ガターのシェブロン(▼/▶)クリックと公開 API の両方から操作可能
3. **見出しへのジャンプ** — アウトライン項目からのスクロール移動(折畳中なら展開してから)

折りたたみはテキストストレージを一切変更しない(`Binding<String>` は常に全文、undo スタックも汚さない)。

## Architecture

**採用案 A: `NSTextContentStorageDelegate.shouldEnumerate` による要素スキップ**(WWDC26 セッション 370 の公式パターン、macOS 27+)。折畳範囲の段落を列挙時にスキップするとレイアウト対象から外れて非表示になる。`NSTextContentStorage.delegate` は現在未使用のため競合しない。

却下した代替案:

- **案 B: 属性ベースの隠蔽**(フォント極小化等)— ストレージへの属性書き込みが undo を汚し、ハイライトの属性適用と衝突する。TextKit 1 時代のハック
- **案 C: テキスト差し替え**(折畳部分を物理削除して退避)— `Binding<String>` からセクションが消え、「text バインディングは常に全文」という契約を破壊する

レイヤー分担は既存の 2 層構造を踏襲:

- **LapermCore**: `OutlineBuilder`(HighlightPlan → アウトライン構築の純関数)、`FoldingState`(折畳位置集合と編集追従の値型)
- **Laperm**: `FoldingController`(`NSTextContentStorageDelegate` 実装、再パース同期、自動展開)、`LineNumberGutterView` 拡張(シェブロン)、`MarkdownTextView` / `MarkdownEditorView` の公開 API

## Core API(LapermCore)

### OutlineItem / OutlineBuilder

```swift
/// 見出し 1 件分のアウトライン項目
public struct OutlineItem: Hashable, Sendable {
    public var level: Int            // 1...6
    public var title: String         // マーカー除去済みの見出しテキスト
    public var headingRange: NSRange // 見出し行の UTF-16 レンジ
    public var sectionRange: NSRange // 見出し行を含む、セクション全体のレンジ
    public var bodyRange: NSRange    // 折畳時に隠す本体(見出し行の次行頭〜sectionRange 末尾)。本体がなければ length 0

    /// 折畳操作のキー(= headingRange.location)
    public var headingLocation: Int { headingRange.location }
}

/// HighlightPlan の heading スパン + 原文からアウトラインを構築する純関数
public enum OutlineBuilder {
    public static func build(from plan: HighlightPlan, text: String) -> [OutlineItem]
}
```

- `sectionRange`: 見出し行の先頭から、**同レベル以下(数値が同じか小さい)の次の見出しの直前**まで。文書末尾の見出しは文書末尾まで
- フラット配列で返す。ツリー化は level を見て利用側が行う(サイドバーのインデント表示には level で十分)
- ATX(`#`)と Setext(下線式)の両方の `heading` スパンを対象にする

### FoldingState

```swift
public struct FoldingState: Equatable, Sendable {
    /// 折畳 1 件。bodyRange がレイアウトから隠す範囲(見出し行は含まない)。
    public struct Fold: Hashable, Sendable {
        public var headingLocation: Int  // 見出し行頭の UTF-16 オフセット(折畳のキー)
        public var bodyRange: NSRange    // 折畳時に隠す本体レンジ
    }

    public private(set) var folds: [Fold]  // headingLocation 昇順

    /// HighlightPlan.shifted と同じ規則: 編集より前は不変、後は delta 平行移動、
    /// 交差した折畳は解除(= 自動展開の一形態)。dropped で解除された Fold を返す。
    public func shifted(
        byEditAt editedRange: NSRange, changeInLength delta: Int
    ) -> (state: FoldingState, dropped: [Fold])
}
```

編集のたびに `didProcessEditing` 経路で `shifted` を適用するので、パース完了を待たずに折畳位置が追従する。

## UI 層(Laperm)

### FoldingController

```swift
@MainActor
final class FoldingController: NSObject, NSTextContentStorageDelegate {
    private(set) var state: FoldingState
    private(set) var outline: [OutlineItem]  // 最新パース結果から構築
    var onChange: (() -> Void)?              // 折畳状態 or アウトライン変化の通知

    func toggleFold(at headingLocation: Int)
    func fold(at headingLocation: Int)
    func unfold(at headingLocation: Int)
    func unfoldAll()
    func isFolded(headingLocation: Int) -> Bool

    // NSTextContentStorageDelegate:
    // 段落先頭オフセットが「折畳中セクションの本体部分」に含まれていれば false
    func textContentManager(_:shouldEnumerate:options:) -> Bool
}
```

動作の要点:

- **隠すのはセクション本体のみ**。見出し行自体(`headingRange` を含む段落)は表示したまま。見出しが見えないと展開手段を失うため
- トグル時は `textViewportLayoutControllerReceivedSetNeedsLayout` で再レイアウトを要求し、加えて折畳境界の段落に `recordEditAction` + `invalidateLayout`(`BlockFragmentProvider.update` と同じパターン)でフラグメント再生成を確実にする
- **再パース同期**: `Highlighter` のフラッシュ時に `OutlineBuilder.build` を呼び `outline` を更新。折畳中の見出しオフセットが新アウトラインに存在しなければ(見出し行の削除等)その折畳を解除する
- **編集追従**: `didProcessEditing` のタイミングで `state.shifted(...)` を適用。折畳セクション内部への編集は交差判定で自動展開される

ネストした折畳(H2 折畳内の H3 も折畳)で親だけを `unfold` した場合、子の折畳状態は維持される(`foldedHeadingLocations` に残っているため、親展開後も子セクションは畳まれたまま表示される)。

### 自動展開(カーソル進入時)

選択変更の監視箇所で、カーソル位置(または選択範囲)が折畳中セクションの**隠れている本体部分**と交差していたら `unfold` する。ネスト時(H2 折畳内の H3 も折畳)はカーソル位置を含むすべての折畳を解除する。IME 合成中(`hasMarkedText()`)は既存パターンに合わせて判定を遅延し、合成確定後に評価する。

**矢印キーの挙動(実装確定・GUI 検証済み)**: TextKit のカーソル移動はレイアウト行単位のため、折畳領域は矢印キーでは**スキップ**される(VS Code / Vim の fold と同じ。カーソルが不可視位置に入ることはない)。自動展開が発動するのは、検索・プログラム的選択・折畳本体に交差する編集など、選択が実際に隠し領域と交差したときのみ。

### ガター UI(シェブロン)

`LineNumberGutterView` を拡張:

- アウトラインの見出し行に ▼(展開中)/ ▶(折畳中)を描画
- `mouseDown` でシェブロンをヒット判定し、命中したら `FoldingController.toggleFold`
- 行番号は**論理行番号を維持**(折畳で隠れた行の番号は飛ぶ。10 行目で折畳 → 次の表示行は 25、のように)
- `showsLineNumbers == false` のときはシェブロンも出ない。折畳は公開 API からのみ操作可能(v1 割り切り)

## 公開 API

```swift
// MarkdownTextView(AppKit)
public var outline: [OutlineItem] { get }
public var onOutlineChange: (([OutlineItem]) -> Void)?
public var isFoldingEnabled: Bool                    // default true
public func fold(at headingLocation: Int)
public func unfold(at headingLocation: Int)
public func toggleFold(at headingLocation: Int)
public func unfoldAll()
public func isFolded(at headingLocation: Int) -> Bool
public func scrollToHeading(at headingLocation: Int) // 折畳中なら展開してからスクロール

// MarkdownEditorView(SwiftUI)ビルダーモディファイア
func onOutlineChange(_ action: @escaping ([OutlineItem]) -> Void) -> Self
func foldingEnabled(_ enabled: Bool) -> Self
func editorProxy(_ proxy: MarkdownEditorProxy) -> Self  // 命令的 API(ジャンプ・折畳)の呼び出し口
```

- `onOutlineChange` はパース確定時にアウトラインが**実際に変化したときだけ**発火(`[OutlineItem]` の Equatable 比較)
- `isFoldingEnabled = false` にすると全折畳を解除し、以後シェブロンも API 操作も無効

## エラー処理・エッジケース

- Setext 見出しも `heading` スパンとして同様に扱う(cmark が終端を次ブロックまで過大報告するため、HighlightMapper で下線行末尾にクランプ済み)
- コードブロック内の `#` はパーサが見出し扱いしないため誤検出なし
- 空文書・見出しゼロ → アウトライン空配列、折畳不可
- 文書全体が 1 見出しのみ → セクション = 見出し以降全部
- 折畳中の全文置換(`text` バインディング差し替え)→ 編集交差判定で全折畳解除
- 折畳領域内の画像プレビュー → オーバーレイのレイアウト時に viewport へ現れないため自然に非表示になることを確認する(現れる場合は folded 判定で除外)

## テスト

- **LapermCoreTests**
  - `OutlineBuilderTests`: レベル混在、Setext、ネスト、末尾セクション、sectionRange 境界、title のマーカー除去
  - `FoldingStateTests`: shifted の平行移動・交差解除
- **LapermTests**
  - `FoldingControllerTests`: shouldEnumerate 判定(見出し行は表示・本体は非表示)、再パース同期、見出し消失時の折畳解除、unfoldAll
  - 既存 `LineIndex` / ガター描画への影響確認
- **GUI 検証**(CLAUDE.md 必須・computer use): シェブロンのクリック折畳/展開、カーソル進入の自動展開、アウトラインサイドバーからのジャンプ

## Example アプリ

サイドバーに `List` ベースのアウトライン(level インデント + クリックでジャンプ)を追加し、`onOutlineChange` / `scrollToHeading` の使用例とする。
