# MarkdownEditor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TextKit2 をフル活用した macOS 向けシンタックスハイライト型 Markdown エディタライブラリ(+ ExampleMacOS アプリ)を実装する。

**Architecture:** プラットフォーム非依存の `MarkdownEditorCore`(swift-markdown による全文パース → `HighlightPlan` 生成 → 差分計算)と、AppKit 層 `MarkdownEditor`(`NSTextView` サブクラス、renderingAttributes による色適用、`NSTextLayoutFragment` サブクラスによるブロック装飾、viewport デリゲートによる行番号ガター、SwiftUI ラッパー)の 2 ターゲット構成。

**Tech Stack:** Swift 6.4 / SwiftPM / apple(swiftlang)/swift-markdown / TextKit2(macOS 27 の WWDC26 API 含む)/ Swift Testing / XcodeGen(Example アプリ)

**Spec:** `docs/superpowers/specs/2026-07-14-markdown-editor-design.md`

## Global Constraints

- 対象 OS: macOS 27.0 以上(`platforms: [.macOS("27.0")]`)
- Swift 6 言語モード + `.enableUpcomingFeature("ApproachableConcurrency")`(全ターゲット)
- 外部依存は `https://github.com/swiftlang/swift-markdown.git`(`from: "0.4.0"`)のみ
- `MarkdownEditorCore` は AppKit を import しない(Foundation + Markdown のみ)
- AttributedString の Markdown 描画機能(`AttributedString(markdown:)`)は使用しない
- エディタはテキスト内容を一切改変しない(属性・描画のみ。構文記号は淡色表示で残す)
- TextKit1 へのフォールバックを防ぐため、`NSTextView` の `layoutManager` プロパティには絶対に触れない(`textLayoutManager` のみ使用)
- 文書全体のジオメトリ照会(全文 `enumerateTextLayoutFragments` 等)をしない
- コミットメッセージには「Task N of markdown-editor plan」と変更概要を含める(ユーザーの CLAUDE.md 要件)
- テストは Swift Testing(`import Testing`)で書く。`swift test` が全パスしてからコミットする

## File Structure

```
Package.swift                                     … Task 1 で 2 ターゲット構成に変更
Sources/
├── MarkdownEditorCore/
│   ├── SyntaxKind.swift                          … Task 2(意味的スタイル種別)
│   ├── HighlightPlan.swift                       … Task 2(HighlightSpan / HighlightPlan / shifted)
│   ├── HighlightDiff.swift                       … Task 3(差分計算)
│   ├── SourceLocationConverter.swift             … Task 4(SourceRange → NSRange)
│   ├── HighlightMapper.swift                     … Task 5(AST → HighlightPlan)
│   └── MarkdownParser.swift                      … Task 5(公開エントリポイント)
└── MarkdownEditor/
    ├── Exports.swift                             … Task 1(Core の再エクスポート)
    ├── MarkdownTheme.swift                       … Task 6(テーマ + 属性分離)
    ├── NSTextContentManager+Ranges.swift         … Task 7(NSRange → NSTextRange)
    ├── Highlighter.swift                         … Task 7(差分適用エンジン)
    ├── MarkdownTextView.swift                    … Task 8(NSTextView サブクラス)/ Task 10(viewport オーバーライド)
    ├── BlockFragments.swift                      … Task 9(装飾フラグメント 3 種)
    ├── BlockFragmentProvider.swift               … Task 9(NSTextLayoutManagerDelegate)
    ├── LineIndex.swift                           … Task 10(行番号計算)
    ├── LineNumberGutterView.swift                … Task 10(NSRulerView ガター)
    └── MarkdownEditorView.swift                  … Task 11(SwiftUI ラッパー)
Tests/
├── MarkdownEditorCoreTests/                      … Task 2〜5 + Task 12(性能)
└── MarkdownEditorTests/                          … Task 6〜11
ExampleMacOS/
├── project.yml                                   … Task 13(XcodeGen 定義)
└── Sources/ExampleMacOSApp.swift                 … Task 13
```

**実行環境メモ:** このマシンは macOS 27.0 / Swift 6.4 / XcodeGen インストール済み。Xcode MCP はセッションに未接続のため、ビルド・実行は `swift build` / `swift test` / `xcodebuild` CLI を使う(Xcode MCP が接続された場合は同等操作をそちらで行ってよい)。

---

### Task 1: パッケージ再構成(2 ターゲット + swift-markdown 依存)

**Files:**
- Modify: `Package.swift`
- Create: `Sources/MarkdownEditorCore/SyntaxKind.swift`(このタスクで完成形を書く。Task 2 以降は変更しない)
- Create: `Sources/MarkdownEditor/Exports.swift`(Core の再エクスポート)
- Delete: `Sources/MarkdownEditor/MarkdownEditor.swift`(テンプレートの hello 関数)
- Modify: `Tests/MarkdownEditorTests/MarkdownEditorTests.swift`
- Create: `Tests/MarkdownEditorCoreTests/MarkdownEditorCoreTests.swift`

**Interfaces:**
- Consumes: なし(最初のタスク)
- Produces: ターゲット `MarkdownEditorCore`(依存: `Markdown`)、ターゲット `MarkdownEditor`(依存: `MarkdownEditorCore`)。以降の全タスクがこの構成に乗る。

- [ ] **Step 1: Package.swift を書き換える**

```swift
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MarkdownEditor",
    platforms: [
        .macOS("27.0"),
    ],
    products: [
        .library(name: "MarkdownEditor", targets: ["MarkdownEditor"]),
        .library(name: "MarkdownEditorCore", targets: ["MarkdownEditorCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.4.0"),
    ],
    targets: [
        .target(
            name: "MarkdownEditorCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .target(
            name: "MarkdownEditor",
            dependencies: ["MarkdownEditorCore"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "MarkdownEditorCoreTests",
            dependencies: ["MarkdownEditorCore"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "MarkdownEditorTests",
            dependencies: ["MarkdownEditor"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

- [ ] **Step 2: ソースディレクトリを再構成する**

```bash
mkdir -p Sources/MarkdownEditorCore Tests/MarkdownEditorCoreTests
rm Sources/MarkdownEditor/MarkdownEditor.swift
```

`Sources/MarkdownEditorCore/SyntaxKind.swift` を最小内容で作成(Task 2 で完成させる):

```swift
/// Markdown 要素の意味的スタイル種別。テーマがこれを具体的な属性に変換する。
public enum SyntaxKind: Hashable, Sendable {
    case heading(level: Int)
    case emphasis
    case strong
    case inlineCode
    case codeBlock
    case blockquote
    case listMarker
    case link
    case thematicBreak
    case syntaxMarker
}
```

`Sources/MarkdownEditor/Exports.swift` を作成(UI ターゲットを空にしないため + Core の型を再エクスポート):

```swift
@_exported import MarkdownEditorCore
```

- [ ] **Step 3: テストファイルを差し替える**

`Tests/MarkdownEditorTests/MarkdownEditorTests.swift` を以下で置き換え:

```swift
import Testing
@testable import MarkdownEditor

@Test func moduleLoads() {
    // MarkdownEditor が MarkdownEditorCore を再エクスポートしていること
    let kind: SyntaxKind = .strong
    #expect(kind == .strong)
}
```

`Tests/MarkdownEditorCoreTests/MarkdownEditorCoreTests.swift` を作成:

```swift
import Testing
@testable import MarkdownEditorCore

@Test func syntaxKindIsHashable() {
    let set: Set<SyntaxKind> = [.heading(level: 1), .heading(level: 1), .strong]
    #expect(set.count == 2)
}
```

- [ ] **Step 4: ビルドとテストを実行して確認**

Run: `swift build && swift test`
Expected: 依存解決(swift-markdown のフェッチ)後、ビルド成功、テスト 2 件 PASS

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "build: restructure into Core + UI targets with swift-markdown dependency

Task 1 of markdown-editor plan: two-target SwiftPM layout
(MarkdownEditorCore platform-independent, MarkdownEditor AppKit layer)."
```

---

### Task 2: HighlightSpan / HighlightPlan と編集シフト(Core)

**Files:**
- Modify: `Sources/MarkdownEditorCore/SyntaxKind.swift`(Task 1 の内容のまま — 変更が不要なことを確認)
- Create: `Sources/MarkdownEditorCore/HighlightPlan.swift`
- Test: `Tests/MarkdownEditorCoreTests/HighlightPlanTests.swift`

**Interfaces:**
- Consumes: `SyntaxKind`(Task 1)
- Produces:
  - `public struct HighlightSpan: Hashable, Sendable { public var range: NSRange; public var kind: SyntaxKind; public init(range: NSRange, kind: SyntaxKind) }`
  - `public struct HighlightPlan: Equatable, Sendable { public var spans: [HighlightSpan]; public init(spans: [HighlightSpan] = []); public func shifted(byEditAt editedRange: NSRange, changeInLength delta: Int) -> HighlightPlan }`
  - `spans` は適用順(ブロック → インライン → マーカー)を保持する配列。`range` は UTF-16 ベースの NSRange。

- [ ] **Step 1: 失敗するテストを書く**

`Tests/MarkdownEditorCoreTests/HighlightPlanTests.swift`:

```swift
import Foundation
import Testing
@testable import MarkdownEditorCore

@Test func shiftKeepsSpansBeforeEdit() {
    let plan = HighlightPlan(spans: [
        HighlightSpan(range: NSRange(location: 0, length: 5), kind: .strong),
    ])
    // 位置 10 に 3 文字挿入(didProcessEditing 相当: editedRange={10,3}, delta=+3)
    let shifted = plan.shifted(byEditAt: NSRange(location: 10, length: 3), changeInLength: 3)
    #expect(shifted.spans == plan.spans)
}

@Test func shiftMovesSpansAfterEdit() {
    let plan = HighlightPlan(spans: [
        HighlightSpan(range: NSRange(location: 10, length: 4), kind: .emphasis),
    ])
    // 位置 2 に 3 文字挿入
    let shifted = plan.shifted(byEditAt: NSRange(location: 2, length: 3), changeInLength: 3)
    #expect(shifted.spans == [HighlightSpan(range: NSRange(location: 13, length: 4), kind: .emphasis)])
}

@Test func shiftMovesSpansAfterDeletion() {
    let plan = HighlightPlan(spans: [
        HighlightSpan(range: NSRange(location: 10, length: 4), kind: .emphasis),
    ])
    // 位置 2 の 3 文字を削除(editedRange={2,0}, delta=-3)
    let shifted = plan.shifted(byEditAt: NSRange(location: 2, length: 0), changeInLength: -3)
    #expect(shifted.spans == [HighlightSpan(range: NSRange(location: 7, length: 4), kind: .emphasis)])
}

@Test func shiftDropsSpansIntersectingEdit() {
    let plan = HighlightPlan(spans: [
        HighlightSpan(range: NSRange(location: 4, length: 6), kind: .strong),
    ])
    // 位置 5 に 1 文字挿入 → スパンは編集と交差するので破棄(新パースで再生成される)
    let shifted = plan.shifted(byEditAt: NSRange(location: 5, length: 1), changeInLength: 1)
    #expect(shifted.spans.isEmpty)
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter HighlightPlanTests`
Expected: コンパイルエラー(`HighlightPlan` 未定義)— これが「失敗」に相当

- [ ] **Step 3: 実装を書く**

`Sources/MarkdownEditorCore/HighlightPlan.swift`:

```swift
import Foundation

/// 「この UTF-16 レンジにこの SyntaxKind」という 1 スタイル指定。
public struct HighlightSpan: Hashable, Sendable {
    public var range: NSRange
    public var kind: SyntaxKind

    public init(range: NSRange, kind: SyntaxKind) {
        self.range = range
        self.kind = kind
    }
}

/// 文書全体のハイライト計画。spans は適用順(ブロック → インライン → マーカー)。
public struct HighlightPlan: Equatable, Sendable {
    public var spans: [HighlightSpan]

    public init(spans: [HighlightSpan] = []) {
        self.spans = spans
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
        var result: [HighlightSpan] = []
        result.reserveCapacity(spans.count)
        for span in spans {
            if NSMaxRange(span.range) <= preEditRange.location {
                result.append(span)
            } else if span.range.location >= NSMaxRange(preEditRange) {
                var moved = span
                moved.range.location += delta
                result.append(moved)
            }
            // それ以外(編集と交差)は破棄
        }
        return HighlightPlan(spans: result)
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter HighlightPlanTests`
Expected: 4 件 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownEditorCore/HighlightPlan.swift Tests/MarkdownEditorCoreTests/HighlightPlanTests.swift
git commit -m "feat(core): add HighlightSpan/HighlightPlan with edit shifting

