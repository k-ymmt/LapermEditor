# 画像プレビュー Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 画像記法 `![alt](url)` のシンタックスハイライトと、記法を含む行の直下へのインライン画像プレビュー(非同期ロード・プレースホルダー・エラー表示付き)を実装する。

**Architecture:** Core 層(`LapermCore`)は `visitImage` によるスパン付与と `ImageReference` 収集、URL 解決の純粋関数を提供。UI 層(`Laperm`)は `ImagePreviewController`(destination 単位の状態機械 + 非同期ロード)、段落スペーシング(`paragraphSpacing`)による縦スペース予約、ビューポートレイアウトコールバックで配置する非ヒットテストのオーバーレイビュー(将来 `AVPlayerView` に差し替え可能)で構成する。

**Tech Stack:** Swift 6.4 / SwiftPM / swift-markdown / TextKit2(macOS 27)/ Swift Testing

**Spec:** `docs/superpowers/specs/2026-07-16-image-preview-design.md`

## Global Constraints

- 対象 OS: macOS 27.0 以上。新規外部依存の追加は禁止(swift-markdown のみ)
- `LapermCore` は AppKit を import しない(Foundation + Markdown のみ)
- エディタはテキスト内容を一切改変しない(属性・オーバーレイ描画のみ)
- `NSTextView.layoutManager` プロパティには絶対に触れない(TextKit1 フォールバック防止。`textLayoutManager` のみ使用)
- テストは Swift Testing(`import Testing`)。`swift test --filter` はこの環境では効かないため、常に全体 `swift test` で検証する(全体で ~1s)
- コミットは main へ直接。メッセージ末尾に以下を付ける:
  ```
  Task N of image-preview plan
  Task context: 画像プレビュー機能の実装 (docs/superpowers/specs/2026-07-16-image-preview-design.md)

  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  ```
- プレースホルダー高さ: loading 80pt / failed 44pt、画像 1 枚あたりのパディング 8pt、`maxHeight` デフォルト 320pt(スペック値)

### スペックからの実装上の精緻化(仕様意図は不変)

1. **`ImageLoader` は `Sendable` プロトコルではなく `@MainActor` プロトコル**にする。Swift 6 では非 Sendable の `NSImage` をアクター境界を越えて返せないため。デコードは `DefaultImageLoader` 内部で Sendable な `CGImage` を detached タスクで生成してから main で `NSImage` 化する(「デコードでメインスレッドをブロックしない」というスペック要件は満たす)。
2. **ロードタスクの管理キーは destination 文字列のみ**(スペック案は「記法レンジ + destination」)。レンジをキーに含めると画像より前方の無関係な編集のたびにレンジが変わりロードが再走してしまうため。出現箇所ごとの配置は `ImageReference` のレンジで行う。
3. **スペーシングの除去は「シフト追随したレンジ記録」ではなくマーカー属性(`laperm.imageSpacing`)の走査**で行う。適用済み位置の座標管理が不要になり、編集による座標ずれ起因のバグクラスを丸ごと排除できる。
4. **`recordEditAction` + `invalidateLayout` ワークアラウンドは不要**。スペーシングは textStorage への実属性編集なので TextKit2 の通常経路で再レイアウトされる(ワークアラウンドが必要なのは storage を変更しない BlockFragment の場合のみ)。
5. **`ImageReference.paragraphRange` は「画像記法を含む改行区切りの行」**(`NSString.paragraphRange(for:)`)。Markdown 段落が複数行に渡る場合、プレビューは画像記法がある行の直下に出る(画像だけの行という典型ケースでは Markdown 段落の直下と同義)。

## File Structure

```
Sources/LapermCore/
├── SyntaxKind.swift              … Task 1(.image ケース追加)
├── ImageReference.swift          … Task 1(新規)
├── HighlightPlan.swift           … Task 1(images プロパティ + shifted 対応)
├── HighlightMapper.swift         … Task 2(visitImage + テーブル深度追跡)
└── ImageURLResolver.swift        … Task 3(新規)
Sources/Laperm/
├── ImagePreviewOptions.swift     … Task 4(新規)
├── ImageLoader.swift             … Task 4(新規: protocol + DefaultImageLoader)
├── MarkdownTheme.swift           … Task 4(.image スタイル追加)
├── ImagePreviewController.swift  … Task 5(状態機械)+ Task 6(スペーシング適用)
├── ImagePreviewOverlayView.swift … Task 7(新規: レイアウト計算 + オーバーレイ)
├── MarkdownTextView.swift        … Task 6, 7, 8(統合 + 公開プロパティ)
└── MarkdownEditorView.swift      … Task 8(modifier 追加)
Tests/LapermCoreTests/
├── HighlightPlanTests.swift      … Task 1(追記)
├── MarkdownParserTests.swift     … Task 2(追記)
└── ImageURLResolverTests.swift   … Task 3(新規)
Tests/LapermTests/
├── ImagePreviewControllerTests.swift … Task 5, 6(新規)
├── ImagePreviewLayoutTests.swift     … Task 7(新規)
└── MarkdownEditorViewTests.swift     … Task 8(追記)
Example/ExampleMacOS/ContentView.swift … Task 9(サンプル追加)
```

**実行環境メモ:** ビルド・テストは `swift build` / `swift test` CLI。Example は `xcodebuild -project Example/Example.xcodeproj -scheme ExampleMacOS build`。GUI 検証はプロジェクトスキル `verifying-macos-gui` に従う(computer use 必須)。

---

### Task 1: Core モデル(SyntaxKind.image / ImageReference / HighlightPlan.images)

**Files:**
- Modify: `Sources/LapermCore/SyntaxKind.swift`
- Create: `Sources/LapermCore/ImageReference.swift`
- Modify: `Sources/LapermCore/HighlightPlan.swift`
- Test: `Tests/LapermCoreTests/HighlightPlanTests.swift`(追記)

**Interfaces:**
- Consumes: なし
- Produces: `SyntaxKind.image`、`ImageReference(altText:destination:range:paragraphRange:isInsideTable:)`(Hashable/Sendable)、`HighlightPlan.images: [ImageReference]`、`HighlightPlan.init(spans:images:)`、`shifted(byEditAt:changeInLength:)` が images も追随

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermCoreTests/HighlightPlanTests.swift` に追記:

```swift
@Test func shiftMovesImageReferenceAfterEdit() {
    let image = ImageReference(
        altText: "a", destination: "a.png",
        range: NSRange(location: 20, length: 12),
        paragraphRange: NSRange(location: 20, length: 13))
    let plan = HighlightPlan(spans: [], images: [image])
    // 位置 0 に 5 文字挿入(editedRange は編集後座標)
    let shifted = plan.shifted(byEditAt: NSRange(location: 0, length: 5), changeInLength: 5)
    #expect(shifted.images.count == 1)
    #expect(shifted.images[0].range == NSRange(location: 25, length: 12))
    #expect(shifted.images[0].paragraphRange == NSRange(location: 25, length: 13))
}

@Test func shiftDropsImageReferenceWhenEditIntersectsRange() {
    let image = ImageReference(
        altText: "a", destination: "a.png",
        range: NSRange(location: 20, length: 12),
        paragraphRange: NSRange(location: 20, length: 13))
    let plan = HighlightPlan(spans: [], images: [image])
    // 記法の内部に 1 文字挿入 → 参照は破棄(次のパースで再生成される)
    let shifted = plan.shifted(byEditAt: NSRange(location: 22, length: 1), changeInLength: 1)
    #expect(shifted.images.isEmpty)
}

@Test func shiftDropsImageReferenceWhenEditIntersectsParagraphRangeOnly() {
    let image = ImageReference(
        altText: "a", destination: "a.png",
        range: NSRange(location: 20, length: 12),
        paragraphRange: NSRange(location: 18, length: 20))
    let plan = HighlightPlan(spans: [], images: [image])
    // 記法の後ろ・同一行内に挿入 → paragraphRange が古くなるので破棄
    let shifted = plan.shifted(byEditAt: NSRange(location: 34, length: 1), changeInLength: 1)
    #expect(shifted.images.isEmpty)
}

