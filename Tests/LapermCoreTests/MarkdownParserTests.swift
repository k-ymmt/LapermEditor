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

@Test func setextHeadingRangeStopsAtUnderline() {
    // cmark は Setext 見出しの終端を次ブロックまで過大報告する — 下線行末尾へのクランプを検証
    let md = "Title\n=====\nbody"
    #expect(ranges(of: .heading(level: 1), in: md) == [NSRange(location: 0, length: 11)])
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
    #expect(markers.contains(NSRange(location: 0, length: 2)))   // 1 行目 "> "
    #expect(markers.contains(NSRange(location: 6, length: 2)))   // 2 行目 "> "
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

// MARK: - 画像

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

@Test func multiLineImageParagraphRangeCoversWholeMarkup() {
    // alt テキスト内のソフト改行で記法が複数行にまたがるケース。
    // paragraphRange は記法全体を含む改行区切りブロックになる。
    let md = "before\n![alt\ntext](a.png)\nafter\n"
    let refs = imageReferences(in: md)
    #expect(refs.count == 1)
    #expect(refs[0].range == NSRange(location: 7, length: 18))
    #expect(refs[0].paragraphRange == NSRange(location: 7, length: 19))
}

// MARK: - レビューで見つかった回帰

@Test func smartPunctuationDoesNotBreakLazyLineInlineSpans() {
    // cmark のスマート約物("..." → "…")が有効だと、遅延継続行の桁補正の検証で
    // 原文と Text ノードが食い違い、補正が捨てられて強調が消えていた
    let md = "- item\nlazy with... **bold**"
    #expect(ranges(of: .strong, in: md) == [NSRange(location: 20, length: 8)])
}

@Test func smartPunctuationDoesNotAlterLinkText() {
    let plan = MarkdownParser().highlightPlan(for: "[it's \"quoted\"](https://x.y)")
    #expect(plan.links.map(\.text) == ["it's \"quoted\""])
}

@Test func loneCarriageReturnIsALineEnding() {
    // cmark は単独 CR も行末として扱う。コンバータが LF しか数えないと以降の行がずれる
    let md = "a\rb\n# Title\nmore **bold** here"
    #expect(ranges(of: .heading(level: 1), in: md) == [NSRange(location: 4, length: 7)])
    #expect(ranges(of: .strong, in: md) == [NSRange(location: 17, length: 8)])
}

@Test func tableAfterParagraphWithoutBlankLineIsClampedToHeaderRow() {
    // cmark-gfm は段落直後のテーブルの sourcepos を段落の先頭にしてしまう
    let md = "line1 *x*\nline2 **bold**\n| a | b |\n|---|---|\n| c | d |"
    #expect(ranges(of: .table, in: md) == [NSRange(location: 25, length: 29)])
    #expect(ranges(of: .tableHeader, in: md) == [NSRange(location: 25, length: 9)])
    let markers = ranges(of: .syntaxMarker, in: md)
    // 区切り行はレンジ内 2 行目として行全体がマーカーになる
    #expect(markers.contains(NSRange(location: 35, length: 9)))
    // 飲み込まれた段落行はマーカー扱いされない
    #expect(!markers.contains { $0.location < 25 })
}

@Test func setextHeadingStartingWithHashIsNotATX() {
    let md = "#hashtag\n=====\nbody"
    #expect(ranges(of: .heading(level: 1), in: md) == [NSRange(location: 0, length: 14)])
    #expect(ranges(of: .syntaxMarker, in: md).isEmpty)
}

@Test func indentedFenceLinesAreMarkers() {
    let md = "  ```\n  x\n  ```"
    let markers = ranges(of: .syntaxMarker, in: md)
    #expect(markers.contains(NSRange(location: 2, length: 3)))
    #expect(markers.contains(NSRange(location: 10, length: 5)))
}

@Test func crlfFenceMarkerExcludesCarriageReturn() {
    let md = "```\r\ncode\r\n```"
    #expect(ranges(of: .syntaxMarker, in: md).contains(NSRange(location: 0, length: 3)))
}

// MARK: - Live Preview が隠す Syntax Marker

private func concealable(in markdown: String) -> [NSRange] {
    MarkdownParser().highlightPlan(for: markdown).concealableMarkers.sorted { $0.location < $1.location }
}

@Test func concealableMarkersAreASubsetOfSyntaxMarkerSpans() {
    let md = "# T\n\n> **b** *i* ~~s~~ `c` [l](u) ![a](p)\n\n```\nx\n```\n\n- [ ] t\n\n| a |\n|---|\n| b |\n"
    let markers = Set(ranges(of: .syntaxMarker, in: md))
    for range in concealable(in: md) {
        #expect(markers.contains(range), "\(range)")
    }
}

@Test func concealsHeadingEmphasisCodeAndStrikethroughMarkers() {
    #expect(concealable(in: "## Title") == [NSRange(location: 0, length: 3)])
    #expect(concealable(in: "a **b** c") == [NSRange(location: 2, length: 2), NSRange(location: 5, length: 2)])
    #expect(concealable(in: "a *b* c") == [NSRange(location: 2, length: 1), NSRange(location: 4, length: 1)])
    #expect(concealable(in: "a `b` c") == [NSRange(location: 2, length: 1), NSRange(location: 4, length: 1)])
    #expect(concealable(in: "a ~~b~~ c") == [NSRange(location: 2, length: 2), NSRange(location: 5, length: 2)])
}

@Test func concealsLinkBracketsAndDestinationButKeepsText() {
    let md = "see [here](https://example.com) now"
    // "[" と "](https://example.com)"。リンクテキスト "here" は残る。
    #expect(concealable(in: md) == [NSRange(location: 4, length: 1), NSRange(location: 9, length: 22)])
    #expect(ranges(of: .syntaxMarker, in: md) == [NSRange(location: 4, length: 1), NSRange(location: 9, length: 22)])
    // 強調を含むリンクテキスト
    #expect(concealable(in: "[**a**](u)") == [
        NSRange(location: 0, length: 1), NSRange(location: 1, length: 2), NSRange(location: 4, length: 2),
        NSRange(location: 6, length: 4),
    ])
}

