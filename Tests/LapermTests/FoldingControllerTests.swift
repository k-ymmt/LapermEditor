#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import Laperm
@testable import LapermCore

/// controller に plan/text を同期させるヘルパ
@MainActor
private func makeController(text: String) -> FoldingController {
    let controller = FoldingController()
    controller.sync(plan: MarkdownParser().highlightPlan(for: text), text: text)
    return controller
}

// テキスト: "# A\n"(0-3) "body1\n"(4-9) "body2\n"(10-15) "# B\n"(16-19) "after"(20-24)
private let sample = "# A\nbody1\nbody2\n# B\nafter"

@MainActor @Test func foldRecordsStateAndDirtyRanges() {
    let controller = makeController(text: sample)
    #expect(controller.outline.count == 2)
    #expect(controller.fold(at: 0))
    #expect(controller.isFolded(headingLocation: 0))
    // dirty = 隠した本体レンジ("body1\nbody2\n" = {4,12})
    #expect(controller.takePendingDirtyRanges() == [NSRange(location: 4, length: 12)])
    #expect(controller.takePendingDirtyRanges().isEmpty)  // take でクリアされる
}

@MainActor @Test func foldRejectsUnknownOrEmptyBodyHeading() {
    let controller = makeController(text: "# A\n# B\nbody")
    #expect(!controller.fold(at: 999))       // 存在しない見出し
    #expect(!controller.fold(at: 0))          // 本体なし
    #expect(controller.fold(at: 4))           // "# B" は本体あり
}

@MainActor @Test func toggleAndUnfoldAll() {
    let controller = makeController(text: sample)
    #expect(controller.toggleFold(at: 0))
    #expect(controller.isFolded(headingLocation: 0))
    #expect(controller.toggleFold(at: 0))
    #expect(!controller.isFolded(headingLocation: 0))
    _ = controller.toggleFold(at: 0)
    #expect(controller.unfoldAll())
    #expect(controller.state.isEmpty)
    #expect(!controller.unfoldAll())  // 変化なしなら false
}

@MainActor @Test func shouldEnumerateSkipsFoldedBodyParagraphs() {
    let contentStorage = NSTextContentStorage()
    contentStorage.textStorage?.replaceCharacters(
        in: NSRange(location: 0, length: 0), with: sample)
    let controller = makeController(text: sample)
    contentStorage.delegate = controller
    _ = controller.fold(at: 0)
    var enumerated: [Int] = []
    contentStorage.enumerateTextElements(from: contentStorage.documentRange.location) {
        element in
        if let location = element.elementRange?.location {
            enumerated.append(contentStorage.offset(
                from: contentStorage.documentRange.location, to: location))
        }
        return true
    }
    #expect(enumerated.contains(0))    // 見出し行は残る
    #expect(!enumerated.contains(4))   // body1 は隠れる
    #expect(!enumerated.contains(10))  // body2 は隠れる
    #expect(enumerated.contains(16))   // 次セクションの見出しは残る
}

@MainActor @Test func syncDropsFoldsWhoseHeadingDisappeared() {
    let controller = makeController(text: sample)
    _ = controller.fold(at: 0)
    _ = controller.takePendingDirtyRanges()
    // "# A" が見出しでなくなった新テキストで同期
    let newText = "A\nbody1\nbody2\n# B\nafter"
    controller.sync(plan: MarkdownParser().highlightPlan(for: newText), text: newText)
    #expect(!controller.isFolded(headingLocation: 0))
    #expect(!controller.takePendingDirtyRanges().isEmpty)  // 旧本体が無効化対象に載る
}

@MainActor @Test func syncFiresOutlineChangedOnlyOnChange() {
    let controller = makeController(text: sample)
    var fired = 0
    controller.onOutlineChanged = { fired += 1 }
    controller.sync(plan: MarkdownParser().highlightPlan(for: sample), text: sample)
    #expect(fired == 0)  // 変化なし → 発火しない
    let newText = "# A\nbody1\nbody2\n# B2\nafter"
    controller.sync(plan: MarkdownParser().highlightPlan(for: newText), text: newText)
    #expect(fired == 1)
}

@MainActor @Test func noteEditDropsFoldIntersectingBody() {
    let controller = makeController(text: sample)
    _ = controller.fold(at: 0)
    _ = controller.takePendingDirtyRanges()
    // 本体内(位置 6)へ 1 文字挿入
    controller.noteEdit(editedRange: NSRange(location: 6, length: 1), changeInLength: 1)
    #expect(!controller.isFolded(headingLocation: 0))
    #expect(!controller.takePendingDirtyRanges().isEmpty)
}

@MainActor @Test func unfoldAllIntersectingHandlesCaretAndSelection() {
    let controller = makeController(text: sample)
    _ = controller.fold(at: 0)
    // 見出し行(可視)のキャレットでは解除しない
    #expect(!controller.unfoldAll(intersecting: NSRange(location: 2, length: 0)))
    // 本体内のキャレットで解除する
    #expect(controller.unfoldAll(intersecting: NSRange(location: 6, length: 0)))
    #expect(!controller.isFolded(headingLocation: 0))
}

@MainActor @Test func disabledControllerRejectsFoldAndEnumeratesAll() {
    let contentStorage = NSTextContentStorage()
    contentStorage.textStorage?.replaceCharacters(
        in: NSRange(location: 0, length: 0), with: sample)
    let controller = makeController(text: sample)
    contentStorage.delegate = controller
    // 無効化前に折畳を作っておく(無効化後にちゃんと解除されているかは fold の拒否だけでは
    // 分からないため、実際に列挙してすべてのパラグラフが出てくることまで確認する)
    #expect(controller.fold(at: 0))
    controller.isEnabled = false
    #expect(!controller.fold(at: 0))  // 無効化中は新規折畳を拒否
    var enumerated: [Int] = []
    contentStorage.enumerateTextElements(from: contentStorage.documentRange.location) {
        element in
        if let location = element.elementRange?.location {
            enumerated.append(contentStorage.offset(
                from: contentStorage.documentRange.location, to: location))
        }
        return true
    }
    // 無効化中は既存の折畳があっても隠さず、全パラグラフを列挙する
    #expect(enumerated.contains(4))   // body1
    #expect(enumerated.contains(10))  // body2
}
#endif
