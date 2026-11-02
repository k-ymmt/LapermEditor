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

// パーセント符号化(Laperm ADR 0054): 復号した名前で探し、復号した方が無く書かれたままの綴りのファイルがあればそちら。

@Test func decodesPercentEncodedPaths() {
    #expect(ImageURLResolver.resolve(destination: "images/My%20Image.png", baseURL: base)?.path(percentEncoded: false) == "/docs/images/My Image.png")
    #expect(ImageURLResolver.resolve(destination: "/tmp/a%20b.png", baseURL: nil)?.path(percentEncoded: false) == "/tmp/a b.png")
    #expect(LinkURLResolver.resolve(destination: "docs/%E5%9B%B3.pdf", baseURL: base)?.lastPathComponent == "図.pdf")
    // スキーム付きの URL は復号しない
    #expect(ImageURLResolver.resolve(destination: "https://example.com/a%20b.png", baseURL: base)?.absoluteString == "https://example.com/a%20b.png")
}

@Test func keepsTheWrittenSpellingWhenOnlyThatFileExists() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("laperm-resolver-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data().write(to: dir.appendingPathComponent("a%20b.png"))
    #expect(ImageURLResolver.resolve(destination: "a%20b.png", baseURL: dir)?.lastPathComponent == "a%20b.png")
    // 復号した名前もあれば復号した方
    try Data().write(to: dir.appendingPathComponent("a b.png"))
    #expect(ImageURLResolver.resolve(destination: "a%20b.png", baseURL: dir)?.lastPathComponent == "a b.png")
}
