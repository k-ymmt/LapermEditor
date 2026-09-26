import Foundation
import Testing
@testable import LapermCore

private func codeBlocks(in markdown: String) -> [MarkdownCodeBlock] {
    MarkdownParser().highlightPlan(for: markdown).codeBlocks
}

@Test func fencedCodeBlockCarriesItsLanguageAndContent() throws {
    // "```swift extra\n"(0-14) "let x = 1\n"(15-24) "y\n"(25-26) "```"(27-29)
    let md = "```swift extra\nlet x = 1\ny\n```\n\nafter"
    let block = try #require(codeBlocks(in: md).first)
    #expect(block.range == NSRange(location: 0, length: 30))
    #expect(block.isFenced && block.isClosed)
    #expect(block.language == "swift")
    #expect(block.contentRange == NSRange(location: 15, length: 11))
    #expect(block.contentIndent == 0)
    #expect(block.contentLineRanges(in: md as NSString) == [NSRange(location: 15, length: 9), NSRange(location: 25, length: 1)])
}

@Test func fencedCodeBlockWithoutContentOrWithOneBlankLine() throws {
    let empty = try #require(codeBlocks(in: "```js\n```").first)
    #expect(empty.language == "js")
    #expect(empty.contentRange == nil)
    #expect(empty.contentLineRanges(in: "```js\n```").isEmpty)
    // 空行 1 行の本文: 長さ 0 の本文レンジ(行は 1 つ)
    let blank = try #require(codeBlocks(in: "```\n\n```").first)
    #expect(blank.language == nil)
    #expect(blank.contentRange == NSRange(location: 4, length: 0))
    #expect(blank.contentLineRanges(in: "```\n\n```") == [NSRange(location: 4, length: 0)])
}

@Test func unclosedFenceIsNotClosedAndRunsToTheEnd() throws {
    let md = "```\nunclosed\nline"
    let block = try #require(codeBlocks(in: md).first)
    #expect(block.isFenced && !block.isClosed)
    #expect(block.range == NSRange(location: 0, length: 17))
    #expect(block.contentRange == NSRange(location: 4, length: 13))
    // 終了フェンスに見えるが後ろに文字がある行は閉じない
    let trailing = try #require(codeBlocks(in: "```\nx\n``` y").first)
    #expect(!trailing.isClosed)
    #expect(MarkdownParser().highlightPlan(for: "```\nx\n``` y").spans.filter { $0.kind == .syntaxMarker }.count == 1)
    // 別の文字や短いフェンスでも閉じない、長いフェンスなら閉じる
    #expect(codeBlocks(in: "~~~\nx\n```").first?.isClosed == false)
    #expect(codeBlocks(in: "````\nx\n```").first?.isClosed == false)
    #expect(codeBlocks(in: "```\nx\n`````").first?.isClosed == true)
    #expect(codeBlocks(in: "~~~\nx\n~~~   ").first?.isClosed == true)
}

@Test func indentedFenceKeepsItsIndentWidth() throws {
    // "  ```swift\n"(0-10) "  x\n"(11-14) "  ```"(15-19)
    let md = "  ```swift\n  x\n  ```"
    let block = try #require(codeBlocks(in: md).first)
    #expect(block.range.location == 2)
    #expect(block.contentIndent == 2)
    #expect(block.contentRange == NSRange(location: 11, length: 3))
    let line = try #require(block.contentLineRanges(in: md as NSString).first)
    #expect(block.displayRange(ofContentLine: line, in: md as NSString) == NSRange(location: 13, length: 1))
}

@Test func indentedCodeBlockIsNotFencedAndStripsFourColumns() throws {
    // "para\n\n"(0-5) "    let x = 1\n"(6-19) "    y\n"(20-25) "\nafter"
    let md = "para\n\n    let x = 1\n    y\n\nafter"
    let block = try #require(codeBlocks(in: md).first)
    #expect(!block.isFenced && block.isClosed)
    #expect(block.language == nil)
    #expect(block.contentIndent == 4)
    // cmark のレンジは最後の行の改行を含む(10..<26)が、本文は行末まで
    #expect(block.range == NSRange(location: 10, length: 16))
    #expect(block.contentRange == NSRange(location: 10, length: 15))
    let text = md as NSString
    let lines = block.contentLineRanges(in: text)
    #expect(lines == [NSRange(location: 10, length: 9), NSRange(location: 20, length: 5)])
    #expect(block.displayRange(ofContentLine: lines[1], in: text) == NSRange(location: 24, length: 1))
    // タブ 1 つは 4 桁ぶん
    let tabbed = "\tcode\n\tmore"
    let tabBlock = try #require(codeBlocks(in: tabbed).first)
    let tabLines = tabBlock.contentLineRanges(in: tabbed as NSString)
    #expect(tabLines.count == 2)
    #expect(tabBlock.displayRange(ofContentLine: tabLines[1], in: tabbed as NSString) == NSRange(location: 7, length: 4))
    // インデントより少ない空白しか無い行はある分だけ、インデントの途中で文字が来ればそこから
    #expect(tabBlock.displayRange(ofContentLine: NSRange(location: 0, length: 4), in: "  ab" as NSString) == NSRange(location: 2, length: 2))
}

@Test func codeBlockInsideAListItemIsStillReported() throws {
    // 行頭から始まらない(リスト項目の中)ブロックも構造は出す。折りたたむかは UI 層が決める。
    let block = try #require(codeBlocks(in: "- ```\n  x\n  ```").first)
    #expect(block.range.location == 2)
    #expect(block.contentIndent == 2)
}

@Test func codeBlockHandlesCRLF() throws {
    let md = "```\r\ncode\r\n```"
    let block = try #require(codeBlocks(in: md).first)
    #expect(block.isClosed)
    #expect(block.contentRange == NSRange(location: 5, length: 4))
}

@Test func planShiftsCodeBlocksLikeTables() {
    // "a\n\n"(0-2) "```\nx\n```"(3-11)
    let plan = MarkdownParser().highlightPlan(for: "a\n\n```\nx\n```")
    #expect(plan.codeBlocks.first?.range == NSRange(location: 3, length: 9))
    let after = plan.shifted(byEditAt: NSRange(location: 0, length: 2), changeInLength: 1)
    #expect(after.codeBlocks.first?.range == NSRange(location: 4, length: 9))
    #expect(after.codeBlocks.first?.contentRange == NSRange(location: 8, length: 1))
    let touched = plan.shifted(byEditAt: NSRange(location: 8, length: 1), changeInLength: 1)
    #expect(touched.codeBlocks.isEmpty)
    #expect(plan.codeBlocks.first?.relativeToStart.range == NSRange(location: 0, length: 9))
}