@Test func concealsReferenceLinkAndAutolinkBracketsOnly() {
    #expect(concealable(in: "[a][r]\n\n[r]: https://x.y") == [NSRange(location: 0, length: 1), NSRange(location: 2, length: 4)])
    #expect(concealable(in: "<https://x.y>") == [NSRange(location: 0, length: 1), NSRange(location: 12, length: 1)])
    // 裸の URL にはマーカーが無い
    #expect(concealable(in: "https://x.y").isEmpty)
}

@Test func concealsImageMarkersButKeepsAltText() {
    #expect(concealable(in: "![alt](p.png)") == [NSRange(location: 0, length: 2), NSRange(location: 5, length: 8)])
}

@Test func concealsBlockquoteMarkerWithItsSpace() {
    let md = "> one\n>two\n> > inner\n>"
    #expect(concealable(in: md) == [
        NSRange(location: 0, length: 2), NSRange(location: 6, length: 1),
        NSRange(location: 11, length: 2), NSRange(location: 13, length: 2), NSRange(location: 21, length: 1),
    ])
}

@Test func doesNotConcealFencesCheckboxesOrTables() {
    #expect(concealable(in: "```swift\nlet x = 1\n```").isEmpty)
    #expect(concealable(in: "- [ ] todo\n- [x] done").isEmpty)
    #expect(concealable(in: "| a | b |\n|---|---|\n| 1 | 2 |").isEmpty)
    // Setext 見出し・インデント型コードブロックにもマーカーは無い
    #expect(concealable(in: "Title\n=====").isEmpty)
    #expect(concealable(in: "para\n\n    code").isEmpty)
}
