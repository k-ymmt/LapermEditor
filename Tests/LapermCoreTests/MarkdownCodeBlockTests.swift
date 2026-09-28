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
    #expect(block.lineStart == 0)
    #expect(block.isFenced && block.isClosed && !block.isNested)
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
    // 本文の最後が空行: 終端に長さ 0 の行がある("x" と "")。空行 2 行、CRLF も
    let trailing = try #require(codeBlocks(in: "~~~\nx\n\n~~~").first)
    #expect(trailing.contentRange == NSRange(location: 4, length: 2))
    #expect(trailing.contentLineRanges(in: "~~~\nx\n\n~~~") == [NSRange(location: 4, length: 1), NSRange(location: 6, length: 0)])
    let blanks = try #require(codeBlocks(in: "~~~\n\n\n~~~").first)
    #expect(blanks.contentLineRanges(in: "~~~\n\n\n~~~") == [NSRange(location: 4, length: 0), NSRange(location: 5, length: 0)])
    let crlf = try #require(codeBlocks(in: "~~~\r\nx\r\n\r\n~~~").first)
    #expect(crlf.contentLineRanges(in: "~~~\r\nx\r\n\r\n~~~") == [NSRange(location: 5, length: 1), NSRange(location: 8, length: 0)])
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
    // cmark のレンジはインデントの後から最後の行の改行まで(10..<26)だが、ブロックは行末まで、本文は行頭から行末まで
    #expect(block.range == NSRange(location: 10, length: 15))
    #expect(block.lineStart == 6)
    #expect(block.contentRange == NSRange(location: 6, length: 19))
    let text = md as NSString
    let lines = block.contentLineRanges(in: text)
    #expect(lines == [NSRange(location: 6, length: 13), NSRange(location: 20, length: 5)])
    #expect(block.displayRange(ofContentLine: lines[0], in: text) == NSRange(location: 10, length: 9))
    #expect(block.displayRange(ofContentLine: lines[1], in: text) == NSRange(location: 24, length: 1))
    // 先頭行のインデントが 8 桁: 4 桁だけ除く(cmark が先頭で除いた 4 桁と二重に除かない)
    let deeper = "        first\n    second"
    let deeperBlock = try #require(codeBlocks(in: deeper).first)
    #expect(deeperBlock.range.location == 4)
    let deeperLines = deeperBlock.contentLineRanges(in: deeper as NSString)
    #expect(deeperLines.map { (deeper as NSString).substring(with: deeperBlock.displayRange(ofContentLine: $0, in: deeper as NSString)) } == ["    first", "second"])
    // 各行を 4 桁インデントした "```" はフェンスではなくリテラルのコード
    let literal = try #require(codeBlocks(in: "    ```\n    x\n    ```").first)
    #expect(!literal.isFenced && literal.isClosed)
    #expect(literal.contentLineRanges(in: "    ```\n    x\n    ```").count == 3)
    #expect(MarkdownParser().highlightPlan(for: "    ```\n    x\n    ```").spans.filter { $0.kind == .syntaxMarker }.isEmpty)
    // タブ 1 つは 4 桁ぶん
    let tabbed = "\tcode\n\tmore"
    let tabBlock = try #require(codeBlocks(in: tabbed).first)
    let tabLines = tabBlock.contentLineRanges(in: tabbed as NSString)
    #expect(tabLines.count == 2)
    #expect(tabBlock.displayRange(ofContentLine: tabLines[0], in: tabbed as NSString) == NSRange(location: 1, length: 4))
    #expect(tabBlock.displayRange(ofContentLine: tabLines[1], in: tabbed as NSString) == NSRange(location: 7, length: 4))
    // インデントより少ない空白しか無い行はある分だけ、インデントの途中で文字が来ればそこから
    #expect(tabBlock.displayRange(ofContentLine: NSRange(location: 0, length: 4), in: "  ab" as NSString) == NSRange(location: 2, length: 2))
}

@Test func codeBlockInsideAListItemIsReportedAsNested() throws {
    // リスト項目の中のブロックも構造は出す(`isNested`)。折りたたむかは UI 層が決める。
    let block = try #require(codeBlocks(in: "- ```\n  x\n  ```").first)
    #expect(block.range.location == 2)
    #expect(block.contentIndent == 2)
    #expect(block.isNested)
    // リスト項目の継続行(空白だけが前にある)も、引用の中も入れ子
    #expect(codeBlocks(in: "- item\n\n  ~~~\n  x\n  ~~~").first?.isNested == true)
    #expect(codeBlocks(in: "- item\n\n      indented").first?.isNested == true)
    #expect(codeBlocks(in: "> ```\n> x\n> ```").first?.isNested == true)
    #expect(codeBlocks(in: "  ```\n  x\n  ```").first?.isNested == false)
}

