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
