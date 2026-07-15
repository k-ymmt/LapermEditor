# GFM 拡張(テーブル・タスクリスト・打ち消し線)設計ドキュメント

- 日付: 2026-07-15
- ステータス: 承認済み(ブレインストーミングセッションにて)
- 前提: [2026-07-14-markdown-editor-design.md](2026-07-14-markdown-editor-design.md)(v1 設計)

## 目的

v1 で対象外とした GFM 拡張のうち、テーブル・タスクリスト・打ち消し線の
シンタックスハイライトを追加する。v1 の編集体験方針(ソース常時表示、
テキスト内容は改変しない)とアーキテクチャ(Core = 意味的 SyntaxKind、
UI = テーマ + BlockFragment)をそのまま踏襲する。

## 決定事項(要件)

| 項目 | 決定 |
|---|---|
| 対象要素 | GFM テーブル、タスクリスト、打ち消し線 |
| テーブルの深さ | 属性(等幅フォント・ヘッダー太字・パイプのマーカー化)+ BlockFragment による背景描画。セル列揃えはやらない |
| タスクリスト | チェックボックス(`[ ]`/`[x]`)をマーカー色に。チェック済み項目は本文も淡色化(rendering 属性のみ、打ち消し線は付けない) |
| 打ち消し線 | `~~…~~` 全体に打ち消し線 + 色。デリミタはマーカー化 |
| パーサー | 変更なし。swift-markdown(cmark-gfm ベース)は GFM 要素をデフォルトでパースする |

### 却下した代替案

- **テーブルのセル列揃え(iA Writer 風)**: タブストップまたはカスタムレイアウトが
  必要で工数大。編集中の挿入・削除のたびに揃え直しが走りパフォーマンスリスクあり。
- **チェック済みタスク本文への打ち消し線付加**: ソース表示型エディタでは
  「書いていない装飾の付加」になり、`~~…~~` 記法との視覚的区別が曖昧になるため却下。
- **テーブルを属性のみでスタイリング**: 最小工数だが見た目のテーブル感が薄く、
  既存の BlockFragment 基盤を再利用できるため背景描画まで行う。

## Core 層(MarkdownEditorCore)

### SyntaxKind 追加(4 ケース)

| ケース | 対象レンジ | 想定スタイル層 |
|---|---|---|
| `strikethrough` | `~~…~~` 全体(デリミタ含む) | rendering(打ち消し線 + 色。再レイアウトなし) |
| `table` | テーブルブロック全体 | textStorage(等幅フォント)+ BlockFragment(背景) |
| `tableHeader` | ヘッダー行 | textStorage(太字) |
| `taskChecked` | チェック済みリスト項目の本文 | rendering(淡色化) |

> **実装後の変更(2026-07-15)**: 実機検証で TextKit2 の renderingAttributes は
> `.strikethroughStyle` を描画しないことが判明したため、打ち消し線の
> スタイル・線色は textStorage 層で適用する(色の淡色化は引き続き rendering 層)。
> レイアウトには影響しないため 2 層分離の趣旨は維持される。

マーカー類は既存の `.syntaxMarker` を再利用する:

- 打ち消し線のデリミタ(チルダ列)。cmark-gfm はチルダ 1 個(`~x~`)も
  打ち消し線として解釈するため、デリミタ長は固定 2 ではなく、インラインコードの
  バッククォート走査と同じ方式で実テキストのチルダ列を走査して求める。
  開き側と閉じ側が同じ長さのチルダ列である場合のみマーカー化する。
- テーブルのパイプ `|`(エスケープ `\|` は除外)と区切り行(`---|---` 等の行全体)。
  パイプ位置は AST に含まれないため、既存の引用マーカー(`appendQuoteMarkers`)と
  同様にテキスト走査で求める。走査対象はテーブルブロックのレンジ内に限定する。
- チェックボックス `[ ]` / `[x]` / `[X]`(3 文字)。位置はリストマーカー直後の
  非空白開始位置から走査して求める。

### Visitor 追加・変更

- `visitStrikethrough(_ strikethrough: Strikethrough)` — inline スパン + デリミタ走査。
  `descendInto` で内部の強調等も従来どおり処理する。
- `visitTable(_ table: Table)` — テーブル全体を `table` の block スパンに。
  `table.head` のレンジを `tableHeader` に。区切り行(head と body の間の行)と
  レンジ内のパイプを `.syntaxMarker` に。セル内インライン(強調・打ち消し線・
  インラインコード等)は `descendInto` で従来どおり処理する。
