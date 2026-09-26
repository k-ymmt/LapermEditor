import Foundation
import Testing
@testable import LapermCore

private func tables(in markdown: String) -> [MarkdownTable] {
    MarkdownParser().highlightPlan(for: markdown).tables
}

private func cellTexts(_ row: MarkdownTable.Row, in text: String) -> [String] {
    row.cells.map { (text as NSString).substring(with: $0.range) }
}

@Test func parsesHeaderDelimiterAndBodyRowsWithAlignments() throws {
    // "| a | b | c |\n"(0-13) "|:--|:-:|--:|\n"(14-27) "| 1 | 2 | 3 |"(28-40)
    let md = "| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |"
    let table = try #require(tables(in: md).first)
    #expect(table.range == NSRange(location: 0, length: 41))
    #expect(table.alignments == [.left, .center, .right])
    #expect(table.header.lineRange == NSRange(location: 0, length: 13))
    #expect(table.delimiterLineRange == NSRange(location: 14, length: 13))
    #expect(cellTexts(table.header, in: md) == ["a", "b", "c"])
    #expect(table.header.cells.map(\.range) == [NSRange(location: 2, length: 1), NSRange(location: 6, length: 1), NSRange(location: 10, length: 1)])
    #expect(table.rows.count == 1)
    #expect(cellTexts(table.rows[0], in: md) == ["1", "2", "3"])
    #expect(table.rows[0].lineRange == NSRange(location: 28, length: 13))
}

@Test func padsShortRowsAndDropsExtraCellsLikeGFM() throws {
    let md = "a | b\n--|--\n1\n1 | 2 | 3 | 4"
    let table = try #require(tables(in: md).first)
    #expect(table.columnCount == 2)
    #expect(table.alignments == [.none, .none])
    #expect(cellTexts(table.header, in: md) == ["a", "b"])
    #expect(table.rows.count == 2)
    #expect(cellTexts(table.rows[0], in: md) == ["1", ""])
    #expect(table.rows[0].cells[1].range == NSRange(location: NSMaxRange(table.rows[0].lineRange), length: 0), "the missing cell sits at the line end")
    #expect(cellTexts(table.rows[1], in: md) == ["1", "2"])
}

@Test func escapedPipesStayInsideTheCell() throws {
    let md = "| a \\| b | c |\n|---|---|\n| `x\\|y` | z |"
    let table = try #require(tables(in: md).first)
    #expect(cellTexts(table.header, in: md) == ["a \\| b", "c"])
    #expect(cellTexts(table.rows[0], in: md) == ["`x\\|y`", "z"])
}

@Test func headerOnlyTableAndTrailingNewlineAndEmptyCells() throws {
    let md = "| a |  |\n|---|---|\n"
    let table = try #require(tables(in: md).first)
    #expect(table.rows.isEmpty)
    #expect(cellTexts(table.header, in: md) == ["a", ""])
    #expect(table.header.cells[1].range.length == 0)
    #expect(NSMaxRange(table.range) == 18, "the range ends before the trailing newline")
}

@Test func tablesInsideCodeBlocksAreNotTablesAndTwoTablesAreBothReported() {
    #expect(tables(in: "```\n| a |\n|---|\n```").isEmpty)
    let md = "| a |\n|---|\n| 1 |\n\ntext\n\n| b |\n|:-:|\n| 2 |"
    let found = tables(in: md)
    #expect(found.count == 2)
    #expect(found[0].range.location == 0)
    #expect(found[1].range.location == 25)
    #expect(found[1].alignments == [.center])
}

@Test func tableAfterAParagraphWithoutABlankLineStartsAtTheHeaderLine() throws {
    // cmark-gfm は段落の最終行をヘッダーにするが、Table の位置を段落の先頭にする(HighlightMapper がクランプする)
    let md = "intro\n| a | b |\n|---|---|\n| 1 | 2 |"
    let table = try #require(tables(in: md).first)
    #expect(table.range.location == 6)
    #expect(cellTexts(table.header, in: md) == ["a", "b"])
}

