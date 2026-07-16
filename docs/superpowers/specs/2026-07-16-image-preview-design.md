# 画像プレビュー設計ドキュメント

- 日付: 2026-07-16
- ステータス: 承認済み(ブレインストーミングセッションにて)
- 前提: [2026-07-14-markdown-editor-design.md](2026-07-14-markdown-editor-design.md)(v1 設計)、
  [2026-07-15-gfm-extensions-design.md](2026-07-15-gfm-extensions-design.md)(BlockFragment 基盤)

## 目的

画像記法 `![alt](url)` のシンタックスハイライトと、記法を含む段落の直下への
インライン画像プレビュー表示を追加する。v1 の編集体験方針(ソース常時表示、
テキスト内容は改変しない)を維持し、ソーステキスト・カーソル位置・選択・IME に
一切影響を与えない方式を採る。

## 決定事項(要件)

| 項目 | 決定 |
|---|---|
| 表示方式 | ソースは常時表示のまま、画像記法を含む段落の下に画像をブロック表示(カーソル位置による表示切替はしない) |
| 画像ソース | ローカル相対パス(baseURL 基準)、ローカル絶対パス / `file:` URL、リモート `http(s):` URL |
| サイズ | 原寸を基本とし、エディタ幅と `maxHeight`(デフォルト 320pt)を超える場合はアスペクト比を保って縮小 |
| 読み込み中 | 固定高さ(80pt)のプレースホルダー枠を表示し、完了時に実画像へ差し替え |
| 失敗時 | ⚠ アイコン + alt テキストのコンパクト枠(44pt)を表示。理由による UI の区別はしない(ログには残す) |
| ロード API | `ImageLoader` プロトコル(public)を注入可能にし、デフォルト実装を内蔵 |
| リモート許可 | `allowsRemoteImages` はプライバシー配慮でデフォルト false。不許可時の http(s) 画像は失敗表示 |
| レンダリング方式 | 段落スペーシングでスペースを予約し、オーバーレイビューに `NSImageView` を配置(アプローチ C) |

### 検討した代替案

- **A: スペーシング予約 + カスタム NSTextLayoutFragment 描画**: 最軽量・最小リスクだが、
  `draw(at:in:)` の静止画描画では動画・GIF アニメーションに原理的に到達できない。
  将来の動画対応が要件にあるため却下。
- **B: NSTextContentStorageDelegate による表示専用段落差し替え + NSTextAttachment**:
  TextKit 2 ネイティブの attachment 機構(macOS 27 の ViewProvider 再利用ポリシー含む)を
  使えるが、表示テキストとソースの文字数がずれるため、UTF-16 オフセット前提の
  `HighlightPlan`・挿入ポイントオーバーレイ・入力インターセプト(Vim デモ)全域に
  マッピング層が波及する。本コードベースとの相性が悪く却下。
- **カーソル離脱時に記法を画像へ置換(Obsidian ライブプレビュー風)**: 見た目は
  リッチだが attachment 差し替え + カーソル追跡が必要で、undo・選択・IME との
  相互作用が複雑。ソース常時表示という既存方針とも乖離するため却下。

## Core 層(LapermCore)

### SyntaxKind 追加(1 ケース)

| ケース | 対象レンジ | 想定スタイル層 |
|---|---|---|
| `image` | `![alt](url)` 全体 | rendering(リンク同様の色)。URL 部は既存 `syntaxMarker` で淡色化 |

### HighlightMapper 拡張

- `visitImage` を追加。`image` スパンの付与と同時に `ImageReference` を収集する。
- コードブロック内の画像記法は対象外(swift-markdown が画像としてパースしないため
  自然に除外される)。

### ImageReference(新規、public)

```swift
public struct ImageReference: Equatable, Sendable {
    public let altText: String
    public let destination: String   // 記法に書かれた URL 文字列(未解決)
    public let range: NSRange        // ![alt](url) 全体の UTF-16 レンジ
    public let paragraphRange: NSRange // 所属段落のレンジ(スペーシング適用先)
    public let isInsideTable: Bool   // テーブル内はプレビュー対象外のためのフラグ
}
```

- `HighlightPlan` に `images: [ImageReference]` を追加。
- 既存の `HighlightPlan.shifted(by:)` は `images` の各レンジにも同じシフトを適用する。

### ImageURLResolver(新規、public)

純粋関数。`resolve(destination: String, baseURL: URL?) -> URL?`

| 入力 | 解決結果 |
|---|---|
| `http://…` / `https://…` | そのまま URL 化 |
| `file://…` | そのまま URL 化 |
| `/` 始まりの絶対パス | `URL(filePath:)` |
| 相対パス | `baseURL` に対して解決。`baseURL == nil` なら解決不能(nil) |
| 空文字列・URL 化不能な文字列 | nil |

## UI 層(Laperm)

### ImageLoader プロトコル(新規、public)

```swift
public protocol ImageLoader: Sendable {
    func loadImage(for url: URL) async throws -> NSImage
}
```