@Test func shiftKeepsImageReferenceBeforeEdit() {
    let image = ImageReference(
        altText: "a", destination: "a.png",
        range: NSRange(location: 0, length: 12),
        paragraphRange: NSRange(location: 0, length: 13))
    let plan = HighlightPlan(spans: [], images: [image])
    let shifted = plan.shifted(byEditAt: NSRange(location: 30, length: 5), changeInLength: 5)
    #expect(shifted.images == [image])
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: FAIL(`ImageReference` 未定義のコンパイルエラー)

- [ ] **Step 3: 実装**

`Sources/LapermCore/SyntaxKind.swift` — `case link` の下に追加:

```swift
    case image
```

`Sources/LapermCore/ImageReference.swift` を新規作成:

```swift
import Foundation

/// 画像記法 1 箇所ぶんの参照情報。UI 層のプレビュー表示が消費する。
public struct ImageReference: Hashable, Sendable {
    /// alt テキスト(装飾を除いたプレーンテキスト)
    public var altText: String
    /// 記法に書かれた URL 文字列(未解決)
    public var destination: String
    /// `![alt](url)` 全体の UTF-16 レンジ
    public var range: NSRange
    /// 記法を含む改行区切りの行(テキスト段落)のレンジ。paragraphSpacing の適用先。
    public var paragraphRange: NSRange
    /// テーブルセル内の画像(v1 ではプレビュー対象外)
    public var isInsideTable: Bool

    public init(
        altText: String,
        destination: String,
        range: NSRange,
        paragraphRange: NSRange,
        isInsideTable: Bool = false
    ) {
        self.altText = altText
        self.destination = destination
        self.range = range
        self.paragraphRange = paragraphRange
        self.isInsideTable = isInsideTable
    }
}
```

`Sources/LapermCore/HighlightPlan.swift` — `HighlightPlan` を変更。`images` を追加し、`shifted` の判定ロジックを共通ヘルパーに抽出して images にも適用する:

```swift
/// 文書全体のハイライト計画。spans は適用順(ブロック → インライン → マーカー)。
public struct HighlightPlan: Equatable, Sendable {
    public var spans: [HighlightSpan]
    /// 画像記法の出現一覧(プレビュー表示用)
    public var images: [ImageReference]

    public init(spans: [HighlightSpan] = [], images: [ImageReference] = []) {
        self.spans = spans
        self.images = images
    }

    /// 編集(NSTextStorageDelegate の didProcessEditing 相当の情報)に合わせて
    /// スパン位置を平行移動する。編集レンジと交差するスパンは破棄する
    /// (次のパース結果から再生成されるため)。
    public func shifted(byEditAt editedRange: NSRange, changeInLength delta: Int) -> HighlightPlan {
        // editedRange は編集「後」のレンジ。編集「前」に影響を受けた領域は
        // {editedRange.location, editedRange.length - delta}
        let preEditRange = NSRange(
            location: editedRange.location,
            length: max(0, editedRange.length - delta)
        )
        var resultSpans: [HighlightSpan] = []
        resultSpans.reserveCapacity(spans.count)
        for span in spans {
            guard let range = Self.shift(span.range, preEditRange: preEditRange, delta: delta)
            else { continue }
            var moved = span
            moved.range = range
            resultSpans.append(moved)
        }
        var resultImages: [ImageReference] = []
        resultImages.reserveCapacity(images.count)
        for image in images {
            // range と paragraphRange の両方が編集と交差しない場合のみ残す
            guard let range = Self.shift(image.range, preEditRange: preEditRange, delta: delta),
                  let paragraphRange = Self.shift(
                      image.paragraphRange, preEditRange: preEditRange, delta: delta)
            else { continue }
            var moved = image
            moved.range = range
            moved.paragraphRange = paragraphRange
            resultImages.append(moved)
        }
        return HighlightPlan(spans: resultSpans, images: resultImages)
    }

    /// 編集より前なら不変、後なら delta 平行移動、交差なら nil(破棄)。
    private static func shift(_ range: NSRange, preEditRange: NSRange, delta: Int) -> NSRange? {
        if NSMaxRange(range) <= preEditRange.location {
            return range
        }
        if range.location >= NSMaxRange(preEditRange) {
            return NSRange(location: range.location + delta, length: range.length)
        }
        return nil
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: PASS(既存テスト含め全パス。`HighlightDiff` は spans しか見ないため影響なし)

- [ ] **Step 5: コミット**

```bash
git add Sources/LapermCore Tests/LapermCoreTests
git commit -m "feat(core): add SyntaxKind.image and ImageReference to HighlightPlan

Task 1 of image-preview plan
Task context: 画像プレビュー機能の実装 (docs/superpowers/specs/2026-07-16-image-preview-design.md)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: HighlightMapper.visitImage

**Files:**
- Modify: `Sources/LapermCore/HighlightMapper.swift`
- Test: `Tests/LapermCoreTests/MarkdownParserTests.swift`(追記)

**Interfaces:**
- Consumes: `SyntaxKind.image`、`ImageReference`(Task 1)
- Produces: `MarkdownParser().highlightPlan(for:)` の結果に `.image` スパン、`![` と `](…)` のマーカースパン、`images: [ImageReference]` が含まれる

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermCoreTests/MarkdownParserTests.swift` に追記:

```swift
private func imageReferences(in markdown: String) -> [ImageReference] {
    MarkdownParser().highlightPlan(for: markdown).images
}

@Test func mapsImageSpanWithMarkers() {
    let md = "![alt](a.png)"
    #expect(ranges(of: .image, in: md) == [NSRange(location: 0, length: 13)])
    let markers = ranges(of: .syntaxMarker, in: md)
    #expect(markers.contains(NSRange(location: 0, length: 2)))   // "!["
    #expect(markers.contains(NSRange(location: 5, length: 8)))   // "](a.png)"
}

@Test func collectsImageReference() {
    let md = "before\n\n![結果](images/result.png)\n\nafter"
    let refs = imageReferences(in: md)
    #expect(refs.count == 1)
    #expect(refs[0].altText == "結果")
    #expect(refs[0].destination == "images/result.png")
    #expect(refs[0].range == NSRange(location: 8, length: 24))
    // paragraphRange は記法を含む行(末尾の改行込み)
    #expect(refs[0].paragraphRange == NSRange(location: 8, length: 25))
    #expect(refs[0].isInsideTable == false)
}

@Test func collectsEmptyAltImage() {
    let md = "![](a.png)"
    let refs = imageReferences(in: md)
    #expect(refs.count == 1)
    #expect(refs[0].altText.isEmpty)
    #expect(refs[0].destination == "a.png")
    // alt が空でも "![" と "](a.png)" はマーカー化される
    let markers = ranges(of: .syntaxMarker, in: md)
    #expect(markers.contains(NSRange(location: 0, length: 2)))
    #expect(markers.contains(NSRange(location: 2, length: 8)))
}

@Test func collectsMultipleImagesInOneParagraph() {
    let md = "![a](1.png) と ![b](2.png)"
    let refs = imageReferences(in: md)
    #expect(refs.count == 2)
    #expect(refs.map(\.destination) == ["1.png", "2.png"])
    #expect(refs[0].paragraphRange == refs[1].paragraphRange)
}

@Test func imageInsideCodeBlockIsNotCollected() {
    let md = "```\n![a](1.png)\n```"
    #expect(imageReferences(in: md).isEmpty)
    #expect(ranges(of: .image, in: md).isEmpty)
}

@Test func imageInsideTableIsFlagged() {
    let md = "| a |\n|---|\n| ![i](1.png) |"
    let refs = imageReferences(in: md)
    #expect(refs.count == 1)
    #expect(refs[0].isInsideTable == true)
}

@Test func emptyDestinationImageIsCollected() {
    let md = "![alt]()"
    let refs = imageReferences(in: md)
    #expect(refs.count == 1)
    #expect(refs[0].destination.isEmpty)
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: FAIL(`.image` スパンが空 / `images` が空)

- [ ] **Step 3: 実装**

`Sources/LapermCore/HighlightMapper.swift` を変更。

(a) `plan(for:in:)` を images 対応に:

```swift
    static func plan(for document: Document, in text: String) -> HighlightPlan {
        var visitor = Visitor(converter: SourceLocationConverter(text: text), text: text as NSString)
        visitor.visit(document)
        // 適用順: ブロック → インライン → マーカー
        return HighlightPlan(
            spans: visitor.blockSpans + visitor.inlineSpans + visitor.markerSpans,
            images: visitor.imageReferences
        )
    }
```

(b) `Visitor` にプロパティを追加:

```swift
        var imageReferences: [ImageReference] = []
        private var tableDepth = 0
```

(c) `visitTable` の `descendInto(table)` をテーブル深度の追跡で挟む:

```swift
            tableDepth += 1
            descendInto(table)
            tableDepth -= 1
```

(d) `visitLink` の下に `visitImage` を追加:

```swift
        mutating func visitImage(_ image: Markdown.Image) {
            if let range = nsRange(of: image), range.length >= 2 {
                inlineSpans.append(HighlightSpan(range: range, kind: .image))
                appendImageMarkers(in: range, image: image)
                imageReferences.append(ImageReference(
                    altText: plainAltText(of: image),
                    destination: image.source ?? "",
                    range: range,
                    paragraphRange: text.paragraphRange(for: range),
                    isInsideTable: tableDepth > 0
                ))
            }
            descendInto(image)
        }
```

(e) ヘルパーセクションに追加:

```swift
        /// 画像記法のマーカー: 先頭の "![" と、alt 末尾から記法末尾まで
        /// (インライン形式 "](url)" と参照形式 "][ref]" の両方をカバーする)。
        private mutating func appendImageMarkers(in range: NSRange, image: Markdown.Image) {
            markerSpans.append(HighlightSpan(
                range: NSRange(location: range.location, length: 2),
                kind: .syntaxMarker
            ))
            var altEnd = range.location + 2
            for child in image.children {
                if let childRange = nsRange(of: child) {
                    altEnd = max(altEnd, NSMaxRange(childRange))
                }
            }
            if altEnd < NSMaxRange(range) {
                markerSpans.append(HighlightSpan(
                    range: NSRange(location: altEnd, length: NSMaxRange(range) - altEnd),
                    kind: .syntaxMarker
                ))
            }
        }

        /// alt テキストのプレーンテキスト化(強調などの装飾を剥がして連結)。
        private func plainAltText(of image: Markdown.Image) -> String {
            var result = ""
            func collect(_ markup: Markup) {
                if let textNode = markup as? Markdown.Text { result += textNode.string }
                for child in markup.children { collect(child) }
            }
            collect(image)
            return result
        }
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add Sources/LapermCore/HighlightMapper.swift Tests/LapermCoreTests/MarkdownParserTests.swift
git commit -m "feat(core): map image syntax to spans and collect ImageReferences

Task 2 of image-preview plan
Task context: 画像プレビュー機能の実装 (docs/superpowers/specs/2026-07-16-image-preview-design.md)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: ImageURLResolver

**Files:**
- Create: `Sources/LapermCore/ImageURLResolver.swift`
- Test: `Tests/LapermCoreTests/ImageURLResolverTests.swift`(新規)

**Interfaces:**
- Consumes: なし
- Produces: `ImageURLResolver.resolve(destination: String, baseURL: URL?) -> URL?`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermCoreTests/ImageURLResolverTests.swift` を新規作成:

```swift
import Foundation
import Testing
@testable import LapermCore

private let base = URL(filePath: "/docs/", directoryHint: .isDirectory)

@Test(arguments: [
    // (destination, baseURL あり?, 期待される絶対 URL 文字列 or nil)
    ("https://example.com/a.png", true, "https://example.com/a.png"),
    ("http://example.com/a.png", false, "http://example.com/a.png"),
    ("file:///tmp/a.png", false, "file:///tmp/a.png"),
    ("/tmp/a.png", false, "file:///tmp/a.png"),
    ("images/a.png", true, "file:///docs/images/a.png"),
    ("images/a.png", false, nil),      // 相対パスは baseURL なしでは解決不能
    ("", true, nil),                   // 空文字列
    ("ftp://example.com/a.png", true, nil),  // 未対応スキーム
])
func resolves(destination: String, hasBase: Bool, expected: String?) {
    let url = ImageURLResolver.resolve(destination: destination, baseURL: hasBase ? base : nil)
    #expect(url?.absoluteString == expected)
}

@Test func resolvesJapaneseRelativePath() {
    let url = ImageURLResolver.resolve(destination: "画像/図.png", baseURL: base)
    #expect(url?.isFileURL == true)
    #expect(url?.lastPathComponent == "図.png")
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: FAIL(`ImageURLResolver` 未定義のコンパイルエラー)

- [ ] **Step 3: 実装**

`Sources/LapermCore/ImageURLResolver.swift` を新規作成:

```swift
import Foundation

/// 画像記法の URL 文字列を読み込み可能な URL へ解決する純粋関数。
public enum ImageURLResolver {
    /// - http / https / file スキーム付き → そのまま
    /// - "/" 始まりの絶対パス → file URL
    /// - 相対パス → baseURL に対して解決(baseURL が nil なら解決不能)
    /// - 空文字列・未対応スキーム → nil
    public static func resolve(destination: String, baseURL: URL?) -> URL? {
        guard !destination.isEmpty else { return nil }
        // スキーム判定は URL(string:) に頼らず自前で行う。日本語やスペースを含む
        // 相対パスは URL(string:) が nil を返すため、そちらを先にすると誤判定する。
        if let colon = destination.firstIndex(of: ":") {
            let scheme = destination[..<colon].lowercased()
            switch scheme {
            case "http", "https", "file":
                return URL(string: destination)
            default:
                return nil
            }
        }
        if destination.hasPrefix("/") {
            return URL(filePath: destination)
        }
        guard let baseURL else { return nil }
        return URL(filePath: destination, relativeTo: baseURL).absoluteURL
    }
}
```

注意: `URL(string:)` は日本語を含む http URL では nil になりうるが、その場合は解決不能(nil)として扱う(v1 の割り切り。パーセントエンコード済み URL は通る)。

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add Sources/LapermCore/ImageURLResolver.swift Tests/LapermCoreTests/ImageURLResolverTests.swift
git commit -m "feat(core): add ImageURLResolver

Task 3 of image-preview plan
Task context: 画像プレビュー機能の実装 (docs/superpowers/specs/2026-07-16-image-preview-design.md)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: ImagePreviewOptions / ImageLoader / テーマ

**Files:**
- Create: `Sources/Laperm/ImagePreviewOptions.swift`
- Create: `Sources/Laperm/ImageLoader.swift`
- Modify: `Sources/Laperm/MarkdownTheme.swift`(default テーマに `.image` スタイル追加)
- Test: `Tests/LapermTests/ImagePreviewControllerTests.swift`(新規 — このタスクではローダーのテストのみ)

**Interfaces:**
- Consumes: なし
- Produces:
  - `ImagePreviewOptions(isEnabled:baseURL:maxHeight:allowsRemoteImages:)`(Equatable/Sendable、デフォルト `isEnabled: true, baseURL: nil, maxHeight: 320, allowsRemoteImages: false`)
  - `@MainActor public protocol ImageLoader: AnyObject { func loadImage(for url: URL) async throws -> NSImage }`
  - `DefaultImageLoader`(NSCache キャッシュ内蔵)
  - `ImageLoadError.decodingFailed`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermTests/ImagePreviewControllerTests.swift` を新規作成:

```swift
import AppKit
import Foundation
import Testing
@testable import Laperm

/// テスト用の PNG データ(width×height の単色画像)
func makePNGData(width: Int, height: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// 一時ディレクトリに PNG を書き出して URL を返す
func writeTempPNG(name: String, width: Int = 100, height: Int = 50) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("LapermTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try makePNGData(width: width, height: height).write(to: url)
    return url
}

@Test @MainActor func defaultLoaderLoadsLocalPNG() async throws {
    let url = try writeTempPNG(name: "a.png", width: 100, height: 50)
    let image = try await DefaultImageLoader().loadImage(for: url)
    #expect(image.size.width == 100)
    #expect(image.size.height == 50)
}

@Test @MainActor func defaultLoaderThrowsOnBrokenData() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("LapermTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("broken.png")
    try Data([0x00, 0x01, 0x02]).write(to: url)
    await #expect(throws: (any Error).self) {
        _ = try await DefaultImageLoader().loadImage(for: url)
    }
}

@Test @MainActor func defaultLoaderThrowsOnMissingFile() async throws {
    let url = URL(filePath: "/nonexistent/laperm-missing.png")
    await #expect(throws: (any Error).self) {
        _ = try await DefaultImageLoader().loadImage(for: url)
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: FAIL(`DefaultImageLoader` 未定義のコンパイルエラー)

- [ ] **Step 3: 実装**

`Sources/Laperm/ImagePreviewOptions.swift` を新規作成:

```swift
import Foundation

/// 画像プレビューの設定。
public struct ImagePreviewOptions: Equatable, Sendable {
    /// プレビュー表示の有効/無効(無効時は構文ハイライトのみ)
    public var isEnabled: Bool
    /// 相対パスの解決基準ディレクトリ。nil の場合、相対パスの画像は失敗表示になる。
    public var baseURL: URL?
    /// プレビューの最大高さ(pt)。原寸がこれを超える場合はアスペクト比を保って縮小。
    public var maxHeight: CGFloat
    /// http(s) 画像のロード許可。プライバシー配慮でデフォルト false(不許可時は失敗表示)。
    public var allowsRemoteImages: Bool

    public init(
        isEnabled: Bool = true,
        baseURL: URL? = nil,
        maxHeight: CGFloat = 320,
        allowsRemoteImages: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.maxHeight = maxHeight
        self.allowsRemoteImages = allowsRemoteImages
    }
}
```

`Sources/Laperm/ImageLoader.swift` を新規作成:

```swift
import AppKit
import ImageIO

/// 画像の取得・デコードを差し替え可能にするプロトコル。
/// NSImage は Sendable でないため @MainActor プロトコルとし、実装側は
/// ダウンロード・デコードを Sendable な型(Data / CGImage)でバックグラウンド処理してから
/// main で NSImage 化すること(DefaultImageLoader が参照実装)。
@MainActor
public protocol ImageLoader: AnyObject {
    func loadImage(for url: URL) async throws -> NSImage
}

public enum ImageLoadError: Error {
    case decodingFailed
}

/// 内蔵ローダー。file URL はローカル読み込み、http(s) は URLSession。
/// メモリキャッシュ(NSCache)付き。デコードまで detached タスクで行い、
/// メインスレッドをブロックしない。
@MainActor
public final class DefaultImageLoader: ImageLoader {
    private let cache = NSCache<NSURL, NSImage>()

    public init() {}

    public func loadImage(for url: URL) async throws -> NSImage {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let cgImage = try await Self.decode(url: url)
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    /// 取得とデコードをバックグラウンドで行い、Sendable な CGImage で受け渡す。
    private static func decode(url: URL) async throws -> CGImage {
        let data: Data
        if url.isFileURL {
            data = try await Task.detached(priority: .utility) {
                try Data(contentsOf: url)
            }.value
        } else {
            (data, _) = try await URLSession.shared.data(from: url)
        }
        return try await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw ImageLoadError.decodingFailed }
            return image
        }.value
    }
}
```

`Sources/Laperm/MarkdownTheme.swift` — default テーマの `styles[.link] = ...` の下に追加:

```swift
        styles[.image] = Style(foregroundColor: .linkColor)
```

注意: CGImage のピクセル寸法をそのままポイントとして使う(高 DPI 画像は原寸の 2 倍で扱われるが、maxHeight クランプで実害を抑える v1 の割り切り)。

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add Sources/Laperm Tests/LapermTests/ImagePreviewControllerTests.swift
git commit -m "feat(ui): add ImagePreviewOptions, ImageLoader protocol and DefaultImageLoader

Task 4 of image-preview plan
Task context: 画像プレビュー機能の実装 (docs/superpowers/specs/2026-07-16-image-preview-design.md)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: ImagePreviewController(状態機械・ロード管理)

**Files:**
- Create: `Sources/Laperm/ImagePreviewController.swift`
- Test: `Tests/LapermTests/ImagePreviewControllerTests.swift`(追記)

**Interfaces:**
- Consumes: `ImageReference`(Task 1)、`ImageURLResolver`(Task 3)、`ImageLoader` / `ImagePreviewOptions`(Task 4)
- Produces(internal、Task 6/7 が消費):
  - `ImagePreviewController`(@MainActor final class)
  - `enum State: Equatable { case loading, loaded(NSImage), failed }`
  - `var options: ImagePreviewOptions` / `var loader: any ImageLoader` / `var onStateChange: (() -> Void)?`
  - `private(set) var references: [ImageReference]`(有効時のみ、テーブル内を除外済み)
  - `func update(references: [ImageReference])`
  - `func resetLoads()`
  - `func state(for reference: ImageReference) -> State?`
  - `func displaySize(for reference: ImageReference, containerWidth: CGFloat) -> CGSize`
  - `func reservedHeights(containerWidth: CGFloat) -> [NSRange: CGFloat]`
  - `static let loadingHeight: CGFloat = 80` / `failedHeight: CGFloat = 44` / `padding: CGFloat = 8`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermTests/ImagePreviewControllerTests.swift` に追記:

```swift
import LapermCore

/// 完了タイミングを外から制御できるモックローダー
@MainActor
final class MockImageLoader: ImageLoader {
    var pending: [(url: URL, continuation: CheckedContinuation<NSImage, any Error>)] = []
    var loadCount = 0

    func loadImage(for url: URL) async throws -> NSImage {
        loadCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending.append((url, continuation))
        }
    }

    func finishAll(with result: Result<NSImage, any Error>) {
        let waiting = pending
        pending = []
        for entry in waiting { entry.continuation.resume(with: result) }
    }
}

private func makeReference(
    destination: String, location: Int = 0, isInsideTable: Bool = false
) -> ImageReference {
    ImageReference(
        altText: "alt", destination: destination,
        range: NSRange(location: location, length: 10),
        paragraphRange: NSRange(location: location, length: 11),
        isInsideTable: isInsideTable)
}

/// 非同期の状態遷移を待つヘルパー
@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
}

@Test @MainActor func startsLoadingAndTransitionsToLoaded() async throws {
    let loader = MockImageLoader()
    let controller = ImagePreviewController()
    controller.loader = loader
    controller.options = ImagePreviewOptions(baseURL: URL(filePath: "/docs/"))
    var stateChanged = false
    controller.onStateChange = { stateChanged = true }

    let ref = makeReference(destination: "a.png")
    controller.update(references: [ref])
    #expect(controller.state(for: ref) == .loading)

    try await waitUntil { loader.pending.count == 1 }
    let image = NSImage(size: NSSize(width: 10, height: 10))
    loader.finishAll(with: .success(image))
    try await waitUntil { controller.state(for: ref) == .loaded(image) }
    #expect(stateChanged)
}

@Test @MainActor func failedLoadTransitionsToFailed() async throws {
    let loader = MockImageLoader()
    let controller = ImagePreviewController()
    controller.loader = loader
    controller.options = ImagePreviewOptions(baseURL: URL(filePath: "/docs/"))
    let ref = makeReference(destination: "a.png")
    controller.update(references: [ref])
    try await waitUntil { loader.pending.count == 1 }
    loader.finishAll(with: .failure(ImageLoadError.decodingFailed))
    try await waitUntil { controller.state(for: ref) == .failed }
}

@Test @MainActor func unresolvableDestinationFailsImmediately() {
    let controller = ImagePreviewController()  // baseURL なし
    let ref = makeReference(destination: "relative.png")
    controller.update(references: [ref])
    #expect(controller.state(for: ref) == .failed)
}

@Test @MainActor func remoteDisallowedFailsImmediately() {
    let controller = ImagePreviewController()  // allowsRemoteImages: false
    let ref = makeReference(destination: "https://example.com/a.png")
    controller.update(references: [ref])
    #expect(controller.state(for: ref) == .failed)
}

@Test @MainActor func remoteAllowedStartsLoading() {
    let controller = ImagePreviewController()
    controller.loader = MockImageLoader()
    controller.options = ImagePreviewOptions(allowsRemoteImages: true)
    let ref = makeReference(destination: "https://example.com/a.png")
    controller.update(references: [ref])
    #expect(controller.state(for: ref) == .loading)
}

@Test @MainActor func removedReferenceCancelsAndDiscardsResult() async throws {
    let loader = MockImageLoader()
    let controller = ImagePreviewController()
    controller.loader = loader
    controller.options = ImagePreviewOptions(baseURL: URL(filePath: "/docs/"))
    let ref = makeReference(destination: "a.png")
    controller.update(references: [ref])
    try await waitUntil { loader.pending.count == 1 }
    // 編集で画像が消えた
    controller.update(references: [])
    #expect(controller.state(for: ref) == nil)
    // 遅れて届いた結果は反映されない
    loader.finishAll(with: .success(NSImage(size: NSSize(width: 1, height: 1))))
    try await Task.sleep(for: .milliseconds(50))
    #expect(controller.state(for: ref) == nil)
}

@Test @MainActor func sameDestinationTwiceLoadsOnce() async throws {
    let loader = MockImageLoader()
    let controller = ImagePreviewController()
    controller.loader = loader
    controller.options = ImagePreviewOptions(baseURL: URL(filePath: "/docs/"))
    let ref1 = makeReference(destination: "a.png", location: 0)
    let ref2 = makeReference(destination: "a.png", location: 100)
    controller.update(references: [ref1, ref2])
    try await waitUntil { loader.pending.count == 1 }
    #expect(loader.loadCount == 1)
}

@Test @MainActor func tableImagesAndDisabledOptionAreFilteredOut() {
    let controller = ImagePreviewController()
    controller.options = ImagePreviewOptions(baseURL: URL(filePath: "/docs/"))
    let tableRef = makeReference(destination: "a.png", isInsideTable: true)
    controller.update(references: [tableRef])
    #expect(controller.references.isEmpty)

    controller.options = ImagePreviewOptions(isEnabled: false, baseURL: URL(filePath: "/docs/"))
    controller.update(references: [makeReference(destination: "b.png")])
    #expect(controller.references.isEmpty)
}

@Test @MainActor func displaySizeFitsWidthAndMaxHeight() {
    let controller = ImagePreviewController()
    controller.loader = MockImageLoader()  // 実 IO を避けて状態を決定的にする
    controller.options = ImagePreviewOptions(baseURL: URL(filePath: "/docs/"), maxHeight: 320)
    let ref = makeReference(destination: "a.png")
    controller.update(references: [ref])
    // loading プレースホルダー
    #expect(controller.displaySize(for: ref, containerWidth: 500).height
        == ImagePreviewController.loadingHeight)

    // 原寸 1000×400 → 幅 500 にフィットで 500×200
    controller.setStateForTesting(.loaded(NSImage(size: NSSize(width: 1000, height: 400))),
                                  destination: "a.png")
    #expect(controller.displaySize(for: ref, containerWidth: 500)
        == CGSize(width: 500, height: 200))

    // 原寸 100×800 → maxHeight 320 で 40×320
    controller.setStateForTesting(.loaded(NSImage(size: NSSize(width: 100, height: 800))),
                                  destination: "a.png")
    #expect(controller.displaySize(for: ref, containerWidth: 500)
        == CGSize(width: 40, height: 320))

    // 小さい画像は拡大しない
    controller.setStateForTesting(.loaded(NSImage(size: NSSize(width: 60, height: 30))),
                                  destination: "a.png")
    #expect(controller.displaySize(for: ref, containerWidth: 500)
        == CGSize(width: 60, height: 30))
}

@Test @MainActor func reservedHeightsSumImagesPerParagraph() {
    let controller = ImagePreviewController()
    controller.loader = MockImageLoader()  // 実 IO を避けて状態を決定的にする
    controller.options = ImagePreviewOptions(baseURL: URL(filePath: "/docs/"))
    let ref1 = makeReference(destination: "a.png", location: 0)
    var ref2 = makeReference(destination: "b.png", location: 12)
    ref2.paragraphRange = ref1.paragraphRange  // 同一段落
    controller.update(references: [ref1, ref2])
    controller.setStateForTesting(.loaded(NSImage(size: NSSize(width: 100, height: 50))),
                                  destination: "a.png")
    // a: 50 + 8, b(loading): 80 + 8
    let heights = controller.reservedHeights(containerWidth: 500)
    #expect(heights == [ref1.paragraphRange: 50 + 8 + 80 + 8])
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: FAIL(`ImagePreviewController` 未定義のコンパイルエラー)

- [ ] **Step 3: 実装**

`Sources/Laperm/ImagePreviewController.swift` を新規作成:

```swift
import AppKit
import LapermCore

/// 画像プレビューの状態機械。destination(URL 文字列)単位でロードを管理し、
/// 出現箇所(ImageReference)単位で表示サイズ・予約高さを提供する。
/// レンジではなく destination をロードのキーにするのは、画像より前方の編集で
/// レンジが平行移動するたびに再ロードが走るのを避けるため。
@MainActor
final class ImagePreviewController {
    enum State: Equatable {
        case loading
        case loaded(NSImage)
        case failed
    }

    static let loadingHeight: CGFloat = 80
    static let failedHeight: CGFloat = 44
    /// 画像 1 枚あたりの上下パディング合計
    static let padding: CGFloat = 8
    /// プレースホルダー(loading / failed)の幅上限
    static let placeholderMaxWidth: CGFloat = 240

    var options = ImagePreviewOptions()
    var loader: any ImageLoader = DefaultImageLoader()
    /// ロード完了・失敗で予約高さが変わりうるときに呼ばれる(view が spacing を再適用する)
    var onStateChange: (() -> Void)?

    /// 現在プレビュー対象の参照(isEnabled かつテーブル外のみ)
    private(set) var references: [ImageReference] = []
    private var states: [String: State] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    /// flush 後に最新の参照一覧を渡す。destination 集合の差分でロードを開始/破棄する。
    func update(references newReferences: [ImageReference]) {
        references = options.isEnabled ? newReferences.filter { !$0.isInsideTable } : []
        let needed = Set(references.map(\.destination))
        for destination in Array(states.keys) where !needed.contains(destination) {
            tasks[destination]?.cancel()
            tasks[destination] = nil
            states[destination] = nil
        }
        for destination in needed where states[destination] == nil {
            startLoad(destination: destination)
        }
    }

    /// baseURL / allowsRemoteImages / loader 変更後に呼ぶ。全状態を破棄して再ロードする。
    func resetLoads() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        states = [:]
        let current = references
        references = []
        update(references: current)
    }

    func state(for reference: ImageReference) -> State? {
        states[reference.destination]
    }

    /// 1 画像ぶんの表示サイズ(パディング除く)。containerWidth と maxHeight にフィット。
    func displaySize(for reference: ImageReference, containerWidth: CGFloat) -> CGSize {
        switch states[reference.destination] {
        case .loading, .none:
            return CGSize(
                width: min(containerWidth, Self.placeholderMaxWidth),
                height: Self.loadingHeight)
        case .failed:
            return CGSize(
                width: min(containerWidth, Self.placeholderMaxWidth),
                height: Self.failedHeight)
        case .loaded(let image):
            let size = image.size
            guard size.width > 0, size.height > 0, containerWidth > 0 else {
                return CGSize(
                    width: min(containerWidth, Self.placeholderMaxWidth),
                    height: Self.failedHeight)
            }
            let scale = min(1, containerWidth / size.width, options.maxHeight / size.height)
            return CGSize(width: size.width * scale, height: size.height * scale)
        }
    }

    /// 段落レンジごとの予約高さ(paragraphSpacing 値)。段落内の全画像 + 各 padding。
    func reservedHeights(containerWidth: CGFloat) -> [NSRange: CGFloat] {
        var result: [NSRange: CGFloat] = [:]
        for reference in references {
            let height = displaySize(for: reference, containerWidth: containerWidth).height
            result[reference.paragraphRange, default: 0] += height + Self.padding
        }
        return result
    }

    private func startLoad(destination: String) {
        guard let url = ImageURLResolver.resolve(
                destination: destination, baseURL: options.baseURL),
              url.isFileURL || options.allowsRemoteImages
        else {
            states[destination] = .failed
            return
        }
        states[destination] = .loading
        let loader = self.loader
        tasks[destination] = Task { [weak self] in
            let result: State
            do {
                result = .loaded(try await loader.loadImage(for: url))
            } catch {
                result = .failed
            }
            guard let self, !Task.isCancelled else { return }
            self.tasks[destination] = nil
            // 編集レース対策: この destination がまだ loading のときだけ反映する
            // (update / resetLoads で破棄済みなら何もしない)
            guard self.states[destination] == .loading else { return }
            self.states[destination] = result
            self.onStateChange?()
        }
    }

    /// テスト用: 状態を直接注入する
    func setStateForTesting(_ state: State, destination: String) {
        states[destination] = state
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add Sources/Laperm/ImagePreviewController.swift Tests/LapermTests/ImagePreviewControllerTests.swift
git commit -m "feat(ui): add ImagePreviewController load state machine

Task 5 of image-preview plan
Task context: 画像プレビュー機能の実装 (docs/superpowers/specs/2026-07-16-image-preview-design.md)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: スペーシング適用と MarkdownTextView 統合

**Files:**
- Modify: `Sources/Laperm/ImagePreviewController.swift`(`applySpacings` 追加)
- Modify: `Sources/Laperm/MarkdownTextView.swift`(controller 保持・updateImagePreviews)
- Test: `Tests/LapermTests/ImagePreviewControllerTests.swift`(追記)

**Interfaces:**
- Consumes: `ImagePreviewController`(Task 5)、`Highlighter.currentPlan.images`
- Produces:
  - `ImagePreviewController.applySpacings(contentStorage: NSTextContentStorage, containerWidth: CGFloat)`
  - `ImagePreviewController.spacingAttribute`(`NSAttributedString.Key("laperm.imageSpacing")`)
  - `MarkdownTextView.imagePreviewController`(internal let)と `updateImagePreviews()`(highlightAll / highlightNow から呼ばれる)

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermTests/ImagePreviewControllerTests.swift` に追記:

```swift
@Test @MainActor func applySpacingsSetsParagraphStyleAndMarker() {
    let contentStorage = NSTextContentStorage()
    let storage = NSTextStorage(string: "![a](a.png)\nnext line")
    contentStorage.textStorage = storage
    let controller = ImagePreviewController()
    controller.options = ImagePreviewOptions(baseURL: URL(filePath: "/docs/"))
    var ref = makeReference(destination: "a.png")
    ref.paragraphRange = NSRange(location: 0, length: 12)  // "![a](a.png)\n"
    controller.update(references: [ref])  // → loading (高さ 80 + 8)

    controller.applySpacings(contentStorage: contentStorage, containerWidth: 500)

    let style = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
        as? NSParagraphStyle
    #expect(style?.paragraphSpacing == 88)
    let marker = storage.attribute(
        ImagePreviewController.spacingAttribute, at: 0, effectiveRange: nil) as? CGFloat
    #expect(marker == 88)
    // 隣の段落には付かない
    #expect(storage.attribute(.paragraphStyle, at: 15, effectiveRange: nil) == nil)
}

@Test @MainActor func applySpacingsRemovesStaleSpacing() {
    let contentStorage = NSTextContentStorage()
    let storage = NSTextStorage(string: "![a](a.png)\nnext line")
    contentStorage.textStorage = storage
    let controller = ImagePreviewController()
    controller.options = ImagePreviewOptions(baseURL: URL(filePath: "/docs/"))
    var ref = makeReference(destination: "a.png")
    ref.paragraphRange = NSRange(location: 0, length: 12)
    controller.update(references: [ref])
    controller.applySpacings(contentStorage: contentStorage, containerWidth: 500)

    // 画像が消えたら spacing も消える
    controller.update(references: [])
    controller.applySpacings(contentStorage: contentStorage, containerWidth: 500)
    #expect(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) == nil)
    #expect(storage.attribute(
        ImagePreviewController.spacingAttribute, at: 0, effectiveRange: nil) == nil)
}

