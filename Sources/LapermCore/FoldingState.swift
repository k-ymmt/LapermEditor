import Foundation

/// セクション折りたたみの状態。UI 非依存の値型で、編集による座標追従を提供する。
/// 折畳のキーは見出し行頭の UTF-16 オフセット(headingLocation)。
public struct FoldingState: Equatable, Sendable {
    /// 折畳 1 件。bodyRange がレイアウトから隠す範囲(見出し行は含まない)。
    public struct Fold: Hashable, Sendable {
        public var headingLocation: Int
        public var bodyRange: NSRange

        public init(headingLocation: Int, bodyRange: NSRange) {
            self.headingLocation = headingLocation
            self.bodyRange = bodyRange
        }
    }

    /// headingLocation 昇順
    public private(set) var folds: [Fold]

    public init(folds: [Fold] = []) {
        self.folds = folds.sorted { $0.headingLocation < $1.headingLocation }
    }

    public var isEmpty: Bool { folds.isEmpty }
    public var hiddenRanges: [NSRange] { folds.map(\.bodyRange) }

    public func isFolded(headingLocation: Int) -> Bool {
        folds.contains { $0.headingLocation == headingLocation }
    }

    /// 同じ headingLocation の既存折畳は置き換える(昇順維持)。
    public mutating func insert(_ fold: Fold) {
        folds.removeAll { $0.headingLocation == fold.headingLocation }
        let index = folds.firstIndex { $0.headingLocation > fold.headingLocation } ?? folds.endIndex
        folds.insert(fold, at: index)
    }

    public mutating func remove(headingLocation: Int) {
        folds.removeAll { $0.headingLocation == headingLocation }
    }

    public mutating func removeAll() {
        folds.removeAll()
    }

    /// offset を隠している(bodyRange に含む)折畳をすべて解除し、解除分を返す。
    /// ネスト時は親子の両方が該当し、まとめて解除される。
    @discardableResult
    public mutating func unfoldAll(containing offset: Int) -> [Fold] {
        let removed = folds.filter { NSLocationInRange(offset, $0.bodyRange) }
        folds.removeAll { NSLocationInRange(offset, $0.bodyRange) }
        return removed
    }

    /// 編集(didProcessEditing 相当)に合わせた座標追従。HighlightPlan.shifted と同じ
    /// 規約(editedRange は編集後レンジ、pre-edit 領域は {location, length - delta})。
    /// - 編集が見出しより完全に前: 全体を delta 平行移動
    /// - 編集がセクション本体より完全に後: 不変
    /// - 見出し行内の編集(行頭以上・本体開始未満): 折畳を維持し本体開始のみ delta 移動
    ///   (見出しタイトルのタイピングで勝手に展開しないため)
    /// - それ以外(本体と交差・見出し行頭を跨ぐ): 破棄 = 自動展開。dropped で返す
    public func shifted(
        byEditAt editedRange: NSRange, changeInLength delta: Int
    ) -> (state: FoldingState, dropped: [Fold]) {
        let preEdit = NSRange(
            location: editedRange.location,
            length: max(0, editedRange.length - delta))
        var kept: [Fold] = []
        var dropped: [Fold] = []
        for fold in folds {
            if NSMaxRange(preEdit) <= fold.headingLocation {
                var moved = fold
                moved.headingLocation += delta
                moved.bodyRange.location += delta
                kept.append(moved)
            } else if preEdit.location >= NSMaxRange(fold.bodyRange) {
                kept.append(fold)
            } else if preEdit.location >= fold.headingLocation,
                      NSMaxRange(preEdit) <= fold.bodyRange.location {
                var moved = fold
                moved.bodyRange.location += delta
                kept.append(moved)
            } else {
                dropped.append(fold)
            }
        }
        return (FoldingState(folds: kept), dropped)
    }
}
