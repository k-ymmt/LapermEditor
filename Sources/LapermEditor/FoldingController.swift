#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import LapermCore

/// セクション折りたたみの中核。NSTextContentStorageDelegate として折畳中の
/// 本体段落を列挙から除外し(= レイアウト対象から外れて非表示)、アウトラインの
/// 同期と編集追従を管理する。テキストストレージは一切変更しない。
/// レイアウト無効化はここでは行わず、pendingDirtyRanges として溜めて
/// MarkdownEditorEngine(takePendingDirtyRanges)に委ねる。
@MainActor
final class FoldingController: NSObject {
    private(set) var state = FoldingState() {
        didSet {
            // どの見出しが折りたたまれているかが変わったときだけ通知する。sync で bodyRange だけが
            // 追従した場合や、同じ状態への置き換えでは呼ばない。
            let locations = state.folds.map(\.headingLocation)
            if locations != oldValue.folds.map(\.headingLocation) { onFoldingChanged?(locations) }
        }
    }
    private(set) var outline: [OutlineItem] = []
    var isEnabled = true
    /// アウトラインが実際に変化した(Equatable 比較)ときだけ呼ばれる
    var onOutlineChanged: (() -> Void)?
    /// 折りたたまれている見出しの集合が変わったときに、その見出し位置(昇順)で呼ばれる。
    /// 経路(API、ガター、編集による自動展開、見出しの消失)を問わない。
    var onFoldingChanged: (([Int]) -> Void)?

    /// 折りたたまれている見出しの位置(昇順)
    var foldedHeadingLocations: [Int] { state.folds.map(\.headingLocation) }

    /// 折畳状態の変化で無効化が必要になったレンジ(文書座標)。編集が挟まった場合は
    /// noteEdit がシフト・拡張する。
    private var pendingDirtyRanges: [NSRange] = []

    /// 溜まった無効化レンジを取り出してクリアする(呼び出し側がレイアウトを無効化する)
    func takePendingDirtyRanges() -> [NSRange] {
        defer { pendingDirtyRanges = [] }
        return pendingDirtyRanges
    }

    func isFolded(headingLocation: Int) -> Bool {
        state.isFolded(headingLocation: headingLocation)
    }

    /// 折畳を作る。headingLocation がアウトラインに存在し、本体が空でないときだけ効く。
    @discardableResult
    func fold(at headingLocation: Int) -> Bool {
        guard isEnabled,
              !state.isFolded(headingLocation: headingLocation),
              let item = outline.first(where: { $0.headingLocation == headingLocation }),
              item.bodyRange.length > 0
        else { return false }
        state.insert(.init(headingLocation: headingLocation, bodyRange: item.bodyRange))
        pendingDirtyRanges.append(item.bodyRange)
        return true
    }

    @discardableResult
    func unfold(at headingLocation: Int) -> Bool {
        guard let fold = state.folds.first(where: { $0.headingLocation == headingLocation })
        else { return false }
        state.remove(headingLocation: headingLocation)
        pendingDirtyRanges.append(fold.bodyRange)
        return true
    }

    @discardableResult
    func toggleFold(at headingLocation: Int) -> Bool {
        if state.isFolded(headingLocation: headingLocation) {
            return unfold(at: headingLocation)
        }
        return fold(at: headingLocation)
    }

    @discardableResult
    func unfoldAll() -> Bool {
        guard !state.isEmpty else { return false }
        pendingDirtyRanges.append(contentsOf: state.hiddenRanges)
        state.removeAll()
        return true
    }

    /// range(キャレットは length 0)が折畳の隠し領域と交差していたら該当折畳を
    /// すべて解除する。ネストは親子まとめて解除。
    @discardableResult
    func unfoldAll(intersecting range: NSRange) -> Bool {
        let hits = state.folds.filter { fold in
            if range.length == 0 {
                return NSLocationInRange(range.location, fold.bodyRange)
            }
            return NSIntersectionRange(range, fold.bodyRange).length > 0
        }
        guard !hits.isEmpty else { return false }
        for fold in hits {
            state.remove(headingLocation: fold.headingLocation)
            pendingDirtyRanges.append(fold.bodyRange)
        }
        return true
    }

    /// パース確定時の同期。アウトラインを再構築し、見出しが残っている折畳だけ
    /// bodyRange を新値に更新して維持、消えた見出しの折畳は解除する。
    func sync(plan: HighlightPlan, text: String) {
        let newOutline = OutlineBuilder.build(from: plan, text: text)
        let outlineChanged = newOutline != outline
        outline = newOutline
        var kept: [FoldingState.Fold] = []
        for fold in state.folds {
            if let item = newOutline.first(
                where: { $0.headingLocation == fold.headingLocation }),
                item.bodyRange.length > 0 {
                if item.bodyRange != fold.bodyRange {
                    pendingDirtyRanges.append(fold.bodyRange)
                    pendingDirtyRanges.append(item.bodyRange)
                }
                kept.append(.init(
                    headingLocation: fold.headingLocation, bodyRange: item.bodyRange))
            } else {
                pendingDirtyRanges.append(fold.bodyRange)
            }
        }
        state = FoldingState(folds: kept)
        if outlineChanged { onOutlineChanged?() }
    }

    /// didProcessEditing(.editedCharacters)からの座標追従。
    /// 本体と交差する編集は折畳を破棄(自動展開)し、旧本体を無効化対象へ載せる。
    func noteEdit(editedRange: NSRange, changeInLength delta: Int) {
        let preEdit = NSRange(
            location: editedRange.location,
            length: max(0, editedRange.length - delta))
        // 溜まっている無効化レンジも編集分シフトする(Highlighter.noteEdit と同じ規約:
        // 交差したら編集レンジと合併して拡張)
        pendingDirtyRanges = pendingDirtyRanges.map { range in
            if NSMaxRange(range) <= preEdit.location {
                return range
            } else if range.location >= NSMaxRange(preEdit) {
                return NSRange(location: range.location + delta, length: range.length)
            } else {
                let start = min(range.location, editedRange.location)
                let end = max(NSMaxRange(editedRange), NSMaxRange(range) + delta)
                return NSRange(location: start, length: max(0, end - start))
            }
        }
        guard !state.isEmpty else { return }
        let (newState, dropped) = state.shifted(
            byEditAt: editedRange, changeInLength: delta)
        state = newState
        for fold in dropped {
            // 破棄された折畳の本体を編集後座標の近似(編集レンジと合併)で無効化
            let start = min(fold.bodyRange.location, editedRange.location)
            let end = max(NSMaxRange(editedRange), NSMaxRange(fold.bodyRange) + delta)
            pendingDirtyRanges.append(NSRange(location: start, length: max(0, end - start)))
        }
    }
}

extension FoldingController: NSTextContentStorageDelegate {
    /// 段落の先頭オフセットが折畳中の本体レンジ内なら列挙から除外する。
    /// 見出し行の段落先頭は自分の bodyRange に含まれないため常に表示される。
    func textContentManager(
        _ textContentManager: NSTextContentManager,
        shouldEnumerate textElement: NSTextElement,
        options: NSTextContentManager.EnumerationOptions
    ) -> Bool {
        guard isEnabled, !state.isEmpty,
              let location = textElement.elementRange?.location else { return true }
        let offset = textContentManager.offset(
            from: textContentManager.documentRange.location, to: location)
        return !state.hiddenRanges.contains { NSLocationInRange(offset, $0) }
    }
}

