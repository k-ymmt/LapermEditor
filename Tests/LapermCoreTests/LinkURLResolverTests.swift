import Foundation
import Testing
@testable import LapermCore

private let base = URL(filePath: "/docs/", directoryHint: .isDirectory)

@Test(arguments: [
    // (destination, baseURL あり?, 期待される絶対 URL 文字列 or nil)
    ("https://example.com/a", true, "https://example.com/a"),
    ("http://example.com/a", false, "http://example.com/a"),
    ("file:///tmp/a.md", false, "file:///tmp/a.md"),
    ("mailto:foo@example.com", false, "mailto:foo@example.com"),
    ("/tmp/a.md", false, "file:///tmp/a.md"),
    ("notes/a.md", true, "file:///docs/notes/a.md"),
    ("notes/a.md", false, nil),        // 相対パスは baseURL なしでは解決不能
    ("ftp://example.com", true, nil),  // 未対応スキーム
    ("", true, nil),                   // 空文字列
])
func resolvesLinkDestination(destination: String, hasBase: Bool, expected: String?) {
    let url = LinkURLResolver.resolve(destination: destination, baseURL: hasBase ? base : nil)
    #expect(url?.absoluteString == expected)
}

@Test func imageResolverStillRejectsMailto() {
    #expect(ImageURLResolver.resolve(destination: "mailto:a@b.c", baseURL: nil) == nil)
}

/// パスの中の `:` はスキームの区切りではない(Laperm ADR 0056 の `#epubcfi(…/1:0…)` 付きのリンク)。スキームの形をした前置きだけが
/// スキームとして読まれ、許可されていなければ今までどおり nil。
@Test func aColonInsideThePathIsNotAScheme() {
    let relative = LinkURLResolver.resolve(destination: "Books/x.epub#epubcfi(/6/4!/4/2,/1:0,/1:15)", baseURL: base)
    #expect(relative?.isFileURL == true)
    #expect(relative?.path(percentEncoded: false) == "/docs/Books/x.epub#epubcfi(/6/4!/4/2,/1:0,/1:15)")
    let rooted = LinkURLResolver.resolve(destination: "/Books/x.epub#epubcfi(/6/2!/4/2/1:0)", baseURL: base)
    #expect(rooted?.path(percentEncoded: false) == "/Books/x.epub#epubcfi(/6/2!/4/2/1:0)")
    #expect(LinkURLResolver.resolve(destination: "Note 2:3.md", baseURL: base)?.path(percentEncoded: false) == "/docs/Note 2:3.md")
    #expect(LinkURLResolver.resolve(destination: "javascript:alert(1)", baseURL: base) == nil)
    #expect(LinkURLResolver.resolve(destination: "c++:x", baseURL: base) == nil)
    #expect(ImageURLResolver.resolve(destination: "img/a:b.png", baseURL: base)?.isFileURL == true)
}
