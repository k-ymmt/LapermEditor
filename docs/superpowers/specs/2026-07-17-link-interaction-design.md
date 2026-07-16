# リンク操作(Cmd+クリック・ベア URL 検出・ペーストリンク化)Design

**Date:** 2026-07-17
**Status:** Approved

## Goal

`MarkdownTextView` に 3 つのリンク操作機能を追加する:

1. **Cmd+クリックで開く** — リンク上で Cmd+クリックすると URL を開く。Cmd 押下中のホバーで下線+ポインティングハンドカーソルのフィードバックを表示する
2. **ベア URL の検出** — `https://…` の裸 URL もリンクとしてハイライトし、クリック対象にする
3. **URL ペーストでリンク化** — テキスト選択中に URL をペーストすると `[選択テキスト](URL)` に自動変換する

Cmd+K などのリンク挿入ショートカットは対象外(将来検討)。

## 前提(調査結果)

- 既存実装では `[text](url)` 全体が `.link` としてハイライトされるのみで、URL の抽出・クリック処理は存在しない
- **swift-markdown が有効化している cmark-gfm 拡張は table / strikethrough / tasklist のみ**(`CommonMarkConverter.swift` で確認)。GFM の autolink 拡張は無効のため、ベア URL は Link ノードにならない → Core での自前検出が必要
- `<https://…>` の角括弧 autolink は CommonMark 標準であり、Link ノードとしてパース済み
- 参照リンク `[text][ref]` は cmark が定義を解決済みで、`Link.destination` が最終 URL を返す

## Architecture

既存の「Core が判断し UI が適用する」2 層構造を踏襲する(採用案 A)。

- **LapermCore**: `HighlightMapper` の走査時に `LinkReference`(レンジ + URL 文字列)を収集して `HighlightPlan` に含める(`ImageReference` と同じパターン)。ペーストのリンク化は `EditingAssistant` の純粋関数として追加
- **Laperm**: `MarkdownTextView` が Cmd+クリック・ホバー・ペーストを検出し、Core の判断結果を適用する

### 却下した代替案

- **案 B: textStorage に `.link` 属性を付与して NSTextView 標準機構に委譲** — クリック処理が `NSTextViewDelegate` 経由になり利用側の delegate スロットと衝突する(編集支援設計で却下済みの理由と同じ)。レンダリング属性ベースの既存方針とも不整合
- **案 C: クリック時にその場で行を走査して URL 抽出** — 参照リンクやベア URL の判定を正規表現で再発明することになり、パーサーと結果がズレる

## Core API(LapermCore)

### LinkReference(新規)

```swift
/// リンク 1 箇所ぶんの参照情報。UI 層のクリック処理が消費する。
public struct LinkReference: Hashable, Sendable {
    /// リンクテキスト(装飾を除いたプレーンテキスト。ベア URL では URL 自身)
    public var text: String
    /// 記法に書かれた URL 文字列(未解決)
    public var destination: String
    /// 記法全体の UTF-16 レンジ(ベア URL では URL 自身のレンジ)
    public var range: NSRange
}
```

`ImageReference` と異なり、クリック判定にしか使わないため `paragraphRange` は持たない。

### HighlightPlan 拡張

- `links: [LinkReference]` を追加
- `shifted(byEditAt:changeInLength:)` で `images` と同様に平行移動し、編集と交差したら破棄

### HighlightMapper 拡張

- `visitLink` で `link.destination` を収集して `LinkReference` を生成(既存の `.link` スパン生成に加えて)。参照リンク・角括弧 autolink もここで拾える
- **ベア URL 検出**: `visitText` で `http://` / `https://` を走査する
  - URL の終端は空白・行末まで。末尾の約物(`.` `,` `;` `:` `!` `?` `)` など)は GFM 風にトリムする。ただし `(` と対応が取れている `)` は残す(GFM の括弧バランス規則に準拠)
  - 検出レンジに `.link` スパンと `LinkReference` を追加
  - コードスパン/コードブロック内は `visitText` 自体が呼ばれないため自然に除外される
  - 既存 Link の子テキストは「Link 内を走査中」フラグでスキップし、二重検出を防ぐ

### LinkURLResolver(新規)

`ImageURLResolver` と同じ規則に `mailto:` を加えた許可リスト:

