# GFM 拡張(テーブル・タスクリスト・打ち消し線)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** GFM の打ち消し線・タスクリスト・テーブルのシンタックスハイライトを既存パイプライン(SyntaxKind → HighlightPlan → Highlighter/BlockFragment)に追加する。

**Architecture:** Core 層(MarkdownEditorCore)に SyntaxKind 4 ケースと Visitor 処理を追加し、UI 層(MarkdownEditor)でテーマ・レンダリング属性・BlockFragment を拡張する。パーサー変更は不要(swift-markdown は table/strikethrough/tasklist 拡張を常時有効化している — `CommonMarkConverter.swift:624-626` で確認済み)。

**Tech Stack:** Swift 6 / SwiftPM / TextKit 2(macOS 27+)/ apple/swift-markdown / Swift Testing

**Spec:** `docs/superpowers/specs/2026-07-15-gfm-extensions-design.md`

## Global Constraints

- 対象 OS: macOS 27+。外部依存は `apple/swift-markdown` のみ(追加禁止)
- ソース常時表示型: テキスト内容は一切改変しない(装飾のみ)
- 属性 2 層分離: フォント等レイアウト属性 → `textStorage`(`performEditingTransaction` 内)、色・打ち消し線等 → `NSTextLayoutManager.renderingAttributes`
- コメントは既存コードに合わせて日本語で書く
- 各タスク末尾で `swift test` 全体を実行し、全テスト通過(既存 62 + 追加分)を確認してからコミット
- コミットメッセージ末尾に以下を含める(ユーザー CLAUDE.md の規約):
  ```
  Task context: GFM extensions (docs/superpowers/specs/2026-07-15-gfm-extensions-design.md)

  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_013MdXdcy1HQMdoG47QACBR6
  ```

## 検証済みの事実(実測。信頼してよい)

スクラッチパッケージで swift-markdown(main)の実挙動を確認済み:

- `~x~`(チルダ 1 個)も Strikethrough になる(`CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE` 未指定のため)。開き・閉じのチルダ数が異なる場合は不成立。
- `"- [x] done"` → ListItem @1:1-1:11, checkbox=[x], **Paragraph @1:7-1:11("done" のみ。チェックボックスを含まない)**
- ネスト `"- [x] parent\n  - [ ] child"` → 親の Paragraph は "parent" のみ。子リストは含まれない。
- `"| a | b |\n|---|---|\n| c | d |"` → Table @1:1-3:10(NSRange(0, 29))、Head @1:1-1:10(NSRange(0, 9))。**区切り行(2 行目)は Head にも Body にも含まれない** → テーブルレンジ内の「2 行目」として位置で特定する。

---

### Task 1: Core — 打ち消し線

**Files:**
- Modify: `Sources/MarkdownEditorCore/SyntaxKind.swift`
- Modify: `Sources/MarkdownEditorCore/HighlightMapper.swift`
- Test: `Tests/MarkdownEditorCoreTests/MarkdownParserTests.swift`

**Interfaces:**
- Consumes: 既存 `HighlightMapper.Visitor` の `nsRange(of:)` / `inlineSpans` / `markerSpans`、`visitInlineCode` のバッククォート走査ロジック
- Produces: `SyntaxKind.strikethrough`(Task 2 のテーマ・Highlighter が参照)、`symmetricDelimiterLength(in:character:)` ヘルパー(Visitor 内 private)

- [ ] **Step 1: SyntaxKind にケースを追加**

`Sources/MarkdownEditorCore/SyntaxKind.swift` の `case syntaxMarker` の前に追加:

```swift
    case strikethrough
```

- [ ] **Step 2: 失敗するテストを書く**

`Tests/MarkdownEditorCoreTests/MarkdownParserTests.swift` の末尾に追加:

