import Foundation
import Markdown
import Testing
@testable import LapermCore

private func location(_ line: Int, _ column: Int) -> Markdown.SourceLocation {
    Markdown.SourceLocation(line: line, column: column, source: nil)
}

@Test func convertsASCIIRange() {
    let converter = SourceLocationConverter(text: "# Hello\nworld")
    // 1 行目全体("# Hello" = 7 バイト → col 1..<8)
    let range = converter.nsRange(of: location(1, 1)..<location(1, 8))
    #expect(range == NSRange(location: 0, length: 7))
}

@Test func convertsSecondLine() {
    let converter = SourceLocationConverter(text: "# Hello\nworld")
    let range = converter.nsRange(of: location(2, 1)..<location(2, 6))
    #expect(range == NSRange(location: 8, length: 5))
}

@Test func convertsJapaneseText() {
    // "あ" は UTF-8 で 3 バイト、UTF-16 で 1 ユニット
    let converter = SourceLocationConverter(text: "あいう\nabc")
    // 2 行目の "b"(col 2)から "c" の後(col 4)まで
    let range = converter.nsRange(of: location(2, 2)..<location(2, 4))
    // 1 行目 "あいう\n" = UTF-16 で 4 ユニット → "b" は offset 5
    #expect(range == NSRange(location: 5, length: 2))
}

@Test func convertsEmojiText() {
    // "🎉" は UTF-8 で 4 バイト、UTF-16 で 2 ユニット
    let converter = SourceLocationConverter(text: "🎉x")
    // "x" は UTF-8 col 5、UTF-16 offset 2
    let range = converter.nsRange(of: location(1, 5)..<location(1, 6))
    #expect(range == NSRange(location: 2, length: 1))
}

@Test func rejectsColumnOverflowingIntoNextLine() {
    // "ab\ncd": line 1 is 2 bytes + newline. col 5 は行 1 の終端(オフセット 3)を超えて
    // 行 2 に食い込むため nil を返す
    let converter = SourceLocationConverter(text: "ab\ncd")
    #expect(converter.nsRange(of: location(1, 1)..<location(1, 5)) == nil)
}

@Test func returnsNilForOutOfBounds() {
    let converter = SourceLocationConverter(text: "ab")
    #expect(converter.nsRange(of: location(5, 1)..<location(5, 2)) == nil)
    #expect(converter.nsRange(of: location(1, 1)..<location(1, 99)) == nil)
}