@Test @MainActor func applySpacingsIsIdempotentWhenUnchanged() {
    let contentStorage = NSTextContentStorage()
    let storage = NSTextStorage(string: "![a](a.png)\nnext")
    contentStorage.textStorage = storage
    let controller = ImagePreviewController()
    controller.options = ImagePreviewOptions(baseURL: URL(filePath: "/docs/"))
    var ref = makeReference(destination: "a.png")
    ref.paragraphRange = NSRange(location: 0, length: 12)
    controller.update(references: [ref])
    controller.applySpacings(contentStorage: contentStorage, containerWidth: 500)

    // 変化がなければ 2 回目は編集イベントを発生させない
    var edited = false
    let observer = NotificationCenter.default.addObserver(
        forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
    ) { _ in edited = true }
    defer { NotificationCenter.default.removeObserver(observer) }
    controller.applySpacings(contentStorage: contentStorage, containerWidth: 500)
    #expect(!edited)
}

@Test @MainActor func textViewAppliesSpacingForLocalImageEndToEnd() async throws {
    let url = try writeTempPNG(name: "sample.png", width: 100, height: 50)
    let textView = MarkdownTextView()
    // ヘッドレスでは frame がゼロのまま。コンテナ幅がゼロだと loaded サイズが
    // プレースホルダー扱いになるため、明示的に幅を与える。
    textView.setFrameSize(NSSize(width: 500, height: 300))
    textView.imagePreviewController.options =
        ImagePreviewOptions(baseURL: url.deletingLastPathComponent())
    textView.string = "![sample](sample.png)\n\nafter"
    textView.highlightAll()
    guard let storage = textView.textStorage else {
        Issue.record("textStorage missing")
        return
    }
    // 非同期ロード完了 → onStateChange → spacing 再適用を待つ
    try await waitUntil {
        let style = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle
        return style?.paragraphSpacing == 50 + ImagePreviewController.padding
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: FAIL(`applySpacings` / `imagePreviewController` 未定義のコンパイルエラー)

- [ ] **Step 3: 実装**

`Sources/Laperm/ImagePreviewController.swift` に追加:

```swift
    /// 適用済みスペーシングの発見用マーカー属性。除去時に「どこに適用したか」を
    /// 座標追跡なしで storage 自身から取り出せるようにする(属性は編集に自動追随する)。
    static let spacingAttribute = NSAttributedString.Key("laperm.imageSpacing")

    /// 予約高さを paragraphSpacing として textStorage に反映する。
    /// 実属性編集なので TextKit2 の通常経路で再レイアウトされる
    /// (BlockFragment のような recordEditAction ワークアラウンドは不要)。
    /// 属性のみの編集は .editedAttributes しか発火しないため didProcessEditing の
    /// 文字編集ガードと組み合わせて再入しない。
    func applySpacings(contentStorage: NSTextContentStorage, containerWidth: CGFloat) {
        guard let storage = contentStorage.textStorage else { return }
        var wanted = reservedHeights(containerWidth: containerWidth)
        // 文書外にはみ出た段落レンジは適用しない(パース結果と storage の不整合の防波堤)
        wanted = wanted.filter { NSMaxRange($0.key) <= storage.length }
        var stale: [NSRange] = []
        var unchanged: Set<NSRange> = []
        storage.enumerateAttribute(
            Self.spacingAttribute, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let applied = value as? CGFloat else { return }
            if wanted[range] == applied {
                unchanged.insert(range)
            } else {
                stale.append(range)
            }
        }
        guard !stale.isEmpty || wanted.count > unchanged.count else { return }
        contentStorage.performEditingTransaction {
            for range in stale {
                storage.removeAttribute(.paragraphStyle, range: range)
                storage.removeAttribute(Self.spacingAttribute, range: range)
            }
            for (range, height) in wanted where !unchanged.contains(range) {
                let style = NSMutableParagraphStyle()
                style.paragraphSpacing = height
                storage.addAttribute(.paragraphStyle, value: style, range: range)
                storage.addAttribute(Self.spacingAttribute, value: height, range: range)
            }
        }
    }
```

`Sources/Laperm/MarkdownTextView.swift` を変更。

(a) プロパティ追加(`fragmentProvider` の下):

```swift
    let imagePreviewController = ImagePreviewController()
```

(b) `configure()` の末尾に追加:

```swift
        imagePreviewController.onStateChange = { [weak self] in
            guard let self else { return }
            if self.hasMarkedText() {
                // IME 変換中は spacing 変更を遅延(highlightNow と同じガードに乗せる)
                self.scheduleHighlight()
            } else {
                self.updateImagePreviews()
            }
        }
```

(c) `highlightAll()` と `highlightNow()` の `updateBlockDecorations()` の直後にそれぞれ追加:

```swift
        updateImagePreviews()
```

(d) `updateBlockDecorations()` の下にメソッド追加:

```swift
    /// 画像プレビューの状態を最新プランに同期し、スペーシングを適用する。
    /// 注意: バックグラウンドパース経路では currentPlan の更新が非同期になるため、
    /// ブロック装飾と同様に 1 サイクル遅延する(v1 で許容済みの設計)。
    private func updateImagePreviews() {
        guard let contentStorage = textContentStorage else { return }
        imagePreviewController.update(references: markdownHighlighter.currentPlan.images)
        imagePreviewController.applySpacings(
            contentStorage: contentStorage, containerWidth: imageContainerWidth)
    }

    /// プレビューが使える幅 = テキストコンテナの実効幅(lineFragmentPadding を除く)
    var imageContainerWidth: CGFloat {
        guard let container = textContainer else { return max(0, bounds.width) }
        return max(0, container.size.width - container.lineFragmentPadding * 2)
    }
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: PASS(既存の Highlighter/MarkdownTextView テストにも影響がないこと。
Highlighter のリセット経路は `.font` の add と `.strikethroughStyle/.strikethroughColor` の
remove のみで `.paragraphStyle` に触れないため共存できる)

- [ ] **Step 5: コミット**

```bash
git add Sources/Laperm Tests/LapermTests
git commit -m "feat(ui): reserve preview space via paragraphSpacing

Task 6 of image-preview plan
Task context: 画像プレビュー機能の実装 (docs/superpowers/specs/2026-07-16-image-preview-design.md)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: オーバーレイビューとビューポート配置

**Files:**
- Create: `Sources/Laperm/ImagePreviewOverlayView.swift`
- Modify: `Sources/Laperm/MarkdownTextView.swift`(viewport フック・overlay 統合・幅変更追随)
- Test: `Tests/LapermTests/ImagePreviewLayoutTests.swift`(新規)

**Interfaces:**
- Consumes: `ImagePreviewController`(Task 5/6)
- Produces(internal):
  - `enum ImagePreviewLayout { static func itemFrames(references:sizes:fragmentFrame:leadingInset:padding:) -> [Item] }`、`struct Item: Equatable { var reference: ImageReference; var frame: CGRect }`
  - `final class ImagePreviewOverlayView: NSView` と `struct ImagePreviewOverlayEntry { var reference: ImageReference; var frame: NSRect; var state: ImagePreviewController.State }`、`func update(entries: [ImagePreviewOverlayEntry])`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermTests/ImagePreviewLayoutTests.swift` を新規作成:

```swift
import AppKit
import Foundation
import Testing
import LapermCore
@testable import Laperm

private func ref(location: Int, destination: String) -> ImageReference {
    ImageReference(
        altText: "alt", destination: destination,
        range: NSRange(location: location, length: 10),
        paragraphRange: NSRange(location: 0, length: 30))
}

@Test func stacksImagesBottomUpInSourceOrder() {
    // フラグメント高さ 200、うち予約領域 = (50+8) + (30+8) = 96
    let items = ImagePreviewLayout.itemFrames(
        references: [ref(location: 0, destination: "a.png"), ref(location: 12, destination: "b.png")],
        sizes: [CGSize(width: 100, height: 50), CGSize(width: 60, height: 30)],
        fragmentFrame: CGRect(x: 0, y: 0, width: 500, height: 200),
        leadingInset: 5,
        padding: 8)
    #expect(items.count == 2)
    // 1 枚目: 予約領域先頭(y = 200 - 96 = 104)+ padding/2
    #expect(items[0].frame == CGRect(x: 5, y: 108, width: 100, height: 50))
    // 2 枚目: 1 枚目のスロット(58)ぶん下
    #expect(items[1].frame == CGRect(x: 5, y: 166, width: 60, height: 30))
}

@Test func emptyReferencesYieldNoItems() {
    let items = ImagePreviewLayout.itemFrames(
        references: [], sizes: [],
        fragmentFrame: CGRect(x: 0, y: 0, width: 500, height: 20),
        leadingInset: 5, padding: 8)
    #expect(items.isEmpty)
}

@Test @MainActor func overlayReusesAndRemovesItemViews() {
    let overlay = ImagePreviewOverlayView()
    let reference = ref(location: 0, destination: "a.png")
    overlay.update(entries: [ImagePreviewOverlayEntry(
        reference: reference,
        frame: NSRect(x: 0, y: 0, width: 100, height: 50),
        state: .loading)])
    #expect(overlay.subviews.count == 1)
    let first = overlay.subviews[0]

    // 同じ参照の更新はビューを使い回す
    overlay.update(entries: [ImagePreviewOverlayEntry(
        reference: reference,
        frame: NSRect(x: 0, y: 10, width: 100, height: 50),
        state: .failed)])
    #expect(overlay.subviews.count == 1)
    #expect(overlay.subviews[0] === first)
    #expect(overlay.subviews[0].frame.origin.y == 10)

    // ビューポート外に出たら取り外す
    overlay.update(entries: [])
    #expect(overlay.subviews.isEmpty)
}

@Test @MainActor func overlayIsNotHitTestable() {
    let overlay = ImagePreviewOverlayView()
    #expect(overlay.hitTest(NSPoint(x: 1, y: 1)) == nil)
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: FAIL(`ImagePreviewLayout` / `ImagePreviewOverlayView` 未定義のコンパイルエラー)

- [ ] **Step 3: 実装**

`Sources/Laperm/ImagePreviewOverlayView.swift` を新規作成:

```swift
import AppKit
import LapermCore

/// 予約領域(paragraphSpacing)内に画像を積むレイアウト計算。純粋関数。
enum ImagePreviewLayout {
    struct Item: Equatable {
        var reference: ImageReference
        var frame: CGRect
    }

    /// fragmentFrame(テキストコンテナ座標)末尾の予約領域に、段落内の画像を
    /// ソース順で縦に積む。各画像はスロット(高さ + padding)の中央に置く。
    static func itemFrames(
        references: [ImageReference],
        sizes: [CGSize],
        fragmentFrame: CGRect,
        leadingInset: CGFloat,
        padding: CGFloat
    ) -> [Item] {
        let totalHeight = sizes.reduce(0) { $0 + $1.height + padding }
        var y = fragmentFrame.maxY - totalHeight
        var items: [Item] = []
        for (reference, size) in zip(references, sizes) {
            items.append(Item(
                reference: reference,
                frame: CGRect(
                    x: fragmentFrame.minX + leadingInset,
                    y: y + padding / 2,
                    width: size.width,
                    height: size.height)))
            y += size.height + padding
        }
        return items
    }
}

/// オーバーレイに渡す 1 画像ぶんの表示指示(frame は textView 座標)。
struct ImagePreviewOverlayEntry {
    var reference: ImageReference
    var frame: NSRect
    var state: ImagePreviewController.State
}

/// 画像・プレースホルダー・エラー枠を載せる非ヒットテストのオーバーレイ。
/// 将来はアイテムビューの中身を AVPlayerView 等に差し替えて動画に拡張する。
final class ImagePreviewOverlayView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var itemViews: [ImageReference: ImagePreviewItemView] = [:]

    /// ビューポートレイアウトパスの結果を反映する。ビューは参照単位で使い回し、
    /// 一覧にない参照(ビューポート外・消滅)は取り外す。
    func update(entries: [ImagePreviewOverlayEntry]) {
        var seen: Set<ImageReference> = []
        for entry in entries {
            seen.insert(entry.reference)
            let view: ImagePreviewItemView
            if let existing = itemViews[entry.reference] {
                view = existing
            } else {
                view = ImagePreviewItemView()
                itemViews[entry.reference] = view
                addSubview(view)
            }
            view.frame = entry.frame
            view.state = entry.state
            view.altText = entry.reference.altText
        }
        for (key, view) in itemViews where !seen.contains(key) {
            view.removeFromSuperview()
            itemViews[key] = nil
        }
    }
}

/// 1 画像ぶんの表示(実画像 / ⏳ プレースホルダー / ⚠ エラー枠)。
final class ImagePreviewItemView: NSView {
    var state: ImagePreviewController.State = .loading {
        didSet { if state != oldValue { needsDisplay = true } }
    }
    var altText: String = "" {
        didSet { if altText != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        switch state {
        case .loaded(let image):
            image.draw(
                in: bounds, from: .zero, operation: .sourceOver,
                fraction: 1, respectFlipped: true, hints: nil)
        case .loading:
            drawPlaceholder(text: "⏳")
        case .failed:
            drawPlaceholder(text: "⚠ " + altText)
        }
    }

    private func drawPlaceholder(text: String) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.quaternarySystemFill.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: 12, y: (bounds.height - size.height) / 2),
            withAttributes: attributes)
    }
}
```

`Sources/Laperm/MarkdownTextView.swift` を変更。

(a) プロパティ追加(`insertionPointOverlay` の下):

```swift
    private let imageOverlay = ImagePreviewOverlayView()
    private var collectedImageEntries: [ImagePreviewOverlayEntry] = []
    private var lastImageContainerWidth: CGFloat = 0
```

(b) `configure()` に追加(onStateChange 設定の前):

```swift
        imageOverlay.autoresizingMask = [.width, .height]
        addSubview(imageOverlay)
```

(c) `layout()` を変更(既存の `updateInsertionPointOverlay()` 呼び出しの後に追加):

```swift
        imageOverlay.frame = bounds
        if imageContainerWidth != lastImageContainerWidth {
            lastImageContainerWidth = imageContainerWidth
            // 幅が変わると loaded 画像のフィット高さが変わるため spacing を再計算
            updateImagePreviews()
        }
```

(d) viewport 3 フックを拡張。`textViewportLayoutControllerWillLayout` の
`collectedLines.removeAll(...)` の直後に:

```swift
        collectedImageEntries.removeAll(keepingCapacity: true)
```

`textViewportLayoutController(_:configureRenderingSurfaceFor:)` の末尾
(gutter 用の guard より前、`super` 呼び出しの直後)に:

```swift
        collectImagePreviews(for: textLayoutFragment)
```

注意: 既存実装は `guard gutterView != nil` で早期 return するため、その **前** に
呼び出しを置くこと(ガター非表示でもプレビューは動く必要がある)。

`textViewportLayoutControllerDidLayout` の末尾に:

```swift
        imageOverlay.update(entries: collectedImageEntries)
```

(e) メソッド追加(`updateImagePreviews()` の下):

```swift
    /// このフラグメント(1 テキスト段落)に属する画像のオーバーレイ配置を収集する。
    private func collectImagePreviews(for fragment: NSTextLayoutFragment) {
        let references = imagePreviewController.references
        guard !references.isEmpty,
              let contentManager = textLayoutManager?.textContentManager,
              let elementRange = fragment.textElement?.elementRange
        else { return }
        let start = contentManager.offset(
            from: contentManager.documentRange.location, to: elementRange.location)
        let end = contentManager.offset(
            from: contentManager.documentRange.location, to: elementRange.endLocation)
        let paragraphReferences = references
            .filter { $0.paragraphRange.location >= start && $0.paragraphRange.location < end }
            .sorted { $0.range.location < $1.range.location }
        guard !paragraphReferences.isEmpty else { return }
        let width = imageContainerWidth
        let sizes = paragraphReferences.map {
            imagePreviewController.displaySize(for: $0, containerWidth: width)
        }
        let origin = textContainerOrigin
        let items = ImagePreviewLayout.itemFrames(
            references: paragraphReferences,
            sizes: sizes,
            fragmentFrame: fragment.layoutFragmentFrame,
            leadingInset: textContainer?.lineFragmentPadding ?? 0,
            padding: ImagePreviewController.padding)
        for item in items {
            guard let state = imagePreviewController.state(for: item.reference) else { continue }
            collectedImageEntries.append(ImagePreviewOverlayEntry(
                reference: item.reference,
                frame: item.frame.offsetBy(dx: origin.x, dy: origin.y),
                state: state))
        }
    }
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add Sources/Laperm Tests/LapermTests
git commit -m "feat(ui): place image previews via viewport layout overlay

Task 7 of image-preview plan
Task context: 画像プレビュー機能の実装 (docs/superpowers/specs/2026-07-16-image-preview-design.md)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: 公開 API(MarkdownTextView プロパティ / MarkdownEditorView modifier)

**Files:**
- Modify: `Sources/Laperm/MarkdownTextView.swift`(public プロパティ)
- Modify: `Sources/Laperm/MarkdownEditorView.swift`(modifier)
- Test: `Tests/LapermTests/MarkdownEditorViewTests.swift`(追記)

**Interfaces:**
- Consumes: Task 4〜7 の全部品
- Produces:
  - `MarkdownTextView.imagePreviewOptions: ImagePreviewOptions`(public)
  - `MarkdownTextView.imageLoader: any ImageLoader`(public)
  - `MarkdownEditorView.imagePreviewOptions(_:)` / `.imageLoader(_:)`(public modifier)

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermTests/MarkdownEditorViewTests.swift` に追記(既存テストのスタイルに合わせ、
`apply(to:)` を直接呼んで検証する):

```swift
@Test @MainActor func appliesImagePreviewOptionsAndLoader() {
    let loader = DefaultImageLoader()
    let options = ImagePreviewOptions(
        baseURL: URL(filePath: "/docs/"), maxHeight: 200, allowsRemoteImages: true)
    var text = "hello"
    let view = MarkdownEditorView(text: .init(get: { text }, set: { text = $0 }))
        .imagePreviewOptions(options)
        .imageLoader(loader)
    let textView = MarkdownTextView()
    view.apply(to: textView)
    #expect(textView.imagePreviewOptions == options)
    #expect(textView.imageLoader === loader)
}

@Test @MainActor func changingOptionsResetsLoadStates() {
    let textView = MarkdownTextView()
    textView.string = "![a](a.png)"
    textView.highlightAll()
    // baseURL なし → 相対パスは failed
    let ref = textView.imagePreviewController.references.first
    #expect(ref != nil)
    #expect(textView.imagePreviewController.state(for: ref!) == .failed)
    // baseURL を設定すると再解決されて loading になる(実在パスなのでロード開始)
    let dir = try! writeTempPNG(name: "a.png").deletingLastPathComponent()
    textView.imagePreviewOptions = ImagePreviewOptions(baseURL: dir)
    let newRef = textView.imagePreviewController.references.first
    #expect(newRef != nil)
    #expect(textView.imagePreviewController.state(for: newRef!) != .failed)
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: FAIL(`imagePreviewOptions` / `imageLoader` / modifier 未定義のコンパイルエラー)

- [ ] **Step 3: 実装**

`Sources/Laperm/MarkdownTextView.swift` — `insertionPointStyle` プロパティの下に追加:

```swift
    /// 画像プレビューの設定。baseURL / allowsRemoteImages の変更は全ロードをやり直す。
    public var imagePreviewOptions: ImagePreviewOptions {
        get { imagePreviewController.options }
        set {
            guard imagePreviewController.options != newValue else { return }
            imagePreviewController.options = newValue
            imagePreviewController.resetLoads()
            updateImagePreviews()
        }
    }

    /// 画像ローダー。差し替えると全ロードをやり直す。
    public var imageLoader: any ImageLoader {
        get { imagePreviewController.loader }
        set {
            guard imagePreviewController.loader !== newValue else { return }
            imagePreviewController.loader = newValue
            imagePreviewController.resetLoads()
            updateImagePreviews()
        }
    }
```

`Sources/Laperm/MarkdownEditorView.swift` を変更。

(a) stored プロパティ追加(`insertionPointStyle` の下):

```swift
    private var imagePreviewOptions = ImagePreviewOptions()
    private var imageLoader: (any ImageLoader)?
```

(b) modifier 追加(`insertionPointStyle(_:)` の下):

```swift
    /// 画像プレビューの設定(baseURL・最大高さ・リモート許可など)。
    public func imagePreviewOptions(_ options: ImagePreviewOptions) -> MarkdownEditorView {
        var copy = self
        copy.imagePreviewOptions = options
        return copy
    }

    /// 画像ローダーを差し替える(キャッシュ戦略・認証付き取得などの注入点)。
    public func imageLoader(_ loader: any ImageLoader) -> MarkdownEditorView {
        var copy = self
        copy.imageLoader = loader
        return copy
    }
```

(c) `apply(to:)` に追加:

```swift
        textView.imagePreviewOptions = imagePreviewOptions
        if let imageLoader { textView.imageLoader = imageLoader }
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: PASS(`imagePreviewOptions` setter は Equatable ガード、`imageLoader` setter は
同一性ガードがあるため、SwiftUI の update ごとの `apply(to:)` でロードがリセットされない)

- [ ] **Step 5: コミット**

```bash
git add Sources/Laperm Tests/LapermTests
git commit -m "feat(ui): expose image preview public API

Task 8 of image-preview plan
Task context: 画像プレビュー機能の実装 (docs/superpowers/specs/2026-07-16-image-preview-design.md)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Example アプリ + GUI 検証

**Files:**
- Modify: `Example/ExampleMacOS/ContentView.swift`

**Interfaces:**
- Consumes: `MarkdownEditorView.imagePreviewOptions(_:)`(Task 8)

- [ ] **Step 1: サンプル画像の生成とドキュメント追記**

`Example/ExampleMacOS/ContentView.swift` を変更。

(a) サンプル画像ディレクトリを用意するヘルパーをファイル末尾に追加:

```swift
/// Example 用のサンプル画像(単色 PNG)を一時ディレクトリに生成して、
/// そのディレクトリを imagePreviewOptions.baseURL として使う。
/// ContentView の stored property 初期化子(非分離コンテキスト)から呼ぶため
/// @MainActor は付けない(オフスクリーン描画のみでビュー階層に触れない)。
func makeSampleImageDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LapermExampleImages", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("sample.png")
    if !FileManager.default.fileExists(atPath: file.path) {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 180,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 320, height: 180).fill()
        NSColor.white.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0))
        path.line(to: NSPoint(x: 320, y: 180))
        path.move(to: NSPoint(x: 320, y: 0))
        path.line(to: NSPoint(x: 0, y: 180))
        path.lineWidth = 4
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }
    return directory
}
```

(b) `sampleDocument` に画像セクションを追加(既存セクションの末尾に):

```swift
## 画像

