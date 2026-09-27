import Foundation
import Testing
@testable import LapermCore

private func wikiLinks(in markdown: String) -> [WikiLinkReference] {
    MarkdownParser().highlightPlan(for: markdown).wikiLinks
}

private func markers(in markdown: String) -> [String] {
    let ns = markdown as NSString
    return MarkdownParser().highlightPlan(for: markdown).concealableMarkers
        .sorted { $0.location < $1.location }
        .map { ns.substring(with: $0) }
}

@Test func detectsBasicWikiLink() {
    let md = "See [[Note]] now."
    let result = wikiLinks(in: md)
    #expect(result.count == 1)
    #expect(result[0].target == "Note")
    #expect(result[0].heading == nil)
    #expect(result[0].alias == nil)
    #expect((md as NSString).substring(with: result[0].range) == "[[Note]]")
    #expect(result[0].displayText == "Note")
}

@Test func wikiLinkGetsSpanAndBracketMarkers() {
    let md = "See [[Note]] now."
    let plan = MarkdownParser().highlightPlan(for: md)
    let range = (md as NSString).range(of: "[[Note]]")
    #expect(plan.spans.contains(HighlightSpan(range: range, kind: .wikiLink)))
    #expect(markers(in: md) == ["[[", "]]"])
}

@Test func parsesAliasAndHidesTargetWithPipe() {
    let md = "[[Some Note|shown]]"
    let result = wikiLinks(in: md)
    #expect(result.count == 1)
    #expect(result[0].target == "Some Note")
    #expect(result[0].alias == "shown")
    #expect(result[0].displayText == "shown")
    #expect(markers(in: md) == ["[[", "Some Note|", "]]"])
}

@Test func parsesHeadingAndKeepsItVisible() {
    let md = "[[Note#Section Two]]"
    let result = wikiLinks(in: md)
    #expect(result.count == 1)
    #expect(result[0].target == "Note")
    #expect(result[0].heading == "Section Two")
    #expect(result[0].displayText == "Note#Section Two")
    #expect(markers(in: md) == ["[[", "]]"])
}

@Test func parsesHeadingWithAlias() {
    let result = wikiLinks(in: "[[Note#Sec|label]]")
    #expect(result.count == 1)
    #expect(result[0].target == "Note")
    #expect(result[0].heading == "Sec")
    #expect(result[0].alias == "label")
}

@Test func parsesPathTarget() {
    let result = wikiLinks(in: "[[folder/Sub Note]]")
    #expect(result.count == 1)
    #expect(result[0].target == "folder/Sub Note")
}

@Test func sameNoteHeadingLinkHasEmptyTarget() {
    let result = wikiLinks(in: "[[#Intro]]")
    #expect(result.count == 1)
    #expect(result[0].target == "")
    #expect(result[0].heading == "Intro")
    #expect(result[0].displayText == "#Intro")
}

@Test func trimsWhitespaceAroundParts() {
    let result = wikiLinks(in: "[[ Note # Head | Alias ]]")
    #expect(result.count == 1)
    #expect(result[0].target == "Note")
    #expect(result[0].heading == "Head")
    #expect(result[0].alias == "Alias")
}

@Test func emptyAliasIsTreatedAsNoAlias() {
    let result = wikiLinks(in: "[[Note|]]")
    #expect(result.count == 1)
    #expect(result[0].alias == nil)
    // 区切りの `|` だけ隠して `Note` を見せる
    #expect(markers(in: "[[Note|]]") == ["[[", "|", "]]"])
}

@Test func detectsSeveralWikiLinksInOneLine() {
    let md = "[[A]] and [[B|b]] and [[C#c]]"
    let result = wikiLinks(in: md)
    #expect(result.map(\.target) == ["A", "B", "C"])
}

@Test func ignoresEmbedBlockReferenceAndEmpty() {
    #expect(wikiLinks(in: "![[image.png]]").isEmpty)
    #expect(wikiLinks(in: "[[Note#^abc123]]").isEmpty)
    #expect(wikiLinks(in: "[[]]").isEmpty)
    #expect(wikiLinks(in: "[[ ]]").isEmpty)
    #expect(wikiLinks(in: "[[|alias]]").isEmpty)
}

@Test func embedDoesNotSwallowFollowingWikiLink() {
    let result = wikiLinks(in: "![[img.png]] then [[Note]]")
    #expect(result.map(\.target) == ["Note"])
}

@Test func doesNotSpanLinesOrNestedBrackets() {
    #expect(wikiLinks(in: "[[Note\n]]").isEmpty)
    #expect(wikiLinks(in: "[[No[te]]").isEmpty)
    // `[[A]]]` は最初の `]]` で閉じる
    let result = wikiLinks(in: "[[A]]]")
    #expect(result.count == 1)
    #expect(result[0].target == "A")
}