Task 2 of markdown-editor plan: UTF-16 span model and
edit-aware plan shifting for differential highlighting."
```

---

### Task 3: HighlightDiff — 差分計算(Core)

**Files:**
- Create: `Sources/MarkdownEditorCore/HighlightDiff.swift`
- Test: `Tests/MarkdownEditorCoreTests/HighlightDiffTests.swift`

**Interfaces:**
- Consumes: `HighlightPlan` / `HighlightSpan`(Task 2)
- Produces:
  - `public struct HighlightChanges: Equatable, Sendable { public var invalidatedRanges: [NSRange]; public var spansToApply: [HighlightSpan] }`
  - `public enum HighlightDiff { public static func compute(old: HighlightPlan, new: HighlightPlan, alwaysInvalidating extraRanges: [NSRange] = []) -> HighlightChanges }`
  - `old` は編集分シフト済みの前回計画を渡す。`extraRanges` は「必ず無効化するレンジ」(編集されたレンジそのもの)。`invalidatedRanges` はマージ・ソート済み。`spansToApply` は `new.spans` のうち無効化レンジと重なるもの(元の順序を保持)。

- [ ] **Step 1: 失敗するテストを書く**

`Tests/MarkdownEditorCoreTests/HighlightDiffTests.swift`:

```swift
import Foundation
import Testing
@testable import MarkdownEditorCore

@Test func identicalPlansProduceNoChanges() {
    let plan = HighlightPlan(spans: [
        HighlightSpan(range: NSRange(location: 0, length: 7), kind: .heading(level: 1)),
    ])
    let changes = HighlightDiff.compute(old: plan, new: plan)
    #expect(changes.invalidatedRanges.isEmpty)
    #expect(changes.spansToApply.isEmpty)
}

@Test func changedSpanInvalidatesUnionAndReappliesOverlapping() {
    // 見出しスパンは不変、その内側のマーカーが {0,2} → {0,3} に変化
    let heading = HighlightSpan(range: NSRange(location: 0, length: 10), kind: .heading(level: 1))
    let old = HighlightPlan(spans: [heading, HighlightSpan(range: NSRange(location: 0, length: 2), kind: .syntaxMarker)])
    let new = HighlightPlan(spans: [heading, HighlightSpan(range: NSRange(location: 0, length: 3), kind: .syntaxMarker)])
    let changes = HighlightDiff.compute(old: old, new: new)
    #expect(changes.invalidatedRanges == [NSRange(location: 0, length: 3)])
    // 無効化レンジと重なる見出しスパンも再適用対象に含まれる
    #expect(changes.spansToApply == new.spans)
}

@Test func removedSpanInvalidatesItsRange() {
    let old = HighlightPlan(spans: [HighlightSpan(range: NSRange(location: 5, length: 4), kind: .strong)])
    let new = HighlightPlan(spans: [])
    let changes = HighlightDiff.compute(old: old, new: new)
    #expect(changes.invalidatedRanges == [NSRange(location: 5, length: 4)])
    #expect(changes.spansToApply.isEmpty)
}

@Test func extraRangesAreAlwaysInvalidated() {
    let plan = HighlightPlan(spans: [HighlightSpan(range: NSRange(location: 0, length: 10), kind: .codeBlock)])
    // スパンに変化がなくても編集レンジ(長さ 0 の削除でも)は無効化され、
    // 重なるスパンが再適用される
    let changes = HighlightDiff.compute(old: plan, new: plan, alwaysInvalidating: [NSRange(location: 4, length: 0)])
    #expect(changes.invalidatedRanges == [NSRange(location: 4, length: 0)])
    #expect(changes.spansToApply == plan.spans)
}

