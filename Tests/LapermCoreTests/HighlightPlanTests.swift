import Foundation
import Testing
@testable import LapermCore

@Test func shiftKeepsSpansBeforeEdit() {
    let plan = HighlightPlan(spans: [
        HighlightSpan(range: NSRange(location: 0, length: 5), kind: .strong),
    ])
    // 位置 10 に 3 文字挿入(didProcessEditing 相当: editedRange={10,3}, delta=+3)
    let shifted = plan.shifted(byEditAt: NSRange(location: 10, length: 3), changeInLength: 3)
    #expect(shifted.spans == plan.spans)
}

@Test func shiftMovesSpansAfterEdit() {
    let plan = HighlightPlan(spans: [
        HighlightSpan(range: NSRange(location: 10, length: 4), kind: .emphasis),
    ])
    // 位置 2 に 3 文字挿入
    let shifted = plan.shifted(byEditAt: NSRange(location: 2, length: 3), changeInLength: 3)
    #expect(shifted.spans == [HighlightSpan(range: NSRange(location: 13, length: 4), kind: .emphasis)])
}

@Test func shiftMovesSpansAfterDeletion() {
    let plan = HighlightPlan(spans: [
        HighlightSpan(range: NSRange(location: 10, length: 4), kind: .emphasis),
    ])
    // 位置 2 の 3 文字を削除(editedRange={2,0}, delta=-3)
    let shifted = plan.shifted(byEditAt: NSRange(location: 2, length: 0), changeInLength: -3)
    #expect(shifted.spans == [HighlightSpan(range: NSRange(location: 7, length: 4), kind: .emphasis)])
}

@Test func shiftDropsSpansIntersectingEdit() {
    let plan = HighlightPlan(spans: [
        HighlightSpan(range: NSRange(location: 4, length: 6), kind: .strong),
    ])
    // 位置 5 に 1 文字挿入 → スパンは編集と交差するので破棄(新パースで再生成される)
    let shifted = plan.shifted(byEditAt: NSRange(location: 5, length: 1), changeInLength: 1)
    #expect(shifted.spans.isEmpty)
}

@Test func shiftMovesImageReferenceAfterEdit() {
    let image = ImageReference(
        altText: "a", destination: "a.png",
        range: NSRange(location: 20, length: 12),
        paragraphRange: NSRange(location: 20, length: 13))
    let plan = HighlightPlan(spans: [], images: [image])
    // 位置 0 に 5 文字挿入(editedRange は編集後座標)
    let shifted = plan.shifted(byEditAt: NSRange(location: 0, length: 5), changeInLength: 5)
    #expect(shifted.images.count == 1)
    #expect(shifted.images[0].range == NSRange(location: 25, length: 12))
    #expect(shifted.images[0].paragraphRange == NSRange(location: 25, length: 13))
}

@Test func shiftDropsImageReferenceWhenEditIntersectsRange() {
    let image = ImageReference(
        altText: "a", destination: "a.png",
        range: NSRange(location: 20, length: 12),
        paragraphRange: NSRange(location: 20, length: 13))
    let plan = HighlightPlan(spans: [], images: [image])
    // 記法の内部に 1 文字挿入 → 参照は破棄(次のパースで再生成される)
    let shifted = plan.shifted(byEditAt: NSRange(location: 22, length: 1), changeInLength: 1)
    #expect(shifted.images.isEmpty)
}

@Test func shiftDropsImageReferenceWhenEditIntersectsParagraphRangeOnly() {
    let image = ImageReference(
        altText: "a", destination: "a.png",
        range: NSRange(location: 20, length: 12),
        paragraphRange: NSRange(location: 18, length: 20))
    let plan = HighlightPlan(spans: [], images: [image])
    // 記法の後ろ・同一行内に挿入 → paragraphRange が古くなるので破棄
    let shifted = plan.shifted(byEditAt: NSRange(location: 34, length: 1), changeInLength: 1)
    #expect(shifted.images.isEmpty)
}

@Test func shiftKeepsImageReferenceBeforeEdit() {
    let image = ImageReference(
        altText: "a", destination: "a.png",
        range: NSRange(location: 0, length: 12),
        paragraphRange: NSRange(location: 0, length: 13))
    let plan = HighlightPlan(spans: [], images: [image])
    let shifted = plan.shifted(byEditAt: NSRange(location: 30, length: 5), changeInLength: 5)
    #expect(shifted.images == [image])
}

@Test func shiftMovesLinksAfterEdit() {
    let link = LinkReference(
        text: "a", destination: "https://example.com",
        range: NSRange(location: 10, length: 5))
    let plan = HighlightPlan(links: [link])
    // 位置 0 に 3 文字挿入(editedRange は編集後座標)
    let shifted = plan.shifted(byEditAt: NSRange(location: 0, length: 3), changeInLength: 3)
    #expect(shifted.links == [LinkReference(
        text: "a", destination: "https://example.com",
        range: NSRange(location: 13, length: 5))])
}

@Test func shiftDropsLinksIntersectingEdit() {
    let link = LinkReference(
        text: "a", destination: "https://example.com",
        range: NSRange(location: 10, length: 5))
    let plan = HighlightPlan(links: [link])
    let shifted = plan.shifted(byEditAt: NSRange(location: 12, length: 1), changeInLength: 1)
    #expect(shifted.links.isEmpty)
}
