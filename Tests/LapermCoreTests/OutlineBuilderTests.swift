import Foundation
import Testing
@testable import LapermCore

private func outline(for text: String) -> [OutlineItem] {
    OutlineBuilder.build(from: MarkdownParser().highlightPlan(for: text), text: text)
}

@Test func buildsFlatOutlineWithLevelsAndTitles() {
    let items = outline(for: "# One\ntext\n## Two\n### Three\n")
    #expect(items.map(\.level) == [1, 2, 3])
    #expect(items.map(\.title) == ["One", "Two", "Three"])
}

@Test func sectionRangeExtendsToNextSameOrHigherLevelHeading() {
    // "# A\n" (0-3) "body\n" (4-8) "## B\n" (9-13) "b2\n" (14-16) "# C\n" (17-20) "tail" (21-24)
    let text = "# A\nbody\n## B\nb2\n# C\ntail"
    let items = outline(for: text)
    #expect(items.count == 3)
    // A のセクションは C の行頭(17)の直前まで(## B を包含)
    #expect(items[0].sectionRange == NSRange(location: 0, length: 17))
    // B のセクションは同位以上の次見出し C の行頭まで
    #expect(items[1].sectionRange == NSRange(location: 9, length: 8))
    // 末尾セクションは文書末尾まで
    #expect(items[2].sectionRange == NSRange(location: 17, length: 8))
}

@Test func bodyRangeExcludesHeadingLine() {
    let text = "# A\nbody\n## B\nb2\n# C\ntail"
    let items = outline(for: text)
    // A の本体は "body\n## B\nb2\n"(4〜16)
    #expect(items[0].bodyRange == NSRange(location: 4, length: 13))
    // C の本体は "tail"(21〜24)
    #expect(items[2].bodyRange == NSRange(location: 21, length: 4))
}

@Test func headingWithoutBodyHasEmptyBodyRange() {
    let items = outline(for: "# A\n# B\nbody")
    #expect(items[0].bodyRange.length == 0)
    #expect(items[1].bodyRange == NSRange(location: 8, length: 4))
}

@Test func setextHeadingBodyStartsAfterUnderline() {
    // "Title\n" (0-5) "=====\n" (6-11) "body" (12-15)
    let items = outline(for: "Title\n=====\nbody")
    #expect(items.count == 1)
    #expect(items[0].level == 1)
    #expect(items[0].title == "Title")
    #expect(items[0].bodyRange == NSRange(location: 12, length: 4))
}

@Test func stripsClosingHashesFromTitle() {
    let items = outline(for: "## Two ##\n")
    #expect(items.first?.title == "Two")
}

@Test func emptyDocumentYieldsEmptyOutline() {
    #expect(outline(for: "").isEmpty)
    #expect(outline(for: "plain text only").isEmpty)
}
