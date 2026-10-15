import Foundation
import Testing
@testable import LapermCore

// Link Preview の候補(Laperm ADR 0046): 中身が裸の http(s) URL 1 つだけの、文書直下の段落。

private func candidates(_ markdown: String) -> [LinkPreviewCandidate] {
    MarkdownParser().highlightPlan(for: markdown).linkPreviews
}

@Test func aParagraphThatIsOnlyABareURLIsACandidate() throws {
    // "# T\n"(0-3) "\n"(4) "https://example.com/post\n"(5-29) "\n"(30) "text"(31-34)
    let plan = MarkdownParser().highlightPlan(for: "# T\n\nhttps://example.com/post\n\ntext")
    let candidate = try #require(plan.linkPreviews.first)
    #expect(plan.linkPreviews.count == 1)
    #expect(candidate.range == NSRange(location: 5, length: 24))
    #expect(candidate.urlRange == NSRange(location: 5, length: 24))
    #expect(candidate.destination == "https://example.com/post")
    // 裸の URL のリンクはそのまま(クリック処理と色)
    #expect(plan.links.map(\.destination) == ["https://example.com/post"])

    // 前後の空白(行頭 3 桁まで、行末)は許す: 行全体が段落、URL は空白を除く
    let padded = try #require(candidates("  http://example.com/a  \n").first)
    #expect(padded.range == NSRange(location: 0, length: 24))
    #expect(padded.urlRange == NSRange(location: 2, length: 20))
    #expect(padded.destination == "http://example.com/a")
    // 末尾の句読点は URL の一部ではなく、空白でもない: 候補にしない
    #expect(candidates("http://example.com/a.").isEmpty)

    // 文書の最後の行(改行なし)、Windows の改行、複数の候補
    #expect(candidates("https://a.example").map(\.destination) == ["https://a.example"])
    #expect(candidates("https://a.example\r\n\r\nhttps://b.example\r\n").map(\.destination) == ["https://a.example", "https://b.example"])
    #expect(candidates("https://a.example\r\n\r\nhttps://b.example\r\n").map(\.range) == [NSRange(location: 0, length: 17), NSRange(location: 21, length: 17)])
}

@Test func paragraphsWithAnythingElseOrInsideContainersAreNotCandidates() {
    // 文中の URL、2 つの URL、強調の中、Wiki Link と並ぶ
    #expect(candidates("see https://example.com").isEmpty)
    #expect(candidates("https://a.example https://b.example").isEmpty)
    #expect(candidates("*https://a.example*").isEmpty)
    #expect(candidates("https://a.example [[Note]]").isEmpty)
    // 明示的なリンクの書き方は逃げ道
    #expect(candidates("[https://a.example](https://a.example)").isEmpty)
    #expect(candidates("<https://a.example>").isEmpty)
    // 2 行の段落(次の行が続く)
    #expect(candidates("https://a.example\ntext").isEmpty)
    #expect(candidates("text\nhttps://a.example").isEmpty)
    // リスト項目、引用、表、見出し、コードブロック、Front Matter の source
    #expect(candidates("- https://a.example").isEmpty)
    #expect(candidates("> https://a.example").isEmpty)
    #expect(candidates("| a |\n|---|\n| https://a.example |").isEmpty)
    #expect(candidates("# https://a.example").isEmpty)
    #expect(candidates("```\nhttps://a.example\n```").isEmpty)
    #expect(candidates("    https://a.example").isEmpty)
    #expect(candidates("---\nsource: https://a.example\n---\n\nbody").isEmpty)
    // スキームだけ、http(s) 以外
    #expect(candidates("https://").isEmpty)
    #expect(candidates("ftp://a.example").isEmpty)
}

@Test func candidatesFollowEditsLikeTables() {
    let plan = MarkdownParser().highlightPlan(for: "intro\n\nhttps://a.example\n\nhttps://b.example\n")
    #expect(plan.linkPreviews.map(\.range.location) == [7, 26])
    // 前の編集: 平行移動
    let shifted = plan.shifted(byEditAt: NSRange(location: 0, length: 3), changeInLength: 2)
    #expect(shifted.linkPreviews.map(\.range.location) == [9, 28])
    #expect(shifted.linkPreviews.map(\.urlRange.location) == [9, 28])
    // 中の編集: その候補だけ捨てる(次のパースで再生成)、後ろは平行移動
    let touched = plan.shifted(byEditAt: NSRange(location: 10, length: 1), changeInLength: 1)
    #expect(touched.linkPreviews.map(\.range.location) == [27])
    // 行末への挿入と直前の改行の削除も触れる、直後の行への挿入は触れない
    #expect(plan.linkPreviews[0].isTouched(byEditBefore: NSRange(location: 24, length: 0)))
    #expect(plan.linkPreviews[0].isTouched(byEditBefore: NSRange(location: 6, length: 1)))
    #expect(!plan.linkPreviews[0].isTouched(byEditBefore: NSRange(location: 25, length: 0)))
}
