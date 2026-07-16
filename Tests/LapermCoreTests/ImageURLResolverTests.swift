import Foundation
import Testing
@testable import LapermCore

private let base = URL(filePath: "/docs/", directoryHint: .isDirectory)

@Test(arguments: [
    // (destination, baseURL あり?, 期待される絶対 URL 文字列 or nil)
    ("https://example.com/a.png", true, "https://example.com/a.png"),
    ("http://example.com/a.png", false, "http://example.com/a.png"),
    ("file:///tmp/a.png", false, "file:///tmp/a.png"),
    ("/tmp/a.png", false, "file:///tmp/a.png"),
    ("images/a.png", true, "file:///docs/images/a.png"),
    ("images/a.png", false, nil),      // 相対パスは baseURL なしでは解決不能
    ("", true, nil),                   // 空文字列
    ("ftp://example.com/a.png", true, nil),  // 未対応スキーム
])
func resolves(destination: String, hasBase: Bool, expected: String?) {
    let url = ImageURLResolver.resolve(destination: destination, baseURL: hasBase ? base : nil)
    #expect(url?.absoluteString == expected)
}

@Test func resolvesJapaneseRelativePath() {
    let url = ImageURLResolver.resolve(destination: "画像/図.png", baseURL: base)
    #expect(url?.isFileURL == true)
    #expect(url?.lastPathComponent == "図.png")
}
