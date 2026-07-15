import Foundation
import Testing
@testable import LapermCore

@Test func identicalPlansProduceNoChanges() {
    let plan = HighlightPlan(spans: [
        HighlightSpan(range: NSRange(location: 0, length: 7), kind: .heading(level: 1)),
    ])
    let changes = HighlightDiff.compute(old: plan, new: plan)
    #expect(changes.invalidatedRanges.isEmpty)
    #expect(changes.spansToApply.isEmpty)
}

@Test func changedSpanInvalidatesUnionAndReappliesOverlapping() {
    // 見出しスパンは不変、その内側のマーカーが {0,2} → {0,3} に変化
    let heading = HighlightSpan(range: NSRange(location: 0, length: 10), kind: .heading(level: 1))
    let old = HighlightPlan(spans: [heading, HighlightSpan(range: NSRange(location: 0, length: 2), kind: .syntaxMarker)])
    let new = HighlightPlan(spans: [heading, HighlightSpan(range: NSRange(location: 0, length: 3), kind: .syntaxMarker)])
    let changes = HighlightDiff.compute(old: old, new: new)
    #expect(changes.invalidatedRanges == [NSRange(location: 0, length: 3)])
    // 無効化レンジと重なる見出しスパンも再適用対象に含まれる
    #expect(changes.spansToApply == new.spans)
}

@Test func removedSpanInvalidatesItsRange() {
    let old = HighlightPlan(spans: [HighlightSpan(range: NSRange(location: 5, length: 4), kind: .strong)])
    let new = HighlightPlan(spans: [])
    let changes = HighlightDiff.compute(old: old, new: new)
    #expect(changes.invalidatedRanges == [NSRange(location: 5, length: 4)])
    #expect(changes.spansToApply.isEmpty)
}

@Test func extraRangesAreAlwaysInvalidated() {
    let plan = HighlightPlan(spans: [HighlightSpan(range: NSRange(location: 0, length: 10), kind: .codeBlock)])
    // スパンに変化がなくても編集レンジ(長さ 0 の削除でも)は無効化され、
    // 重なるスパンが再適用される
    let changes = HighlightDiff.compute(old: plan, new: plan, alwaysInvalidating: [NSRange(location: 4, length: 0)])
    #expect(changes.invalidatedRanges == [NSRange(location: 4, length: 0)])
    #expect(changes.spansToApply == plan.spans)
}

@Test func adjacentInvalidatedRangesAreMerged() {
    let old = HighlightPlan(spans: [
        HighlightSpan(range: NSRange(location: 0, length: 5), kind: .strong),
        HighlightSpan(range: NSRange(location: 5, length: 5), kind: .emphasis),
    ])
    let new = HighlightPlan(spans: [])
    let changes = HighlightDiff.compute(old: old, new: new)
    #expect(changes.invalidatedRanges == [NSRange(location: 0, length: 10)])
}