- `visitListItem` に checkbox 分岐を追加 — `listItem.checkbox` が非 nil なら
  チェックボックス 3 文字を `.syntaxMarker` に。`.checked` の場合はリスト項目
  直下の各 Paragraph のレンジを `taskChecked` の inline スパンに(swift-markdown
  の Paragraph レンジはチェックボックスの後から始まり、ネストした子リストを
  含まないため、子項目の状態を汚染しない。実測で確認済み)。

### スパン適用順

既存の「ブロック → インライン → マーカー」の 3 層順序を維持する。
`table` / `tableHeader` はブロック層、`strikethrough` / `taskChecked` はインライン層。
同一レンジで重なる場合は後勝ち(既存挙動)で、マーカーが最後に上書きする。

## UI 層(MarkdownEditor)

### MarkdownTheme 拡張

新 SyntaxKind 4 ケースに対応するスタイル定義を追加する。既存の
Equatable / Sendable / レイアウト属性・レンダリング属性の 2 層分離を踏襲する。

- `strikethrough`: `.strikethroughStyle` + `.strikethroughColor`(textStorage 層。上記の実装後の変更を参照)
- `table`: 等幅フォント(textStorage 層)+ 背景色(BlockFragment が参照)
- `tableHeader`: 太字(textStorage 層)
- `taskChecked`: 前景色の淡色化(rendering 層)

### TableBackgroundFragment

コードブロック背景と同じ `NSTextLayoutFragment` サブクラスパターンで、
テーブルブロックのレンジに角丸背景を描画する。`BlockFragmentProvider` に
`table` ブロックスパンの判定を追加する。既存の deferred 課題
「コードブロック背景の行間矩形連結」と同種の見た目の制約(行ごとの矩形)は
v1 同様に許容する。

### 既存機構との整合

- 打ち消し線・淡色化は renderingAttributes で完結するため再レイアウトが発生せず、
  差分適用・世代番号方式バックグラウンドパース・IME 合成中ガード
  (`hasMarkedText()` / `shouldDeferApply`)はそのまま機能する。
- 等幅フォント・太字は textStorage 層のため、既存どおり
  `performEditingTransaction` 内で適用される。

## エッジケース

- エスケープされたパイプ `\|` はマーカー化しない。
- コードブロック・インラインコード内の `~~` や `|` は AST 上そもそも
  Strikethrough / Table にならないため対象外(既存の descend 制御で担保)。
- チルダ 1 個の打ち消し線(`~x~`)、チルダ 3 個以上はパーサーの解釈に従う
  (デリミタ長は実テキスト走査で決める)。
- チェックボックスの大文字 `[X]` も cmark-gfm はチェック済みとして解釈する。
- ネストしたタスクリスト: `taskChecked` スパンはリスト項目直下の Paragraph の
  レンジのみに付与する。Paragraph レンジはネストした子リストを含まないため、
  親がチェック済みでも未チェックの子項目が淡色化されることはない。
- ヘッダーのみ(body が空)のテーブル、末尾パイプ省略形もパーサーの解釈に従う。

## テスト

- **Core(Swift Testing)**: 各要素のレンジ・マーカー検証。エスケープパイプ、
  `[X]`、チルダ 1 個/非対称チルダ、テーブルセル内の強調・打ち消し線、
  ネストしたタスクリスト、ヘッダーのみのテーブル、コードブロック内の
  `~~`/`|` が対象外であること。
- **UI**: 新テーマ項目の属性適用テスト、`BlockFragmentProvider` のテーブル判定テスト。
  既存パターン(62 テスト)に追加する形。
- **パフォーマンス**: 10k 行回帰テストは既存のまま(パースは元から GFM を処理
  しているため回帰リスクは低い。閾値変更はしない)。
- **目視確認**: ExampleMacOS のサンプル文書に GFM 3 要素を追加する。

## 実装順(1 spec 内で 3 段階)

1. **打ち消し線** — SyntaxKind + Visitor + テーマ。最小で全レイヤーを貫通させる。
2. **タスクリスト** — checkbox 分岐 + 淡色化。
3. **テーブル** — マーカー走査 + tableHeader + TableBackgroundFragment。最大粒度。

各段階でテストを追加し、独立してコミットする(TDD)。

## 対象外(このスペックではやらない)

- セルの視覚的列揃え
- テーブルの罫線(グリッド線)描画
- チェックボックスのクリックによるトグル操作
- GFM オートリンク・脚注などその他の拡張
