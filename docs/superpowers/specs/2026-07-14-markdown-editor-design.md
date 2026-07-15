# MarkdownEditor 設計ドキュメント

- 日付: 2026-07-14
- ステータス: 承認済み(ブレインストーミングセッションにて)

## 目的

TextKit2 をフル活用した macOS 向け Markdown エディタを Swift ライブラリとして実装する。
AttributedString の Markdown 描画機能には依存せず、TextKit2 のレイアウト機構
(レイアウトフラグメント、レンダリング属性、viewport レイアウト)を直接使い、
自由でハイパフォーマンスなレイアウトを実現する。iOS は将来対応とし、
プラットフォーム非依存のコア層を最初から分離しておく。

## 決定事項(要件)

| 項目 | 決定 |
|---|---|
| 編集体験 | シンタックスハイライト型(iA Writer / VS Code 方式)。常にソースを表示し、スタイル装飾のみ行う。テキスト内容は一切改変しない |
| 対象 OS | macOS 27+(WWDC26 の TextKit2 新 API をフル活用) |
| パーサー | apple/swift-markdown(cmark-gfm ベース、SourceRange 取得可能) |
| v1 機能範囲 | CommonMark 基本要素(見出し・強調・斜体・インラインコード・コードブロック・引用・リスト・リンク・水平線)+ 行番号ガター |
| v1 対象外 | GFM 拡張(テーブル・タスクリスト・打ち消し線)、コードブロック内の言語別ハイライト、iOS 対応 |
| 公開 API | AppKit(`NSTextView` サブクラス)+ SwiftUI ラッパー(`NSViewRepresentable`) |
| アーキテクチャ | ハイブリッド: `NSTextView` サブクラス + 属性ベースハイライト + カスタム `NSTextLayoutFragment` 描画 + viewport デリゲートによるガター |

### 却下した代替案

- **完全カスタムビュー**(`NSTextLayoutManager` を直接駆動): レイアウト自由度は最大だが、
  選択・カーソル・IME(特に日本語入力)・アクセシビリティの再実装コストとバグリスクが過大。
  WWDC26 の「フレームワークのテキストビューを拡張せよ」という公式推奨にも反する。
- **属性のみのスタイリング**: 最簡素だが、コードブロック背景や引用線が表現できず
  「TextKit2 フル活用」の目的に合わない。

## モジュール構成

SwiftPM パッケージ、2 ターゲット構成。プラットフォーム指定 `.macOS("27.0")`。
外部依存は `apple/swift-markdown` のみ。

```
MarkdownEditor(パッケージ)
├── MarkdownEditorCore(プラットフォーム非依存。AppKit を import しない)
│   ├── MarkdownParser      … swift-markdown をラップし AST を取得
│   ├── HighlightMapper     … AST の SourceRange → UTF-16 NSRange + SyntaxKind の一覧に変換
│   ├── SyntaxKind          … 意味的スタイル種別(見出しレベル・強調・コード等)の列挙
│   └── HighlightPlan       … 「このレンジにこの SyntaxKind」のリスト(属性適用は UI 層)
└── MarkdownEditor(macOS: AppKit + SwiftUI。Core に依存)
    ├── MarkdownTextView    … NSTextView サブクラス(中心 API)
    ├── MarkdownTheme       … SyntaxKind → NSFont/NSColor 等のスタイル定義(値型・Sendable)
    ├── Highlighter         … HighlightPlan の差分を NSTextContentStorage /
    │                          renderingAttributes に適用
    ├── BlockFragment 群    … コードブロック背景・引用線・水平線の NSTextLayoutFragment
    ├── LineNumberGutter    … viewport デリゲートによる行番号表示
    └── MarkdownEditorView  … SwiftUI ラッパー(NSViewRepresentable)
```

- Core は意味的な `SyntaxKind` までを担い、`NSFont`/`NSColor` への変換は UI 層の
  `MarkdownTheme` が行う。iOS 対応時は `NSFont → UIFont` 等の typealias 分岐で
  UI ターゲットを拡張するだけで済む。
- Core はロジックのみのため Swift Testing で高速にユニットテスト可能。

## ハイライトパイプライン

```
テキスト変更
  → 全文パース(swift-markdown)
  → HighlightMapper が新しい HighlightPlan を生成
  → 前回 Plan との差分を取り、変わったレンジのみ属性適用
```

### 設計判断

1. **パースは常に全文、適用は差分のみ。**
   Markdown はコードフェンス 1 つで文書後半全体の解釈が変わる非局所的文法のため、
   パラグラフ局所の差分パースは正しさの保証が難しい。cmark 系パーサーは MB/秒オーダーで
   動作するため、正しさは全文パースに、速さは属性適用の差分化に担わせる。
2. **属性の 2 層分離。**
   - レイアウトに影響しない色装飾 → `NSTextLayoutManager.renderingAttributes`
     (適用しても再レイアウトが発生しない)
   - フォント・太さ・パラグラフスタイル等 → `textStorage` に
     `performEditingTransaction { }` 内で適用
   タイピング中の変化の大半は色のみのため、再レイアウトをほぼゼロにできる。