```swift
// MARK: - GFM 打ち消し線

@Test func mapsStrikethroughWithDelimiters() {
    let md = "a ~~del~~ b"
    #expect(ranges(of: .strikethrough, in: md) == [NSRange(location: 2, length: 7)])
    let markers = ranges(of: .syntaxMarker, in: md)
    #expect(markers.contains(NSRange(location: 2, length: 2)))
    #expect(markers.contains(NSRange(location: 7, length: 2)))
}

@Test func mapsSingleTildeStrikethrough() {
    // cmark-gfm は DOUBLE_TILDE オプション未指定のためチルダ 1 個も打ち消し線になる
    let md = "~x~"
    #expect(ranges(of: .strikethrough, in: md) == [NSRange(location: 0, length: 3)])
    let markers = ranges(of: .syntaxMarker, in: md)
    #expect(markers.contains(NSRange(location: 0, length: 1)))
    #expect(markers.contains(NSRange(location: 2, length: 1)))
}

@Test func strikethroughInsideCodeBlockIsNotMapped() {
    let md = "```\n~~x~~\n```"
    #expect(ranges(of: .strikethrough, in: md).isEmpty)
}

@Test func nestedEmphasisInsideStrikethroughIsMapped() {
    let md = "~~a *em* b~~"
    #expect(ranges(of: .strikethrough, in: md) == [NSRange(location: 0, length: 12)])
    #expect(ranges(of: .emphasis, in: md) == [NSRange(location: 4, length: 4)])
}
```

- [ ] **Step 3: テストが失敗することを確認**

Run: `swift test --filter Strikethrough`
Expected: FAIL(`.strikethrough` のスパンが空のため `#expect` 失敗。コンパイルは Step 1 で通る)

- [ ] **Step 4: 実装**

`Sources/MarkdownEditorCore/HighlightMapper.swift` を編集する。

(a) `visitInlineCode` のバッククォート走査を共通ヘルパーに抽出する。Visitor の「ヘルパー」セクション(`appendDelimited` の近く)に追加:

```swift
        /// range の先頭にある character の連続長を求め、閉じ側にも同じ長さの列が
        /// ある場合のみその長さを返す(なければ 0)。インラインコードのバッククォートと
        /// 打ち消し線のチルダで共用する。
        private func symmetricDelimiterLength(in range: NSRange, character: unichar) -> Int {
            let end = NSMaxRange(range)
            var delimiter = 0
            while range.location + delimiter < end,
                  text.character(at: range.location + delimiter) == character {
                delimiter += 1
            }
            guard delimiter > 0, range.length >= delimiter * 2 else { return 0 }
            for i in (end - delimiter)..<end where text.character(at: i) != character {
                return 0
            }
            return delimiter
        }
```

(b) `visitInlineCode` の `let backtick = ...` から `if closingIsBackticks {` の直前までの走査コードを削除し、ヘルパー呼び出しに置き換える(既存のコメント「デリミタは実際のバッククォート列を走査して求める…」は残す):

