import Foundation
import Testing
@testable import LapermCore

private func parse(_ text: String) -> FrontMatter? { FrontMatterParser.parse(text) }

private func line(_ text: String, _ index: Int) -> NSRange {
    let ns = text as NSString
    var location = 0
    for _ in 0..<index {
        location = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
    }
    var start = 0
    var contentsEnd = 0
    ns.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
    return NSRange(location: start, length: contentsEnd - start)
}

// MARK: - 認識規則

@Test func recognizesObsidianStyleFrontMatter() throws {
    let md = "---\ntitle: Foo\ndescription: Bar\ntags:\n  - Foo\n  - Bar\n  - Hoge\n---\n\nContent\n"
    let fm = try #require(parse(md))
    #expect(fm.range == NSRange(location: 0, length: (md as NSString).range(of: "\n---").location + 4))
    #expect(fm.openingFenceRange == NSRange(location: 0, length: 3))
    #expect(fm.closingFenceRange == line(md, 7))
    #expect(fm.properties.map(\.key) == ["title", "description", "tags"])
    #expect(fm.properties[0].value == .text("Foo"))
    #expect(fm.properties[1].value == .text("Bar"))
    #expect(fm.properties[2].value == .list(["Foo", "Bar", "Hoge"]))
    // リストの Property は末尾の項目行までを覆う
    #expect(fm.properties[2].lineRange == NSRange(location: line(md, 3).location, length: NSMaxRange(line(md, 6)) - line(md, 3).location))
    #expect(fm.endIncludingNewline(in: md as NSString) == NSMaxRange(fm.range) + 1)
}

@Test func requiresFenceOnTheVeryFirstLineAndAClosingFence() {
    #expect(parse("\n---\ntitle: x\n---\n") == nil)          // 先頭の空行は不可
    #expect(parse(" ---\ntitle: x\n---\n") == nil)           // インデントは不可
    #expect(parse("----\ntitle: x\n---\n") == nil)           // ちょうど --- だけ
    #expect(parse("---\ntitle: x\n") == nil)                 // 閉じ無し
    #expect(parse("---\ntitle: x\n...\n") == nil)            // YAML の ... は非対応
    #expect(parse("---\ntitle: x\n--- \n") != nil)           // 末尾の空白は無視
    #expect(parse("---\ntitle: x\n---") != nil)              // 文書末尾で閉じる(改行無し)
    #expect(parse("---") == nil)
    #expect(parse("---\n---") != nil)                        // 空の Front Matter
    #expect(parse("---\n---")?.properties.isEmpty == true)
}

@Test func allowsLeadingBOMAndCRLF() throws {
    let bom = try #require(parse("\u{FEFF}---\ntitle: x\n---\nbody"))
    #expect(bom.range.location == 0)
    #expect(bom.properties.first?.value == .text("x"))
    let crlf = try #require(parse("---\r\ntitle: x\r\ntags:\r\n- a\r\n---\r\nbody"))
    #expect(crlf.properties.map(\.value) == [.text("x"), .list(["a"])])
    #expect((("---\r\ntitle: x\r\ntags:\r\n- a\r\n---" as NSString).length) == NSMaxRange(crlf.range))
}

// MARK: - YAML サブセット

@Test func readsScalarsQuotesCommentsAndFlowLists() throws {
    let md = """
    ---
    # a comment line
    title: "Quoted: value" # trailing
    single: 'it''s'
    plain: hello # comment
    hash: a#b
    empty:
    number: 42
    flow: [a, "b, c", 'd', , e]
    ---
    """
    let fm = try #require(parse(md))
    let values = Dictionary(uniqueKeysWithValues: fm.properties.map { ($0.key!, $0.value) })
    #expect(values["title"] == .text("Quoted: value"))
    #expect(values["single"] == .text("it's"))
    #expect(values["plain"] == .text("hello"))
    #expect(values["hash"] == .text("a#b"))
    #expect(values["empty"] == .text(""))
    #expect(values["number"] == .text("42"))
    #expect(values["flow"] == .list(["a", "b, c", "d", "e"]))
    #expect(fm.properties.count == 7)
}

@Test func keepsUnparseableLinesAsRawRows() throws {
    let md = """
    ---
    nested:
      child: 1
    - orphan item
    no colon here
    block: |
      line one
    key: value
    ---
    """
    let fm = try #require(parse(md))
    #expect(fm.properties.map(\.key) == ["nested", nil, nil, nil, nil, nil, "key"])
    #expect(fm.properties[0].value == .text(""))
    #expect(fm.properties[1].value == .raw("  child: 1"))
    #expect(fm.properties[2].value == .raw("- orphan item"))
    #expect(fm.properties[3].value == .raw("no colon here"))
    #expect(fm.properties[4].value == .raw("block: |"))
    #expect(fm.properties[5].value == .raw("  line one"))
    #expect(fm.properties[6].value == .text("value"))
}

