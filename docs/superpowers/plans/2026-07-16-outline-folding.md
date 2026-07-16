# 見出しアウトライン / セクション折りたたみ Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 見出しベースのアウトライン提供 API とセクション折りたたみ(ガターのシェブロン + 公開 API)を実装する。

**Architecture:** 折りたたみは `NSTextContentStorageDelegate.shouldEnumerate` で折畳中セクションの本体段落を列挙から除外する(テキストストレージ無変更)。LapermCore に純ロジック(`OutlineBuilder` / `FoldingState`)、Laperm に `FoldingController`(delegate 実装・同期・編集追従)と UI 統合を置く。

**Tech Stack:** Swift 6 / macOS 27+ / TextKit 2 / Swift Testing

**Spec:** `docs/superpowers/specs/2026-07-16-outline-folding-design.md`(全タスクの正とする)

## Global Constraints

- ターゲット: Swift 6, macOS 27+。テストは Swift Testing(`@Test` / `#expect`)
- **`MarkdownTextView`(および利用側)は `layoutManager` プロパティに絶対アクセスしない**(TextKit 1 フォールバック防止)。`textLayoutManager` を使う
- 折りたたみは textStorage を一切変更しない(`Binding<String>` は常に全文、undo 非汚染)
- コード中のドキュメントコメントは既存に合わせ日本語
- テストは `swift test`(全件実行。`--filter` はこの環境で効かない。全件で ~0.5s)
- コミットは main へ直接。メッセージ末尾に `Task context: 見出しアウトライン/折りたたみ (docs/superpowers/specs/2026-07-16-outline-folding-design.md)` と `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` トレーラを付ける
- Example のビルド確認: `xcodebuild -project Example/Example.xcodeproj -scheme ExampleMacOS build`
- ユーザー可視の挙動(シェブロン・折畳・自動展開)は最後に computer use による GUI 検証が必須(プロジェクトスキル `verifying-macos-gui` に従う)

---

### Task 1: OutlineItem + OutlineBuilder(LapermCore)

**Files:**
- Create: `Sources/LapermCore/OutlineBuilder.swift`
- Test: `Tests/LapermCoreTests/OutlineBuilderTests.swift`

**Interfaces:**
- Consumes: `HighlightPlan.spans`(`SyntaxKind.heading(level:)` スパン)、`MarkdownParser.highlightPlan(for:)`(テストで使用)
- Produces: `OutlineItem`(`level: Int`, `title: String`, `headingRange: NSRange`, `sectionRange: NSRange`, `bodyRange: NSRange`, `headingLocation: Int { headingRange.location }`)と `OutlineBuilder.build(from: HighlightPlan, text: String) -> [OutlineItem]`。後続タスクは `headingLocation` を折畳キー、`bodyRange` を隠蔽範囲として使う

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermCoreTests/OutlineBuilderTests.swift`:

```swift
import Foundation
import Testing
@testable import LapermCore

private func outline(for text: String) -> [OutlineItem] {
    OutlineBuilder.build(from: MarkdownParser().highlightPlan(for: text), text: text)
}

@Test func buildsFlatOutlineWithLevelsAndTitles() {
    let items = outline(for: "# One\ntext\n## Two\n### Three\n")
    #expect(items.map(\.level) == [1, 2, 3])
    #expect(items.map(\.title) == ["One", "Two", "Three"])
}

@Test func sectionRangeExtendsToNextSameOrHigherLevelHeading() {
    // "# A\n" (0-3) "body\n" (4-8) "## B\n" (9-13) "b2\n" (14-16) "# C\n" (17-20) "tail" (21-24)
    let text = "# A\nbody\n## B\nb2\n# C\ntail"
    let items = outline(for: text)
    #expect(items.count == 3)
    // A のセクションは C の行頭(17)の直前まで(## B を包含)
    #expect(items[0].sectionRange == NSRange(location: 0, length: 17))
    // B のセクションは同位以上の次見出し C の行頭まで
    #expect(items[1].sectionRange == NSRange(location: 9, length: 8))
    // 末尾セクションは文書末尾まで
    #expect(items[2].sectionRange == NSRange(location: 17, length: 8))
}

@Test func bodyRangeExcludesHeadingLine() {
    let text = "# A\nbody\n## B\nb2\n# C\ntail"
    let items = outline(for: text)
    // A の本体は "body\n## B\nb2\n"(4〜16)
    #expect(items[0].bodyRange == NSRange(location: 4, length: 13))
    // C の本体は "tail"(21〜24)
    #expect(items[2].bodyRange == NSRange(location: 21, length: 4))
}

@Test func headingWithoutBodyHasEmptyBodyRange() {
    let items = outline(for: "# A\n# B\nbody")
    #expect(items[0].bodyRange.length == 0)
    #expect(items[1].bodyRange == NSRange(location: 4, length: 8))
}

@Test func setextHeadingBodyStartsAfterUnderline() {
    // "Title\n" (0-5) "=====\n" (6-11) "body" (12-15)
    let items = outline(for: "Title\n=====\nbody")
    #expect(items.count == 1)
    #expect(items[0].level == 1)
    #expect(items[0].title == "Title")
    #expect(items[0].bodyRange == NSRange(location: 12, length: 4))
}

@Test func stripsClosingHashesFromTitle() {
    let items = outline(for: "## Two ##\n")
    #expect(items.first?.title == "Two")
}

@Test func emptyDocumentYieldsEmptyOutline() {
    #expect(outline(for: "").isEmpty)
    #expect(outline(for: "plain text only").isEmpty)
}
```

注意: 冒頭の擬似コードブロックは書かない。2 つ目のコードブロックが完成形。

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: FAIL(`OutlineBuilder` / `OutlineItem` 未定義のコンパイルエラー)

- [ ] **Step 3: 実装を書く**

`Sources/LapermCore/OutlineBuilder.swift`:

```swift
import Foundation

/// 見出し 1 件分のアウトライン項目。
public struct OutlineItem: Hashable, Sendable {
    /// 見出しレベル(1...6)
    public var level: Int
    /// マーカー除去済みの見出しテキスト
    public var title: String
    /// 見出し(スパン)の UTF-16 レンジ
    public var headingRange: NSRange
    /// 見出し行頭から、次の同位以上見出しの行頭直前(または文書末尾)まで
    public var sectionRange: NSRange
    /// 折畳時に隠す本体(見出し行の次行頭〜sectionRange 末尾)。本体がなければ length 0
    public var bodyRange: NSRange

    /// 折畳操作のキーとして使う見出し位置
    public var headingLocation: Int { headingRange.location }

    public init(
        level: Int, title: String,
        headingRange: NSRange, sectionRange: NSRange, bodyRange: NSRange
    ) {
        self.level = level
        self.title = title
        self.headingRange = headingRange
        self.sectionRange = sectionRange
        self.bodyRange = bodyRange
    }
}

/// HighlightPlan の heading スパンと原文からアウトラインを構築する純関数。
public enum OutlineBuilder {
    public static func build(from plan: HighlightPlan, text: String) -> [OutlineItem] {
        let ns = text as NSString
        let headings = plan.spans
            .compactMap { span -> (range: NSRange, level: Int)? in
                guard case .heading(let level) = span.kind else { return nil }
                return (span.range, level)
            }
            .sorted { $0.range.location < $1.range.location }
        return headings.enumerated().map { index, heading in
            let headingLine = ns.lineRange(
                for: NSRange(location: heading.range.location, length: 0))
            let sectionStart = headingLine.location
            // 同位以上(数値が同じか小さい)の次見出しの行頭がセクション終端
            let sectionEnd = headings[(index + 1)...]
                .first { $0.level <= heading.level }
                .map { ns.lineRange(for: NSRange(location: $0.range.location, length: 0)).location }
                ?? ns.length
            // Setext 見出しは 2 行(テキスト行 + 下線行)。本体は見出しレンジ末尾を
            // 含む行の次行頭から。
            let headingEndLine = ns.lineRange(
                for: NSRange(
                    location: max(heading.range.location, NSMaxRange(heading.range) - 1),
                    length: 0))
            let bodyStart = min(NSMaxRange(headingEndLine), sectionEnd)
            return OutlineItem(
                level: heading.level,
                title: title(ofHeadingAt: heading.range, in: ns),
                headingRange: heading.range,
                sectionRange: NSRange(location: sectionStart, length: sectionEnd - sectionStart),
                bodyRange: NSRange(location: bodyStart, length: max(0, sectionEnd - bodyStart))
            )
        }
    }

