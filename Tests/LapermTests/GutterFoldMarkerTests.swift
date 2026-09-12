#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import Laperm

@MainActor
private func makeGutterWithLines() -> (LineNumberGutterView, MarkdownTextView) {
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    scrollView.layoutSubtreeIfNeeded()
    let textView = scrollView.documentView as! MarkdownTextView
    let gutter = scrollView.verticalRulerView as! LineNumberGutterView
    gutter.lines = [
        .init(number: 1, yInTextView: 0,
              foldMarker: .init(headingLocation: 0, isFolded: false)),
        .init(number: 2, yInTextView: 20, foldMarker: nil),
        .init(number: 3, yInTextView: 40,
              foldMarker: .init(headingLocation: 16, isFolded: true)),
    ]
    return (gutter, textView)
}

@MainActor @Test func hitTestFindsChevronOnMarkerLine() {
    let (gutter, textView) = makeGutterWithLines()
    let y0 = gutter.convert(NSPoint(x: 0, y: 0), from: textView).y
    let hit = gutter.foldMarkerHeadingLocation(atPoint: NSPoint(x: 8, y: y0 + 4))
    #expect(hit == 0)
}

@MainActor @Test func hitTestMissesLinesWithoutMarkerAndRightSide() {
    let (gutter, textView) = makeGutterWithLines()
    let y1 = gutter.convert(NSPoint(x: 0, y: 20), from: textView).y
    #expect(gutter.foldMarkerHeadingLocation(atPoint: NSPoint(x: 8, y: y1 + 4)) == nil)
    let y0 = gutter.convert(NSPoint(x: 0, y: 0), from: textView).y
    // シェブロン列(左端 16pt)より右は行番号領域なのでヒットしない
    #expect(gutter.foldMarkerHeadingLocation(atPoint: NSPoint(x: 30, y: y0 + 4)) == nil)
}

@MainActor @Test func mouseDownOnChevronInvokesCallback() {
    let (gutter, textView) = makeGutterWithLines()
    var toggled: [Int] = []
    gutter.onToggleFold = { toggled.append($0) }
    let y2 = gutter.convert(NSPoint(x: 0, y: 40), from: textView).y
    // mouseDown 相当の分岐をテストから直接呼ぶ(イベント合成不要の継ぎ目)
    if let headingLocation = gutter.foldMarkerHeadingLocation(
        atPoint: NSPoint(x: 8, y: y2 + 4)) {
        gutter.onToggleFold?(headingLocation)
    }
    #expect(toggled == [16])
}

// H1/H2 のように実フラグメント高がガター数字フォントの固定行高より大きい場合、
// 従来は行下半分がデッドゾーンになりシェブロンをクリックできなかった。
@MainActor @Test func hitTestCoversFullFragmentHeightForTallHeadings() {
    let (gutter, textView) = makeGutterWithLines()
    gutter.lines = [
        .init(number: 1, yInTextView: 0, heightInTextView: 34,
              foldMarker: .init(headingLocation: 0, isFolded: false)),
    ]
    let y0 = gutter.convert(NSPoint(x: 0, y: 0), from: textView).y
    // 従来の固定行高(~17pt)では届かなかった行下部でもヒットする
    #expect(gutter.foldMarkerHeadingLocation(atPoint: NSPoint(x: 8, y: y0 + 28)) == 0)
    // フラグメント高を超えた位置はヒットしない
    #expect(gutter.foldMarkerHeadingLocation(atPoint: NSPoint(x: 8, y: y0 + 40)) == nil)
}

// viewport 収集の統合確認: 見出し行に foldMarker が付く
@MainActor @Test func viewportPassCollectsFoldMarkersForHeadingLines() {
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    scrollView.layoutSubtreeIfNeeded()
    let textView = scrollView.documentView as! MarkdownTextView
    textView.string = "# A\nbody1\nbody2\n# B\nafter"
    textView.highlightAll()
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    let gutter = scrollView.verticalRulerView as! LineNumberGutterView
    let markers = gutter.lines.compactMap(\.foldMarker)
    #expect(markers.map(\.headingLocation) == [0, 16])
    #expect(markers.allSatisfy { !$0.isFolded })
}

// 回帰確認: 折畳が 1 件もない状態で isFoldingEnabled をトグルしても
// (applyFoldingChanges の dirty レンジが空で早期リターンする状況でも)
// ガターの foldMarker 収集(collectedLines)が現在の有効状態に追従すること。
@MainActor @Test func togglingFoldingEnabledRefreshesGutterMarkersWithNoActiveFold() {
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    scrollView.layoutSubtreeIfNeeded()
    let textView = scrollView.documentView as! MarkdownTextView
    textView.string = "# A\nbody1\nbody2\n# B\nafter"
    textView.highlightAll()
    let controller = textView.textLayoutManager!.textViewportLayoutController
    controller.layoutViewport()
    let gutter = scrollView.verticalRulerView as! LineNumberGutterView
    #expect(!gutter.lines.compactMap(\.foldMarker).isEmpty)

    // 折畳を無効化(アクティブな折畳なし → dirty レンジは空のまま)
    textView.isFoldingEnabled = false
    controller.layoutViewport()
    #expect(gutter.lines.compactMap(\.foldMarker).isEmpty)

    // 再度有効化するとシェブロンが戻る
    textView.isFoldingEnabled = true
    controller.layoutViewport()
    #expect(!gutter.lines.compactMap(\.foldMarker).isEmpty)
}

@MainActor @Test func gutterLinesAccountForTextContainerInset() {
    // フラグメント frame はコンテナ座標なので、textContainerInset ぶんずらしてビュー座標にする
    // (UIKit 版と同じ扱い。以前は AppKit 版だけ無視していた)
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    scrollView.layoutSubtreeIfNeeded()
    let textView = scrollView.documentView as! MarkdownTextView
    textView.textContainerInset = NSSize(width: 0, height: 12)
    textView.string = "one\ntwo"
    textView.highlightAll()
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    let gutter = scrollView.verticalRulerView as! LineNumberGutterView
    #expect(gutter.lines.first?.yInTextView == 12)
}
#endif