```swift
        mutating func visitInlineCode(_ inlineCode: InlineCode) {
            guard let range = nsRange(of: inlineCode), range.length > 0 else { return }
            inlineSpans.append(HighlightSpan(range: range, kind: .inlineCode))
            // デリミタは実際のバッククォート列を走査して求める。
            // CommonMark はパディングスペースを code から剥がすため、
            // (range.length - code.length) / 2 のような算術では
            // スペースまでマーカーに含めてしまう。
            let delimiter = symmetricDelimiterLength(
                in: range, character: unichar(UnicodeScalar("`").value))
            if delimiter > 0 {
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
```

(c) インライン要素セクションに `visitStrikethrough` を追加(`visitLink` の後):

```swift
        mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
            if let range = nsRange(of: strikethrough), range.length > 0 {
                inlineSpans.append(HighlightSpan(range: range, kind: .strikethrough))
                // cmark-gfm はチルダ 1 個も打ち消し線にするため、デリミタ長は
                // 実テキストのチルダ列を走査して求める(インラインコードと同方式)。
                let delimiter = symmetricDelimiterLength(
                    in: range, character: unichar(UnicodeScalar("~").value))
                if delimiter > 0 {
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
            descendInto(strikethrough)
        }
```

- [ ] **Step 5: テストが通ることを確認**

Run: `swift test --filter Strikethrough`
Expected: PASS(4 テスト)

- [ ] **Step 6: 全テスト実行**

Run: `swift test`
Expected: 全テスト PASS(Core 36 + UI 30。既存の `mapsInlineCodeDelimiters` / `paddedDoubleBacktickCodeMarksOnlyBackticks` がリファクタ後も通ることを特に確認)

- [ ] **Step 7: コミット**

```bash
git add Sources/MarkdownEditorCore Tests/MarkdownEditorCoreTests
git commit -m "feat(core): map GFM strikethrough with tilde-scan delimiters"
```
(末尾に Global Constraints のトレーラーを付ける)

---

### Task 2: UI — 打ち消し線のレンダリング属性

**Files:**
- Modify: `Sources/MarkdownEditor/MarkdownTheme.swift`
- Modify: `Sources/MarkdownEditor/Highlighter.swift:208-221`(レンダリング属性適用ループ)
- Test: `Tests/MarkdownEditorTests/MarkdownThemeTests.swift`, `Tests/MarkdownEditorTests/HighlighterTests.swift`

**Interfaces:**
- Consumes: `SyntaxKind.strikethrough`(Task 1)、既存 `MarkdownTheme.Style` / `Highlighter.apply`
- Produces: `Style.strikethrough: Bool`(init 末尾にデフォルト引数 `false` で追加)、`MarkdownTheme.renderingAttributes(for:) -> [NSAttributedString.Key: Any]`(internal。Highlighter が使用。既存 `renderingColor(for:)` は残す)

- [ ] **Step 1: Style にプロパティを追加**

`Sources/MarkdownEditor/MarkdownTheme.swift` の `Style` を置き換え:

```swift
    public struct Style: Equatable, @unchecked Sendable {
        /// レイアウトに影響する属性(textStorage へ適用)
        public var font: NSFont?
        /// レイアウトに影響しない属性(renderingAttributes へ適用)
        public var foregroundColor: NSColor?
        /// 打ち消し線(レンダリング属性。レイアウトに影響しない)
        public var strikethrough: Bool

        public init(font: NSFont? = nil, foregroundColor: NSColor? = nil, strikethrough: Bool = false) {
            self.font = font
            self.foregroundColor = foregroundColor
            self.strikethrough = strikethrough
        }
    }
```

- [ ] **Step 2: 失敗するテストを書く**

`Tests/MarkdownEditorTests/MarkdownThemeTests.swift` に追加:

```swift
@Test func defaultThemeStrikesThroughStrikethrough() {
    let theme = MarkdownTheme.default
    let attributes = theme.renderingAttributes(for: .strikethrough)
    #expect(attributes[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)
    #expect(attributes[.foregroundColor] != nil)
    // フォント変更なし(レイアウト非影響)
    #expect(theme.layoutFont(for: .strikethrough) == nil)
}
```

`Tests/MarkdownEditorTests/HighlighterTests.swift` に追加(ファイル内既存ヘルパー `makeTextKitStack` を使う):

```swift
@MainActor
private func renderingAttributeValue(
    _ key: NSAttributedString.Key, at offset: Int, _ layoutManager: NSTextLayoutManager
) -> Any? {
    guard let contentManager = layoutManager.textContentManager,
          let location = contentManager.location(contentManager.documentRange.location, offsetBy: offset)
    else { return nil }
    var value: Any?
    layoutManager.enumerateRenderingAttributes(from: location, reverse: false) { _, attributes, _ in
        value = attributes[key]
        return false  // 最初の run だけ見る
    }
    return value
}

@MainActor @Test func rehighlightAllAppliesStrikethroughRenderingAttribute() {
    let (contentStorage, layoutManager) = makeTextKitStack("a ~~del~~ b")
    let highlighter = Highlighter(theme: .default)
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)
    // 位置 4 は "del" の内部
    let style = renderingAttributeValue(.strikethroughStyle, at: 4, layoutManager) as? Int
    #expect(style == NSUnderlineStyle.single.rawValue)
}

@MainActor @Test func removingStrikethroughClearsRenderingAttribute() {
    let (contentStorage, layoutManager) = makeTextKitStack("~~del~~")
    let highlighter = Highlighter(theme: .default)
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)
    // 開きチルダ 2 個を "xx" に置換して打ち消し線を解除
    contentStorage.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 2), with: "xx")
    highlighter.noteEdit(editedRange: NSRange(location: 0, length: 2), changeInLength: 0)
    highlighter.flushPendingHighlight(contentStorage: contentStorage, layoutManager: layoutManager)
    // "xxdel~~" の 'e'(位置 3)に打ち消し線が残っていないこと
    #expect(renderingAttributeValue(.strikethroughStyle, at: 3, layoutManager) == nil)
}
```

- [ ] **Step 3: テストが失敗することを確認**

Run: `swift test --filter strikethrough 2>&1 | tail -20`
Expected: コンパイルエラー(`renderingAttributes(for:)` 未定義)。定義追加後は `defaultThemeStrikesThroughStrikethrough` と `rehighlightAllAppliesStrikethroughRenderingAttribute` が FAIL

- [ ] **Step 4: 実装**

(a) `MarkdownTheme.swift` 末尾の `extension MarkdownTheme` に追加:

```swift
    /// kind に適用するレンダリング属性(色・打ち消し線)。renderingAttributes へ適用する。
    func renderingAttributes(for kind: SyntaxKind) -> [NSAttributedString.Key: Any] {
        guard let style = style(for: kind) else { return [:] }
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let color = style.foregroundColor {
            attributes[.foregroundColor] = color
        }
        if style.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            if let color = style.foregroundColor {
                attributes[.strikethroughColor] = color
            }
        }
        return attributes
    }
