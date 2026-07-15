import Foundation
import Testing

@testable import Laperm

@Test func lineNumbersForSimpleText() {
    let index = LineIndex(text: "one\ntwo\nthree")
    #expect(index.lineNumber(at: 0) == 1)  // "o"
    #expect(index.lineNumber(at: 3) == 1)  // "\n" 自体は行 1
    #expect(index.lineNumber(at: 4) == 2)  // "t"
    #expect(index.lineNumber(at: 8) == 3)  // "t"
}

@Test func lineNumbersWithJapanese() {
    let index = LineIndex(text: "あいう\nかきく")
    #expect(index.lineNumber(at: 0) == 1)
    #expect(index.lineNumber(at: 4) == 2)  // "か"(UTF-16 で 4)
}

@Test func emptyTextIsSingleLine() {
    let index = LineIndex(text: "")
    #expect(index.lineNumber(at: 0) == 1)
}