@Test func duplicateKeysStayAsSeparateRows() throws {
    let fm = try #require(parse("---\na: 1\na: 2\n---\n"))
    #expect(fm.properties.map(\.value) == [.text("1"), .text("2")])
}

@Test func listStopsAtNextKeyAndBlankLinesAreIgnoredInsideList() throws {
    let fm = try #require(parse("---\ntags:\n- a\n\n- b\nother: x\n- c\n---\n"))
    #expect(fm.properties.count == 3)
    #expect(fm.properties[0].value == .list(["a", "b"]))
    #expect(fm.properties[1].value == .text("x"))
    #expect(fm.properties[2].value == .raw("- c"))
}

// MARK: - HighlightPlan への統合

private func spans(of kind: SyntaxKind, in markdown: String) -> [NSRange] {
    MarkdownParser().highlightPlan(for: markdown).spans.filter { $0.kind == kind }.map(\.range)
}

@Test func frontMatterIsNotInterpretedAsMarkdown() {
    // 以前は "title: Foo" + "---" が Setext 見出し、リストの項目がリストになっていた
    let md = "---\ntitle: Foo\ntags:\n  - Foo\n---\n\n# Heading\n\nbody **bold**\n"
    let plan = MarkdownParser().highlightPlan(for: md)
    #expect(plan.frontMatter != nil)
    #expect(spans(of: .heading(level: 2), in: md).isEmpty)
    #expect(spans(of: .listMarker, in: md).isEmpty)
    #expect(spans(of: .thematicBreak, in: md).isEmpty)
    #expect(spans(of: .frontMatter, in: md) == [NSRange(location: 0, length: 32)])
    #expect(spans(of: .frontMatterKey, in: md) == [NSRange(location: 4, length: 5), NSRange(location: 15, length: 4)])
    // 両端の --- は Syntax Marker だが、Live Preview で隠す対象ではない
    #expect(spans(of: .syntaxMarker, in: md).contains(NSRange(location: 0, length: 3)))
    #expect(spans(of: .syntaxMarker, in: md).contains(NSRange(location: 29, length: 3)))
    #expect(!plan.concealableMarkers.contains(NSRange(location: 0, length: 3)))
    #expect(!plan.concealableMarkers.contains(NSRange(location: 29, length: 3)))
    // 本文は元の位置でそのまま解釈される
    #expect(spans(of: .heading(level: 1), in: md) == [NSRange(location: 34, length: 9)])
    #expect(spans(of: .strong, in: md) == [NSRange(location: 50, length: 8)])
    #expect(OutlineBuilder.build(from: plan, text: md).map(\.title) == ["Heading"])
}

@Test func withoutFrontMatterDashesStillMakeSetextHeadings() {
    let md = "Title\n---\nbody"
    #expect(spans(of: .heading(level: 2), in: md).count == 1)
    #expect(MarkdownParser().highlightPlan(for: md).frontMatter == nil)
}

@Test func blankingKeepsUTF16LengthAndNewlines() {
    let text = "---\n題: 🎉\n---\nbody"
    let blanked = MarkdownParser.blanking(NSRange(location: 0, length: 13), in: text)
    #expect((blanked as NSString).length == (text as NSString).length)
    #expect(blanked == "   \n     \n   \nbody")
}

@Test func shiftedPlanDropsFrontMatterOnlyWhenTheEditTouchesIt() {
    let md = "---\na: 1\n---\nbody\n"
    let plan = MarkdownParser().highlightPlan(for: md)
    let fm = plan.frontMatter
    #expect(fm?.range == NSRange(location: 0, length: 12))
    // ブロックの後ろ(次の行以降)の編集では残る
    #expect(plan.shifted(byEditAt: NSRange(location: 13, length: 1), changeInLength: 1).frontMatter == fm)
    #expect(plan.shifted(byEditAt: NSRange(location: 17, length: 0), changeInLength: -1).frontMatter == fm)
    // 閉じの --- の直後(行末)への挿入、ブロック内の編集、先頭への挿入では破棄
    #expect(plan.shifted(byEditAt: NSRange(location: 12, length: 1), changeInLength: 1).frontMatter == nil)
    #expect(plan.shifted(byEditAt: NSRange(location: 5, length: 1), changeInLength: 1).frontMatter == nil)
    #expect(plan.shifted(byEditAt: NSRange(location: 0, length: 1), changeInLength: 1).frontMatter == nil)
    // 閉じの --- の改行を消す編集(pre-edit が行末を覆う)でも破棄
    #expect(plan.shifted(byEditAt: NSRange(location: 12, length: 0), changeInLength: -1).frontMatter == nil)
}