@Test func adjacentInvalidatedRangesAreMerged() {
    let old = HighlightPlan(spans: [
        HighlightSpan(range: NSRange(location: 0, length: 5), kind: .strong),
        HighlightSpan(range: NSRange(location: 5, length: 5), kind: .emphasis),
    ])
    let new = HighlightPlan(spans: [])
    let changes = HighlightDiff.compute(old: old, new: new)
    #expect(changes.invalidatedRanges == [NSRange(location: 0, length: 10)])
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter HighlightDiffTests`
Expected: コンパイルエラー(`HighlightDiff` 未定義)

- [ ] **Step 3: 実装を書く**

`Sources/MarkdownEditorCore/HighlightDiff.swift`:

```swift
import Foundation

/// 差分計算の結果。invalidatedRanges を本文スタイルへリセットしてから
/// spansToApply を順に適用する、という契約で UI 層が消費する。
public struct HighlightChanges: Equatable, Sendable {
    public var invalidatedRanges: [NSRange]
    public var spansToApply: [HighlightSpan]

    public init(invalidatedRanges: [NSRange] = [], spansToApply: [HighlightSpan] = []) {
        self.invalidatedRanges = invalidatedRanges
        self.spansToApply = spansToApply
    }
}

public enum HighlightDiff {
    /// old(編集分シフト済み)と new の差分から、リセットすべきレンジと
    /// 再適用すべきスパンを求める。extraRanges は常に無効化する(編集レンジ用)。
    public static func compute(
        old: HighlightPlan,
        new: HighlightPlan,
        alwaysInvalidating extraRanges: [NSRange] = []
    ) -> HighlightChanges {
        let oldSet = Set(old.spans)
        let newSet = Set(new.spans)
        let removed = old.spans.filter { !newSet.contains($0) }
        let added = new.spans.filter { !oldSet.contains($0) }

        let dirty = removed.map(\.range) + added.map(\.range) + extraRanges
        if dirty.isEmpty {
            return HighlightChanges()
        }
        let invalidated = mergeRanges(dirty)
        let toApply = new.spans.filter { span in
            invalidated.contains { overlaps($0, span.range) }
        }
        return HighlightChanges(invalidatedRanges: invalidated, spansToApply: toApply)
    }

    /// 交差判定。長さ 0 のレンジ(削除編集)は「相手のレンジ内にあるか」で判定する。
    static func overlaps(_ a: NSRange, _ b: NSRange) -> Bool {
        if a.length == 0 { return NSLocationInRange(a.location, b) }
        if b.length == 0 { return NSLocationInRange(b.location, a) }
        return NSIntersectionRange(a, b).length > 0
    }

    /// ソートし、隣接・重複レンジをマージする。
    static func mergeRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in sorted {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter HighlightDiffTests`
Expected: 5 件 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownEditorCore/HighlightDiff.swift Tests/MarkdownEditorCoreTests/HighlightDiffTests.swift
git commit -m "feat(core): add HighlightDiff for differential attribute application

Task 3 of markdown-editor plan: set-difference over spans,
merged invalidated ranges, overlap-aware reapply list."
```

---

### Task 4: SourceLocationConverter — SourceRange → NSRange(Core)

**Files:**
- Create: `Sources/MarkdownEditorCore/SourceLocationConverter.swift`
- Test: `Tests/MarkdownEditorCoreTests/SourceLocationConverterTests.swift`

**Interfaces:**
- Consumes: swift-markdown の `SourceLocation` / `SourceRange`(`Range<SourceLocation>`)。`SourceLocation` は 1-based の `line` と、**UTF-8 バイト単位** 1-based の `column` を持つ(cmark-gfm 由来)。
- Produces(internal — 同モジュール内の HighlightMapper が使用):
  - `struct SourceLocationConverter { init(text: String); func nsRange(of sourceRange: SourceRange) -> NSRange? }`
  - 返す NSRange は UTF-16 ベース。変換不能(範囲外)なら nil。

**注意:** もし日本語テストが「column を UTF-8 バイトとして解釈」で失敗する場合、swift-markdown のバージョンによって column の単位が異なる可能性がある。その場合は Step 1 のテストの期待値は変えず、実装側の `utf8.index(_:offsetBy:)` を `unicodeScalars` ベースに切り替えて再検証すること(期待値 = 正しい NSRange は不変)。

- [ ] **Step 1: 失敗するテストを書く**

`Tests/MarkdownEditorCoreTests/SourceLocationConverterTests.swift`:

```swift
import Foundation
import Markdown
import Testing
@testable import MarkdownEditorCore

private func location(_ line: Int, _ column: Int) -> SourceLocation {
    SourceLocation(line: line, column: column, source: nil)
}

@Test func convertsASCIIRange() {
    let converter = SourceLocationConverter(text: "# Hello\nworld")
    // 1 行目全体("# Hello" = 7 バイト → col 1..<8)
    let range = converter.nsRange(of: location(1, 1)..<location(1, 8))
    #expect(range == NSRange(location: 0, length: 7))
}

@Test func convertsSecondLine() {
    let converter = SourceLocationConverter(text: "# Hello\nworld")
    let range = converter.nsRange(of: location(2, 1)..<location(2, 6))
    #expect(range == NSRange(location: 8, length: 5))
}

@Test func convertsJapaneseText() {
    // "あ" は UTF-8 で 3 バイト、UTF-16 で 1 ユニット
    let converter = SourceLocationConverter(text: "あいう\nabc")
    // 2 行目の "b"(col 2)から "c" の後(col 4)まで
    let range = converter.nsRange(of: location(2, 2)..<location(2, 4))
    // 1 行目 "あいう\n" = UTF-16 で 4 ユニット → "b" は offset 5
    #expect(range == NSRange(location: 5, length: 2))
}

@Test func convertsEmojiText() {
    // "🎉" は UTF-8 で 4 バイト、UTF-16 で 2 ユニット
    let converter = SourceLocationConverter(text: "🎉x")
    // "x" は UTF-8 col 5、UTF-16 offset 2
    let range = converter.nsRange(of: location(1, 5)..<location(1, 6))
    #expect(range == NSRange(location: 2, length: 1))
}

@Test func returnsNilForOutOfBounds() {
    let converter = SourceLocationConverter(text: "ab")
    #expect(converter.nsRange(of: location(5, 1)..<location(5, 2)) == nil)
    #expect(converter.nsRange(of: location(1, 1)..<location(1, 99)) == nil)
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter SourceLocationConverterTests`
Expected: コンパイルエラー(`SourceLocationConverter` 未定義)

- [ ] **Step 3: 実装を書く**

`Sources/MarkdownEditorCore/SourceLocationConverter.swift`:

```swift
import Foundation
import Markdown

/// swift-markdown の SourceLocation(1-based 行、UTF-8 バイト単位 1-based 桁)を
/// UTF-16 ベースの NSRange に変換する。1 文書につき 1 インスタンス生成して使う。
struct SourceLocationConverter {
    private let text: String
    /// 各行の先頭を指す String.Index(UTF-8 視点で "\n" の直後)
    private let lineStartIndices: [String.Index]

    init(text: String) {
        self.text = text
        var starts: [String.Index] = [text.startIndex]
        let utf8 = text.utf8
        var i = utf8.startIndex
        while i < utf8.endIndex {
            if utf8[i] == UInt8(ascii: "\n") {
                starts.append(utf8.index(after: i))
            }
            i = utf8.index(after: i)
        }
        self.lineStartIndices = starts
    }

    func nsRange(of sourceRange: SourceRange) -> NSRange? {
        guard let lower = stringIndex(of: sourceRange.lowerBound),
              let upper = stringIndex(of: sourceRange.upperBound),
              lower <= upper else { return nil }
        return NSRange(lower..<upper, in: text)
    }

    private func stringIndex(of location: SourceLocation) -> String.Index? {
        let lineIndex = location.line - 1
        guard lineIndex >= 0, lineIndex < lineStartIndices.count else { return nil }
        let lineStart = lineStartIndices[lineIndex]
        let utf8 = text.utf8
        guard let index = utf8.index(
            lineStart,
            offsetBy: location.column - 1,
            limitedBy: utf8.endIndex
        ) else { return nil }
        // 行内桁が実際には次行へはみ出すケース(不正な column)を拒否する
        if lineIndex + 1 < lineStartIndices.count, index > lineStartIndices[lineIndex + 1] {
            return nil
        }
        return index
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter SourceLocationConverterTests`
Expected: 5 件 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownEditorCore/SourceLocationConverter.swift Tests/MarkdownEditorCoreTests/SourceLocationConverterTests.swift
git commit -m "feat(core): add SourceLocation -> NSRange converter

Task 4 of markdown-editor plan: UTF-8 byte columns from
swift-markdown mapped to UTF-16 NSRanges, verified with
Japanese and emoji text."
```

---

### Task 5: HighlightMapper + MarkdownParser(Core)

**Files:**
- Create: `Sources/MarkdownEditorCore/HighlightMapper.swift`
- Create: `Sources/MarkdownEditorCore/MarkdownParser.swift`
- Test: `Tests/MarkdownEditorCoreTests/MarkdownParserTests.swift`

**Interfaces:**
- Consumes: `SourceLocationConverter`(Task 4)、`HighlightPlan`/`HighlightSpan`/`SyntaxKind`(Task 2)、swift-markdown の `Document` / `MarkupWalker`
- Produces:
  - `public struct MarkdownParser: Sendable { public init(); public func highlightPlan(for text: String) -> HighlightPlan }`
  - スパン生成規則(テーマ・フラグメントがこの契約に依存):
    - `.heading(level:)` = 見出し行全体。行頭の `#…`(+直後のスペース 1 個)に `.syntaxMarker` を重ねる(Setext 見出しにはマーカーなし)
    - `.strong` / `.emphasis` = デリミタ込み全体。両端のデリミタ(2 文字 / 1 文字)に `.syntaxMarker`
    - `.inlineCode` = バッククォート込み全体。両端のバッククォート列に `.syntaxMarker`
    - `.codeBlock` = ブロック全体。フェンス行(``` や ~~~)に `.syntaxMarker`(インデント型コードブロックにはマーカーなし)
    - `.blockquote` = ブロック全体(最外の BlockQuote のみ)。各行頭の `>` 1 文字ずつに `.syntaxMarker`
    - `.listMarker` = リストマーカー(`-` `*` `+` または `1.` `1)`)のみ
    - `.link` = リンク全体(`[text](url)` 込み)。v1 では内部マーカーなし
    - `.thematicBreak` = 水平線行全体
  - `HighlightPlan.spans` の順序: 全ブロックスパン → 全インラインスパン → 全マーカースパン

- [ ] **Step 1: 失敗するテストを書く**

`Tests/MarkdownEditorCoreTests/MarkdownParserTests.swift`:

```swift
import Foundation
import Testing
@testable import MarkdownEditorCore

private func ranges(of kind: SyntaxKind, in markdown: String) -> [NSRange] {
    MarkdownParser().highlightPlan(for: markdown).spans
        .filter { $0.kind == kind }
        .map(\.range)
}

@Test func mapsHeadingWithMarker() {
    let md = "## Title"
    #expect(ranges(of: .heading(level: 2), in: md) == [NSRange(location: 0, length: 8)])
    #expect(ranges(of: .syntaxMarker, in: md) == [NSRange(location: 0, length: 3)])  // "## "
}

@Test func mapsStrongWithDelimitersAndJapanese() {
    let md = "前**強調**後"
    #expect(ranges(of: .strong, in: md) == [NSRange(location: 1, length: 6)])
    let markers = ranges(of: .syntaxMarker, in: md)
    #expect(markers.contains(NSRange(location: 1, length: 2)))
    #expect(markers.contains(NSRange(location: 5, length: 2)))
}

@Test func mapsEmphasis() {
    let md = "an *em* word"
    #expect(ranges(of: .emphasis, in: md) == [NSRange(location: 3, length: 4)])
}

@Test func mapsInlineCodeDelimiters() {
    let md = "a `code` b"
    #expect(ranges(of: .inlineCode, in: md) == [NSRange(location: 2, length: 6)])
    let markers = ranges(of: .syntaxMarker, in: md)
    #expect(markers.contains(NSRange(location: 2, length: 1)))
    #expect(markers.contains(NSRange(location: 7, length: 1)))
}

@Test func mapsFencedCodeBlockWithFenceMarkers() {
    let md = "```swift\nlet x = 1\n```"
    let blocks = ranges(of: .codeBlock, in: md)
    #expect(blocks.count == 1)
    #expect(blocks[0].location == 0)
    let markers = ranges(of: .syntaxMarker, in: md)
    // 開始フェンス行 "```swift" と終了フェンス行 "```"
    #expect(markers.contains(NSRange(location: 0, length: 8)))
    #expect(markers.contains(NSRange(location: 19, length: 3)))
}

@Test func mapsBlockquoteWithLineMarkers() {
    let md = "> one\n> two"
    let blocks = ranges(of: .blockquote, in: md)
    #expect(blocks.count == 1)
    let markers = ranges(of: .syntaxMarker, in: md)
    #expect(markers.contains(NSRange(location: 0, length: 1)))   // 1 行目 ">"
    #expect(markers.contains(NSRange(location: 6, length: 1)))   // 2 行目 ">"
}

@Test func nestedBlockquoteEmitsOneBlockSpanPerTopLevel() {
    let md = "> outer\n> > inner"
    // 最外の BlockQuote だけがブロックスパンを生成する
    #expect(ranges(of: .blockquote, in: md).count == 1)
}

@Test func mapsListMarkers() {
    let md = "- one\n- two\n\n1. first"
    let markers = ranges(of: .listMarker, in: md)
    #expect(markers.contains(NSRange(location: 0, length: 1)))   // "-"
    #expect(markers.contains(NSRange(location: 6, length: 1)))   // "-"
    #expect(markers.contains(NSRange(location: 13, length: 2)))  // "1."
}

@Test func mapsLink() {
    let md = "see [here](https://example.com) now"
    #expect(ranges(of: .link, in: md) == [NSRange(location: 4, length: 27)])
}

@Test func mapsThematicBreak() {
    let md = "a\n\n---\n\nb"
    let breaks = ranges(of: .thematicBreak, in: md)
    #expect(breaks.count == 1)
    #expect(breaks[0].location == 3)
}

@Test func blockSpansComeBeforeInlineAndMarkerSpans() {
    let plan = MarkdownParser().highlightPlan(for: "# T **s**")
    let kinds = plan.spans.map(\.kind)
    let headingIndex = kinds.firstIndex(of: .heading(level: 1))!
    let strongIndex = kinds.firstIndex(of: .strong)!
    let markerIndex = kinds.firstIndex(of: .syntaxMarker)!
    #expect(headingIndex < strongIndex)
    #expect(strongIndex < markerIndex)
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter MarkdownParserTests`
Expected: コンパイルエラー(`MarkdownParser` 未定義)

- [ ] **Step 3: 実装を書く**

`Sources/MarkdownEditorCore/MarkdownParser.swift`:

```swift
import Foundation
import Markdown

/// 公開エントリポイント。Markdown テキストからハイライト計画を生成する。
public struct MarkdownParser: Sendable {
    public init() {}

    public func highlightPlan(for text: String) -> HighlightPlan {
        let document = Document(parsing: text)
        return HighlightMapper.plan(for: document, in: text)
    }
}
```

`Sources/MarkdownEditorCore/HighlightMapper.swift`:

```swift
import Foundation
import Markdown

/// swift-markdown の AST を歩いて HighlightPlan を生成する。
enum HighlightMapper {
    static func plan(for document: Document, in text: String) -> HighlightPlan {
        var visitor = Visitor(converter: SourceLocationConverter(text: text), text: text as NSString)
        visitor.visit(document)
        // 適用順: ブロック → インライン → マーカー
        return HighlightPlan(spans: visitor.blockSpans + visitor.inlineSpans + visitor.markerSpans)
    }

    private struct Visitor: MarkupWalker {
        let converter: SourceLocationConverter
        let text: NSString
        var blockSpans: [HighlightSpan] = []
        var inlineSpans: [HighlightSpan] = []
        var markerSpans: [HighlightSpan] = []

        private func nsRange(of markup: Markup) -> NSRange? {
            guard let sourceRange = markup.range else { return nil }
            return converter.nsRange(of: sourceRange)
        }

        // MARK: ブロック要素

        mutating func visitHeading(_ heading: Heading) {
            if let range = nsRange(of: heading), range.length > 0 {
                blockSpans.append(HighlightSpan(range: range, kind: .heading(level: heading.level)))
                // ATX 見出しの行頭 "#…"(+スペース 1 個)をマーカーに。Setext はマーカーなし。
                let markerLength = leadingHashMarkerLength(in: range)
                if markerLength > 0 {
                    markerSpans.append(HighlightSpan(
                        range: NSRange(location: range.location, length: markerLength),
                        kind: .syntaxMarker
                    ))
                }
            }
            descendInto(heading)
        }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            guard let range = nsRange(of: codeBlock), range.length > 0 else { return }
            blockSpans.append(HighlightSpan(range: range, kind: .codeBlock))
            // フェンス行をマーカーに(インデント型コードブロックはフェンスなし)
            let firstLine = clippedLineRange(at: range.location, within: range)
            if isFenceLine(firstLine) {
                markerSpans.append(HighlightSpan(range: firstLine, kind: .syntaxMarker))
                let lastLine = clippedLineRange(at: max(range.location, NSMaxRange(range) - 1), within: range)
                if lastLine != firstLine, isFenceLine(lastLine) {
                    markerSpans.append(HighlightSpan(range: lastLine, kind: .syntaxMarker))
                }
            }
            // コードブロック内部は descend しない(強調等を解釈しない)
        }

        mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
            // 最外の BlockQuote のみブロックスパンと行頭マーカーを生成
            if !(blockQuote.parent is BlockQuote), let range = nsRange(of: blockQuote), range.length > 0 {
                blockSpans.append(HighlightSpan(range: range, kind: .blockquote))
                appendQuoteMarkers(in: range)
            }
            descendInto(blockQuote)
        }

        mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
            if let range = nsRange(of: thematicBreak), range.length > 0 {
                blockSpans.append(HighlightSpan(range: range, kind: .thematicBreak))
            }
        }

        mutating func visitListItem(_ listItem: ListItem) {
            if let range = nsRange(of: listItem), range.length > 0,
               let marker = listMarkerRange(in: range) {
                inlineSpans.append(HighlightSpan(range: marker, kind: .listMarker))
            }
            descendInto(listItem)
        }

        // MARK: インライン要素

        mutating func visitStrong(_ strong: Strong) {
            appendDelimited(strong, kind: .strong, delimiterLength: 2)
            descendInto(strong)
        }

        mutating func visitEmphasis(_ emphasis: Emphasis) {
            appendDelimited(emphasis, kind: .emphasis, delimiterLength: 1)
            descendInto(emphasis)
        }

        mutating func visitInlineCode(_ inlineCode: InlineCode) {
            guard let range = nsRange(of: inlineCode), range.length > 0 else { return }
            inlineSpans.append(HighlightSpan(range: range, kind: .inlineCode))
            let codeLength = (inlineCode.code as NSString).length
            let delimiter = max(0, (range.length - codeLength) / 2)
            if delimiter > 0, range.length >= delimiter * 2 {
                markerSpans.append(HighlightSpan(
                    range: NSRange(location: range.location, length: delimiter),
                    kind: .syntaxMarker
                ))
                markerSpans.append(HighlightSpan(
                    range: NSRange(location: NSMaxRange(range) - delimiter, length: delimiter),
                    kind: .syntaxMarker
                ))
            }
        }

        mutating func visitLink(_ link: Link) {
            if let range = nsRange(of: link), range.length > 0 {
                inlineSpans.append(HighlightSpan(range: range, kind: .link))
            }
            descendInto(link)
        }

        // MARK: ヘルパー

        private mutating func appendDelimited(_ markup: Markup, kind: SyntaxKind, delimiterLength: Int) {
            guard let range = nsRange(of: markup), range.length >= delimiterLength * 2 else { return }
            inlineSpans.append(HighlightSpan(range: range, kind: kind))
            markerSpans.append(HighlightSpan(
                range: NSRange(location: range.location, length: delimiterLength),
                kind: .syntaxMarker
            ))
            markerSpans.append(HighlightSpan(
                range: NSRange(location: NSMaxRange(range) - delimiterLength, length: delimiterLength),
                kind: .syntaxMarker
            ))
        }

        /// 行頭の "#…"(最大 6 個)+ 直後のスペース 1 個の長さ。ATX 見出しでなければ 0。
        private func leadingHashMarkerLength(in range: NSRange) -> Int {
            let end = NSMaxRange(range)
            var i = range.location
            var count = 0
            while i < end, count < 6, text.character(at: i) == UInt16(UnicodeScalar("#").value) {
                count += 1
                i += 1
            }
            guard count > 0 else { return 0 }
            if i < end, text.character(at: i) == UInt16(UnicodeScalar(" ").value) {
                count += 1
            }
            return count
        }

        /// location を含む行のレンジを range 内にクリップし、末尾の改行を除いて返す。
        private func clippedLineRange(at location: Int, within range: NSRange) -> NSRange {
            var line = text.lineRange(for: NSRange(location: location, length: 0))
            // 末尾の改行を除く
            while line.length > 0, text.character(at: NSMaxRange(line) - 1) == UInt16(UnicodeScalar("\n").value) {
                line.length -= 1
            }
            return NSIntersectionRange(line, range)
        }

        private func isFenceLine(_ line: NSRange) -> Bool {
            guard line.length >= 3 else { return false }
            let first = text.character(at: line.location)
            let backtick = UInt16(UnicodeScalar("`").value)
            let tilde = UInt16(UnicodeScalar("~").value)
            guard first == backtick || first == tilde else { return false }
            return text.character(at: line.location + 1) == first
                && text.character(at: line.location + 2) == first
        }

        /// range 内の各行頭にある ">" を 1 文字ずつマーカーとして追加(ネスト分も拾う)。
        private mutating func appendQuoteMarkers(in range: NSRange) {
            let space = UInt16(UnicodeScalar(" ").value)
            let gt = UInt16(UnicodeScalar(">").value)
            var location = range.location
            let end = NSMaxRange(range)
            while location < end {
                let line = text.lineRange(for: NSRange(location: location, length: 0))
                let lineEnd = min(NSMaxRange(line), end)
                var i = line.location
                var leadingSpaces = 0
                while i < lineEnd, text.character(at: i) == space, leadingSpaces < 3 {
                    i += 1
                    leadingSpaces += 1
                }
                while i < lineEnd, text.character(at: i) == gt {
                    markerSpans.append(HighlightSpan(range: NSRange(location: i, length: 1), kind: .syntaxMarker))
                    i += 1
                    if i < lineEnd, text.character(at: i) == space { i += 1 }
                }
                if NSMaxRange(line) <= location { break }
                location = NSMaxRange(line)
            }
        }

        /// リストアイテム先頭のマーカー("-" "*" "+" または "1." "1)")のレンジ。
        private func listMarkerRange(in range: NSRange) -> NSRange? {
            let end = NSMaxRange(range)
            var i = range.location
            let space = UInt16(UnicodeScalar(" ").value)
            while i < end, text.character(at: i) == space { i += 1 }
            guard i < end else { return nil }
            let start = i
            let c = text.character(at: i)
            let bullets: [UInt16] = ["-", "*", "+"].map { UInt16(UnicodeScalar($0)!.value) }
            if bullets.contains(c) {
                i += 1
            } else {
                let zero = UInt16(UnicodeScalar("0").value)
                let nine = UInt16(UnicodeScalar("9").value)
                while i < end, (zero...nine).contains(text.character(at: i)) { i += 1 }
                guard i > start, i < end else { return nil }
                let dot = UInt16(UnicodeScalar(".").value)
                let paren = UInt16(UnicodeScalar(")").value)
                guard text.character(at: i) == dot || text.character(at: i) == paren else { return nil }
                i += 1
            }
            return NSRange(location: start, length: i - start)
        }
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter MarkdownParserTests`
Expected: 11 件 PASS。失敗した場合、期待値(NSRange)は手計算済みなので実装側を疑うこと。特に `SourceLocation.column` の単位(Task 4 の注意書き)と、code block の `range` が末尾改行を含むかを最初に確認する。

- [ ] **Step 5: 全テストを回して回帰確認 & Commit**

Run: `swift test`
Expected: 全件 PASS

```bash
git add Sources/MarkdownEditorCore Tests/MarkdownEditorCoreTests
git commit -m "feat(core): add HighlightMapper and MarkdownParser

Task 5 of markdown-editor plan: MarkupWalker mapping CommonMark
basics to HighlightSpans with syntax-marker extraction."
```

---

### Task 6: MarkdownTheme(UI 層)

**Files:**
- Create: `Sources/MarkdownEditor/MarkdownTheme.swift`
- Test: `Tests/MarkdownEditorTests/MarkdownThemeTests.swift`

**Interfaces:**
- Consumes: `SyntaxKind`(Core)
- Produces:
  - `public struct MarkdownTheme: @unchecked Sendable`(NSFont/NSColor はスレッドセーフだが Sendable 宣言がないため @unchecked)
    - `public struct Style: @unchecked Sendable { public var font: NSFont?; public var foregroundColor: NSColor?; public init(font: NSFont? = nil, foregroundColor: NSColor? = nil) }`
    - `public var bodyFont: NSFont` / `public var bodyColor: NSColor` / `public var backgroundColor: NSColor`
    - `public var codeBlockBackgroundColor: NSColor` / `public var blockquoteBarColor: NSColor` / `public var thematicBreakLineColor: NSColor`(フラグメント描画用)
    - `public var styles: [SyntaxKind: Style]`
    - `public func style(for kind: SyntaxKind) -> Style?`
    - `public static let default: MarkdownTheme`
  - internal ヘルパー(Highlighter が使用):
    - `var bodyLayoutAttributes: [NSAttributedString.Key: Any]`(= `[.font: bodyFont]`)
    - `func layoutFont(for kind: SyntaxKind) -> NSFont?`
    - `func renderingColor(for kind: SyntaxKind) -> NSColor?`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/MarkdownEditorTests/MarkdownThemeTests.swift`:

```swift
import AppKit
import Testing
@testable import MarkdownEditor

@Test func defaultThemeStylesAllHeadingLevels() {
    let theme = MarkdownTheme.default
    var previousSize = CGFloat.greatestFiniteMagnitude
    for level in 1...6 {
        let font = theme.style(for: .heading(level: level))?.font
        #expect(font != nil, "見出しレベル \(level) にフォントがない")
        let size = font!.pointSize
        #expect(size <= previousSize, "見出しサイズはレベルが下がるほど小さい")
        previousSize = size
    }
}

@Test func defaultThemeDimsSyntaxMarkers() {
    #expect(MarkdownTheme.default.renderingColor(for: .syntaxMarker) != nil)
}

@Test func layoutAndRenderingAttributesAreSeparated() {
    let theme = MarkdownTheme.default
    // 見出しはフォント(レイアウト属性)を持つ
    #expect(theme.layoutFont(for: .heading(level: 1)) != nil)
    // syntaxMarker は色のみ(フォント変更なし)
    #expect(theme.layoutFont(for: .syntaxMarker) == nil)
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter MarkdownThemeTests`
Expected: コンパイルエラー(`MarkdownTheme` 未定義)

- [ ] **Step 3: 実装を書く**

`Sources/MarkdownEditor/MarkdownTheme.swift`:

```swift
import AppKit
import MarkdownEditorCore

/// SyntaxKind を具体的なフォント・色に対応付けるテーマ。
/// NSFont / NSColor はイミュータブルでスレッドセーフのため @unchecked Sendable。
public struct MarkdownTheme: @unchecked Sendable {
    public struct Style: @unchecked Sendable {
        /// レイアウトに影響する属性(textStorage へ適用)
        public var font: NSFont?
        /// レイアウトに影響しない属性(renderingAttributes へ適用)
        public var foregroundColor: NSColor?

        public init(font: NSFont? = nil, foregroundColor: NSColor? = nil) {
            self.font = font
            self.foregroundColor = foregroundColor
        }
    }

    public var bodyFont: NSFont
    public var bodyColor: NSColor
    public var backgroundColor: NSColor
    public var codeBlockBackgroundColor: NSColor
    public var blockquoteBarColor: NSColor
    public var thematicBreakLineColor: NSColor
    public var styles: [SyntaxKind: Style]

    public init(
        bodyFont: NSFont,
        bodyColor: NSColor,
        backgroundColor: NSColor,
        codeBlockBackgroundColor: NSColor,
        blockquoteBarColor: NSColor,
        thematicBreakLineColor: NSColor,
        styles: [SyntaxKind: Style]
    ) {
        self.bodyFont = bodyFont
        self.bodyColor = bodyColor
        self.backgroundColor = backgroundColor
        self.codeBlockBackgroundColor = codeBlockBackgroundColor
        self.blockquoteBarColor = blockquoteBarColor
        self.thematicBreakLineColor = thematicBreakLineColor
        self.styles = styles
    }

    public func style(for kind: SyntaxKind) -> Style? {
        styles[kind]
    }

    public static let `default`: MarkdownTheme = {
        let bodySize: CGFloat = 14
        let body = NSFont.monospacedSystemFont(ofSize: bodySize, weight: .regular)
        let italicBody = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)

        var styles: [SyntaxKind: Style] = [:]
        let headingSizes: [CGFloat] = [26, 22, 19, 17, 15, 14]
        for level in 1...6 {
            styles[.heading(level: level)] = Style(
                font: .systemFont(ofSize: headingSizes[level - 1], weight: .bold)
            )
        }
        styles[.strong] = Style(font: .monospacedSystemFont(ofSize: bodySize, weight: .bold))
        styles[.emphasis] = Style(font: italicBody)
        styles[.inlineCode] = Style(foregroundColor: .systemPink)
        styles[.codeBlock] = Style(foregroundColor: .textColor)
        styles[.blockquote] = Style(foregroundColor: .secondaryLabelColor)
        styles[.listMarker] = Style(foregroundColor: .systemOrange)
        styles[.link] = Style(foregroundColor: .linkColor)
        styles[.thematicBreak] = Style(foregroundColor: .tertiaryLabelColor)
        styles[.syntaxMarker] = Style(foregroundColor: .tertiaryLabelColor)

        return MarkdownTheme(
            bodyFont: body,
            bodyColor: .textColor,
            backgroundColor: .textBackgroundColor,
            codeBlockBackgroundColor: .quaternarySystemFill,
            blockquoteBarColor: .systemGray,
            thematicBreakLineColor: .separatorColor,
            styles: styles
        )
    }()
}

extension MarkdownTheme {
    var bodyLayoutAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont]
    }

    func layoutFont(for kind: SyntaxKind) -> NSFont? {
        style(for: kind)?.font
    }

    func renderingColor(for kind: SyntaxKind) -> NSColor? {
        style(for: kind)?.foregroundColor
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter MarkdownThemeTests`
Expected: 3 件 PASS(`.quaternarySystemFill` が存在しない場合は `.quaternaryLabelColor` に置き換える)

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownEditor/MarkdownTheme.swift Tests/MarkdownEditorTests/MarkdownThemeTests.swift
git commit -m "feat(ui): add MarkdownTheme with layout/rendering attribute split

Task 6 of markdown-editor plan: SyntaxKind -> NSFont/NSColor
mapping; fonts go to textStorage, colors to renderingAttributes."
```

---

### Task 7: Highlighter — 差分適用エンジン(UI 層)

**Files:**
- Create: `Sources/MarkdownEditor/NSTextContentManager+Ranges.swift`
- Create: `Sources/MarkdownEditor/Highlighter.swift`
- Test: `Tests/MarkdownEditorTests/HighlighterTests.swift`

**Interfaces:**
- Consumes: `MarkdownParser` / `HighlightPlan` / `HighlightDiff`(Core)、`MarkdownTheme`(Task 6)
- Produces:
  - `extension NSTextContentManager { func textRange(for range: NSRange) -> NSTextRange? }`(internal)
  - `@MainActor public final class Highlighter`:
    - `public init(theme: MarkdownTheme)`
    - `public var theme: MarkdownTheme`(セットしても自動再ハイライトはしない — 呼び出し側が `rehighlightAll` を呼ぶ)
    - `public private(set) var currentPlan: HighlightPlan`
    - `public func rehighlightAll(contentStorage: NSTextContentStorage, layoutManager: NSTextLayoutManager)`
    - `public func noteEdit(editedRange: NSRange, changeInLength delta: Int)` — didProcessEditing から呼ぶ。currentPlan をシフトし編集レンジを記録するだけ(storage には触らない)
    - `public func flushPendingHighlight(contentStorage: NSTextContentStorage, layoutManager: NSTextLayoutManager)` — 保留編集があれば全文パース → 差分適用
- 適用契約: フォントは `performEditingTransaction` 内で `textStorage` へ、色は `layoutManager.setRenderingAttributes` / `addRenderingAttribute` へ。無効化レンジはまず本文スタイルにリセットしてから spansToApply を順に重ねる。

- [ ] **Step 1: 失敗するテストを書く**

`Tests/MarkdownEditorTests/HighlighterTests.swift`:

```swift
import AppKit
import Testing
@testable import MarkdownEditor
@testable import MarkdownEditorCore

/// ビューなしで TextKit2 スタックを組むテストヘルパー
@MainActor
private func makeTextKitStack(_ text: String) -> (NSTextContentStorage, NSTextLayoutManager) {
    let contentStorage = NSTextContentStorage()
    let layoutManager = NSTextLayoutManager()
    contentStorage.addTextLayoutManager(layoutManager)
    let container = NSTextContainer(size: CGSize(width: 400, height: 0))
    layoutManager.textContainer = container
    contentStorage.textStorage?.replaceCharacters(
        in: NSRange(location: 0, length: 0), with: text)
    return (contentStorage, layoutManager)
}

@MainActor
private func renderingColor(at offset: Int, _ layoutManager: NSTextLayoutManager) -> NSColor? {
    guard let contentManager = layoutManager.textContentManager,
          let location = contentManager.location(contentManager.documentRange.location, offsetBy: offset)
    else { return nil }
    var color: NSColor?
    layoutManager.enumerateRenderingAttributes(from: location, reverse: false) { _, attributes, _ in
        color = attributes[.foregroundColor] as? NSColor
        return false  // 最初の run だけ見る
    }
    return color
}

@MainActor @Test func rehighlightAllAppliesHeadingFont() {
    let (contentStorage, layoutManager) = makeTextKitStack("# Title")
    let highlighter = Highlighter(theme: .default)
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)

    let font = contentStorage.textStorage!.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
    #expect(font == MarkdownTheme.default.style(for: .heading(level: 1))?.font)
}

@MainActor @Test func rehighlightAllAppliesMarkerRenderingColor() {
    let (contentStorage, layoutManager) = makeTextKitStack("# Title")
    let highlighter = Highlighter(theme: .default)
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)

    // 位置 0 は "# " マーカー → syntaxMarker 色
    #expect(renderingColor(at: 0, layoutManager) == MarkdownTheme.default.renderingColor(for: .syntaxMarker))
}

@MainActor @Test func editUpdatesHighlightDifferentially() {
    let (contentStorage, layoutManager) = makeTextKitStack("plain text")
    let highlighter = Highlighter(theme: .default)
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)

    // 先頭に "# " を挿入して見出し化
    contentStorage.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
    highlighter.noteEdit(editedRange: NSRange(location: 0, length: 2), changeInLength: 2)
    highlighter.flushPendingHighlight(contentStorage: contentStorage, layoutManager: layoutManager)

    let font = contentStorage.textStorage!.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
    #expect(font == MarkdownTheme.default.style(for: .heading(level: 1))?.font)
}