ローカル画像(表示される):

![サンプル](sample.png)

存在しないパス(エラー枠):

![見つからない画像](missing.png)

リモート画像(デフォルト不許可 → エラー枠):

![リモート](https://example.com/remote.png)
```

(c) `ContentView` の `MarkdownEditorView` に modifier を追加し、baseURL を渡す
(`ContentView` に `private let imageDirectory = makeSampleImageDirectory()` を追加):

```swift
                .imagePreviewOptions(.init(baseURL: imageDirectory))
```

- [ ] **Step 2: ライブラリのテストと Example のビルドを確認**

Run: `swift test`
Expected: PASS

Run: `xcodebuild -project Example/Example.xcodeproj -scheme ExampleMacOS build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: GUI 検証(computer use 必須 — CLAUDE.md の検証ポリシー)**

プロジェクトスキル `verifying-macos-gui`(`.claude/skills/verifying-macos-gui/SKILL.md`)に
従って、ビルドした Example アプリを実際に起動し、スクリーンショットで以下を確認する:

1. `![サンプル](sample.png)` の行の下にティール色のサンプル画像が表示されている
   (記法テキスト自体も残っている)
2. `missing.png` の行の下に「⚠ 見つからない画像」のエラー枠が表示されている
3. リモート URL の行の下にエラー枠が表示されている(デフォルト不許可)
4. 画像セクションより上にテキストを追記すると、プレビューが記法の行に追随する
5. スクロールしてもプレビューがテキストとずれない
6. 画像記法の URL 部分を編集して壊すとプレビューが消える

- [ ] **Step 4: コミット**

```bash
git add Example
git commit -m "feat(example): add image preview samples to demo document

Task 9 of image-preview plan
Task context: 画像プレビュー機能の実装 (docs/superpowers/specs/2026-07-16-image-preview-design.md)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## 完了条件

- `swift test` 全パス(既存 179 件 + 本プランの新規テスト)
- Example アプリがビルドでき、computer use による GUI 検証 6 項目をスクリーンショットで確認済み
- 全タスクがコミット済み(main 直接)