@Test func ignoresWikiLinkInsideCodeAndFrontMatter() {
    #expect(wikiLinks(in: "`[[Note]]`").isEmpty)
    #expect(wikiLinks(in: "```\n[[Note]]\n```\n").isEmpty)
    #expect(wikiLinks(in: "---\nrelated: [[Note]]\n---\nbody").isEmpty)
    #expect(wikiLinks(in: "---\nrelated: x\n---\n[[Note]]").count == 1)
}

@Test func wikiLinkInsideEmphasisAndListAndTable() {
    #expect(wikiLinks(in: "**[[Bold]]**").map(\.target) == ["Bold"])
    #expect(wikiLinks(in: "- item [[Listed]]").map(\.target) == ["Listed"])
    #expect(wikiLinks(in: "> quoted [[Quoted]]").map(\.target) == ["Quoted"])
    let md = "| a | b |\n|---|---|\n| [[Cell]] | x |\n"
    let result = wikiLinks(in: md)
    #expect(result.map(\.target) == ["Cell"])
    #expect((md as NSString).substring(with: result[0].range) == "[[Cell]]")
}

@Test func wikiLinkWithURLInsideIsNotAlsoABareURL() {
    let md = "[[https://example.com]] and https://example.org"
    let plan = MarkdownParser().highlightPlan(for: md)
    #expect(plan.wikiLinks.map(\.target) == ["https://example.com"])
    #expect(plan.links.map(\.destination) == ["https://example.org"])
}

@Test func wikiLinkRangeIsCorrectAfterCJK() {
    let md = "日本語の文 [[ノート]] 続き"
    let result = wikiLinks(in: md)
    #expect(result.count == 1)
    #expect(result[0].target == "ノート")
    #expect((md as NSString).substring(with: result[0].range) == "[[ノート]]")
}

@Test func wikiLinkOnLazyContinuationLine() {
    let md = "- item\ncontinued [[Note]]"
    let result = wikiLinks(in: md)
    #expect(result.count == 1)
    #expect((md as NSString).substring(with: result[0].range) == "[[Note]]")
}

@Test func shiftMovesWikiLinksAfterEdit() {
    let plan = HighlightPlan(wikiLinks: [WikiLinkReference(target: "N", range: NSRange(location: 10, length: 5))])
    let shifted = plan.shifted(byEditAt: NSRange(location: 2, length: 3), changeInLength: 3)
    #expect(shifted.wikiLinks.map(\.range) == [NSRange(location: 13, length: 5)])
    let dropped = plan.shifted(byEditAt: NSRange(location: 12, length: 1), changeInLength: 1)
    #expect(dropped.wikiLinks.isEmpty)
}

@Test func typingSecondBracketInsideAutoClosedPairYieldsWikiBrackets() {
    // `[` → `[]`(自動閉じ)、その中で `[` → `[[]]`
    let first = EditingAssistant.insertion(text: "", selection: NSRange(location: 0, length: 0), typing: "[")
    #expect(first?.replacementString == "[]")
    let second = EditingAssistant.insertion(text: "[]", selection: NSRange(location: 1, length: 0), typing: "[")
    #expect(second?.replacementString == "[]")
    #expect(second?.selectedRange == NSRange(location: 2, length: 0))
    // `]` はタイプオーバーで閉じ側を進むだけ
    let close = EditingAssistant.insertion(text: "[[Note]]", selection: NSRange(location: 6, length: 0), typing: "]")
    #expect(close?.replacementString == "")
    #expect(close?.selectedRange == NSRange(location: 7, length: 0))
}

// MARK: - codex レビュー後(エスケープ、テーブルの `\|`)

@Test func escapedOpeningBracketIsLiteral() {
    #expect(wikiLinks(in: "\\[[Note]]").isEmpty)
    #expect(wikiLinks(in: "\\\\[[Note]]").map(\.target) == ["Note"])  // `\\` はバックスラッシュのエスケープ
    #expect(wikiLinks(in: "a \\[[x]] and [[y]]").map(\.target) == ["y"])
}

@Test func aliasInsideATableCellUsesTheEscapedPipe() {
    let md = "| h |\n|---|\n| [[Note\\|Alias]] |\n"
    let result = wikiLinks(in: md)
    #expect(result.count == 1)
    #expect(result[0].target == "Note")
    #expect(result[0].alias == "Alias")
    #expect((md as NSString).substring(with: result[0].range) == "[[Note\\|Alias]]")
    let hidden = markers(in: md).filter { $0.contains("Note") || $0 == "[[" || $0 == "]]" }
    #expect(hidden.contains("Note\\|"))
    // セルの外では `\|` は普通の文字(Alias は `Alias`、target は `Note\`)
    let outside = wikiLinks(in: "[[Note\\|Alias]]")
    #expect(outside[0].target == "Note\\")
}