@MainActor @Test func flushWithoutEditsDoesNothing() {
    let (contentStorage, layoutManager) = makeTextKitStack("# Title")
    let highlighter = Highlighter(theme: .default)
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)
    let planBefore = highlighter.currentPlan
    highlighter.flushPendingHighlight(contentStorage: contentStorage, layoutManager: layoutManager)
    #expect(highlighter.currentPlan == planBefore)
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter HighlighterTests`
Expected: コンパイルエラー(`Highlighter` 未定義)

- [ ] **Step 3: 実装を書く**

`Sources/MarkdownEditor/NSTextContentManager+Ranges.swift`:

```swift
import AppKit

extension NSTextContentManager {
    /// UTF-16 NSRange を NSTextRange に変換する。範囲外なら nil。
    func textRange(for range: NSRange) -> NSTextRange? {
        guard let start = location(documentRange.location, offsetBy: range.location),
              let end = location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }
}
```

`Sources/MarkdownEditor/Highlighter.swift`:

```swift
import AppKit
import MarkdownEditorCore

/// パース結果(HighlightPlan)を TextKit2 スタックへ差分適用するエンジン。
/// フォント(レイアウト属性)は textStorage へ、色は renderingAttributes へ適用する。
@MainActor
public final class Highlighter {
    public var theme: MarkdownTheme
    public private(set) var currentPlan = HighlightPlan()