```

(b) `MarkdownTheme.default` の styles に追加(`styles[.syntaxMarker]` の前):

```swift
        styles[.strikethrough] = Style(foregroundColor: .secondaryLabelColor, strikethrough: true)
```

(c) `Highlighter.swift` の `apply` 内、色適用ループ(`for span in spans { guard let color = theme.renderingColor...`)を置き換え:

```swift
        for span in spans {
            let attributes = theme.renderingAttributes(for: span.kind)
            guard !attributes.isEmpty else { continue }
            let clipped = clip(span.range, to: documentLength)
            guard clipped.length > 0,
                  let textRange = contentStorage.textRange(for: clipped) else { continue }
            for (key, value) in attributes {
                layoutManager.addRenderingAttribute(key, value: value, for: textRange)
            }
        }
```

リセット側(`setRenderingAttributes([.foregroundColor: theme.bodyColor], ...)`)は変更不要 — `setRenderingAttributes` はレンジの属性を丸ごと置換するため打ち消し線も消える。

- [ ] **Step 5: テストが通ることを確認**

Run: `swift test --filter strikethrough 2>&1 | tail -10` → PASS(Task 1 の Core テスト含む)

- [ ] **Step 6: 全テスト実行**

Run: `swift test`
Expected: 全テスト PASS

- [ ] **Step 7: コミット**

```bash
git add Sources/MarkdownEditor Tests/MarkdownEditorTests
git commit -m "feat(ui): render GFM strikethrough via rendering attributes"
```
(末尾に Global Constraints のトレーラーを付ける)

---

### Task 3: タスクリスト(Core + テーマ)

**Files:**
- Modify: `Sources/MarkdownEditorCore/SyntaxKind.swift`
- Modify: `Sources/MarkdownEditorCore/HighlightMapper.swift`(`visitListItem` と新ヘルパー)
- Modify: `Sources/MarkdownEditor/MarkdownTheme.swift`(default テーマに 1 エントリ)
- Test: `Tests/MarkdownEditorCoreTests/MarkdownParserTests.swift`, `Tests/MarkdownEditorTests/MarkdownThemeTests.swift`

**Interfaces:**
- Consumes: `ListItem.checkbox: Checkbox?`(swift-markdown。`.checked` / `.unchecked`)、既存 `listMarkerRange(in:)`
- Produces: `SyntaxKind.taskChecked`

- [ ] **Step 1: SyntaxKind にケースを追加**

```swift
    case taskChecked
```
(`case strikethrough` の後に)

- [ ] **Step 2: 失敗するテストを書く**

`Tests/MarkdownEditorCoreTests/MarkdownParserTests.swift` に追加:

```swift
// MARK: - GFM タスクリスト

@Test func mapsUncheckedTaskCheckboxAsMarker() {
    let md = "- [ ] todo"
    let markers = ranges(of: .syntaxMarker, in: md)
    #expect(markers.contains(NSRange(location: 2, length: 3)))  // "[ ]"
    #expect(ranges(of: .taskChecked, in: md).isEmpty)
    // 既存のリストマーカーも維持される
    #expect(ranges(of: .listMarker, in: md).contains(NSRange(location: 0, length: 1)))
}

@Test func checkedTaskDimsBodyParagraphOnly() {
    // Paragraph レンジはチェックボックスの後("done")から始まる(実測済み)
    let md = "- [x] done"
    #expect(ranges(of: .taskChecked, in: md) == [NSRange(location: 6, length: 4)])
    #expect(ranges(of: .syntaxMarker, in: md).contains(NSRange(location: 2, length: 3)))  // "[x]"
}

@Test func uppercaseCheckedTaskIsAlsoDimmed() {
    let md = "- [X] done"
    #expect(ranges(of: .taskChecked, in: md) == [NSRange(location: 6, length: 4)])
}

@Test func nestedUncheckedChildIsNotDimmedByCheckedParent() {
    let md = "- [x] parent\n  - [ ] child"
    // 親の taskChecked は "parent"(6..<12)のみ。子リストを含まない
    #expect(ranges(of: .taskChecked, in: md) == [NSRange(location: 6, length: 6)])
    // 子のチェックボックス "[ ]"(位置 17)はマーカーになる
    #expect(ranges(of: .syntaxMarker, in: md).contains(NSRange(location: 17, length: 3)))
}

@Test func plainListItemHasNoCheckboxMarker() {
    let md = "- [link](https://example.com)"
    // checkbox なしのリスト項目では "[li" 等がマーカー化されないこと
    #expect(ranges(of: .taskChecked, in: md).isEmpty)
    #expect(!ranges(of: .syntaxMarker, in: md).contains(NSRange(location: 2, length: 3)))
}
```

`Tests/MarkdownEditorTests/MarkdownThemeTests.swift` に追加:

```swift
@Test func defaultThemeDimsCheckedTasks() {
    let theme = MarkdownTheme.default
    #expect(theme.renderingColor(for: .taskChecked) != nil)
    #expect(theme.layoutFont(for: .taskChecked) == nil)
}
```

- [ ] **Step 3: テストが失敗することを確認**

Run: `swift test --filter Task 2>&1 | tail -10` および `swift test --filter defaultThemeDimsCheckedTasks 2>&1 | tail -5`
Expected: FAIL(taskChecked スパンなし / テーマエントリなし)

- [ ] **Step 4: 実装**

(a) `HighlightMapper.swift` の `visitListItem` を置き換え:

```swift
        mutating func visitListItem(_ listItem: ListItem) {
            if let range = nsRange(of: listItem), range.length > 0,
               let marker = listMarkerRange(in: range) {
                inlineSpans.append(HighlightSpan(range: marker, kind: .listMarker))
                if let checkbox = listItem.checkbox,
                   let box = checkboxRange(after: marker, within: range) {
                    markerSpans.append(HighlightSpan(range: box, kind: .syntaxMarker))
                    if checkbox == .checked {
                        // チェック済み: 項目直下の Paragraph のみ淡色化。
                        // Paragraph レンジはチェックボックスの後から始まり、
                        // ネストした子リストを含まないため子項目を汚染しない。
                        for child in listItem.children where child is Paragraph {
                            if let paragraphRange = nsRange(of: child), paragraphRange.length > 0 {
                                inlineSpans.append(
                                    HighlightSpan(range: paragraphRange, kind: .taskChecked))
                            }
                        }
                    }
                }
            }
            descendInto(listItem)
        }
```

(b) ヘルパーセクション(`listMarkerRange` の後)に追加:

```swift
        /// リストマーカー直後の "[ ]" / "[x]" / "[X]"(3 文字)のレンジ。なければ nil。
        /// 呼び出し側で listItem.checkbox の存在を確認してから使うこと
        /// (checkbox 非 nil ならパーサーが認めた実チェックボックスが必ず存在する)。
        private func checkboxRange(after marker: NSRange, within range: NSRange) -> NSRange? {
            let end = NSMaxRange(range)
            let space = unichar(UnicodeScalar(" ").value)
            var i = NSMaxRange(marker)
            while i < end, text.character(at: i) == space { i += 1 }
            guard i + 3 <= end,
                  text.character(at: i) == unichar(UnicodeScalar("[").value),
                  text.character(at: i + 2) == unichar(UnicodeScalar("]").value) else { return nil }
            return NSRange(location: i, length: 3)
        }
```

(c) `MarkdownTheme.default` の styles に追加(`styles[.strikethrough]` の後):

```swift
        styles[.taskChecked] = Style(foregroundColor: .tertiaryLabelColor)
```

- [ ] **Step 5: テストが通ることを確認**

Run: `swift test --filter Task 2>&1 | tail -10` → PASS

- [ ] **Step 6: 全テスト実行**

Run: `swift test`
Expected: 全テスト PASS

- [ ] **Step 7: コミット**

```bash
git add Sources Tests
git commit -m "feat: highlight GFM task lists with dimmed checked items"
```
(末尾に Global Constraints のトレーラーを付ける)

---

### Task 4: Core — テーブル

**Files:**
- Modify: `Sources/MarkdownEditorCore/SyntaxKind.swift`
- Modify: `Sources/MarkdownEditorCore/HighlightMapper.swift`
- Test: `Tests/MarkdownEditorCoreTests/MarkdownParserTests.swift`

**Interfaces:**
- Consumes: `Markdown.Table` / `table.head`(swift-markdown)、既存 `clippedLineRange(at:within:)`
- Produces: `SyntaxKind.table`(ブロックスパン。Task 5 の BlockFragmentProvider が参照)、`SyntaxKind.tableHeader`(ブロックスパン。Task 5 のテーマが参照)

- [ ] **Step 1: SyntaxKind にケースを追加**

```swift
    case table
    case tableHeader
```
(`case taskChecked` の後に)

- [ ] **Step 2: 失敗するテストを書く**

`Tests/MarkdownEditorCoreTests/MarkdownParserTests.swift` に追加:

```swift
// MARK: - GFM テーブル

@Test func mapsTableWithHeaderAndMarkers() {
    let md = "| a | b |\n|---|---|\n| c | d |"
    // Table @1:1-3:10, Head @1:1-1:10(実測済み)
    #expect(ranges(of: .table, in: md) == [NSRange(location: 0, length: 29)])
    #expect(ranges(of: .tableHeader, in: md) == [NSRange(location: 0, length: 9)])
    let markers = ranges(of: .syntaxMarker, in: md)
    // 区切り行(2 行目)は行全体がマーカー
    #expect(markers.contains(NSRange(location: 10, length: 9)))
    // ヘッダー行・ボディ行のパイプは 1 文字ずつマーカー
    for location in [0, 4, 8, 20, 24, 28] {
        #expect(markers.contains(NSRange(location: location, length: 1)), "パイプ位置 \(location)")
    }
}

@Test func escapedPipeInCellIsNotMarker() {
    let md = "| a\\|b |\n|---|\n| c |"
    let markers = ranges(of: .syntaxMarker, in: md)
    // "| a\|b |" の位置 4(エスケープされたパイプ)はマーカーにしない
    #expect(!markers.contains(NSRange(location: 4, length: 1)))
    #expect(markers.contains(NSRange(location: 0, length: 1)))
    #expect(markers.contains(NSRange(location: 7, length: 1)))
}

@Test func inlineElementsInsideTableCellsAreMapped() {
    let md = "| **a** |\n|---|\n| ~~b~~ |"
    #expect(ranges(of: .strong, in: md) == [NSRange(location: 2, length: 5)])
    #expect(ranges(of: .strikethrough, in: md).count == 1)
}

@Test func headerOnlyTableIsMapped() {
    let md = "| a |\n|---|"
    #expect(ranges(of: .table, in: md).count == 1)
    #expect(ranges(of: .tableHeader, in: md) == [NSRange(location: 0, length: 5)])
}

@Test func pipesInsideCodeBlockAreNotTableMarkers() {
    let md = "```\n| a |\n```"
    #expect(ranges(of: .table, in: md).isEmpty)
    // フェンス行以外にマーカーがないこと(パイプがマーカー化されていない)
    #expect(!ranges(of: .syntaxMarker, in: md).contains(NSRange(location: 4, length: 1)))
}
```

- [ ] **Step 3: テストが失敗することを確認**

Run: `swift test --filter Table 2>&1 | tail -10` と `swift test --filter escapedPipe 2>&1 | tail -5` と `swift test --filter pipesInside 2>&1 | tail -5`
Expected: FAIL(table スパンなし)

- [ ] **Step 4: 実装**

`HighlightMapper.swift` のブロック要素セクション(`visitThematicBreak` の後)に追加:

```swift
        mutating func visitTable(_ table: Markdown.Table) {
            if let range = nsRange(of: table), range.length > 0 {
                blockSpans.append(HighlightSpan(range: range, kind: .table))
                if let headRange = nsRange(of: table.head), headRange.length > 0 {
                    blockSpans.append(HighlightSpan(range: headRange, kind: .tableHeader))
                }
                appendTableMarkers(in: range)
            }
            descendInto(table)
        }
```

注: `Table` は Foundation の型と衝突しないが、明示的に `Markdown.Table` と書いて誤解を避ける(コンパイルエラーになる場合は `Table` に変える)。

ヘルパーセクションに追加:

```swift
        /// テーブルレンジ内のパイプ("\|" エスケープを除く)と区切り行をマーカー化する。
        /// GFM テーブルはヘッダー 1 行 + 区切り行 1 行 + ボディという固定構造のため、
        /// レンジ内の 2 行目を区切り行("---|---" 等)として行全体をマーカーにする
        /// (区切り行は AST の Head にも Body にも含まれない)。
        private mutating func appendTableMarkers(in range: NSRange) {
            let pipe = unichar(UnicodeScalar("|").value)
            let backslash = unichar(UnicodeScalar("\\").value)
            var location = range.location
            let end = NSMaxRange(range)
            var lineIndex = 0
            while location < end {
                let line = clippedLineRange(at: location, within: range)
                if lineIndex == 1 {
                    if line.length > 0 {
                        markerSpans.append(HighlightSpan(range: line, kind: .syntaxMarker))
                    }
                } else {
                    var i = line.location
                    while i < NSMaxRange(line) {
                        if text.character(at: i) == pipe,
                           i == line.location || text.character(at: i - 1) != backslash {
                            markerSpans.append(HighlightSpan(
                                range: NSRange(location: i, length: 1), kind: .syntaxMarker))
                        }
                        i += 1
                    }
                }
                let fullLine = text.lineRange(for: NSRange(location: location, length: 0))
                if NSMaxRange(fullLine) <= location { break }
                location = NSMaxRange(fullLine)
                lineIndex += 1
            }
        }
```

- [ ] **Step 5: テストが通ることを確認**

Run: `swift test --filter Table 2>&1 | tail -10` ほか Step 3 のフィルタ → PASS

- [ ] **Step 6: 全テスト実行**

Run: `swift test`
Expected: 全テスト PASS

- [ ] **Step 7: コミット**

```bash
git add Sources/MarkdownEditorCore Tests/MarkdownEditorCoreTests
git commit -m "feat(core): map GFM tables with header, pipe and delimiter-row markers"
```
(末尾に Global Constraints のトレーラーを付ける)

---

### Task 5: UI — テーブルのテーマと背景フラグメント

**Files:**
- Modify: `Sources/MarkdownEditor/MarkdownTheme.swift`
- Modify: `Sources/MarkdownEditor/BlockFragments.swift`
- Modify: `Sources/MarkdownEditor/BlockFragmentProvider.swift`
- Test: `Tests/MarkdownEditorTests/MarkdownThemeTests.swift`, `Tests/MarkdownEditorTests/BlockFragmentTests.swift`

**Interfaces:**
- Consumes: `SyntaxKind.table` / `.tableHeader`(Task 4)、既存 `CodeBlockFragment` パターン
- Produces: `MarkdownTheme.tableBackgroundColor: NSColor`(init 末尾にデフォルト引数付きで追加)、`TableBackgroundFragment`(internal final class)

- [ ] **Step 1: 失敗するテストを書く**

`Tests/MarkdownEditorTests/MarkdownThemeTests.swift` に追加:

```swift
@Test func defaultThemeBoldsTableHeaderOnly() {
    let theme = MarkdownTheme.default
    // ヘッダー行は太字(レイアウト属性)
    #expect(theme.layoutFont(for: .tableHeader) != nil)
    // テーブル全体はフォント変更なし(デフォルトテーマの本文は元から等幅)
    #expect(theme.layoutFont(for: .table) == nil)
}
```

`Tests/MarkdownEditorTests/BlockFragmentTests.swift` に追加(既存ヘルパー `layoutFragments(in:)` を使う):

```swift
@MainActor @Test func tableGetsTableBackgroundFragment() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "| a | b |\n|---|---|\n| c | d |"
    textView.highlightAll()
    #expect(layoutFragments(in: textView).contains { $0 is TableBackgroundFragment })
}

