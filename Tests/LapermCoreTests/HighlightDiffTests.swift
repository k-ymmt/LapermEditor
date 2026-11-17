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

/// 再適用するスパンの絞り込み(二分探索)が、全無効化レンジとの総当たりと同じ結果になる。
/// 長さ 0 のレンジ(削除の編集レンジ・空スパン)と隣接レンジを多く含む乱数の計画で比べる。
@Test func spansToApplyMatchBruteForceOverlapCheck() {
    var generator = SystemRandomNumberGenerator()
    func randomSpans(_ count: Int) -> [HighlightSpan] {
        (0..<count).map { _ in
            HighlightSpan(
                range: NSRange(location: Int.random(in: 0..<200, using: &generator), length: Int.random(in: 0..<6, using: &generator)),
                kind: Bool.random(using: &generator) ? .strong : .emphasis)
        }
    }
    for _ in 0..<300 {
        let old = HighlightPlan(spans: randomSpans(Int.random(in: 0..<40, using: &generator)))
        let new = HighlightPlan(spans: randomSpans(Int.random(in: 0..<40, using: &generator)))
        let extra = (0..<Int.random(in: 0..<4, using: &generator)).map { _ in
            NSRange(location: Int.random(in: 0..<200, using: &generator), length: Int.random(in: 0..<3, using: &generator))
        }
        let changes = HighlightDiff.compute(old: old, new: new, alwaysInvalidating: extra)
        let expected = new.spans.filter { span in
            changes.invalidatedRanges.contains { HighlightDiff.overlaps($0, span.range) }
        }
        #expect(changes.spansToApply == expected)
    }
}

/// 構造が大きく変わる編集(数千のスパンが入れ替わる)でも差分の計算が無効化レンジ数 × スパン数にならない。
@Test func diffWithManyDisjointChangesStaysFast() {
    let count = 20_000
    let old = HighlightPlan(spans: (0..<count).map { HighlightSpan(range: NSRange(location: $0 * 10, length: 3), kind: .strong) })
    let new = HighlightPlan(spans: (0..<count).map { HighlightSpan(range: NSRange(location: $0 * 10, length: 3), kind: .emphasis) })
    let clock = ContinuousClock()
    var changes = HighlightChanges()
    let elapsed = clock.measure { changes = HighlightDiff.compute(old: old, new: new) }
    #expect(changes.invalidatedRanges.count == count)
    #expect(changes.spansToApply == new.spans)
    // 総当たり(2 万 × 2 万 = 4 億回の判定)なら数秒かかる。debug ビルドでも 1 秒を大きく下回る
    #expect(elapsed < .seconds(1))
}