    private let parser = MarkdownParser()
    private var pendingEditedRanges: [NSRange] = []

    public init(theme: MarkdownTheme) {
        self.theme = theme
    }

    /// 全文を再ハイライトする(初期表示・テーマ変更・プログラムによる全文置換時)。
    public func rehighlightAll(
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager
    ) {
        guard let storage = contentStorage.textStorage else { return }
        let plan = parser.highlightPlan(for: storage.string)
        let fullRange = NSRange(location: 0, length: storage.length)
        apply(
            spans: plan.spans,
            resetting: [fullRange],
            contentStorage: contentStorage,
            layoutManager: layoutManager
        )
        currentPlan = plan
        pendingEditedRanges = []
    }

    /// NSTextStorageDelegate の didProcessEditing(.editedCharacters)から呼ぶ。
    /// storage には触らず、計画のシフトと編集レンジの記録だけを行う。
    public func noteEdit(editedRange: NSRange, changeInLength delta: Int) {
        currentPlan = currentPlan.shifted(byEditAt: editedRange, changeInLength: delta)
        pendingEditedRanges.append(editedRange)
    }

    /// 保留中の編集をまとめて処理する(ランループの次サイクルで呼ぶ)。
    public func flushPendingHighlight(
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager
    ) {
        guard !pendingEditedRanges.isEmpty, let storage = contentStorage.textStorage else { return }
        let newPlan = parser.highlightPlan(for: storage.string)
        let changes = HighlightDiff.compute(
            old: currentPlan,
            new: newPlan,
            alwaysInvalidating: pendingEditedRanges
        )
        apply(
            spans: changes.spansToApply,
            resetting: changes.invalidatedRanges,
            contentStorage: contentStorage,
            layoutManager: layoutManager
        )
        currentPlan = newPlan
        pendingEditedRanges = []
    }

    // MARK: - 適用

    private func apply(
        spans: [HighlightSpan],
        resetting invalidated: [NSRange],
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager
    ) {
        guard let storage = contentStorage.textStorage else { return }
        let documentLength = storage.length

        // 1) レイアウトに影響する属性(フォント)— 編集トランザクション内で適用。
        //    setAttributes は .editedAttributes しか発火しないため didProcessEditing の
        //    文字編集ガードと組み合わせて再入しない。
        contentStorage.performEditingTransaction {
            for range in invalidated {
                let clipped = clip(range, to: documentLength)
                guard clipped.length > 0 else { continue }
                storage.setAttributes(theme.bodyLayoutAttributes, range: clipped)
            }
            for span in spans {
                guard let font = theme.layoutFont(for: span.kind) else { continue }
                let clipped = clip(span.range, to: documentLength)
                guard clipped.length > 0 else { continue }
                storage.addAttributes([.font: font], range: clipped)
            }
        }

        // 2) レイアウトに影響しない属性(色)— renderingAttributes へ。再レイアウトなし。
        for range in invalidated {
            let clipped = clip(range, to: documentLength)
            guard clipped.length > 0,
                  let textRange = contentStorage.textRange(for: clipped) else { continue }
            layoutManager.setRenderingAttributes([.foregroundColor: theme.bodyColor], for: textRange)
        }
        for span in spans {
            guard let color = theme.renderingColor(for: span.kind) else { continue }
            let clipped = clip(span.range, to: documentLength)
            guard clipped.length > 0,
                  let textRange = contentStorage.textRange(for: clipped) else { continue }
            layoutManager.addRenderingAttribute(.foregroundColor, value: color, for: textRange)
        }
    }

