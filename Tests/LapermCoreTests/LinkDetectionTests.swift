import Foundation
import Testing
@testable import LapermCore

private func links(in markdown: String) -> [LinkReference] {
    MarkdownParser().highlightPlan(for: markdown).links
}

@Test func collectsInlineLinkDestination() {
    let md = "See [site](https://example.com/a)."
    let result = links(in: md)
    #expect(result.count == 1)
    #expect(result[0].destination == "https://example.com/a")
    #expect(result[0].text == "site")
    #expect((md as NSString).substring(with: result[0].range)
        == "[site](https://example.com/a)")
}

@Test func collectsReferenceLinkDestination() {
    let md = "See [site][ref].\n\n[ref]: https://example.com/r"
    let result = links(in: md)
    #expect(result.count == 1)
    #expect(result[0].destination == "https://example.com/r")
    #expect((md as NSString).substring(with: result[0].range) == "[site][ref]")
}

@Test func collectsAngleAutolink() {
    let md = "Go <https://example.com> now."
    let result = links(in: md)
    #expect(result.count == 1)
    #expect(result[0].destination == "https://example.com")
}

@Test func detectsBareURL() {
    let md = "See https://example.com/path now"
    let result = links(in: md)
    #expect(result.count == 1)
    #expect(result[0].destination == "https://example.com/path")
    #expect((md as NSString).substring(with: result[0].range) == "https://example.com/path")
}

@Test func bareURLGetsLinkSpan() {
    let md = "See https://example.com now"
    let plan = MarkdownParser().highlightPlan(for: md)
    let expected = ((md as NSString).range(of: "https://example.com"))
    #expect(plan.spans.contains(HighlightSpan(range: expected, kind: .link)))
}

@Test func trimsTrailingPunctuation() {
    let result = links(in: "Read (https://example.com/a).")
    #expect(result.count == 1)
    #expect(result[0].destination == "https://example.com/a")
}

@Test func keepsBalancedParen() {
    let md = "See https://en.wikipedia.org/wiki/Foo_(bar) now"
    let result = links(in: md)
    #expect(result[0].destination == "https://en.wikipedia.org/wiki/Foo_(bar)")
}

@Test func skipsBareURLInCodeSpan() {
    #expect(links(in: "run `https://example.com` ok").isEmpty)
}

@Test func skipsBareURLInCodeBlock() {
    #expect(links(in: "```\nhttps://example.com\n```").isEmpty)
}

@Test func skipsBareURLInsideLinkText() {
    let result = links(in: "[https://inner.example](https://outer.example)")
    #expect(result.count == 1)
    #expect(result[0].destination == "https://outer.example")
}

@Test func skipsBareURLInsideImageAlt() {
    let result = links(in: "![https://inner.example](img.png)")
    #expect(result.isEmpty)
}

@Test func requiresBoundaryBeforeURL() {
    #expect(links(in: "xhttps://example.com").isEmpty)
}

@Test func schemeOnlyIsNotALink() {
    #expect(links(in: "prefix https:// suffix").isEmpty)
}

@Test func stopsAtNonASCII() {
    let result = links(in: "リンクは https://example.com、です")
    #expect(result.count == 1)
    #expect(result[0].destination == "https://example.com")
}

@Test func httpSchemeAlsoDetected() {
    let result = links(in: "See http://example.com now")
    #expect(result[0].destination == "http://example.com")
}

// MARK: - スキーム判定の境界(割り当てゼロの手書き比較に置き換えた際の仕様固定)

@Test func upperCaseSchemesAreDetected() {
    #expect(links(in: "See HTTPS://EXAMPLE.COM now")[0].destination == "HTTPS://EXAMPLE.COM")
    #expect(links(in: "See Https://example.com now")[0].destination == "Https://example.com")
    #expect(links(in: "See hTtP://example.com now")[0].destination == "hTtP://example.com")
}

@Test func wordsStartingWithHAreNotSchemes() {
    #expect(links(in: "hello http world https hat").isEmpty)
    #expect(links(in: "h").isEmpty)
    #expect(links(in: "https:/example.com").isEmpty)
    #expect(links(in: "http:example.com").isEmpty)
}

@Test func schemeCutOffAtTextNodeEndIsNotDetected() {
    // Text ノードが "http" の途中で終わる(後続が強調)ケースで範囲外を読まない
    #expect(links(in: "htt*p*://example.com").isEmpty)
    #expect(links(in: "text ending in h").isEmpty)
    #expect(links(in: "http*s*://example.com").isEmpty)
}

@Test func nonASCIILookalikesAreNotSchemes() {
    // U+017F LATIN SMALL LETTER LONG S: `lowercased()` では不変だが `.caseInsensitive`
    // 検索は "s" と同一視する。ASCII 折り畳みのみという設計を固定する。
    #expect(links(in: "see httpſ://example.com now").isEmpty)
    // 全角コロン U+FF1A / 全角スラッシュ U+FF0F
    #expect(links(in: "see https：//example.com now").isEmpty)
    #expect(links(in: "see https:／/example.com now").isEmpty)
}

@Test func schemeInsideCJKTextIsDetectedAtCodeUnitBoundary() {
    let md = "日本語https://example.com/路径 end"
    let result = links(in: md)
    #expect(result.count == 1)
    #expect(result[0].destination == "https://example.com/")
    #expect((md as NSString).substring(with: result[0].range) == "https://example.com/")
}