@MainActor @Test func breakingTableRemovesTableFragment() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "| a |\n|---|"
    textView.highlightAll()
    #expect(layoutFragments(in: textView).contains { $0 is TableBackgroundFragment })
    // 区切り行の先頭を壊す → テーブル消滅
    textView.textStorage!.replaceCharacters(in: NSRange(location: 6, length: 1), with: "x")
    textView.highlightNow()
    #expect(!layoutFragments(in: textView).contains { $0 is TableBackgroundFragment })
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter Table 2>&1 | tail -10`
Expected: コンパイルエラー(`TableBackgroundFragment` 未定義)

- [ ] **Step 3: 実装**

(a) `MarkdownTheme.swift`: プロパティ `public var tableBackgroundColor: NSColor` を `codeBlockBackgroundColor` の直後に追加し、init に**末尾**パラメータとして追加(既存呼び出しを壊さないようデフォルト値付き):

```swift
    public init(
        bodyFont: NSFont,
        bodyColor: NSColor,
        backgroundColor: NSColor,
        codeBlockBackgroundColor: NSColor,
        blockquoteBarColor: NSColor,
        thematicBreakLineColor: NSColor,
        styles: [SyntaxKind: Style],
        tableBackgroundColor: NSColor = .quaternarySystemFill
    ) {
        self.bodyFont = bodyFont
        self.bodyColor = bodyColor
        self.backgroundColor = backgroundColor
        self.codeBlockBackgroundColor = codeBlockBackgroundColor
        self.blockquoteBarColor = blockquoteBarColor
        self.thematicBreakLineColor = thematicBreakLineColor
        self.styles = styles
        self.tableBackgroundColor = tableBackgroundColor
    }
