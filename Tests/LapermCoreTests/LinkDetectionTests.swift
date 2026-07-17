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