- `http` / `https` / `file` / `mailto` スキーム付き → そのまま URL 化
- `/` 始まりの絶対パス → file URL
- 相対パス → baseURL に対して解決(baseURL が nil なら解決不能)
- 空文字列・未対応スキーム → nil

実装はスキーム許可リストをパラメータ化した共通ヘルパーに寄せ、`ImageURLResolver` の公開挙動は変えない。

### EditingAssistant.linkifyPaste(新規)

```swift
/// 選択中に URL をペーストしたとき [選択](URL) へ変換する EditCommand を返す。
/// 対象外なら nil(呼び出し側は通常のペーストへフォールバック)。
public static func linkifyPaste(
    text: NSString, selection: NSRange, pasted: String
) -> EditCommand?
```

採用条件(すべて満たすとき変換):

- 選択が非空で単一行内に収まっている
- `pasted` が URL 形状: `http://` または `https://` で始まり、空白・改行を含まない
- 選択テキスト自体が URL 形状ではない(URL を URL で潰す事故防止)

結果: 選択レンジを `[選択テキスト](ペースト URL)` で置換し、カーソルは `)` の直後。

制限(v1): 選択が既存リンク記法やコードスパン内かどうかの文脈判定は行わない(EditingAssistant の行単位走査方針の範囲内に留める)。

## UI API(Laperm)

### LinkOptions(新規)

```swift
public struct LinkOptions: Equatable, Sendable {
    /// Cmd+クリックでリンクを開く
    public var opensOnCommandClick: Bool = true
    /// 相対パスの解決基準(ImagePreviewOptions.baseURL と同じ役割)
    public var baseURL: URL? = nil
}
```

### EditingOptions 拡張

- `linkifiesPastedURL: Bool = true` を追加(ペースト変換は編集支援の管轄)

### MarkdownTextView 拡張

- `public var linkOptions: LinkOptions`
- `public var onOpenLink: ((URL) -> Bool)?` — `true` を返したら消費。`false` / nil ならデフォルト動作(`NSWorkspace.shared.open`)
- **mouseDown**: Cmd 押下+クリック位置が `LinkReference.range` 内なら `LinkURLResolver` で解決して開く。座標→オフセット変換はチェックボックストグルの既存経路を再利用し、テスト可能なよう `openLink(atPoint:) -> Bool` を分離する。イベントは消費してカーソル移動させない(VS Code と同様)
- **ホバーフィードバック**: Cmd 押下中にリンク上へポインタが乗ったら `NSCursor.pointingHand` と下線の renderingAttributes を一時付与し、外れたら解除。`NSTrackingArea`(mouseMoved)+ `flagsChanged` で Cmd の押下/解放にも追従する
- **paste(_:)**: pasteboard の string と現在選択を `EditingAssistant.linkifyPaste` へ渡し、`EditCommand` が返れば undo 対応経路で適用。nil なら `super.paste(_:)`

### SwiftUI(MarkdownEditorView)

既存モディファイアのパターンを踏襲:

- `.markdownLinkOptions(_ options: LinkOptions)`
- `.onMarkdownOpenLink(_ handler: @escaping (URL) -> Bool)`

## Example アプリ

- デモ文書にリンクサンプル(通常リンク・参照リンク・ベア URL・相対パス)を追加
- `onOpenLink` で消費して「最後に開いた URL」をステータスラベルに表示する(実ブラウザを起動せずに GUI 検証できるようにするため)

## Testing

- **Core(Swift Testing)**:
  - HighlightMapper: ベア URL の境界(行頭・行末・約物トリム・括弧バランス)、コードスパン/コードブロック内で検出しない、既存リンク内で二重検出しない、参照リンク・角括弧 autolink の destination 収集
  - HighlightPlan: `links` の shift・交差破棄
  - LinkURLResolver: スキーム許可表・絶対/相対パス・baseURL なし
  - EditingAssistant.linkifyPaste: 採用/不採用の各条件、カーソル位置
- **UI(@MainActor テスト)**: `openLink(atPoint:)` のヒットテスト、paste 経路の分岐、`onOpenLink` の消費/フォールバック
- **GUI 検証(verifying-macos-gui)**: Example アプリで Cmd+クリック(ステータスラベル確認)、Cmd ホバーの下線+カーソル変化、選択中 URL ペーストのリンク化をスクリーンショットで確認