    /// レンジを文書長にクリップする。パース結果と storage の不整合が起きた場合の防波堤。
    private func clip(_ range: NSRange, to documentLength: Int) -> NSRange {
        let location = min(max(0, range.location), documentLength)
        let length = min(range.length, documentLength - location)
        assert(location == range.location && length == range.length,
               "HighlightPlan range \(range) exceeds document length \(documentLength)")
        return NSRange(location: location, length: length)
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter HighlighterTests`
Expected: 4 件 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownEditor/Highlighter.swift Sources/MarkdownEditor/NSTextContentManager+Ranges.swift Tests/MarkdownEditorTests/HighlighterTests.swift
git commit -m "feat(ui): add Highlighter applying diffs via editing transactions and rendering attributes

Task 7 of markdown-editor plan: fonts through performEditingTransaction,
colors through renderingAttributes to avoid relayout while typing."
```

---

### Task 8: MarkdownTextView — NSTextView サブクラス(UI 層)

**Files:**
- Create: `Sources/MarkdownEditor/MarkdownTextView.swift`
- Test: `Tests/MarkdownEditorTests/MarkdownTextViewTests.swift`

**Interfaces:**
- Consumes: `Highlighter`(Task 7)、`MarkdownTheme`(Task 6)
- Produces:
  - `@MainActor public final class MarkdownTextView: NSTextView, NSTextStorageDelegate`
    - `public convenience init(theme: MarkdownTheme = .default)` — TextKit2 スタックを自前構築
    - `public var theme: MarkdownTheme { get set }` — セットで背景色更新+全文再ハイライト
    - `public var showsLineNumbers: Bool { get set }`(Task 10 まで格納のみ)
    - `public func highlightAll()` — 全文再ハイライト(プログラムで string を差し替えた後に呼ぶ)
    - `func highlightNow()`(internal)— 保留編集を即時処理。テストと Task 9/10 が使用
    - `var markdownHighlighter: Highlighter { get }`(internal)— Task 9 のフラグメントプロバイダが計画を参照
- 編集フロー: `textStorage(_:didProcessEditing:range:changeInLength:)` で `.editedCharacters` のみ `noteEdit` + 次ランループに `highlightNow()` をスケジュール(1 ランループ内の連続編集はまとめて 1 回処理)。

- [ ] **Step 1: 失敗するテストを書く**

`Tests/MarkdownEditorTests/MarkdownTextViewTests.swift`:

```swift
import AppKit
import Testing
@testable import MarkdownEditor
@testable import MarkdownEditorCore

@MainActor @Test func usesTextKit2Stack() {
    let textView = MarkdownTextView()
    // textLayoutManager プロパティで確認する(layoutManager には触れない — TextKit1 フォールバック防止)
    #expect(textView.textLayoutManager != nil)
    #expect(textView.textContentStorage != nil)
}

@MainActor @Test func highlightsInitialTextAfterHighlightAll() {
    let textView = MarkdownTextView()
    textView.string = "# Title"
    textView.highlightAll()
    let font = textView.textStorage!.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
    #expect(font == MarkdownTheme.default.style(for: .heading(level: 1))?.font)
}

@MainActor @Test func typingSchedulesHighlight() {
    let textView = MarkdownTextView()
    textView.string = "plain"
    textView.highlightAll()
    // 編集をシミュレート(didProcessEditing 経由で noteEdit される)
    textView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
    // 非同期スケジュールを待たず、直接 flush して差分適用を検証
    textView.highlightNow()
    let font = textView.textStorage!.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
    #expect(font == MarkdownTheme.default.style(for: .heading(level: 1))?.font)
}

@MainActor @Test func settingThemeRehighlights() {
    let textView = MarkdownTextView()
    textView.string = "# Title"
    textView.highlightAll()
    var theme = MarkdownTheme.default
    theme.styles[.heading(level: 1)] = MarkdownTheme.Style(font: .systemFont(ofSize: 40, weight: .heavy))
    textView.theme = theme
    let font = textView.textStorage!.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
    #expect(font?.pointSize == 40)
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter MarkdownTextViewTests`
Expected: コンパイルエラー(`MarkdownTextView` 未定義)

- [ ] **Step 3: 実装を書く**

`Sources/MarkdownEditor/MarkdownTextView.swift`:

```swift
import AppKit
import MarkdownEditorCore

/// TextKit2 ベースの Markdown エディタビュー。
/// 警告: このクラス(および利用側)は `layoutManager` プロパティに絶対にアクセスしないこと。
/// アクセスした瞬間に TextKit1 互換モードへフォールバックし、全機能が壊れる。
@MainActor
public final class MarkdownTextView: NSTextView {
    let markdownHighlighter: Highlighter
    private var highlightScheduled = false

    public var theme: MarkdownTheme {
        get { markdownHighlighter.theme }
        set {
            markdownHighlighter.theme = newValue
            backgroundColor = newValue.backgroundColor
            font = newValue.bodyFont
            highlightAll()
        }
    }

    /// Task 10 でガター表示の切り替えに接続する。それまでは格納のみ。
    public var showsLineNumbers: Bool = true

    public convenience init(theme: MarkdownTheme = .default) {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: 1_000_000))
        container.widthTracksTextView = true
        layoutManager.textContainer = container
        self.init(frame: .zero, textContainer: container, theme: theme)
    }

    init(frame frameRect: NSRect, textContainer container: NSTextContainer?, theme: MarkdownTheme) {
        self.markdownHighlighter = Highlighter(theme: theme)
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("MarkdownTextView does not support NSCoder")
    }

    private func configure() {
        isRichText = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        font = markdownHighlighter.theme.bodyFont
        drawsBackground = true
        backgroundColor = markdownHighlighter.theme.backgroundColor
        // NSTextContentStorage は NSTextStorageObserving 経由で storage を監視するため
        // delegate スロットは空いている
        textStorage?.delegate = self
    }

    /// 全文を再ハイライトする。`string` をプログラムで差し替えた後に呼ぶこと。
    public func highlightAll() {
        guard let contentStorage = textContentStorage,
              let layoutManager = textLayoutManager else { return }
        markdownHighlighter.rehighlightAll(
            contentStorage: contentStorage, layoutManager: layoutManager)
    }

    /// 保留中の編集を即時処理する(通常は didProcessEditing からの遅延実行で呼ばれる)。
    func highlightNow() {
        highlightScheduled = false
        guard let contentStorage = textContentStorage,
              let layoutManager = textLayoutManager else { return }
        markdownHighlighter.flushPendingHighlight(
            contentStorage: contentStorage, layoutManager: layoutManager)
    }

    private func scheduleHighlight() {
        guard !highlightScheduled else { return }
        highlightScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.highlightNow()
        }
    }
}

extension MarkdownTextView: NSTextStorageDelegate {
    public func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        // 属性のみの編集(自分自身のハイライト適用)には反応しない — 無限ループ防止
        guard editedMask.contains(.editedCharacters) else { return }
        markdownHighlighter.noteEdit(editedRange: editedRange, changeInLength: delta)
        scheduleHighlight()
    }
}
```

**コンパイル注記:** Swift 6 で `NSTextStorageDelegate` メソッドの MainActor 分離が合わない場合は、メソッドを `nonisolated` にして本体を `MainActor.assumeIsolated { ... }` で包む(delegate 呼び出しは常にメインスレッド)。

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter MarkdownTextViewTests`
Expected: 4 件 PASS

- [ ] **Step 5: 全テスト回帰確認 & Commit**

Run: `swift test`
Expected: 全件 PASS

```bash
git add Sources/MarkdownEditor/MarkdownTextView.swift Tests/MarkdownEditorTests/MarkdownTextViewTests.swift
git commit -m "feat(ui): add MarkdownTextView with TextKit2 stack and edit-driven highlighting

Task 8 of markdown-editor plan: NSTextView subclass, storage delegate
edit capture, coalesced next-runloop differential highlight."
```

---

### Task 9: ブロック装飾フラグメント(UI 層)

**Files:**
- Create: `Sources/MarkdownEditor/BlockFragments.swift`
- Create: `Sources/MarkdownEditor/BlockFragmentProvider.swift`
- Modify: `Sources/MarkdownEditor/MarkdownTextView.swift`(プロバイダ接続)
- Test: `Tests/MarkdownEditorTests/BlockFragmentTests.swift`

**Interfaces:**
- Consumes: `HighlightPlan`(Core)、`MarkdownTheme`(Task 6)、`MarkdownTextView.markdownHighlighter`(Task 8)
- Produces(すべて internal):
  - `enum BlockDecoration: Equatable { case codeBlock, blockquote, thematicBreak }`
  - `struct Decoration: Equatable { var range: NSRange; var kind: BlockDecoration }`
  - `final class CodeBlockFragment / BlockquoteFragment / ThematicBreakFragment: NSTextLayoutFragment`
  - `@MainActor final class BlockFragmentProvider: NSObject, NSTextLayoutManagerDelegate`
    - `init(theme: MarkdownTheme)` / `var theme: MarkdownTheme`
    - `func update(plan: HighlightPlan, contentManager: NSTextContentManager, layoutManager: NSTextLayoutManager)` — 装飾リストを差し替え、変化したレンジのレイアウトを無効化
  - `MarkdownTextView` は `configure()` でプロバイダを生成し `textLayoutManager?.delegate` に設定、`highlightAll()`/`highlightNow()` の末尾で `update(plan:)` を呼ぶ

- [ ] **Step 1: 失敗するテストを書く**

`Tests/MarkdownEditorTests/BlockFragmentTests.swift`:

```swift
import AppKit
import Testing
@testable import MarkdownEditor
@testable import MarkdownEditorCore

@MainActor
private func layoutFragments(in textView: MarkdownTextView) -> [NSTextLayoutFragment] {
    let layoutManager = textView.textLayoutManager!
    layoutManager.ensureLayout(for: layoutManager.documentRange)
    var fragments: [NSTextLayoutFragment] = []
    layoutManager.enumerateTextLayoutFragments(
        from: layoutManager.documentRange.location, options: []
    ) { fragment in
        fragments.append(fragment)
        return true
    }
    return fragments
}

@MainActor @Test func codeBlockParagraphGetsCodeBlockFragment() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "plain\n\n```\nlet x = 1\n```"
    textView.highlightAll()
    let fragments = layoutFragments(in: textView)
    #expect(fragments.contains { $0 is CodeBlockFragment })
    // 先頭の "plain" 段落は通常フラグメント
    #expect(!(fragments.first is CodeBlockFragment))
}

@MainActor @Test func blockquoteParagraphGetsBlockquoteFragment() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "> quoted"
    textView.highlightAll()
    #expect(layoutFragments(in: textView).contains { $0 is BlockquoteFragment })
}

@MainActor @Test func thematicBreakGetsThematicBreakFragment() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "a\n\n---\n\nb"
    textView.highlightAll()
    #expect(layoutFragments(in: textView).contains { $0 is ThematicBreakFragment })
}

@MainActor @Test func editingIntoCodeBlockSwapsFragment() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "```\ncode\n```\ntail"
    textView.highlightAll()
    #expect(layoutFragments(in: textView).contains { $0 is CodeBlockFragment })
    // 開始フェンスを壊す → コードブロック消滅
    textView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 1), with: "x")
    textView.highlightNow()
    #expect(!layoutFragments(in: textView).contains { $0 is CodeBlockFragment })
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter BlockFragmentTests`
Expected: コンパイルエラー(`CodeBlockFragment` 未定義)

- [ ] **Step 3: フラグメント 3 種を書く**

`Sources/MarkdownEditor/BlockFragments.swift`:

```swift
import AppKit

