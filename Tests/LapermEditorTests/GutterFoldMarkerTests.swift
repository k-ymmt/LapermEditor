#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import LapermEditor

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
// MARK: - 背景(Laperm issue #8)

/// ガターをオフスクリーン描画し、ガター座標(pt、flipped でない)の点の色を返す。
@MainActor
private func renderedGutterColor(_ gutter: LineNumberGutterView, at point: CGPoint) throws -> NSColor {
    let rep = try #require(gutter.bitmapImageRepForCachingDisplay(in: gutter.bounds))
    gutter.cacheDisplay(in: gutter.bounds, to: rep)
    let scaleX = CGFloat(rep.pixelsWide) / gutter.bounds.width
    let scaleY = CGFloat(rep.pixelsHigh) / gutter.bounds.height
    // ビットマップの y は上から数える
    let y = gutter.isFlipped ? point.y : gutter.bounds.height - point.y
    let color = try #require(rep.colorAt(x: Int(point.x * scaleX), y: Int(y * scaleY)))
    return try #require(color.usingColorSpace(.sRGB))
}

/// 描画はビットマップの色空間を経由するので成分が数 % ずれる(青で green が 0.05)。検査に使う色は既定のガター
/// (灰色)と大きく違うので、この許容誤差でも取り違えない。
private func isGutterColor(_ color: NSColor, close expected: NSColor) -> Bool {
    guard let expected = expected.usingColorSpace(.sRGB) else { return false }
    return abs(color.redComponent - expected.redComponent) <= 0.08
        && abs(color.greenComponent - expected.greenComponent) <= 0.08
        && abs(color.blueComponent - expected.blueComponent) <= 0.08
}

/// 行番号ガターの背景はエディタ(Theme)の背景と同じ色で、右端に境界線も引かない(Xcode と同じ見た目)。
/// NSRulerView の既定の描画はコントロール背景色 + 境界線なので、ウィンドウ上部のタイトルがガターの所で切れて見えていた。
@MainActor @Test func gutterBackgroundMatchesTheEditorThemeWithoutABorder() throws {
    let (gutter, textView) = makeGutterWithLines()
    var theme = MarkdownTheme.default
    theme.backgroundColor = NSColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1)
    textView.theme = theme
    let midY = gutter.bounds.midY
    // 番号の無い高さ(下の方)の左寄りと、境界線の位置(右端の 1pt)
    let low = min(gutter.bounds.maxY, gutter.bounds.minY + 10)
    for point in [CGPoint(x: 2, y: midY), CGPoint(x: gutter.bounds.width - 0.5, y: midY), CGPoint(x: 2, y: low)] {
        let color = try renderedGutterColor(gutter, at: point)
        #expect(isGutterColor(color, close: theme.backgroundColor), "gutter pixel at \(point) is \(color)")
    }

    // Theme を変えるとガターも追従する
    theme.backgroundColor = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.8, alpha: 1)
    textView.theme = theme
    let after = try renderedGutterColor(gutter, at: CGPoint(x: 2, y: midY))
    #expect(isGutterColor(after, close: theme.backgroundColor), "gutter after a theme change is \(after)")
}

#endif