```

`MarkdownTheme.default` の styles に追加(`styles[.taskChecked]` の後):

```swift
        styles[.tableHeader] = Style(font: .monospacedSystemFont(ofSize: bodySize, weight: .bold))
```

注: デフォルトテーマの本文は元から等幅のため `styles[.table]` にフォントは設定しない。プロポーショナル本文のカスタムテーマでは利用側が `styles[.table]` に等幅フォントを設定できる。

(b) `BlockFragments.swift` 末尾に追加:

```swift
/// テーブル: テキスト背面に角丸背景(コードブロックと同型)
final class TableBackgroundFragment: NSTextLayoutFragment {
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
```

(c) `BlockFragmentProvider.swift`:

`BlockDecoration` に `case table` を追加。

`update(plan:...)` の compactMap に追加:

```swift
            case .table: Decoration(range: span.range, kind: .table)
```
(`.tableHeader` は装飾対象ではないので追加しない)

`textLayoutFragmentFor` の switch に追加:

```swift
        case .table:
            let fragment = TableBackgroundFragment(textElement: textElement, range: textElement.elementRange)
            fragment.fillColor = theme.tableBackgroundColor
            return fragment
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter Table 2>&1 | tail -10` → PASS

- [ ] **Step 5: 全テスト実行**

Run: `swift test`
Expected: 全テスト PASS

- [ ] **Step 6: コミット**

```bash
git add Sources/MarkdownEditor Tests/MarkdownEditorTests
git commit -m "feat(ui): add table header bold and TableBackgroundFragment decoration"
```
(末尾に Global Constraints のトレーラーを付ける)

---

### Task 6: ExampleMacOS サンプル更新と最終検証

**Files:**
- Modify: `ExampleMacOS/Sources/ExampleMacOSApp.swift:47-71`(`sampleDocument`)

**Interfaces:**
- Consumes: Task 1-5 の全機能
- Produces: なし(目視確認用)

- [ ] **Step 1: サンプル文書に GFM セクションを追加**

`sampleDocument` の `---` の後(`日本語も絵文字…` の前)に挿入:

```swift
    ## GFM 拡張