3. **文書全体のジオメトリ照会をしない。** レイアウトは viewport 範囲+オーバードローに限定し、
   TextKit2 の非連続レイアウトを壊さない。
4. **バックグラウンドパース。** パースが 16ms を超える巨大文書ではパースを
   バックグラウンドキューで行い、世代番号で古い結果を破棄(編集が連続する場合は
   最後の 1 回だけ適用)。

### パフォーマンス目標

- 10,000 行 / 1MB 程度の文書で、1 キーストロークあたりのハイライト処理
  (パース+差分適用)を 16ms 以内(目標 8ms)
- スクロールは ProMotion 120fps を維持

### エラーハンドリング

パーサーは不正な Markdown でも失敗しない(すべて何らかの AST になる)。
例外系はレンジ変換の不整合のみ: 変換結果が文書長を超えた場合は該当スタイルを
スキップし、debug ビルドでは assert する。

## カスタム描画とガター

### ブロック装飾 — NSTextLayoutFragment サブクラス

`NSTextLayoutManagerDelegate.textLayoutManager(_:textLayoutFragmentFor:in:)` で
パラグラフのブロック種別に応じたフラグメントを返す。

| フラグメント | 描画内容 |
|---|---|
| `CodeBlockFragment` | テキスト背面に角丸背景矩形(連続行は矩形を連結) |
| `BlockquoteFragment` | 行頭側に縦のアクセントバー(ネスト分だけ複数本) |
| `ThematicBreakFragment` | `---` テキストに重ねて水平罫線 |

- 各フラグメントは `draw(at:in:)` で装飾を描画後 `super` を呼び、テキスト描画は
  フレームワークに任せる。
- ブロック種別は `HighlightPlan` のブロック情報をデリゲートが参照して決定。
- ブロック種別が変わったレンジは `invalidateLayout(for:)` でフラグメントを再生成
  (フラグメントは不変オブジェクトのため差し替え)。

### 行番号ガター — macOS 27 viewport デリゲート

`NSTextView` の `NSTextViewportLayoutControllerDelegate` 公開準拠を利用し、
`MarkdownTextView` で以下をオーバーライド(必ず `super` を呼ぶ):

1. `textViewportLayoutControllerWillLayout(_:)` — 行番号収集配列をリセット
2. `textViewportLayoutController(_:configureRenderingSurfaceFor:)` —
   各フラグメントの `layoutFragmentFrame` と行番号を記録
3. `textViewportLayoutControllerDidLayout(_:)` — `viewportBounds.origin` を差し引いて
   ガタービューへ反映

- 開始行番号は viewport 以前のパラグラフ数を `enumerateTextElements(from:)` で数える
  (全文走査はしない)。
- ガターは scroll view 内の専用 `NSView`。折り返し行には番号を振らない。

## 公開 API

```swift
// AppKit(中心 API)
public final class MarkdownTextView: NSTextView {
    public var theme: MarkdownTheme          // 差し替えで全文再スタイル
    public var showsLineNumbers: Bool
    public static func scrollableMarkdownEditor() -> NSScrollView  // ガター込み推奨構成
}

// SwiftUI ラッパー
public struct MarkdownEditorView: View {
    public init(text: Binding<String>, theme: MarkdownTheme = .default)
    public func showsLineNumbers(_ flag: Bool) -> Self
}

// テーマ(値型・Sendable)
public struct MarkdownTheme: Sendable {
    // 意味スロット: 本文 / 見出し(レベル別) / 強調 / 斜体 / インラインコード /
    // コードブロック / 引用 / リンク / リストマーカー / 水平線 / 構文記号
    public static let `default`: MarkdownTheme
}
```

- テキスト取得・変更・通知は `NSTextView` 標準 API(`string`, `textDidChange` 等)を
  そのまま使い、重複 API を作らない。
- 構文記号(`#`、`**`、`` ` `` 等)は削除・隠蔽せず淡色表示する。

## ExampleMacOS と検証

- **ExampleMacOS**: リポジトリ直下 `ExampleMacOS/` に Xcode プロジェクトとして作成。
  ローカルパッケージ参照でライブラリを組み込む SwiftUI アプリ。
  機能はエディタ+テーマ切替+行番号トグル+サンプル文書読み込みの最小構成。
- **ビルド・実行**: Xcode MCP を使用(パッケージ本体は `swift test` も併用)。
- **挙動確認**: computer-use で ExampleMacOS を操作。スクリーンショットで
  ハイライト・ガター表示を確認し、タイピング操作で編集時の挙動を検証。

## テスト戦略

- **Core 層(Swift Testing、中心)**
  - パース → `HighlightPlan` 変換の正しさ(見出し・強調・コードブロック・ネスト引用)
  - UTF-16 レンジ変換(日本語・絵文字・サロゲートペアを含む)
  - 差分適用ロジック
  - 巨大文書でのパース時間の回帰テスト
- **UI 層(最小限)**
  - 属性適用後の `textStorage` 属性検証をヘッドレスで実施
  - 描画の見た目は computer-use による目視確認で補完