@Test func delimiterAlignmentsRejectNonDelimiterLines() {
    func alignments(_ line: String) -> [MarkdownTable.Alignment]? {
        MarkdownTableParser.delimiterAlignments(line: NSRange(location: 0, length: (line as NSString).length), in: line as NSString)
    }
    #expect(alignments("|---|:--:|") == [.none, .center])
    #expect(alignments("  --- | --: ") == [.none, .right])
    #expect(alignments("| a |") == nil)
    #expect(alignments("|") == nil)
    #expect(alignments("|---||---|") == nil, "an empty cell between pipes is not a delimiter row")
    #expect(alignments(":-:") == [.center])
    #expect(alignments("::") == nil)
}

@Test func inlinePositionsAfterAnEscapedPipeInTheSameCellAreCorrected() throws {
    // cmark-gfm はセルの `\|` を 1 文字に縮めてからインラインを解釈するので、同じセルの後続要素が左にずれて報告される
    let md = "| [a \\| b](u) | c |\n|---|---|\n| x \\| `y` | **z** \\| w |\n| \\| *q* | r |"
    let plan = MarkdownParser().highlightPlan(for: md)
    let ns = md as NSString
    func text(_ kind: SyntaxKind) -> [String] { plan.spans.filter { $0.kind == kind }.map { ns.substring(with: $0.range) } }
    #expect(text(.link) == ["[a \\| b](u)"])
    #expect(text(.inlineCode) == ["`y`"])
    #expect(text(.strong) == ["**z**"], "an escape in a later cell does not move earlier cells")
    #expect(text(.emphasis) == ["*q*"])
    #expect(plan.concealableMarkers.map { ns.substring(with: $0) } == ["[", "](u)", "`", "`", "**", "**", "*", "*"])
    #expect(plan.links.first?.range == plan.spans.first { $0.kind == .link }?.range)
}

@Test func tableInsideAListItemAfterAParagraphStartsAtTheContentNotTheLineStart() throws {
    let md = "- intro\n  | a |\n  |---|\n  | x |"
    let plan = MarkdownParser().highlightPlan(for: md)
    let table = try #require(plan.tables.first)
    #expect(table.range.location == 10, "the clamped range skips the indent like cmark's own ranges do")
    #expect(plan.spans.first { $0.kind == .table }?.range.location == 10)
    #expect(cellTexts(table.header, in: md) == ["a"])
    #expect(cellTexts(table.rows[0], in: md) == ["x"])
}

@Test func planShiftsTablesAfterAnEditAndDropsTouchedOnes() throws {
    let md = "x\n\n| a |\n|---|\n| 1 |"
    let plan = MarkdownParser().highlightPlan(for: md)
    let table = try #require(plan.tables.first)
    #expect(table.range.location == 3)
    // 前に 5 文字挿入: すべてのレンジが 5 動く
    let moved = plan.shifted(byEditAt: NSRange(location: 0, length: 5), changeInLength: 5)
    #expect(moved.tables.count == 1)
    #expect(moved.tables[0] == table.shifted(by: 5))
    #expect(moved.tables[0].relativeToStart == table.relativeToStart)
    // テーブルの中を編集: 破棄
    let edited = plan.shifted(byEditAt: NSRange(location: 10, length: 1), changeInLength: 1)
    #expect(edited.tables.isEmpty)
    // 後ろの編集: 不変
    let after = plan.shifted(byEditAt: NSRange(location: 21, length: 1), changeInLength: 1)
    #expect(after.tables == plan.tables)
    // 境界(Live Preview の表と同じ規則): 先頭への挿入、内容の末尾(20)への挿入、直前の改行(2)の削除は破棄。
    // 直後の行頭(21)への挿入は保持(行が増えるかは次のパースが決める)
    #expect(plan.shifted(byEditAt: NSRange(location: 3, length: 1), changeInLength: 1).tables.isEmpty)
    #expect(plan.shifted(byEditAt: NSRange(location: 20, length: 1), changeInLength: 1).tables.isEmpty)
    #expect(plan.shifted(byEditAt: NSRange(location: 2, length: 0), changeInLength: -1).tables.isEmpty)
    #expect(table.isTouched(byEditBefore: NSRange(location: 21, length: 0)) == false)
    #expect(table.isTouched(byEditBefore: NSRange(location: 20, length: 0)))
    #expect(table.isTouched(byEditBefore: NSRange(location: 2, length: 1)))
    #expect(table.isTouched(byEditBefore: NSRange(location: 0, length: 2)) == false)
}