    ~~打ち消し線~~ が使えます。

    - [x] 完了したタスク
    - [ ] 未完了のタスク

    | 構文 | 対応 |
    |------|------|
    | テーブル | あり |
    | `インラインコード` | あり |

```

- [ ] **Step 2: パッケージ全テスト + Example ビルド**

Run: `swift test`
Expected: 全テスト PASS

Run: `xcodebuild -project ExampleMacOS/ExampleMacOS.xcodeproj -scheme ExampleMacOS build 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: 目視確認(実行者が可能な場合)**

ExampleMacOS を起動し、以下を確認する:
- `~~打ち消し線~~` に実際に線が描画されること。**もし renderingAttributes 経由で打ち消し線が描画されない場合**(TextKit2 のレンダリング属性サポート差異): `Highlighter.apply` の textStorage 側トランザクションで `.strikethroughStyle` を適用する方式に切り替える(レイアウトには影響しないため 2 層分離の趣旨は維持される)。その場合は `removingStrikethroughClearsRenderingAttribute` テストも textStorage 検査に書き換えること。
- チェック済みタスクの本文が淡色になること
- テーブルに角丸背景が付き、ヘッダー行が太字になること
- テーマトグル(ツールバー)切り替えで表示が崩れないこと

- [ ] **Step 4: コミット**

```bash
git add ExampleMacOS/Sources/ExampleMacOSApp.swift
git commit -m "feat(example): showcase GFM extensions in sample document"
```
(末尾に Global Constraints のトレーラーを付ける)
