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
