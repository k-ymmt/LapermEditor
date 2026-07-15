import Foundation

/// 「この UTF-16 レンジにこの SyntaxKind」という 1 スタイル指定。
public struct HighlightSpan: Hashable, Sendable {
    public var range: NSRange
    public var kind: SyntaxKind

    public init(range: NSRange, kind: SyntaxKind) {
        self.range = range
        self.kind = kind
    }
}

/// 文書全体のハイライト計画。spans は適用順(ブロック → インライン → マーカー)。
public struct HighlightPlan: Equatable, Sendable {
    public var spans: [HighlightSpan]

    public init(spans: [HighlightSpan] = []) {
        self.spans = spans
    }

    /// 編集(NSTextStorageDelegate の didProcessEditing 相当の情報)に合わせて
    /// スパン位置を平行移動する。編集レンジと交差するスパンは破棄する
    /// (次のパース結果から再生成されるため)。
    public func shifted(byEditAt editedRange: NSRange, changeInLength delta: Int) -> HighlightPlan {
        // editedRange は編集「後」のレンジ。編集「前」に影響を受けた領域は
        // {editedRange.location, editedRange.length - delta}
        let preEditRange = NSRange(
            location: editedRange.location,
            length: max(0, editedRange.length - delta)
        )
        var result: [HighlightSpan] = []
        result.reserveCapacity(spans.count)
        for span in spans {
            if NSMaxRange(span.range) <= preEditRange.location {
                result.append(span)
            } else if span.range.location >= NSMaxRange(preEditRange) {
                var moved = span
                moved.range.location += delta
                result.append(moved)
            }
            // それ以外(編集と交差)は破棄
        }
        return HighlightPlan(spans: result)
    }
}