- デフォルト実装 `DefaultImageLoader` を内蔵:
  - `file:` URL は `NSImage(contentsOf:)` をバックグラウンドで実行
  - `http(s):` URL は `URLSession.shared` で取得してデコード
  - `NSCache<NSURL, NSImage>` によるメモリキャッシュ
- デコードは `loadImage` 内(非メインスレッド)で完結させ、メインスレッドを
  ブロックしない。

### ImagePreviewOptions(新規、public)

```swift
public struct ImagePreviewOptions: Equatable, Sendable {
    public var isEnabled: Bool = true
    public var baseURL: URL? = nil
    public var maxHeight: CGFloat = 320
    public var allowsRemoteImages: Bool = false
}
```

### ImagePreviewController(新規、internal)

画像ごとの状態機械とロードタスクを管理する。

- 状態: `loading` / `loaded(NSImage)` / `failed`
- キー: `(記法レンジ, destination 文字列)` の組
- `Highlighter` のフラッシュ時に現行プランの画像集合を受け取り、前回と diff:
  - 新規 → `ImageURLResolver` で解決。解決不能・リモート不許可なら即 `failed`、
    それ以外は `ImageLoader` を `Task` で起動
  - 消滅 → タスクをキャンセルしビューを破棄
  - destination 変更 → 旧タスクをキャンセルして再ロード
- ロード完了は MainActor に戻す。完了時に該当キーが現行集合に存在しなければ
  結果を破棄(編集レース対策)。世代番号でさらに古い適用を防ぐ
  (バックグラウンド解析と同じ方式)。

### スペース予約(Highlighter 拡張)

- 画像を含む段落に `NSParagraphStyle.paragraphSpacing` を適用して縦スペースを
  予約する。フォントと同じ textStorage チャネル(編集トランザクション内)で
  適用するため、新しい適用経路は不要。
- 予約高さ = 段落内の各画像の表示高さの合計 + パディング(画像 1 枚につき上下計 8pt):
  - `loading`: 80pt / `failed`: 44pt
  - `loaded`: 原寸をエディタ幅(テキストコンテナの実効幅 = lineFragmentPadding を
    除いた幅)と `maxHeight` にフィットさせた高さ
- ロード完了・エディタ幅変更で予約高さが変わる場合のみ再適用し、既存の
  `recordEditAction` + `invalidateLayout` ワークアラウンドでレイアウトを更新する。
- IME 変換中(marked text)は既存のハイライト遅延ガードに乗るため、変換中に
  spacing 変更は走らない。

### ImagePreviewOverlayView(新規、internal)

- 挿入ポイントオーバーレイと同様の非ヒットテストオーバーレイ。
- ビューポートレイアウトコールバック(行番号ガターと同型)で画像段落の
  フラグメント枠を収集し、テキスト末尾行の下(予約スペース内)に
  `NSImageView` / プレースホルダービュー / エラービューを配置する。
- ビューポート外に出たビューは取り外して再利用する。
- 将来、配置するビューを `AVPlayerView` 等に差し替えることで動画・GIF に拡張できる
  (スペース予約・ロード・解決のコアはそのまま流用)。

### 公開 API

- `MarkdownEditorView` に `.imageLoader(_:)` / `.imagePreviewOptions(_:)` modifier を追加
- `MarkdownTextView` に `imageLoader` / `imagePreviewOptions` プロパティを追加

## スコープ境界(v1)

- 1 段落に複数画像がある場合は、段落の下にソース順で縦に積んで表示する。
- テーブルセル内の画像は構文ハイライトのみでプレビューなし
  (テーブル背景装飾との干渉を避ける。`ImageReference.isInsideTable` で除外)。
- アニメーション GIF は静止フレーム表示(動画対応と合わせて将来拡張)。
- クリックで拡大などのインタラクションは対象外。
- 参照形式リンク画像(`![alt][ref]`)は swift-markdown が解決したもののみ対象
  (未定義参照は画像としてパースされないため自然に対象外)。

## テスト戦略

- **Core**:
  - `visitImage`: alt 空、URL 空、日本語 alt、1 段落複数画像、コードブロック内は
    対象外、テーブル内の `isInsideTable` フラグ
  - `ImageURLResolver`: テーブル駆動テスト(上記の解決表)
  - `HighlightPlan.shifted`: `images` のレンジ追随
- **UI**:
  - モック `ImageLoader` で `ImagePreviewController` の状態遷移
    (成功 / 失敗 / キャンセル / destination 差し替え / リモート不許可 / 編集レース)
  - spacing 適用と再適用(高さ不変時に再適用しないこと)
  - オーバーレイのフレーム計算
- **GUI 検証**(CLAUDE.md 方針、`verifying-macos-gui` スキル):
  - Example アプリに画像入りサンプルを追加し、computer use で実表示を確認:
    ローカル画像の表示、壊れた URL のエラー枠、スクロール追随
