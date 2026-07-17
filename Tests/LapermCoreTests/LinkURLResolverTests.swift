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
