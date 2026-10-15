import Foundation
import Testing
@testable import LapermCore

/// Embed の挿入記法(Laperm ADR 0045): 空白を含むパスは `<…>` で囲み、パーサーがその destination を読めること。
@Test func plainPathsStayPlainAndPathsWithSpacesAreWrappedInAngleBrackets() {
    #expect(MarkdownLinkSyntax.destination("Attachments/x.png") == "Attachments/x.png")
    #expect(MarkdownLinkSyntax.destination("../Attachments/x.png") == "../Attachments/x.png")
    #expect(MarkdownLinkSyntax.destination("Attachments/Pasted image 20261015123456.png") == "<Attachments/Pasted image 20261015123456.png>")
    #expect(MarkdownLinkSyntax.destination("a(1).png") == "<a(1).png>")
    #expect(MarkdownLinkSyntax.destination("a<b>.png") == "<a\\<b\\>.png>")
    #expect(MarkdownLinkSyntax.destination("日本語.png") == "日本語.png")
    #expect(MarkdownLinkSyntax.destination("") == "<>")
    #expect(MarkdownLinkSyntax.destination("tab\tx.png") == "<tab\tx.png>")
    #expect(MarkdownLinkSyntax.destination("a\\!.png") == "<a\\\\!.png>", "a backslash would escape the next character")
    #expect(MarkdownLinkSyntax.destination("a&copy;.png") == "a&amp;copy;.png", "an entity reference would be decoded")
}

@Test func escapedNamesRoundTripThroughTheParser() {
    for path in ["a\\!.png", "a&copy;.png", "Pasted image 20261015123456.png", "x(1).png", "<y>.png", "a\\&b.png"] {
        let images = MarkdownParser().highlightPlan(for: MarkdownLinkSyntax.image(path: path) + "\n").images
        #expect(images.first?.destination == path, "the parser reads back \(path): \(String(describing: images.first?.destination))")
    }
}

@Test func imageAndLinkSyntaxEscapeTheLabel() {
    #expect(MarkdownLinkSyntax.image(path: "x.png") == "![](x.png)")
    #expect(MarkdownLinkSyntax.image(path: "a b.png", alt: "shot") == "![shot](<a b.png>)")
    #expect(MarkdownLinkSyntax.link(text: "report [draft].pdf", path: "Files/report [draft].pdf") == "[report \\[draft\\].pdf](<Files/report [draft].pdf>)")
    #expect(MarkdownLinkSyntax.link(text: "a\nb", path: "x.pdf") == "[a b](x.pdf)")
    #expect(MarkdownLinkSyntax.link(text: "a&b.pdf", path: "a&b.pdf") == "[a&amp;b.pdf](a&amp;b.pdf)")
    #expect(MarkdownLinkSyntax.imageEmbeds(paths: ["a.png", "b c.png"]) == "![](a.png)\n![](<b c.png>)")
    #expect(MarkdownLinkSyntax.imageEmbeds(paths: []) == "")
}

@Test func theParserReadsAnAngleBracketDestinationWithSpaces() {
    let markdown = "Before\n\n" + MarkdownLinkSyntax.image(path: "../Attachments/Pasted image 20261015123456.png") + "\n"
    let images = MarkdownParser().highlightPlan(for: markdown).images
    #expect(images.count == 1)
    #expect(images.first?.destination == "../Attachments/Pasted image 20261015123456.png")
    #expect(images.first?.altText == "")
    let resolved = ImageURLResolver.resolve(destination: images.first?.destination ?? "", baseURL: URL(filePath: "/Vault/Projects/"))
    #expect(resolved?.standardizedFileURL.path(percentEncoded: false) == "/Vault/Attachments/Pasted image 20261015123456.png")
}