    /// 見出しテキストからマーカーを除去したタイトル。
    /// ATX: 先頭の `#…`、および空白で区切られた末尾の閉じ `#…` を除去。
    /// Setext: 1 行目(テキスト行)をそのまま使う。
    private static func title(ofHeadingAt range: NSRange, in text: NSString) -> String {
        let raw = text.substring(with: range)
        let firstLine = raw.split(
            separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[0]
        var body = firstLine.drop(while: { $0 == "#" })
        let trailingHashes = body.reversed().prefix(while: { $0 == "#" }).count
        if trailingHashes > 0 {
            let cut = body.index(body.endIndex, offsetBy: -trailingHashes)
            if cut > body.startIndex, body[body.index(before: cut)] == " " {
                body = body[..<cut]
            }
        }
        return body.trimmingCharacters(in: .whitespaces)
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: PASS(全件)。もし `sectionRange` / `bodyRange` の期待値がずれた場合、swift-markdown の heading スパンが行末の改行を含むかを `MarkdownParserTests` の既存期待値で確認し、**テストの期待オフセットではなく実装の行レンジ計算を疑う**こと(期待値はプレーンな UTF-16 オフセット計算で正しい)。

- [ ] **Step 5: コミット**

```bash
git add Sources/LapermCore/OutlineBuilder.swift Tests/LapermCoreTests/OutlineBuilderTests.swift
git commit -m "feat(core): add OutlineItem and OutlineBuilder

Task context: 見出しアウトライン/折りたたみ (docs/superpowers/specs/2026-07-16-outline-folding-design.md)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: FoldingState(LapermCore)

**Files:**
- Create: `Sources/LapermCore/FoldingState.swift`
- Test: `Tests/LapermCoreTests/FoldingStateTests.swift`

**Interfaces:**
- Consumes: なし(Foundation のみ)
- Produces: `FoldingState`(`folds: [Fold]`, `hiddenRanges: [NSRange]`, `isFolded(headingLocation:)`, `insert(_:)`, `remove(headingLocation:)`, `removeAll()`, `unfoldAll(containing:) -> [Fold]`, `shifted(byEditAt:changeInLength:) -> (state: FoldingState, dropped: [Fold])`)。`Fold` は `headingLocation: Int` + `bodyRange: NSRange`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermCoreTests/FoldingStateTests.swift`:

```swift
import Foundation
import Testing
@testable import LapermCore

private func fold(_ headingLocation: Int, body: NSRange) -> FoldingState.Fold {
    FoldingState.Fold(headingLocation: headingLocation, bodyRange: body)
}

@Test func insertKeepsAscendingOrderAndReplacesSameKey() {
    var state = FoldingState()
    state.insert(fold(20, body: NSRange(location: 24, length: 5)))
    state.insert(fold(0, body: NSRange(location: 4, length: 10)))
    state.insert(fold(20, body: NSRange(location: 24, length: 8)))
    #expect(state.folds.map(\.headingLocation) == [0, 20])
    #expect(state.folds[1].bodyRange.length == 8)
}

@Test func hiddenRangesAndIsFolded() {
    var state = FoldingState()
    state.insert(fold(0, body: NSRange(location: 4, length: 10)))
    #expect(state.hiddenRanges == [NSRange(location: 4, length: 10)])
    #expect(state.isFolded(headingLocation: 0))
    #expect(!state.isFolded(headingLocation: 4))
    state.remove(headingLocation: 0)
    #expect(state.folds.isEmpty)
}

@Test func unfoldAllContainingRemovesFoldsHidingOffset() {
    var state = FoldingState()
    state.insert(fold(0, body: NSRange(location: 4, length: 30)))   // 親
    state.insert(fold(10, body: NSRange(location: 15, length: 10))) // 子(親の本体内)
    let removed = state.unfoldAll(containing: 18)  // 両方の本体内
    #expect(removed.map(\.headingLocation).sorted() == [0, 10])
    #expect(state.folds.isEmpty)
}

@Test func unfoldAllContainingIgnoresVisibleOffset() {
    var state = FoldingState()
    state.insert(fold(0, body: NSRange(location: 4, length: 10)))
    #expect(state.unfoldAll(containing: 2).isEmpty)  // 見出し行内は隠れていない
    #expect(state.folds.count == 1)
}

@Test func shiftKeepsFoldWhenEditIsAfterSection() {
    let state = FoldingState(folds: [fold(0, body: NSRange(location: 4, length: 10))])
    let (shifted, dropped) = state.shifted(
        byEditAt: NSRange(location: 20, length: 3), changeInLength: 3)
    #expect(shifted == state)
    #expect(dropped.isEmpty)
}

@Test func shiftMovesFoldWhenEditIsBeforeHeading() {
    let state = FoldingState(folds: [fold(10, body: NSRange(location: 14, length: 6))])
    // 位置 2 に 3 文字挿入
    let (shifted, dropped) = state.shifted(
        byEditAt: NSRange(location: 2, length: 3), changeInLength: 3)
    #expect(shifted.folds == [fold(13, body: NSRange(location: 17, length: 6))])
    #expect(dropped.isEmpty)
}

@Test func shiftKeepsFoldOnHeadingLineEdit() {
    // 見出し行内(headingLocation 以上・bodyRange 開始未満)の編集は折畳を維持し
    // 本体開始だけ delta 移動(見出しタイトルのタイピングで勝手に展開しない)
    let state = FoldingState(folds: [fold(0, body: NSRange(location: 8, length: 6))])
    let (shifted, dropped) = state.shifted(
        byEditAt: NSRange(location: 3, length: 2), changeInLength: 2)
    #expect(shifted.folds == [fold(0, body: NSRange(location: 10, length: 6))])
    #expect(dropped.isEmpty)
}

@Test func shiftDropsFoldWhenEditIntersectsBody() {
    let state = FoldingState(folds: [fold(0, body: NSRange(location: 4, length: 10))])
    // 本体内(位置 6)への 1 文字挿入 → 自動展開(破棄)
    let (shifted, dropped) = state.shifted(
        byEditAt: NSRange(location: 6, length: 1), changeInLength: 1)
    #expect(shifted.folds.isEmpty)
    #expect(dropped == [fold(0, body: NSRange(location: 4, length: 10))])
}

@Test func shiftDropsFoldWhenEditCrossesHeadingStart() {
    let state = FoldingState(folds: [fold(10, body: NSRange(location: 14, length: 6))])
    // 位置 8〜12 の削除(見出し行頭を跨ぐ)→ 破棄
    let (shifted, dropped) = state.shifted(
        byEditAt: NSRange(location: 8, length: 0), changeInLength: -4)
    #expect(shifted.folds.isEmpty)
    #expect(dropped.count == 1)
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: FAIL(`FoldingState` 未定義のコンパイルエラー)

- [ ] **Step 3: 実装を書く**

`Sources/LapermCore/FoldingState.swift`:

```swift
import Foundation

/// セクション折りたたみの状態。UI 非依存の値型で、編集による座標追従を提供する。
/// 折畳のキーは見出し行頭の UTF-16 オフセット(headingLocation)。
public struct FoldingState: Equatable, Sendable {
    /// 折畳 1 件。bodyRange がレイアウトから隠す範囲(見出し行は含まない)。
    public struct Fold: Hashable, Sendable {
        public var headingLocation: Int
        public var bodyRange: NSRange

        public init(headingLocation: Int, bodyRange: NSRange) {
            self.headingLocation = headingLocation
            self.bodyRange = bodyRange
        }
    }

    /// headingLocation 昇順
    public private(set) var folds: [Fold]

    public init(folds: [Fold] = []) {
        self.folds = folds.sorted { $0.headingLocation < $1.headingLocation }
    }

    public var isEmpty: Bool { folds.isEmpty }
    public var hiddenRanges: [NSRange] { folds.map(\.bodyRange) }

    public func isFolded(headingLocation: Int) -> Bool {
        folds.contains { $0.headingLocation == headingLocation }
    }

    /// 同じ headingLocation の既存折畳は置き換える(昇順維持)。
    public mutating func insert(_ fold: Fold) {
        folds.removeAll { $0.headingLocation == fold.headingLocation }
        let index = folds.firstIndex { $0.headingLocation > fold.headingLocation } ?? folds.endIndex
        folds.insert(fold, at: index)
    }

    public mutating func remove(headingLocation: Int) {
        folds.removeAll { $0.headingLocation == headingLocation }
    }

    public mutating func removeAll() {
        folds.removeAll()
    }

    /// offset を隠している(bodyRange に含む)折畳をすべて解除し、解除分を返す。
    /// ネスト時は親子の両方が該当し、まとめて解除される。
    @discardableResult
    public mutating func unfoldAll(containing offset: Int) -> [Fold] {
        let removed = folds.filter { NSLocationInRange(offset, $0.bodyRange) }
        folds.removeAll { NSLocationInRange(offset, $0.bodyRange) }
        return removed
    }

    /// 編集(didProcessEditing 相当)に合わせた座標追従。HighlightPlan.shifted と同じ
    /// 規約(editedRange は編集後レンジ、pre-edit 領域は {location, length - delta})。
    /// - 編集が見出しより完全に前: 全体を delta 平行移動
    /// - 編集がセクション本体より完全に後: 不変
    /// - 見出し行内の編集(行頭以上・本体開始未満): 折畳を維持し本体開始のみ delta 移動
    ///   (見出しタイトルのタイピングで勝手に展開しないため)
    /// - それ以外(本体と交差・見出し行頭を跨ぐ): 破棄 = 自動展開。dropped で返す
    public func shifted(
        byEditAt editedRange: NSRange, changeInLength delta: Int
    ) -> (state: FoldingState, dropped: [Fold]) {
        let preEdit = NSRange(
            location: editedRange.location,
            length: max(0, editedRange.length - delta))
        var kept: [Fold] = []
        var dropped: [Fold] = []
        for fold in folds {
            if NSMaxRange(preEdit) <= fold.headingLocation {
                var moved = fold
                moved.headingLocation += delta
                moved.bodyRange.location += delta
                kept.append(moved)
            } else if preEdit.location >= NSMaxRange(fold.bodyRange) {
                kept.append(fold)
            } else if preEdit.location >= fold.headingLocation,
                      NSMaxRange(preEdit) <= fold.bodyRange.location {
                var moved = fold
                moved.bodyRange.location += delta
                kept.append(moved)
            } else {
                dropped.append(fold)
            }
        }
        return (FoldingState(folds: kept), dropped)
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: PASS(全件)

- [ ] **Step 5: コミット**

```bash
git add Sources/LapermCore/FoldingState.swift Tests/LapermCoreTests/FoldingStateTests.swift
git commit -m "feat(core): add FoldingState with edit-tracking shift

Task context: 見出しアウトライン/折りたたみ (docs/superpowers/specs/2026-07-16-outline-folding-design.md)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: FoldingController(Laperm)

**Files:**
- Create: `Sources/Laperm/FoldingController.swift`
- Test: `Tests/LapermTests/FoldingControllerTests.swift`

**Interfaces:**
- Consumes: `OutlineBuilder.build(from:text:)`, `FoldingState`, `HighlightPlan`
- Produces: `FoldingController`(`@MainActor` / `NSTextContentStorageDelegate`)。プロパティ `state: FoldingState`, `outline: [OutlineItem]`, `isEnabled: Bool`, `onOutlineChanged: (() -> Void)?`。メソッド `isFolded(headingLocation:) -> Bool`, `fold(at:) -> Bool`, `unfold(at:) -> Bool`, `toggleFold(at:) -> Bool`, `unfoldAll() -> Bool`, `unfoldAll(intersecting: NSRange) -> Bool`, `sync(plan:text:)`, `noteEdit(editedRange:changeInLength:)`, `takePendingDirtyRanges() -> [NSRange]`。Task 4 は `takePendingDirtyRanges` の戻り値をレイアウト無効化に使う

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermTests/FoldingControllerTests.swift`:

```swift
import AppKit
import Foundation
import Testing
@testable import Laperm
@testable import LapermCore

/// controller に plan/text を同期させるヘルパ
@MainActor
private func makeController(text: String) -> FoldingController {
    let controller = FoldingController()
    controller.sync(plan: MarkdownParser().highlightPlan(for: text), text: text)
    return controller
}

// テキスト: "# A\n"(0-3) "body1\n"(4-9) "body2\n"(10-15) "# B\n"(16-19) "after"(20-24)
private let sample = "# A\nbody1\nbody2\n# B\nafter"

@MainActor @Test func foldRecordsStateAndDirtyRanges() {
    let controller = makeController(text: sample)
    #expect(controller.outline.count == 2)
    #expect(controller.fold(at: 0))
    #expect(controller.isFolded(headingLocation: 0))
    // dirty = 隠した本体レンジ("body1\nbody2\n" = {4,12})
    #expect(controller.takePendingDirtyRanges() == [NSRange(location: 4, length: 12)])
    #expect(controller.takePendingDirtyRanges().isEmpty)  // take でクリアされる
}

@MainActor @Test func foldRejectsUnknownOrEmptyBodyHeading() {
    let controller = makeController(text: "# A\n# B\nbody")
    #expect(!controller.fold(at: 999))       // 存在しない見出し
    #expect(!controller.fold(at: 0))          // 本体なし
    #expect(controller.fold(at: 4))           // "# B" は本体あり
}

@MainActor @Test func toggleAndUnfoldAll() {
    let controller = makeController(text: sample)
    #expect(controller.toggleFold(at: 0))
    #expect(controller.isFolded(headingLocation: 0))
    #expect(controller.toggleFold(at: 0))
    #expect(!controller.isFolded(headingLocation: 0))
    _ = controller.toggleFold(at: 0)
    #expect(controller.unfoldAll())
    #expect(controller.state.isEmpty)
    #expect(!controller.unfoldAll())  // 変化なしなら false
}

@MainActor @Test func shouldEnumerateSkipsFoldedBodyParagraphs() {
    let contentStorage = NSTextContentStorage()
    contentStorage.textStorage?.replaceCharacters(
        in: NSRange(location: 0, length: 0), with: sample)
    let controller = makeController(text: sample)
    contentStorage.delegate = controller
    _ = controller.fold(at: 0)
    var enumerated: [Int] = []
    contentStorage.enumerateTextElements(from: contentStorage.documentRange.location) {
        element in
        if let location = element.elementRange?.location {
            enumerated.append(contentStorage.offset(
                from: contentStorage.documentRange.location, to: location))
        }
        return true
    }
    #expect(enumerated.contains(0))    // 見出し行は残る
    #expect(!enumerated.contains(4))   // body1 は隠れる
    #expect(!enumerated.contains(10))  // body2 は隠れる
    #expect(enumerated.contains(16))   // 次セクションの見出しは残る
}

@MainActor @Test func syncDropsFoldsWhoseHeadingDisappeared() {
    let controller = makeController(text: sample)
    _ = controller.fold(at: 0)
    _ = controller.takePendingDirtyRanges()
    // "# A" が見出しでなくなった新テキストで同期
    let newText = "A\nbody1\nbody2\n# B\nafter"
    controller.sync(plan: MarkdownParser().highlightPlan(for: newText), text: newText)
    #expect(!controller.isFolded(headingLocation: 0))
    #expect(!controller.takePendingDirtyRanges().isEmpty)  // 旧本体が無効化対象に載る
}

@MainActor @Test func syncFiresOutlineChangedOnlyOnChange() {
    let controller = makeController(text: sample)
    var fired = 0
    controller.onOutlineChanged = { fired += 1 }
    controller.sync(plan: MarkdownParser().highlightPlan(for: sample), text: sample)
    #expect(fired == 0)  // 変化なし → 発火しない
    let newText = "# A\nbody1\nbody2\n# B2\nafter"
    controller.sync(plan: MarkdownParser().highlightPlan(for: newText), text: newText)
    #expect(fired == 1)
}

@MainActor @Test func noteEditDropsFoldIntersectingBody() {
    let controller = makeController(text: sample)
    _ = controller.fold(at: 0)
    _ = controller.takePendingDirtyRanges()
    // 本体内(位置 6)へ 1 文字挿入
    controller.noteEdit(editedRange: NSRange(location: 6, length: 1), changeInLength: 1)
    #expect(!controller.isFolded(headingLocation: 0))
    #expect(!controller.takePendingDirtyRanges().isEmpty)
}

@MainActor @Test func unfoldAllIntersectingHandlesCaretAndSelection() {
    let controller = makeController(text: sample)
    _ = controller.fold(at: 0)
    // 見出し行(可視)のキャレットでは解除しない
    #expect(!controller.unfoldAll(intersecting: NSRange(location: 2, length: 0)))
    // 本体内のキャレットで解除する
    #expect(controller.unfoldAll(intersecting: NSRange(location: 6, length: 0)))
    #expect(!controller.isFolded(headingLocation: 0))
}

@MainActor @Test func disabledControllerRejectsFoldAndEnumeratesAll() {
    let controller = makeController(text: sample)
    controller.isEnabled = false
    #expect(!controller.fold(at: 0))
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: FAIL(`FoldingController` 未定義のコンパイルエラー)

- [ ] **Step 3: 実装を書く**

`Sources/Laperm/FoldingController.swift`:

```swift
import AppKit
import LapermCore

/// セクション折りたたみの中核。NSTextContentStorageDelegate として折畳中の
/// 本体段落を列挙から除外し(= レイアウト対象から外れて非表示)、アウトラインの
/// 同期と編集追従を管理する。テキストストレージは一切変更しない。
/// レイアウト無効化はここでは行わず、pendingDirtyRanges として溜めて
/// MarkdownTextView(takePendingDirtyRanges)に委ねる。
@MainActor
final class FoldingController: NSObject {
    private(set) var state = FoldingState()
    private(set) var outline: [OutlineItem] = []
    var isEnabled = true
    /// アウトラインが実際に変化した(Equatable 比較)ときだけ呼ばれる
    var onOutlineChanged: (() -> Void)?

    /// 折畳状態の変化で無効化が必要になったレンジ(文書座標)。編集が挟まった場合は
    /// noteEdit がシフト・拡張する。
    private var pendingDirtyRanges: [NSRange] = []

    /// 溜まった無効化レンジを取り出してクリアする(呼び出し側がレイアウトを無効化する)
    func takePendingDirtyRanges() -> [NSRange] {
        defer { pendingDirtyRanges = [] }
        return pendingDirtyRanges
    }

    func isFolded(headingLocation: Int) -> Bool {
        state.isFolded(headingLocation: headingLocation)
    }

    /// 折畳を作る。headingLocation がアウトラインに存在し、本体が空でないときだけ効く。
    @discardableResult
    func fold(at headingLocation: Int) -> Bool {
        guard isEnabled,
              !state.isFolded(headingLocation: headingLocation),
              let item = outline.first(where: { $0.headingLocation == headingLocation }),
              item.bodyRange.length > 0
        else { return false }
        state.insert(.init(headingLocation: headingLocation, bodyRange: item.bodyRange))
        pendingDirtyRanges.append(item.bodyRange)
        return true
    }

    @discardableResult
    func unfold(at headingLocation: Int) -> Bool {
        guard let fold = state.folds.first(where: { $0.headingLocation == headingLocation })
        else { return false }
        state.remove(headingLocation: headingLocation)
        pendingDirtyRanges.append(fold.bodyRange)
        return true
    }

    @discardableResult
    func toggleFold(at headingLocation: Int) -> Bool {
        if state.isFolded(headingLocation: headingLocation) {
            return unfold(at: headingLocation)
        }
        return fold(at: headingLocation)
    }

    @discardableResult
    func unfoldAll() -> Bool {
        guard !state.isEmpty else { return false }
        pendingDirtyRanges.append(contentsOf: state.hiddenRanges)
        state.removeAll()
        return true
    }

    /// range(キャレットは length 0)が折畳の隠し領域と交差していたら該当折畳を
    /// すべて解除する。ネストは親子まとめて解除。
    @discardableResult
    func unfoldAll(intersecting range: NSRange) -> Bool {
        let hits = state.folds.filter { fold in
            if range.length == 0 {
                return NSLocationInRange(range.location, fold.bodyRange)
            }
            return NSIntersectionRange(range, fold.bodyRange).length > 0
        }
        guard !hits.isEmpty else { return false }
        for fold in hits {
            state.remove(headingLocation: fold.headingLocation)
            pendingDirtyRanges.append(fold.bodyRange)
        }
        return true
    }

    /// パース確定時の同期。アウトラインを再構築し、見出しが残っている折畳だけ
    /// bodyRange を新値に更新して維持、消えた見出しの折畳は解除する。
    func sync(plan: HighlightPlan, text: String) {
        let newOutline = OutlineBuilder.build(from: plan, text: text)
        let outlineChanged = newOutline != outline
        outline = newOutline
        var kept: [FoldingState.Fold] = []
        for fold in state.folds {
            if let item = newOutline.first(
                where: { $0.headingLocation == fold.headingLocation }),
                item.bodyRange.length > 0 {
                if item.bodyRange != fold.bodyRange {
                    pendingDirtyRanges.append(fold.bodyRange)
                    pendingDirtyRanges.append(item.bodyRange)
                }
                kept.append(.init(
                    headingLocation: fold.headingLocation, bodyRange: item.bodyRange))
            } else {
                pendingDirtyRanges.append(fold.bodyRange)
            }
        }
        state = FoldingState(folds: kept)
        if outlineChanged { onOutlineChanged?() }
    }

    /// didProcessEditing(.editedCharacters)からの座標追従。
    /// 本体と交差する編集は折畳を破棄(自動展開)し、旧本体を無効化対象へ載せる。
    func noteEdit(editedRange: NSRange, changeInLength delta: Int) {
        let preEdit = NSRange(
            location: editedRange.location,
            length: max(0, editedRange.length - delta))
        // 溜まっている無効化レンジも編集分シフトする(Highlighter.noteEdit と同じ規約:
        // 交差したら編集レンジと合併して拡張)
        pendingDirtyRanges = pendingDirtyRanges.map { range in
            if NSMaxRange(range) <= preEdit.location {
                return range
            } else if range.location >= NSMaxRange(preEdit) {
                return NSRange(location: range.location + delta, length: range.length)
            } else {
                let start = min(range.location, editedRange.location)
                let end = max(NSMaxRange(editedRange), NSMaxRange(range) + delta)
                return NSRange(location: start, length: max(0, end - start))
            }
        }
        guard !state.isEmpty else { return }
        let (newState, dropped) = state.shifted(
            byEditAt: editedRange, changeInLength: delta)
        state = newState
        for fold in dropped {
            // 破棄された折畳の本体を編集後座標の近似(編集レンジと合併)で無効化
            let start = min(fold.bodyRange.location, editedRange.location)
            let end = max(NSMaxRange(editedRange), NSMaxRange(fold.bodyRange) + delta)
            pendingDirtyRanges.append(NSRange(location: start, length: max(0, end - start)))
        }
    }
}

extension FoldingController: NSTextContentStorageDelegate {
    /// 段落の先頭オフセットが折畳中の本体レンジ内なら列挙から除外する。
    /// 見出し行の段落先頭は自分の bodyRange に含まれないため常に表示される。
    func textContentManager(
        _ textContentManager: NSTextContentManager,
        shouldEnumerate textElement: NSTextElement,
        options: NSTextContentManager.EnumerationOptions
    ) -> Bool {
        guard isEnabled, !state.isEmpty,
              let location = textElement.elementRange?.location else { return true }
        let offset = textContentManager.offset(
            from: textContentManager.documentRange.location, to: location)
        return !state.hiddenRanges.contains { NSLocationInRange(offset, $0) }
    }
}
```

Swift 6 の分離チェックで `shouldEnumerate` の conformance がエラーになる場合は、`BlockFragmentProvider`(`Sources/Laperm/BlockFragmentProvider.swift`)がすでに同種の AppKit delegate を @MainActor クラスで実装しているので、その解決方法(コメント含む)をそのまま踏襲すること。

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: PASS(全件)。`shouldEnumerateSkipsFoldedBodyParagraphs` が失敗する(全段落が列挙される)場合は、`NSTextContentStorage.delegate` への代入が効いているか・`enumerateTextElements` がメインスレッドで走っているかを確認する。

- [ ] **Step 5: コミット**

```bash
git add Sources/Laperm/FoldingController.swift Tests/LapermTests/FoldingControllerTests.swift
git commit -m "feat(ui): add FoldingController with shouldEnumerate-based hiding

Task context: 見出しアウトライン/折りたたみ (docs/superpowers/specs/2026-07-16-outline-folding-design.md)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: MarkdownTextView 統合と公開 API

**Files:**
- Modify: `Sources/Laperm/MarkdownTextView.swift`
- Test: `Tests/LapermTests/MarkdownTextViewFoldingTests.swift`(新規)

**Interfaces:**
- Consumes: `FoldingController`(Task 3 の全メソッド)、既存の `highlightNow()` / `highlightAll()` / `didProcessEditing` / `setSelectedRanges`
- Produces: `MarkdownTextView` 公開 API — `outline: [OutlineItem]`, `onOutlineChange: (([OutlineItem]) -> Void)?`, `isFoldingEnabled: Bool`(default true), `fold(at:)`, `unfold(at:)`, `toggleFold(at:)`, `unfoldAll()`, `isFolded(at:) -> Bool`, `scrollToHeading(at:)`。内部 `foldingController`(Task 5 がガター連携で参照)

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermTests/MarkdownTextViewFoldingTests.swift`:

```swift
import AppKit
import Foundation
import Testing
@testable import Laperm
@testable import LapermCore

// テキスト: "# A\n"(0-3) "body1\n"(4-9) "body2\n"(10-15) "# B\n"(16-19) "after"(20-24)
private let sample = "# A\nbody1\nbody2\n# B\nafter"

@MainActor
private func makeTextView() -> MarkdownTextView {
    let textView = MarkdownTextView()
    textView.string = sample
    textView.highlightAll()
    return textView
}

@MainActor
private func enumeratedOffsets(_ textView: MarkdownTextView) -> [Int] {
    let contentManager = textView.textLayoutManager!.textContentManager!
    var offsets: [Int] = []
    contentManager.enumerateTextElements(from: contentManager.documentRange.location) {
        element in
        if let location = element.elementRange?.location {
            offsets.append(contentManager.offset(
                from: contentManager.documentRange.location, to: location))
        }
        return true
    }
    return offsets
}

@MainActor @Test func outlineIsAvailableAfterHighlightAll() {
    let textView = makeTextView()
    #expect(textView.outline.map(\.title) == ["A", "B"])
}

@MainActor @Test func foldHidesBodyAndKeepsHeading() {
    let textView = makeTextView()
    textView.fold(at: 0)
    #expect(textView.isFolded(at: 0))
    let offsets = enumeratedOffsets(textView)
    #expect(offsets.contains(0))
    #expect(!offsets.contains(4))
    #expect(!offsets.contains(10))
    #expect(offsets.contains(16))
}

@MainActor @Test func caretEnteringHiddenBodyAutoExpands() {
    let textView = makeTextView()
    textView.fold(at: 0)
    textView.setSelectedRange(NSRange(location: 6, length: 0))  // body1 内
    #expect(!textView.isFolded(at: 0))
}

@MainActor @Test func editInHiddenBodyAutoExpands() {
    let textView = makeTextView()
    textView.fold(at: 0)
    textView.textStorage!.replaceCharacters(
        in: NSRange(location: 6, length: 0), with: "x")
    #expect(!textView.isFolded(at: 0))
}

@MainActor @Test func headingRemovalUnfoldsAfterReparse() {
    let textView = makeTextView()
    textView.fold(at: 0)
    // "# " を消して見出しでなくす(見出し行内の編集なので即時は維持される)
    textView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 2), with: "")
    textView.highlightNow()  // 再パース → sync → 見出し消失で解除
    #expect(!textView.isFolded(at: 0))
    #expect(textView.outline.map(\.title) == ["B"])
}

@MainActor @Test func onOutlineChangeFiresOnActualChange() {
    let textView = MarkdownTextView()
    var received: [[String]] = []
    textView.onOutlineChange = { received.append($0.map(\.title)) }
    textView.string = sample
    textView.highlightAll()
    #expect(received == [["A", "B"]])
    textView.highlightAll()  // アウトライン不変 → 発火しない
    #expect(received.count == 1)
}

@MainActor @Test func disablingFoldingUnfoldsAllAndBlocksFold() {
    let textView = makeTextView()
    textView.fold(at: 0)
    textView.isFoldingEnabled = false
    #expect(!textView.isFolded(at: 0))
    textView.fold(at: 0)
    #expect(!textView.isFolded(at: 0))
    #expect(enumeratedOffsets(textView).contains(4))
}

@MainActor @Test func scrollToHeadingUnfoldsAncestors() {
    // "# A\n"(0-3) "## B\n"(4-8) "body\n"(9-13)
    let textView = MarkdownTextView()
    textView.string = "# A\n## B\nbody\n"
    textView.highlightAll()
    textView.fold(at: 0)  // A を折畳 → "## B" ごと隠れる
    textView.scrollToHeading(at: 4)
    #expect(!textView.isFolded(at: 0))
}

@MainActor @Test func performCommandStillWorksWhileFolded() {
    // 折畳が undo 経路の編集(perform)を妨げないこと
    let textView = makeTextView()
    textView.fold(at: 0)
    let done = textView.perform(EditCommand(
        replacementRange: NSRange(location: 20, length: 0),
        replacementString: "!",
        selectedRange: NSRange(location: 21, length: 0)))
    #expect(done)
    #expect(textView.string.contains("!"))
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: FAIL(`outline` / `fold(at:)` 等が未定義のコンパイルエラー)

- [ ] **Step 3: MarkdownTextView に統合を実装**

`Sources/Laperm/MarkdownTextView.swift` に以下を追加・変更する。

(a) プロパティ追加(`imagePreviewController` の近くに):

```swift
    let foldingController = FoldingController()
```

(b) 公開 API 追加(`imageLoader` プロパティの後あたりに):

```swift
    // MARK: - アウトライン / 折りたたみ

    /// 現在のアウトライン(パース確定時に更新される)
    public var outline: [OutlineItem] { foldingController.outline }

    /// アウトラインが実際に変化したときだけ呼ばれる(Equatable 比較)
    public var onOutlineChange: (([OutlineItem]) -> Void)?

    /// 折りたたみ機能の有効/無効。無効化すると全折畳を解除し、以後の折畳操作を無視する
    public var isFoldingEnabled: Bool = true {
        didSet {
            guard isFoldingEnabled != oldValue else { return }
            if !isFoldingEnabled { foldingController.unfoldAll() }
            foldingController.isEnabled = isFoldingEnabled
            applyFoldingChanges()
            gutterView?.needsDisplay = true
        }
    }

    /// headingLocation(OutlineItem.headingLocation)のセクションを折りたたむ
    public func fold(at headingLocation: Int) {
        if foldingController.fold(at: headingLocation) { applyFoldingChanges() }
    }

    public func unfold(at headingLocation: Int) {
        if foldingController.unfold(at: headingLocation) { applyFoldingChanges() }
    }

    public func toggleFold(at headingLocation: Int) {
        if foldingController.toggleFold(at: headingLocation) { applyFoldingChanges() }
    }

    public func unfoldAll() {
        if foldingController.unfoldAll() { applyFoldingChanges() }
    }

    public func isFolded(at headingLocation: Int) -> Bool {
        foldingController.isFolded(headingLocation: headingLocation)
    }

    /// 見出しへスクロールする。祖先セクションが折畳中なら先に展開する
    public func scrollToHeading(at headingLocation: Int) {
        if foldingController.unfoldAll(
            intersecting: NSRange(location: headingLocation, length: 0)) {
            applyFoldingChanges()
        }
        scrollRangeToVisible(NSRange(location: headingLocation, length: 0))
    }
```

(c) configure() に配線を追加(`textStorage?.delegate = self` の後):

```swift
        // NSTextContentStorage の delegate は未使用なので折畳コントローラが使う。
        // shouldEnumerate で折畳中の本体段落を列挙から除外する(ストレージ無変更)。
        textContentStorage?.delegate = foldingController
        foldingController.onOutlineChanged = { [weak self] in
            guard let self else { return }
            self.onOutlineChange?(self.foldingController.outline)
        }
```

(d) 折畳変化のレイアウト反映ヘルパを追加(`updateBlockDecorations()` の近くに):

```swift
    /// 折畳状態の変化をレイアウトへ反映する。BlockFragmentProvider.update と同じく
    /// recordEditAction で要素再生成を強制し、ビューポートへ再レイアウトを要求する。
    private func applyFoldingChanges() {
        let dirtyRanges = foldingController.takePendingDirtyRanges()
        guard !dirtyRanges.isEmpty,
              let contentStorage = textContentStorage,
              let layoutManager = textLayoutManager else { return }
        let textRanges = dirtyRanges.compactMap { contentStorage.textRange(for: $0) }
        contentStorage.performEditingTransaction {
            for textRange in textRanges {
                contentStorage.recordEditAction(in: textRange, newTextRange: textRange)
            }
        }
        for textRange in textRanges {
            layoutManager.invalidateLayout(for: textRange)
        }
        let controller = layoutManager.textViewportLayoutController
        controller.delegate?.textViewportLayoutControllerReceivedSetNeedsLayout?(controller)
        gutterView?.needsDisplay = true
        needsLayout = true
    }
```

`textViewportLayoutControllerReceivedSetNeedsLayout` のオプショナル呼び出しがコンパイルできない場合(SDK 上で optional でない等)は、代わりに `needsLayout = true` + `layoutSubtreeIfNeeded()` は使わず `invalidateLayout` のみで進め、GUI 検証で表示更新を確認して調整する。

(e) highlightNow() / highlightAll() に同期を追加。両メソッドの `updateBlockDecorations()` の直後に:

```swift
        syncFolding()
```

を挿入し、ヘルパを追加:

```swift
    /// パース確定後にアウトライン・折畳状態を最新プランへ同期する。
    /// バックグラウンドパース経路では currentPlan の更新が非同期のため、ブロック装飾と
    /// 同様に 1 サイクル遅延する(v1 で許容済みの設計)。
    private func syncFolding() {
        foldingController.sync(plan: markdownHighlighter.currentPlan, text: string)
        applyFoldingChanges()
    }
```

(f) didProcessEditing(拡張内)に追従を追加。`markdownHighlighter.noteEdit(...)` の直後:

```swift
        foldingController.noteEdit(editedRange: editedRange, changeInLength: delta)
```

無効化レンジの適用は次の highlightNow → syncFolding → applyFoldingChanges で行われる(processEditing 中に recordEditAction を重ねない)。

(g) setSelectedRanges override に自動展開を追加。既存の `updateInsertionPointOverlay()` の後:

```swift
        autoExpandFoldsAtSelection()
```

ヘルパ:

```swift
    /// カーソル(選択)が折畳の隠し領域に入ったら自動展開する。
    /// IME 変換中は変換セッションを乱さないよう見送る(確定後の選択変更で再評価される)。
    private func autoExpandFoldsAtSelection() {
        guard isFoldingEnabled, !foldingController.state.isEmpty, !hasMarkedText()
        else { return }
        var changed = false
        for value in selectedRanges {
            if foldingController.unfoldAll(intersecting: value.rangeValue) {
                changed = true
            }
        }
        if changed { applyFoldingChanges() }
    }
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: PASS(全件、既存テスト含む)。既存テストが落ちた場合は折畳配線が既存経路(ハイライト・画像プレビュー)を壊していないか確認する。特に `textContentStorage?.delegate` 代入で既存挙動が変わらないこと。

- [ ] **Step 5: コミット**

```bash
git add Sources/Laperm/MarkdownTextView.swift Tests/LapermTests/MarkdownTextViewFoldingTests.swift
git commit -m "feat(ui): integrate folding into MarkdownTextView with public API

Task context: 見出しアウトライン/折りたたみ (docs/superpowers/specs/2026-07-16-outline-folding-design.md)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: ガターのシェブロン UI

**Files:**
- Modify: `Sources/Laperm/LineNumberGutterView.swift`
- Modify: `Sources/Laperm/MarkdownTextView.swift`(viewport 収集と scrollableMarkdownEditor 配線)
- Test: `Tests/LapermTests/GutterFoldMarkerTests.swift`(新規)

**Interfaces:**
- Consumes: `MarkdownTextView.foldingController`(outline / isFolded)、`toggleFold(at:)`
- Produces: `LineNumberGutterView.FoldMarker`(`headingLocation: Int`, `isFolded: Bool`)、`Line.foldMarker: FoldMarker?`、`onToggleFold: ((Int) -> Void)?`、`foldMarkerHeadingLocation(atPoint:) -> Int?`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermTests/GutterFoldMarkerTests.swift`:

```swift
import AppKit
import Foundation
import Testing
@testable import Laperm

@MainActor
private func makeGutterWithLines() -> (LineNumberGutterView, MarkdownTextView) {
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    scrollView.layoutSubtreeIfNeeded()
    let textView = scrollView.documentView as! MarkdownTextView
    let gutter = scrollView.verticalRulerView as! LineNumberGutterView
    gutter.lines = [
        .init(number: 1, yInTextView: 0,
              foldMarker: .init(headingLocation: 0, isFolded: false)),
        .init(number: 2, yInTextView: 20, foldMarker: nil),
        .init(number: 3, yInTextView: 40,
              foldMarker: .init(headingLocation: 16, isFolded: true)),
    ]
    return (gutter, textView)
}

@MainActor @Test func hitTestFindsChevronOnMarkerLine() {
    let (gutter, textView) = makeGutterWithLines()
    let y0 = gutter.convert(NSPoint(x: 0, y: 0), from: textView).y
    let hit = gutter.foldMarkerHeadingLocation(atPoint: NSPoint(x: 8, y: y0 + 4))
    #expect(hit == 0)
}

@MainActor @Test func hitTestMissesLinesWithoutMarkerAndRightSide() {
    let (gutter, textView) = makeGutterWithLines()
    let y1 = gutter.convert(NSPoint(x: 0, y: 20), from: textView).y
    #expect(gutter.foldMarkerHeadingLocation(atPoint: NSPoint(x: 8, y: y1 + 4)) == nil)
    let y0 = gutter.convert(NSPoint(x: 0, y: 0), from: textView).y
    // シェブロン列(左端 16pt)より右は行番号領域なのでヒットしない
    #expect(gutter.foldMarkerHeadingLocation(atPoint: NSPoint(x: 30, y: y0 + 4)) == nil)
}

@MainActor @Test func mouseDownOnChevronInvokesCallback() {
    let (gutter, textView) = makeGutterWithLines()
    var toggled: [Int] = []
    gutter.onToggleFold = { toggled.append($0) }
    let y2 = gutter.convert(NSPoint(x: 0, y: 40), from: textView).y
    // mouseDown 相当の分岐をテストから直接呼ぶ(イベント合成不要の継ぎ目)
    if let headingLocation = gutter.foldMarkerHeadingLocation(
        atPoint: NSPoint(x: 8, y: y2 + 4)) {
        gutter.onToggleFold?(headingLocation)
    }
    #expect(toggled == [16])
}

// viewport 収集の統合確認: 見出し行に foldMarker が付く
@MainActor @Test func viewportPassCollectsFoldMarkersForHeadingLines() {
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    scrollView.layoutSubtreeIfNeeded()
    let textView = scrollView.documentView as! MarkdownTextView
    textView.string = "# A\nbody1\nbody2\n# B\nafter"
    textView.highlightAll()
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    let gutter = scrollView.verticalRulerView as! LineNumberGutterView
    let markers = gutter.lines.compactMap(\.foldMarker)
    #expect(markers.map(\.headingLocation) == [0, 16])
    #expect(markers.allSatisfy { !$0.isFolded })
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: FAIL(`FoldMarker` / `foldMarker` / `onToggleFold` 未定義のコンパイルエラー)

- [ ] **Step 3: 実装を書く**

(a) `Sources/Laperm/LineNumberGutterView.swift` を以下に更新:

```swift
import AppKit

/// スクロールビューの垂直ルーラーとして行番号と折畳シェブロンを描画する。
/// 行情報は MarkdownTextView の viewport レイアウトパスから供給される。
@MainActor
final class LineNumberGutterView: NSRulerView {
    /// 見出し行に表示する折畳インジケータ
    struct FoldMarker: Equatable {
        var headingLocation: Int
        var isFolded: Bool
    }

    struct Line: Equatable {
        var number: Int
        /// テキストビュー座標系でのフラグメント上端 y
        var yInTextView: CGFloat
        var foldMarker: FoldMarker? = nil
    }

    var lines: [Line] = [] {
        didSet { if lines != oldValue { needsDisplay = true } }
    }
    var numberFont: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    var numberColor: NSColor = .tertiaryLabelColor
    var chevronColor: NSColor = .secondaryLabelColor
    /// シェブロンのクリックで呼ばれる(引数は headingLocation)
    var onToggleFold: ((Int) -> Void)?

    /// シェブロン列の幅(左端からここまでがクリック判定域)
    private let chevronColumnWidth: CGFloat = 16

    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 44
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("LineNumberGutterView does not support NSCoder")
    }

    /// point(ガター座標)がシェブロンに当たっていればその headingLocation を返す
    func foldMarkerHeadingLocation(atPoint point: NSPoint) -> Int? {
        guard point.x <= chevronColumnWidth, let textView = clientView else { return nil }
        let lineHeight = numberFont.ascender - numberFont.descender + 6
        for line in lines {
            guard let marker = line.foldMarker else { continue }
            let y = convert(NSPoint(x: 0, y: line.yInTextView), from: textView).y
            if point.y >= y, point.y < y + lineHeight {
                return marker.headingLocation
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let headingLocation = foldMarkerHeadingLocation(atPoint: point) {
            onToggleFold?(headingLocation)
            return
        }
        super.mouseDown(with: event)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: numberColor,
        ]
        let chevronAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: chevronColor,
        ]
        for line in lines {
            let y = convert(NSPoint(x: 0, y: line.yInTextView), from: textView).y
            let label = NSAttributedString(string: "\(line.number)", attributes: attributes)
            let size = label.size()
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y))
            if let marker = line.foldMarker {
                let chevron = NSAttributedString(
                    string: marker.isFolded ? "▶" : "▼", attributes: chevronAttributes)
                chevron.draw(at: NSPoint(x: 4, y: y + 1))
            }
        }
    }
}
```

(b) `Sources/Laperm/MarkdownTextView.swift` の viewport 収集(`textViewportLayoutController(_:configureRenderingSurfaceFor:)`)で、`collectedLines.append(...)` を以下に変更:

```swift
        let endOffset = contentManager.offset(
            from: contentManager.documentRange.location,
            to: textLayoutFragment.rangeInElement.endLocation
        )
        collectedLines.append(
            .init(
                number: index.lineNumber(at: offset),
                yInTextView: textLayoutFragment.layoutFragmentFrame.minY,
                foldMarker: foldMarker(inParagraphFrom: offset, to: endOffset)
            ))
```

ヘルパを追加:

```swift
    /// [start, end) の段落にアウトラインの見出しがあればシェブロン情報を返す。
    /// 本体のない見出し(折畳不可)にはシェブロンを出さない。
    private func foldMarker(
        inParagraphFrom start: Int, to end: Int
    ) -> LineNumberGutterView.FoldMarker? {
        guard isFoldingEnabled else { return nil }
        guard let item = foldingController.outline.first(where: {
            $0.headingLocation >= start && $0.headingLocation < end && $0.bodyRange.length > 0
        }) else { return nil }
        return .init(
            headingLocation: item.headingLocation,
            isFolded: foldingController.isFolded(headingLocation: item.headingLocation))
    }
```

(c) `scrollableMarkdownEditor(theme:)` の `textView.gutterView = gutter` の前に配線を追加:

```swift
        gutter.onToggleFold = { [weak textView] headingLocation in
            textView?.toggleFold(at: headingLocation)
        }
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: PASS(全件)。`viewportPassCollectsFoldMarkersForHeadingLines` で `layoutViewport()` が lines を供給しない場合、既存の viewport 系テスト(`ImagePreviewLastLineTests` 等)がどうやってレイアウトパスを走らせているかを確認して同じ方法を使う。

- [ ] **Step 5: コミット**

```bash
git add Sources/Laperm/LineNumberGutterView.swift Sources/Laperm/MarkdownTextView.swift Tests/LapermTests/GutterFoldMarkerTests.swift
git commit -m "feat(ui): add fold chevrons to line number gutter

Task context: 見出しアウトライン/折りたたみ (docs/superpowers/specs/2026-07-16-outline-folding-design.md)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: SwiftUI モディファイアと MarkdownEditorProxy

**Files:**
- Modify: `Sources/Laperm/MarkdownEditorView.swift`
- Create: `Sources/Laperm/MarkdownEditorProxy.swift`
- Modify: `docs/superpowers/specs/2026-07-16-outline-folding-design.md`(公開 API に proxy を追記)
- Test: `Tests/LapermTests/MarkdownEditorViewTests.swift`(追記)

**Interfaces:**
- Consumes: `MarkdownTextView.onOutlineChange` / `isFoldingEnabled` / `scrollToHeading(at:)`(Task 4)
- Produces: `MarkdownEditorView.onOutlineChange(_:)`, `.foldingEnabled(_:)`, `.editorProxy(_:)` モディファイア。`MarkdownEditorProxy`(`scrollToHeading(at:)`, `fold(at:)`, `unfold(at:)`, `toggleFold(at:)`, `unfoldAll()` を textView へ転送)

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermTests/MarkdownEditorViewTests.swift` に追記(既存テストのスタイルに合わせ、`apply(to:)` を継ぎ目に使う):

```swift
@MainActor @Test func appliesOutlineAndFoldingModifiers() {
    let textView = MarkdownTextView()
    var received: [[OutlineItem]] = []
    let proxy = MarkdownEditorProxy()
    let view = MarkdownEditorView(text: .constant("# A\nbody"))
        .onOutlineChange { received.append($0) }
        .foldingEnabled(false)
        .editorProxy(proxy)
    view.apply(to: textView)
    #expect(textView.isFoldingEnabled == false)
    #expect(textView.onOutlineChange != nil)
    #expect(proxy.textView === textView)
}

@MainActor @Test func proxyForwardsToTextView() {
    let proxy = MarkdownEditorProxy()
    let textView = MarkdownTextView()
    textView.string = "# A\nbody"
    textView.highlightAll()
    proxy.textView = textView
    proxy.fold(at: 0)
    #expect(textView.isFolded(at: 0))
    proxy.unfoldAll()
    #expect(!textView.isFolded(at: 0))
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: FAIL(`onOutlineChange` モディファイア / `MarkdownEditorProxy` 未定義)

- [ ] **Step 3: 実装を書く**

(a) `Sources/Laperm/MarkdownEditorProxy.swift`:

```swift
import AppKit
import LapermCore

/// SwiftUI(MarkdownEditorView)から MarkdownTextView の命令的 API
/// (scrollToHeading / fold 等)を呼ぶための橋。`.editorProxy(_:)` で接続する。
/// 利用側(@State 等)が所有権を持ち、ビューは weak 参照のみ保持する。
@MainActor
public final class MarkdownEditorProxy {
    public internal(set) weak var textView: MarkdownTextView?

    public init() {}

    public func scrollToHeading(at headingLocation: Int) {
        textView?.scrollToHeading(at: headingLocation)
    }
    public func fold(at headingLocation: Int) { textView?.fold(at: headingLocation) }
    public func unfold(at headingLocation: Int) { textView?.unfold(at: headingLocation) }
    public func toggleFold(at headingLocation: Int) { textView?.toggleFold(at: headingLocation) }
    public func unfoldAll() { textView?.unfoldAll() }
}
```

(b) `Sources/Laperm/MarkdownEditorView.swift` — stored property を追加:

```swift
    private var onOutlineChange: (([OutlineItem]) -> Void)?
    private var foldingEnabled = true
    private var proxy: MarkdownEditorProxy?
```

モディファイアを追加(`imageLoader` モディファイアの後):

```swift
    /// アウトライン変化の通知を受け取る(パース確定時、実変化があったときだけ)。
    public func onOutlineChange(
        _ action: @escaping ([OutlineItem]) -> Void
    ) -> MarkdownEditorView {
        var copy = self
        copy.onOutlineChange = action
        return copy
    }

    /// セクション折りたたみの有効/無効(デフォルト有効)。
    public func foldingEnabled(_ enabled: Bool) -> MarkdownEditorView {
        var copy = self
        copy.foldingEnabled = enabled
        return copy
    }

    /// 命令的 API(scrollToHeading / fold 等)の呼び出し口を接続する。
    public func editorProxy(_ proxy: MarkdownEditorProxy) -> MarkdownEditorView {
        var copy = self
        copy.proxy = proxy
        return copy
    }
```

`apply(to:)` に追記:

```swift
        textView.onOutlineChange = onOutlineChange
        textView.isFoldingEnabled = foldingEnabled
        proxy?.textView = textView
```

(c) `makeNSView` の順序を変更 — `apply(to:)` を `highlightAll()` より**前**に移す(初回パースの onOutlineChange を取りこぼさないため):

```swift
    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MarkdownTextView.scrollableMarkdownEditor(theme: theme)
        let textView = scrollView.documentView as! MarkdownTextView
        textView.delegate = context.coordinator
        apply(to: textView)
        textView.string = text
        textView.highlightAll()
        textView.showsLineNumbers = showsLineNumbers
        return scrollView
    }
```

(d) spec の「公開 API」節の SwiftUI ブロックに 1 行追記:

```swift
func editorProxy(_ proxy: MarkdownEditorProxy) -> Self  // 命令的 API(ジャンプ・折畳)の呼び出し口
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: PASS(全件)

- [ ] **Step 5: コミット**

```bash
git add Sources/Laperm/MarkdownEditorProxy.swift Sources/Laperm/MarkdownEditorView.swift Tests/LapermTests/MarkdownEditorViewTests.swift docs/superpowers/specs/2026-07-16-outline-folding-design.md
git commit -m "feat(ui): add SwiftUI outline/folding modifiers and MarkdownEditorProxy

Task context: 見出しアウトライン/折りたたみ (docs/superpowers/specs/2026-07-16-outline-folding-design.md)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Example アプリにアウトラインサイドバーを追加

**Files:**
- Modify: `Example/ExampleMacOS/ContentView.swift`

**Interfaces:**
- Consumes: `MarkdownEditorView.onOutlineChange` / `.editorProxy` / `MarkdownEditorProxy.scrollToHeading(at:)`、`OutlineItem`(title / level / headingLocation)

- [ ] **Step 1: ContentView をサイドバー付きに変更**

`Example/ExampleMacOS/ContentView.swift` の `body` を `NavigationSplitView` で包む。`@State` を追加:

```swift
    @State private var outline: [OutlineItem] = []
    @State private var editorProxy = MarkdownEditorProxy()
```

`body` を以下の構造に変更(既存の `MarkdownEditorView(...)` チェーンとツールバー・safeAreaInset はそのまま detail 側へ移す):

```swift
    var body: some View {
        NavigationSplitView {
            List(outline, id: \.headingLocation) { item in
                Button {
                    editorProxy.scrollToHeading(at: item.headingLocation)
                } label: {
                    Text(item.title)
                        .lineLimit(1)
                        .padding(.leading, CGFloat(item.level - 1) * 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 200)
        } detail: {
            MarkdownEditorView(
                text: $text, theme: useAlternateTheme ? Self.alternateTheme : .default)
                .showsLineNumbers(showsLineNumbers)
                .inputInterceptor(vim.isEnabled ? vim : nil)
                .insertionPointStyle(vim.insertionPointStyle)
                .imagePreviewOptions(.init(baseURL: imageDirectory))
                .onOutlineChange { outline = $0 }
                .editorProxy(editorProxy)
                .frame(minWidth: 640, minHeight: 480)
                .toolbar { /* 既存のツールバー内容そのまま */ }
                .safeAreaInset(edge: .bottom, spacing: 0) { /* 既存の Vim ステータスそのまま */ }
        }
    }
```

`import Laperm` 済みなので追加 import は不要。既存 sampleDocument は見出しが 6 個あるためデモにそのまま使える。

- [ ] **Step 2: Example がビルドできることを確認**

Run: `xcodebuild -project Example/Example.xcodeproj -scheme ExampleMacOS build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: ライブラリのテストも回す**

Run: `swift test`
Expected: PASS(全件)

- [ ] **Step 4: コミット**

```bash
git add Example/ExampleMacOS/ContentView.swift
git commit -m "feat(example): add outline sidebar with jump-to-heading

Task context: 見出しアウトライン/折りたたみ (docs/superpowers/specs/2026-07-16-outline-folding-design.md)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: GUI 検証(computer use・必須)

**Files:**
- なし(検証のみ。修正が出た場合は該当ファイル)

**Interfaces:**
- Consumes: ビルド済み Example アプリ、プロジェクトスキル `verifying-macos-gui`(`.claude/skills/verifying-macos-gui/SKILL.md`)

- [ ] **Step 1: verifying-macos-gui スキルを読み、その手順どおりに Example を起動する**

スキルの指示(ビルド・起動・スクリーンショット・入力合成の方法)を最優先とする。

- [ ] **Step 2: 以下のシナリオをスクリーンショットで確認する**

1. **初期表示**: サイドバーに見出し一覧(「Laperm デモ」「コードブロック」「GFM 拡張」…)がレベルインデント付きで出ている。ガターの見出し行に ▼ が出ている
2. **折りたたみ**: 「## コードブロック」行の ▼ をクリック → 本体(コードブロック〜リスト)が消え、▶ に変わり、次の見出しが直下に詰まる。行番号が飛ぶ(論理行番号維持)ことを確認
3. **展開**: ▶ を再クリック → 本体が復元される
4. **カーソル自動展開**: 再度折りたたみ、見出し行末にカーソルを置いて ↓ キー → セクションが自動展開されカーソルが見える
5. **サイドバージャンプ**: 「## 画像」をサイドバーでクリック → 該当見出しへスクロールする
6. **画像プレビューとの整合**: 「## 画像」セクションを折りたたみ → 画像プレビュー(サンプル画像・エラー枠)がすべて消える。展開で復元される
7. **テキスト保全**: 折りたたみ中に Cmd+A → Cmd+C で全文がコピーできる(ストレージ無変更の傍証)。または折畳→展開後に文書が元どおりであること

- [ ] **Step 3: 問題があれば修正して再検証、なければ全テストを最終実行**

Run: `swift test`
Expected: PASS(全件)

- [ ] **Step 4: 検証で修正が入った場合はコミット**

```bash
git add -A
git commit -m "fix(ui): address GUI verification findings for outline/folding

Task context: 見出しアウトライン/折りたたみ (docs/superpowers/specs/2026-07-16-outline-folding-design.md)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