@Test func editsTouchTheBlockFromItsLineStart() throws {
    // "a\n\n"(0-2) "    x\n"(3-8) "    y"(9-13): ブロックは 7..<14、行頭は 3
    let block = try #require(codeBlocks(in: "a\n\n    x\n    y").first)
    #expect(block.lineStart == 3 && block.range == NSRange(location: 7, length: 7))
    #expect(block.isTouched(byEditBefore: NSRange(location: 3, length: 0)), "insertion at the line start")
    #expect(block.isTouched(byEditBefore: NSRange(location: 4, length: 1)), "deletion inside the indentation")
    #expect(block.isTouched(byEditBefore: NSRange(location: 2, length: 1)), "deletion of the newline before")
    #expect(!block.isTouched(byEditBefore: NSRange(location: 2, length: 0)), "insertion on the line before")
    #expect(block.isTouched(byEditBefore: NSRange(location: 14, length: 0)), "insertion at the content end")
    #expect(block.shifted(by: 2).lineStart == 5)
    #expect(block.relativeToStart.lineStart == -4)
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
    // インデント型: 先頭のインデントの中の編集も破棄(Live Preview の箱と同じ規則)
    let indented = MarkdownParser().highlightPlan(for: "a\n\n    x\n    y")
    #expect(indented.shifted(byEditAt: NSRange(location: 3, length: 0), changeInLength: -1).codeBlocks.isEmpty)
    #expect(indented.shifted(byEditAt: NSRange(location: 1, length: 1), changeInLength: 1).codeBlocks.first?.lineStart == 4)
    #expect(plan.codeBlocks.first?.relativeToStart.range == NSRange(location: 0, length: 9))
}

@Test func unclosedFenceSpanRunsToTheDocumentEndIncludingTrailingBlankLines() throws {
    // 開始フェンスの直後で改行しただけ: cmark のレンジはフェンス行だけだが、ブロックは文書末(改行の後の空行)まで
    // (Laperm issue #4: 改行したカーソル行にも背景が付く)
    func codeBlockSpan(_ md: String) -> NSRange? {
        MarkdownParser().highlightPlan(for: md).spans.first { $0.kind == .codeBlock }?.range
    }
    #expect(codeBlockSpan("```\n") == NSRange(location: 0, length: 4))
    #expect(codeBlockSpan("```\n\n") == NSRange(location: 0, length: 5))
    #expect(codeBlockSpan("```\nabc\n\n\n") == NSRange(location: 0, length: 10))
    #expect(codeBlockSpan("a\n\n```\n\n") == NSRange(location: 3, length: 5))
    // ブロックのレンジは最後の行の行末(空行なら行頭 = 前の行の改行の後)まで、本文は文書末まで
    let block = try #require(codeBlocks(in: "```\n\n").first)
    #expect(!block.isClosed)
    #expect(block.range == NSRange(location: 0, length: 4))
    #expect(block.contentRange == NSRange(location: 4, length: 1))
    #expect(block.contentLineRanges(in: "```\n\n") == [NSRange(location: 4, length: 0), NSRange(location: 5, length: 0)])
    let fenceOnly = try #require(codeBlocks(in: "```\n").first)
    #expect(fenceOnly.range == NSRange(location: 0, length: 3))
    #expect(fenceOnly.contentRange == nil)
    // 閉じたブロックとインデント型は従来どおり(末尾の空行はブロックの外)
    #expect(codeBlockSpan("```\nabc\n```\n\n") == NSRange(location: 0, length: 11))
    #expect(codeBlockSpan("    code\n\n") == NSRange(location: 4, length: 5))
    // リスト項目の中の閉じていないフェンスは容器の終わりまで(cmark のレンジのまま: 最後の行の改行までで、
    // 文書末の空行は含まない)
    #expect(codeBlockSpan("- ```\n  x\n\n") == NSRange(location: 2, length: 8))
    #expect(codeBlocks(in: "- ```\n  x\n\n").first?.isNested == true)
}
