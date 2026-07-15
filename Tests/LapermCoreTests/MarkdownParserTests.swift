import Foundation
import Testing
@testable import LapermCore

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

@Test func paddedDoubleBacktickCodeMarksOnlyBackticks() {
    // "`` `x` ``": CommonMark はパディングスペースを剥がすので code は "`x`"
    let md = "a `` `x` `` b"
    #expect(ranges(of: .inlineCode, in: md) == [NSRange(location: 2, length: 9)])
    let markers = ranges(of: .syntaxMarker, in: md)
    #expect(markers.contains(NSRange(location: 2, length: 2)))   // 開き ``
    #expect(markers.contains(NSRange(location: 9, length: 2)))   // 閉じ ``
    #expect(!markers.contains(NSRange(location: 2, length: 3)))  // スペースを含めない
}

@Test func setextHeadingHasNoSyntaxMarker() {
    let md = "Title\n====="
    #expect(ranges(of: .heading(level: 1), in: md).count == 1)
    #expect(ranges(of: .syntaxMarker, in: md).isEmpty)
}

@Test func indentedCodeBlockHasNoFenceMarker() {
    let md = "para\n\n    let x = 1"
    #expect(ranges(of: .codeBlock, in: md).count == 1)
    #expect(ranges(of: .syntaxMarker, in: md).isEmpty)
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

@Test func asymmetricTildesAreNotStrikethrough() {
    // 開き・閉じのチルダ数が異なる場合、cmark-gfm は打ち消し線にしない
    let md = "~~x~"
    #expect(ranges(of: .strikethrough, in: md).isEmpty)
    #expect(ranges(of: .syntaxMarker, in: md).isEmpty)
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
