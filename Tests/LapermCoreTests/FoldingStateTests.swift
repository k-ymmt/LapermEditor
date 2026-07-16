import Foundation
import Testing
@testable import LapermCore

private func fold(_ headingLocation: Int, body: NSRange) -> FoldingState.Fold {
    FoldingState.Fold(headingLocation: headingLocation, bodyRange: body)
}

@Test func insertKeepsAscendingOrderAndReplacesSameKey() {
    var state = FoldingState()
    state.insert(fold(20, body: NSRange(location: 24, length: 5)))
    state.insert(fold(0, body: NSRange(location: 4, length: 10)))
    state.insert(fold(20, body: NSRange(location: 24, length: 8)))
    #expect(state.folds.map(\.headingLocation) == [0, 20])
    #expect(state.folds[1].bodyRange.length == 8)
}

@Test func hiddenRangesAndIsFolded() {
    var state = FoldingState()
    state.insert(fold(0, body: NSRange(location: 4, length: 10)))
    #expect(state.hiddenRanges == [NSRange(location: 4, length: 10)])
    #expect(state.isFolded(headingLocation: 0))
    #expect(!state.isFolded(headingLocation: 4))
    state.remove(headingLocation: 0)
    #expect(state.folds.isEmpty)
}

@Test func unfoldAllContainingRemovesFoldsHidingOffset() {
    var state = FoldingState()
    state.insert(fold(0, body: NSRange(location: 4, length: 30)))   // 親
    state.insert(fold(10, body: NSRange(location: 15, length: 10))) // 子(親の本体内)
    let removed = state.unfoldAll(containing: 18)  // 両方の本体内
    #expect(removed.map(\.headingLocation).sorted() == [0, 10])
    #expect(state.folds.isEmpty)
}

@Test func unfoldAllContainingIgnoresVisibleOffset() {
    var state = FoldingState()
    state.insert(fold(0, body: NSRange(location: 4, length: 10)))
    #expect(state.unfoldAll(containing: 2).isEmpty)  // 見出し行内は隠れていない
    #expect(state.folds.count == 1)
}

@Test func shiftKeepsFoldWhenEditIsAfterSection() {
    let state = FoldingState(folds: [fold(0, body: NSRange(location: 4, length: 10))])
    let (shifted, dropped) = state.shifted(
        byEditAt: NSRange(location: 20, length: 3), changeInLength: 3)
    #expect(shifted == state)
    #expect(dropped.isEmpty)
}

@Test func shiftMovesFoldWhenEditIsBeforeHeading() {
    let state = FoldingState(folds: [fold(10, body: NSRange(location: 14, length: 6))])
    // 位置 2 に 3 文字挿入
    let (shifted, dropped) = state.shifted(
        byEditAt: NSRange(location: 2, length: 3), changeInLength: 3)
    #expect(shifted.folds == [fold(13, body: NSRange(location: 17, length: 6))])
    #expect(dropped.isEmpty)
}

@Test func shiftKeepsFoldOnHeadingLineEdit() {
    // 見出し行内(headingLocation 以上・bodyRange 開始未満)の編集は折畳を維持し
    // 本体開始だけ delta 移動(見出しタイトルのタイピングで勝手に展開しない)
    let state = FoldingState(folds: [fold(0, body: NSRange(location: 8, length: 6))])
    let (shifted, dropped) = state.shifted(
        byEditAt: NSRange(location: 3, length: 2), changeInLength: 2)
    #expect(shifted.folds == [fold(0, body: NSRange(location: 10, length: 6))])
    #expect(dropped.isEmpty)
}

@Test func shiftDropsFoldWhenEditIntersectsBody() {
    let state = FoldingState(folds: [fold(0, body: NSRange(location: 4, length: 10))])
    // 本体内(位置 6)への 1 文字挿入 → 自動展開(破棄)
    let (shifted, dropped) = state.shifted(
        byEditAt: NSRange(location: 6, length: 1), changeInLength: 1)
    #expect(shifted.folds.isEmpty)
    #expect(dropped == [fold(0, body: NSRange(location: 4, length: 10))])
}

@Test func shiftDropsFoldWhenEditCrossesHeadingStart() {
    let state = FoldingState(folds: [fold(10, body: NSRange(location: 14, length: 6))])
    // 位置 8〜12 の削除(見出し行頭を跨ぐ)→ 破棄
    let (shifted, dropped) = state.shifted(
        byEditAt: NSRange(location: 8, length: 0), changeInLength: -4)
    #expect(shifted.folds.isEmpty)
    #expect(dropped.count == 1)
}