/// コードブロック: テキスト背面に角丸背景
final class CodeBlockFragment: NSTextLayoutFragment {
    var fillColor: NSColor = .quaternarySystemFill

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        let rect = renderingSurfaceBounds.insetBy(dx: 2, dy: 0)
        let path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.setFillColor(fillColor.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

/// 引用: 行頭側に縦のアクセントバー
final class BlockquoteFragment: NSTextLayoutFragment {
    var barColor: NSColor = .systemGray

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        let bounds = renderingSurfaceBounds
        context.setFillColor(barColor.cgColor)
        context.fill(CGRect(x: bounds.minX + 2, y: bounds.minY, width: 3, height: bounds.height))
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

/// 水平線: "---" テキストに重ねて罫線を描画
final class ThematicBreakFragment: NSTextLayoutFragment {
    var lineColor: NSColor = .separatorColor

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        let bounds = renderingSurfaceBounds
        context.setStrokeColor(lineColor.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: bounds.minX, y: bounds.midY))
        context.addLine(to: CGPoint(x: bounds.maxX, y: bounds.midY))
        context.strokePath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}
```

- [ ] **Step 4: プロバイダを書く**

`Sources/MarkdownEditor/BlockFragmentProvider.swift`:

```swift
import AppKit
import MarkdownEditorCore

enum BlockDecoration: Equatable {
    case codeBlock
    case blockquote
    case thematicBreak
}

struct Decoration: Equatable {
    var range: NSRange
    var kind: BlockDecoration
}

/// HighlightPlan のブロック情報に基づき、装飾付き NSTextLayoutFragment を供給する。
@MainActor
final class BlockFragmentProvider: NSObject, NSTextLayoutManagerDelegate {
    var theme: MarkdownTheme
    /// NSTextView が内部で delegate を持っていた場合に備えて転送先を保持
    weak var fallbackDelegate: NSTextLayoutManagerDelegate?
    private var decorations: [Decoration] = []

    init(theme: MarkdownTheme) {
        self.theme = theme
    }

    /// 新しい計画から装飾リストを作り直し、変化したレンジのレイアウトを無効化する。
    func update(
        plan: HighlightPlan,
        contentManager: NSTextContentManager,
        layoutManager: NSTextLayoutManager
    ) {
        let new = plan.spans.compactMap { span -> Decoration? in
            switch span.kind {
            case .codeBlock: Decoration(range: span.range, kind: .codeBlock)
            case .blockquote: Decoration(range: span.range, kind: .blockquote)
            case .thematicBreak: Decoration(range: span.range, kind: .thematicBreak)
            default: nil
            }
        }
        guard new != decorations else { return }
        // 旧・新の装飾レンジを無効化してフラグメントを再生成させる
        let dirtyRanges = (decorations + new).map(\.range)
        decorations = new
        for range in dirtyRanges {
            if let textRange = contentManager.textRange(for: range) {
                layoutManager.invalidateLayout(for: textRange)
            }
        }
    }

    private func decoration(at location: NSTextLocation, in contentManager: NSTextContentManager) -> BlockDecoration? {
        let offset = contentManager.offset(from: contentManager.documentRange.location, to: location)
        return decorations.first { NSLocationInRange(offset, $0.range) }?.kind
    }

    nonisolated func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        MainActor.assumeIsolated {
            guard let contentManager = textLayoutManager.textContentManager,
                  let kind = decoration(at: location, in: contentManager) else {
                return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
            }
            switch kind {
            case .codeBlock:
                let fragment = CodeBlockFragment(textElement: textElement, range: textElement.elementRange)
                fragment.fillColor = theme.codeBlockBackgroundColor
                return fragment
            case .blockquote:
                let fragment = BlockquoteFragment(textElement: textElement, range: textElement.elementRange)
                fragment.barColor = theme.blockquoteBarColor
                return fragment
            case .thematicBreak:
                let fragment = ThematicBreakFragment(textElement: textElement, range: textElement.elementRange)
                fragment.lineColor = theme.thematicBreakLineColor
                return fragment
            }
        }
    }

    // 未実装のデリゲートメソッドは既存デリゲートへ転送する
    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (fallbackDelegate?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if super.responds(to: aSelector) { return nil }
        return fallbackDelegate
    }
}
```

- [ ] **Step 5: MarkdownTextView に接続する**

`Sources/MarkdownEditor/MarkdownTextView.swift` に以下を追加:

プロパティ(`markdownHighlighter` の下):

```swift
    private var fragmentProvider: BlockFragmentProvider!
```

`configure()` の末尾に追加:

```swift
        let provider = BlockFragmentProvider(theme: markdownHighlighter.theme)
        provider.fallbackDelegate = textLayoutManager?.delegate
        textLayoutManager?.delegate = provider
        fragmentProvider = provider
```

`theme` の setter(`highlightAll()` の前)に追加:

```swift
            fragmentProvider.theme = newValue
```

`highlightAll()` と `highlightNow()` の末尾に共通処理を追加:

```swift
    private func updateBlockDecorations() {
        guard let contentStorage = textContentStorage,
              let layoutManager = textLayoutManager else { return }
        fragmentProvider.update(
            plan: markdownHighlighter.currentPlan,
            contentManager: contentStorage,
            layoutManager: layoutManager
        )
    }
```

`highlightAll()` の末尾に `updateBlockDecorations()`、`highlightNow()` の末尾に `updateBlockDecorations()` を追記。

- [ ] **Step 6: テストが通ることを確認**

Run: `swift test --filter BlockFragmentTests`
Expected: 4 件 PASS

**注記:** `textLayoutManager.delegate` の差し替えで NSTextView 標準動作(選択・スクロール)が壊れる兆候があれば、`fallbackDelegate` 転送が機能しているかを最初に疑う。`ensureLayout` が使えない場合(API 名差異)は `layoutViewport()` + フレーム設定で代替する。

- [ ] **Step 7: 全テスト回帰確認 & Commit**

Run: `swift test`
Expected: 全件 PASS

```bash
git add Sources/MarkdownEditor Tests/MarkdownEditorTests/BlockFragmentTests.swift
git commit -m "feat(ui): add block decoration fragments (code/quote/hr)

Task 9 of markdown-editor plan: NSTextLayoutFragment subclasses with
custom draw(at:in:), provider via NSTextLayoutManagerDelegate,
layout invalidation on block changes."
```

---

### Task 10: 行番号ガター + scrollableMarkdownEditor(UI 層)

**Files:**
- Create: `Sources/MarkdownEditor/LineIndex.swift`
- Create: `Sources/MarkdownEditor/LineNumberGutterView.swift`
- Modify: `Sources/MarkdownEditor/MarkdownTextView.swift`(viewport デリゲートのオーバーライド + ファクトリ)
- Test: `Tests/MarkdownEditorTests/LineIndexTests.swift`

**Interfaces:**
- Consumes: `MarkdownTextView`(Task 8/9)
- Produces:
  - `struct LineIndex`(internal): `init(text: String)`, `func lineNumber(at utf16Offset: Int) -> Int`(1-based)
  - `final class LineNumberGutterView: NSRulerView`(internal): `struct Line { var number: Int; var yInTextView: CGFloat }`, `var lines: [Line]`
  - `MarkdownTextView`:
    - macOS 27 の公開デリゲート準拠を利用した 3 つの viewport メソッドオーバーライド(必ず `super` を呼ぶ)
    - `public static func scrollableMarkdownEditor(theme: MarkdownTheme = .default) -> NSScrollView` — ガター付きスクロールビュー。`documentView` は `MarkdownTextView`
    - `showsLineNumbers` が `enclosingScrollView?.rulersVisible` に接続される

- [ ] **Step 1: LineIndex の失敗するテストを書く**

`Tests/MarkdownEditorTests/LineIndexTests.swift`:

```swift
import Foundation
import Testing
@testable import MarkdownEditor

@Test func lineNumbersForSimpleText() {
    let index = LineIndex(text: "one\ntwo\nthree")
    #expect(index.lineNumber(at: 0) == 1)   // "o"
    #expect(index.lineNumber(at: 3) == 1)   // "\n" 自体は行 1
    #expect(index.lineNumber(at: 4) == 2)   // "t"
    #expect(index.lineNumber(at: 8) == 3)   // "t"
}

@Test func lineNumbersWithJapanese() {
    let index = LineIndex(text: "あいう\nかきく")
    #expect(index.lineNumber(at: 0) == 1)
    #expect(index.lineNumber(at: 4) == 2)   // "か"(UTF-16 で 4)
}

@Test func emptyTextIsSingleLine() {
    let index = LineIndex(text: "")
    #expect(index.lineNumber(at: 0) == 1)
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter LineIndexTests`
Expected: コンパイルエラー(`LineIndex` 未定義)

- [ ] **Step 3: LineIndex を実装する**

`Sources/MarkdownEditor/LineIndex.swift`:

```swift
import Foundation

/// UTF-16 オフセット → 1-based 行番号の変換。編集のたびに作り直す
/// (10k 行でも数ミリ秒。ボトルネックになったら差分更新に切り替える)。
struct LineIndex {
    /// 各行の先頭 UTF-16 オフセット(昇順)
    private let lineStarts: [Int]

    init(text: String) {
        let ns = text as NSString
        var starts = [0]
        var i = 0
        while i < ns.length {
            if ns.character(at: i) == 10 {  // "\n"
                starts.append(i + 1)
            }
            i += 1
        }
        self.lineStarts = starts
    }

    func lineNumber(at utf16Offset: Int) -> Int {
        // lineStarts[i] <= offset を満たす最大の i を二分探索
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= utf16Offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low + 1
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter LineIndexTests`
Expected: 3 件 PASS

- [ ] **Step 5: ガタービューを実装する**

`Sources/MarkdownEditor/LineNumberGutterView.swift`:

```swift
import AppKit

/// スクロールビューの垂直ルーラーとして行番号を描画する。
/// 行情報は MarkdownTextView の viewport レイアウトパスから供給される。
@MainActor
final class LineNumberGutterView: NSRulerView {
    struct Line: Equatable {
        var number: Int
        /// テキストビュー座標系でのフラグメント上端 y
        var yInTextView: CGFloat
    }

    var lines: [Line] = [] {
        didSet { if lines != oldValue { needsDisplay = true } }
    }
    var numberFont: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    var numberColor: NSColor = .tertiaryLabelColor

    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 44
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("LineNumberGutterView does not support NSCoder")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: numberColor,
        ]
        for line in lines {
            let label = NSAttributedString(string: "\(line.number)", attributes: attributes)
            let size = label.size()
            let y = convert(NSPoint(x: 0, y: line.yInTextView), from: textView).y
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y))
        }
    }
}
```

- [ ] **Step 6: MarkdownTextView に viewport オーバーライドとファクトリを追加する**

`Sources/MarkdownEditor/MarkdownTextView.swift` に追加。

プロパティ:

```swift
    weak var gutterView: LineNumberGutterView?
    private var lineIndex: LineIndex?
    private var collectedLines: [LineNumberGutterView.Line] = []
```

`showsLineNumbers` を格納プロパティから置き換え:

```swift
    public var showsLineNumbers: Bool = true {
        didSet { enclosingScrollView?.rulersVisible = showsLineNumbers }
    }
```

viewport デリゲートオーバーライド(macOS 27 で NSTextView が NSTextViewportLayoutControllerDelegate に公開準拠。**必ず super を呼ぶ**):

```swift
    public override func textViewportLayoutControllerWillLayout(
        _ textViewportLayoutController: NSTextViewportLayoutController
    ) {
        super.textViewportLayoutControllerWillLayout(textViewportLayoutController)
        collectedLines.removeAll(keepingCapacity: true)
    }

    public override func textViewportLayoutController(
        _ textViewportLayoutController: NSTextViewportLayoutController,
        configureRenderingSurfaceFor textLayoutFragment: NSTextLayoutFragment
    ) {
        super.textViewportLayoutController(
            textViewportLayoutController,
            configureRenderingSurfaceFor: textLayoutFragment
        )
        guard gutterView != nil,
              let contentManager = textLayoutManager?.textContentManager else { return }
        let offset = contentManager.offset(
            from: contentManager.documentRange.location,
            to: textLayoutFragment.rangeInElement.location
        )
        let index = lineIndex ?? LineIndex(text: string)
        lineIndex = index
        collectedLines.append(.init(
            number: index.lineNumber(at: offset),
            yInTextView: textLayoutFragment.layoutFragmentFrame.minY
        ))
    }

    public override func textViewportLayoutControllerDidLayout(
        _ textViewportLayoutController: NSTextViewportLayoutController
    ) {
        super.textViewportLayoutControllerDidLayout(textViewportLayoutController)
        gutterView?.lines = collectedLines
    }
```

`textStorage(_:didProcessEditing:...)` の `.editedCharacters` ガード直後に行キャッシュ無効化を追加:

```swift
        lineIndex = nil
```

ファクトリ(クラス末尾に追加):

```swift
    /// ガター付きの推奨構成。documentView は MarkdownTextView。
    public static func scrollableMarkdownEditor(theme: MarkdownTheme = .default) -> NSScrollView {
        let textView = MarkdownTextView(theme: theme)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true

        let gutter = LineNumberGutterView(scrollView: scrollView)
        gutter.clientView = textView
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = textView.showsLineNumbers
        textView.gutterView = gutter
        return scrollView
    }
```

- [ ] **Step 7: ビルドと全テストを確認 & Commit**

Run: `swift build && swift test`
Expected: ビルド成功、全件 PASS(ガターの見た目は Task 14 の computer-use で確認)

**注記:** viewport デリゲートメソッドのシグネチャが上記と異なりコンパイルエラーになる場合は、`textkit2` スキルの `references/wwdc2026-session-370.md` にある正確なシグネチャを確認して合わせること。オーバーライド自体が不可能な場合(準拠が非公開だった場合)のフォールバックは `NSTextViewportLayoutController` の delegate 差し替え+転送だが、まず公式 API を試す。

```bash
git add Sources/MarkdownEditor Tests/MarkdownEditorTests/LineIndexTests.swift
git commit -m "feat(ui): add line-number gutter via viewport layout delegate

Task 10 of markdown-editor plan: macOS 27 public viewport delegate
overrides collect fragment frames; NSRulerView draws numbers;
scrollableMarkdownEditor() factory."
```

---

### Task 11: SwiftUI ラッパー MarkdownEditorView(UI 層)

**Files:**
- Create: `Sources/MarkdownEditor/MarkdownEditorView.swift`
- Test: `Tests/MarkdownEditorTests/MarkdownEditorViewTests.swift`

**Interfaces:**
- Consumes: `MarkdownTextView.scrollableMarkdownEditor(theme:)`(Task 10)
- Produces:
  - `public struct MarkdownEditorView: NSViewRepresentable`
    - `public init(text: Binding<String>, theme: MarkdownTheme = .default)`
    - `public func showsLineNumbers(_ flag: Bool) -> MarkdownEditorView`(デフォルト true)
    - `makeNSView` → `NSScrollView`(documentView が `MarkdownTextView`)
    - 双方向同期: ユーザー編集 → `textDidChange` → Binding 更新 / Binding 変更 → `updateNSView` で `string` 差し替え + `highlightAll()`(フィードバックループは Coordinator のフラグで遮断)

- [ ] **Step 1: 失敗するテストを書く**

`Tests/MarkdownEditorTests/MarkdownEditorViewTests.swift`:

```swift
import SwiftUI
import Testing
@testable import MarkdownEditor

// NSViewRepresentable.Context は外部から構築できないため、makeNSView 経路は
// ExampleMacOS(Task 13-14)で検証し、ここでは Coordinator の同期ロジックを検証する。

@MainActor @Test func textDidChangeUpdatesBinding() {
    var text = "a"
    let binding = Binding(get: { text }, set: { text = $0 })
    let coordinator = MarkdownEditorView(text: binding).makeCoordinator()

    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    textView.string = "changed"
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    #expect(text == "changed")
}

