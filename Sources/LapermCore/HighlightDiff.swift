import Foundation

/// 差分計算の結果。invalidatedRanges を本文スタイルへリセットしてから
/// spansToApply を順に適用する、という契約で UI 層が消費する。
public struct HighlightChanges: Equatable, Sendable {
    public var invalidatedRanges: [NSRange]
    public var spansToApply: [HighlightSpan]

    public init(invalidatedRanges: [NSRange] = [], spansToApply: [HighlightSpan] = []) {
        self.invalidatedRanges = invalidatedRanges
        self.spansToApply = spansToApply
    }
}

public enum HighlightDiff {
    /// old(編集分シフト済み)と new の差分から、リセットすべきレンジと
    /// 再適用すべきスパンを求める。extraRanges は常に無効化する(編集レンジ用)。
    public static func compute(
        old: HighlightPlan,
        new: HighlightPlan,
        alwaysInvalidating extraRanges: [NSRange] = []
    ) -> HighlightChanges {
        let oldSet = Set(old.spans)
        let newSet = Set(new.spans)
        let removed = old.spans.filter { !newSet.contains($0) }
        let added = new.spans.filter { !oldSet.contains($0) }

        let dirty = removed.map(\.range) + added.map(\.range) + extraRanges
        if dirty.isEmpty {
            return HighlightChanges()
        }
        let invalidated = mergeRanges(dirty)
        let toApply = new.spans.filter { span in
            intersectsAny(span.range, sortedDisjoint: invalidated)
        }
        return HighlightChanges(invalidatedRanges: invalidated, spansToApply: toApply)
    }

    /// `range` が `ranges`(`mergeRanges` の結果: 位置順で互いに離れている)のどれかと `overlaps` で交差するか。
    /// 候補を二分探索で絞る(スパン数 × 無効化レンジ数の総当たりにしない: 構造が大きく変わる編集では両方が数千になる)。
    /// 離れたレンジの終端は単調増加なので、終端が `range` の先頭以上の最初のレンジから、先頭が `range` の終端以下の
    /// レンジまでだけが交差しうる。
    static func intersectsAny(_ range: NSRange, sortedDisjoint ranges: [NSRange]) -> Bool {
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(ranges[mid]) < range.location { low = mid + 1 } else { high = mid }
        }
        var index = low
        while index < ranges.count, ranges[index].location <= NSMaxRange(range) {
            if overlaps(ranges[index], range) { return true }
            index += 1
        }
        return false
    }

    /// 交差判定。長さ 0 のレンジ(削除編集)は「相手のレンジ内にあるか」で判定する。
    static func overlaps(_ a: NSRange, _ b: NSRange) -> Bool {
        if a.length == 0 { return NSLocationInRange(a.location, b) }
        if b.length == 0 { return NSLocationInRange(b.location, a) }
        return NSIntersectionRange(a, b).length > 0
    }

    /// ソートし、隣接・重複レンジをマージする。
    public static func mergeRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in sorted {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