@MainActor @Test func swiftUIUpdateGuardSuppressesFeedback() {
    var text = "a"
    let binding = Binding(get: { text }, set: { text = $0 })
    let coordinator = MarkdownEditorView(text: binding).makeCoordinator()

    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    textView.string = "changed"
    coordinator.isUpdatingFromSwiftUI = true
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    #expect(text == "a")  // ガード中は Binding を更新しない
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter MarkdownEditorViewTests`
Expected: コンパイルエラー(`MarkdownEditorView` 未定義)

- [ ] **Step 3: 実装を書く**

`Sources/MarkdownEditor/MarkdownEditorView.swift`:

```swift
import SwiftUI

/// MarkdownTextView の SwiftUI ラッパー。
public struct MarkdownEditorView: NSViewRepresentable {
    @Binding private var text: String
    private var theme: MarkdownTheme
    private var showsLineNumbers = true

    public init(text: Binding<String>, theme: MarkdownTheme = .default) {
        self._text = text
        self.theme = theme
    }

    public func showsLineNumbers(_ flag: Bool) -> MarkdownEditorView {
        var copy = self
        copy.showsLineNumbers = flag
        return copy
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MarkdownTextView.scrollableMarkdownEditor(theme: theme)
        let textView = scrollView.documentView as! MarkdownTextView
        textView.delegate = context.coordinator
        textView.string = text
        textView.highlightAll()
        textView.showsLineNumbers = showsLineNumbers
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! MarkdownTextView
        context.coordinator.text = $text
        if textView.string != text {
            context.coordinator.isUpdatingFromSwiftUI = true
            textView.string = text
            textView.highlightAll()
            context.coordinator.isUpdatingFromSwiftUI = false
        }
        if textView.theme.bodyFont != theme.bodyFont || textView.theme.bodyColor != theme.bodyColor {
            textView.theme = theme
        }
        textView.showsLineNumbers = showsLineNumbers
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var isUpdatingFromSwiftUI = false

        init(text: Binding<String>) {
            self.text = text
        }

        public func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromSwiftUI,
                  let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
```

**注記:** `updateNSView` のテーマ比較は「全フィールド比較」ではなく代表フィールドのみ(NSFont/NSColor の同値性で十分)。毎回 `textView.theme = theme` を代入すると updateNSView のたびに全文再ハイライトが走るため、この比較は省略しないこと。

- [ ] **Step 4: テストが通ることを確認 & Commit**

Run: `swift test`
Expected: 全件 PASS

```bash
git add Sources/MarkdownEditor/MarkdownEditorView.swift Tests/MarkdownEditorTests/MarkdownEditorViewTests.swift
git commit -m "feat(ui): add SwiftUI MarkdownEditorView wrapper

Task 11 of markdown-editor plan: NSViewRepresentable with two-way
text binding and feedback-loop guard."
```

---

### Task 12: パフォーマンス回帰テスト(Core)

**Files:**
- Test: `Tests/MarkdownEditorCoreTests/PerformanceTests.swift`

**Interfaces:**
- Consumes: `MarkdownParser`(Task 5)、`HighlightDiff`(Task 3)
- Produces: 回帰テストのみ(公開 API なし)

- [ ] **Step 1: テストを書く(このタスクは実装がないため「失敗→実装」ではなく閾値検証)**

`Tests/MarkdownEditorCoreTests/PerformanceTests.swift`:

```swift
import Foundation
import Testing
@testable import MarkdownEditorCore

private func makeLargeDocument(lines: Int) -> String {
    var result: [String] = []
    result.reserveCapacity(lines)
    for i in 0..<lines {
        switch i % 6 {
        case 0: result.append("# 見出し \(i)")
        case 1: result.append("Some **bold** and *italic* text with `code` on line \(i).")
        case 2: result.append("- list item \(i) with [link](https://example.com/\(i))")
        case 3: result.append("> 引用テキスト \(i) 🎉")
        case 4: result.append("```\nlet x = \(i)\n```")
        default: result.append("日本語の段落 \(i) plain paragraph.")
        }
    }
    return result.joined(separator: "\n\n")
}

@Test func fullParseOf10kLinesStaysWithinBudget() {
    let text = makeLargeDocument(lines: 10_000)
    let parser = MarkdownParser()
    _ = parser.highlightPlan(for: text)  // ウォームアップ

    let clock = ContinuousClock()
    let elapsed = clock.measure {
        _ = parser.highlightPlan(for: text)
    }
    // 実機目標は 16ms 以内(spec)。CI マシン差を見込んで 100ms を回帰閾値にする。
    #expect(elapsed < .milliseconds(100), "全文パースが \(elapsed) かかった")
}

@Test func diffOfSingleEditIsSmall() {
    let text = makeLargeDocument(lines: 10_000)
    let parser = MarkdownParser()
    let before = parser.highlightPlan(for: text)

    // 文書中央の 1 段落だけを変更したのと等価な編集(1 文字挿入)
    let insertAt = (text as NSString).length / 2
    let edited = (text as NSString).replacingCharacters(
        in: NSRange(location: insertAt, length: 0), with: "x")
    let after = parser.highlightPlan(for: edited)

    let shifted = before.shifted(
        byEditAt: NSRange(location: insertAt, length: 1), changeInLength: 1)
    let changes = HighlightDiff.compute(
        old: shifted, new: after,
        alwaysInvalidating: [NSRange(location: insertAt, length: 1)])

    // 差分適用対象が全スパンの 1% 未満であること(=差分化が機能している)
    #expect(changes.spansToApply.count < after.spans.count / 100,
            "再適用スパン \(changes.spansToApply.count) / 全 \(after.spans.count)")
}
```

- [ ] **Step 2: テストが通ることを確認**

Run: `swift test --filter PerformanceTests`
Expected: 2 件 PASS。`diffOfSingleEditIsSmall` が失敗する場合は差分化が壊れている(shifted / compute の突き合わせを確認)。`fullParseOf10kLines` が失敗する場合はマッパーの計算量を疑う(特に `appendQuoteMarkers` の走査)。

- [ ] **Step 3: Commit**

```bash
git add Tests/MarkdownEditorCoreTests/PerformanceTests.swift
git commit -m "test(core): add performance regression tests for 10k-line documents

Task 12 of markdown-editor plan: full-parse budget and
differential-application ratio guards."
```

---

### Task 13: ExampleMacOS アプリ

**Files:**
- Create: `ExampleMacOS/project.yml`
- Create: `ExampleMacOS/Sources/ExampleMacOSApp.swift`
- Modify: `.gitignore`(生成物を除外)

**Interfaces:**
- Consumes: `MarkdownEditorView` / `MarkdownTheme`(ライブラリの公開 API のみ。@testable 不使用)
- Produces: `ExampleMacOS.xcodeproj`(XcodeGen 生成、コミットしない)、起動可能な .app

- [ ] **Step 1: XcodeGen 定義を書く**

`ExampleMacOS/project.yml`:

```yaml
name: ExampleMacOS
options:
  bundleIdPrefix: net.kymmt
packages:
  MarkdownEditor:
    path: ..
targets:
  ExampleMacOS:
    type: application
    platform: macOS
    deploymentTarget: "27.0"
    sources: [Sources]
    dependencies:
      - package: MarkdownEditor
        product: MarkdownEditor
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        PRODUCT_BUNDLE_IDENTIFIER: net.kymmt.ExampleMacOS
        SWIFT_VERSION: "6.0"
        CODE_SIGN_IDENTITY: "-"
```

- [ ] **Step 2: アプリ本体を書く**

`ExampleMacOS/Sources/ExampleMacOSApp.swift`:

```swift
import MarkdownEditor
import SwiftUI

@main
struct ExampleMacOSApp: App {
    var body: some Scene {
        WindowGroup("MarkdownEditor Example") {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var text = ContentView.sampleDocument
    @State private var showsLineNumbers = true

    var body: some View {
        MarkdownEditorView(text: $text)
            .showsLineNumbers(showsLineNumbers)
            .frame(minWidth: 640, minHeight: 480)
            .toolbar {
                ToolbarItem {
                    Toggle("行番号", isOn: $showsLineNumbers)
                }
            }
    }

    static let sampleDocument = """
    # MarkdownEditor デモ

    TextKit2 をフル活用した **シンタックスハイライト型** エディタです。\
    *イタリック* や `インラインコード` も装飾されます。

    ## コードブロック

    ```swift
    let editor = MarkdownTextView()
    editor.string = "# Hello"
    ```

    > 引用は縦バー付きで表示されます。
    > > ネストも可能。

    - リスト項目 1
    - リスト項目 2 と [リンク](https://example.com)

    1. 番号付きリスト

    ---

    日本語も絵文字 🎉 も正しくハイライトされます。
    """
}
```

- [ ] **Step 3: .gitignore に生成物を追加**

`.gitignore` の末尾に追記:

```
ExampleMacOS/ExampleMacOS.xcodeproj
ExampleMacOS/build
```

- [ ] **Step 4: プロジェクト生成とビルド**

Run:

```bash
cd ExampleMacOS && xcodegen generate && \
xcodebuild -project ExampleMacOS.xcodeproj -scheme ExampleMacOS \
  -configuration Debug -derivedDataPath build build
```

Expected: `** BUILD SUCCEEDED **`

(Xcode MCP がセッションに接続されている場合は、同等のビルドを MCP のビルドツールで行ってよい。)

- [ ] **Step 5: Commit**

```bash
git add ExampleMacOS/project.yml ExampleMacOS/Sources .gitignore
git commit -m "feat(example): add ExampleMacOS SwiftUI app via XcodeGen

Task 13 of markdown-editor plan: local-package-referencing demo app
with sample document, theme default, line-number toggle."
```

---

### Task 14: 実機検証(起動 + computer-use)

**Files:** なし(検証タスク。修正が出た場合は該当ファイルを直して個別コミット)

**Interfaces:**
- Consumes: Task 13 でビルドした `ExampleMacOS.app`

- [ ] **Step 1: アプリを起動する**

Run: `open ExampleMacOS/build/Build/Products/Debug/ExampleMacOS.app`
Expected: ウィンドウが開き、サンプル文書が表示される

- [ ] **Step 2: computer-use で表示を検証する**

computer-use MCP の `request_access` で ExampleMacOS へのアクセスを取得し、`screenshot` で以下を目視確認する:

1. `# MarkdownEditor デモ` が大きな太字で表示され、`# ` が淡色
2. `**シンタックスハイライト型**` が太字、`**` が淡色
3. コードブロックに角丸背景があり、フェンス行が淡色
4. 引用行の行頭に縦バー
5. リストマーカー(`-` `1.`)に色
6. リンクがリンク色
7. `---` に水平罫線が重なる
8. 左端ガターに行番号(折り返し行には番号なし)
9. 日本語・絵文字が正しい位置でハイライトされている(ズレなし)

- [ ] **Step 3: computer-use で編集動作を検証する**

1. 文末をクリックし `type` で改行 + `## 追加見出し` を入力 → 入力直後に見出しスタイルが付くこと
2. 既存コードブロックの開始フェンス ``` の 1 文字を削除 → ブロック背景が消えること(非局所的な再解釈の確認)
3. 元に戻す(Cmd+Z)→ 背景が復活すること(undo とハイライトの整合)
4. ツールバーの「行番号」トグルを切り替え → ガターが表示/非表示になること
5. 各操作後に `screenshot` で確認し、問題があれば systematic-debugging スキルで原因を特定して修正する

- [ ] **Step 4: 全テスト最終確認 & Commit(修正があった場合)**

Run: `swift test`
Expected: 全件 PASS

検証で修正が発生した場合のみ:

```bash
git add -A
git commit -m "fix: address issues found in live verification

Task 14 of markdown-editor plan: fixes from computer-use
verification of ExampleMacOS."
```

---

## 実装順序と依存関係

```
Task 1 (パッケージ) → Task 2 (Plan) → Task 3 (Diff) ┐
                    → Task 4 (Converter) → Task 5 (Mapper/Parser) ┤
                                                                   ├→ Task 7 (Highlighter) → Task 8 (TextView)
Task 6 (Theme) ────────────────────────────────────────────────────┘        ↓
                                                              Task 9 (Fragments) → Task 10 (Gutter) → Task 11 (SwiftUI)
Task 12 (性能テスト) は Task 5 以降いつでも                                 → Task 13 (Example) → Task 14 (検証)
```

直列実行が基本(Task 6 のみ Task 2 完了後なら並行可)。

## 明示的にやらないこと(YAGNI)

- GFM 拡張(テーブル・タスクリスト・打ち消し線)— v2
- コードブロック内の言語別ハイライト — v2
- バックグラウンドパース(spec 記載の世代番号方式)— v1 は同期パースで性能目標を満たせる見込みのため、Task 12 の回帰テストが実測で破綻した場合にのみ着手する
- iOS ターゲット — 将来。Core/UI 分離で準備済み
- テーマのライブ切替アニメーション、設定永続化
