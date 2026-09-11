#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import Laperm
@testable import LapermCore

// テキスト: "# A\n"(0-3) "body1\n"(4-9) "body2\n"(10-15) "# B\n"(16-19) "after"(20-24)
private let sample = "# A\nbody1\nbody2\n# B\nafter"

@MainActor
private func enumeratedOffsets(_ textView: MarkdownTextView) -> [Int] {
    let contentManager = textView.textLayoutManager!.textContentManager!
    var offsets: [Int] = []
    contentManager.enumerateTextElements(from: contentManager.documentRange.location) { element in
        if let location = element.elementRange?.location {
            offsets.append(contentManager.offset(
                from: contentManager.documentRange.location, to: location))
        }
        return true
    }
    return offsets
}

@MainActor @Test func outlineIsAvailableAfterHighlightAll() {
    let textView = makeLaidOutTextView(sample)
    #expect(textView.outline.map(\.title) == ["A", "B"])
}

@MainActor @Test func foldHidesBodyAndKeepsHeading() {
    let textView = makeLaidOutTextView(sample)
    textView.fold(at: 0)
    #expect(textView.isFolded(at: 0))
    let offsets = enumeratedOffsets(textView)
    #expect(offsets.contains(0))
    #expect(!offsets.contains(4))
    #expect(!offsets.contains(10))
    #expect(offsets.contains(16))
}

@MainActor @Test func caretEnteringHiddenBodyAutoExpands() {
    let textView = makeLaidOutTextView(sample)
    textView.fold(at: 0)
    textView.selectedRange = NSRange(location: 6, length: 0)  // body1 内
    #expect(!textView.isFolded(at: 0))
}

@MainActor @Test func editInHiddenBodyAutoExpands() {
    let textView = makeLaidOutTextView(sample)
    textView.fold(at: 0)
    textView.textContentStorage!.textStorage!
        .replaceCharacters(in: NSRange(location: 6, length: 0), with: "x")
    #expect(!textView.isFolded(at: 0))
}

@MainActor @Test func headingRemovalUnfoldsAfterReparse() {
    let textView = makeLaidOutTextView(sample)
    textView.fold(at: 0)
    textView.textContentStorage!.textStorage!
        .replaceCharacters(in: NSRange(location: 0, length: 2), with: "")
    textView.highlightNow()
    #expect(!textView.isFolded(at: 0))
    #expect(textView.outline.map(\.title) == ["B"])
}

@MainActor @Test func onOutlineChangeFiresOnActualChange() {
    let textView = MarkdownTextView()
    var received: [[String]] = []
    textView.onOutlineChange = { received.append($0.map(\.title)) }
    textView.text = sample
    textView.highlightAll()
    #expect(received == [["A", "B"]])
    textView.highlightAll()
    #expect(received.count == 1)
}

@MainActor @Test func disablingFoldingUnfoldsAllAndBlocksFold() {
    let textView = makeLaidOutTextView(sample)
    textView.fold(at: 0)
    textView.isFoldingEnabled = false
    #expect(!textView.isFolded(at: 0))
    textView.fold(at: 0)
    #expect(!textView.isFolded(at: 0))
    #expect(enumeratedOffsets(textView).contains(4))
}

@MainActor @Test func scrollToHeadingUnfoldsAncestors() {
    let textView = makeLaidOutTextView("# A\n## B\nbody\n")
    textView.fold(at: 0)
    textView.scrollToHeading(at: 4)
    #expect(!textView.isFolded(at: 0))
}

@MainActor @Test func proxyForwardsToTextView() {
    let proxy = MarkdownEditorProxy()
    let textView = makeLaidOutTextView("# A\nbody")
    proxy.textView = textView
    proxy.fold(at: 0)
    #expect(textView.isFolded(at: 0))
    proxy.unfoldAll()
    #expect(!textView.isFolded(at: 0))
}

// MARK: - ガター

@MainActor @Test func gutterHitTestFindsChevronOnMarkerLine() {
    let gutter = LineNumberGutterView(frame: CGRect(x: 0, y: 0, width: 44, height: 300))
    gutter.lines = [
        .init(number: 1, yInTextView: 0, foldMarker: .init(headingLocation: 0, isFolded: false)),
        .init(number: 2, yInTextView: 20, foldMarker: nil),
        .init(number: 3, yInTextView: 40, foldMarker: .init(headingLocation: 16, isFolded: true)),
    ]
    #expect(gutter.foldMarkerHeadingLocation(atPoint: CGPoint(x: 8, y: 4)) == 0)
    #expect(gutter.foldMarkerHeadingLocation(atPoint: CGPoint(x: 8, y: 24)) == nil)
    #expect(gutter.foldMarkerHeadingLocation(atPoint: CGPoint(x: 30, y: 4)) == nil)
    #expect(gutter.foldMarkerHeadingLocation(atPoint: CGPoint(x: 8, y: 44)) == 16)
}

@MainActor @Test func gutterHitTestAccountsForScrollOffset() {
    // 可視領域にピン留めしているため、行 y からスクロール量を引いてヒット判定する
    let gutter = LineNumberGutterView(frame: CGRect(x: 0, y: 0, width: 44, height: 300))
    gutter.lines = [
        .init(number: 5, yInTextView: 100, heightInTextView: 34,
              foldMarker: .init(headingLocation: 0, isFolded: false)),
    ]
    gutter.contentOffsetY = 90
    #expect(gutter.foldMarkerHeadingLocation(atPoint: CGPoint(x: 8, y: 12)) == 0)
    #expect(gutter.foldMarkerHeadingLocation(atPoint: CGPoint(x: 8, y: 28)) == 0)
    #expect(gutter.foldMarkerHeadingLocation(atPoint: CGPoint(x: 8, y: 50)) == nil)
}

@MainActor @Test func viewportPassCollectsLineNumbersAndFoldMarkers() {
    let textView = makeLaidOutTextView(sample)
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    let lines = textView.gutterView.lines
    #expect(lines.map(\.number) == [1, 2, 3, 4, 5])
    let markers = lines.compactMap(\.foldMarker)
    #expect(markers.map(\.headingLocation) == [0, 16])
    #expect(markers.allSatisfy { !$0.isFolded })
    // 行 y はコンテナ上端インセットぶんずれている(ビュー座標)
    #expect(lines.first?.yInTextView == textView.textContainerInset.top)
}

@MainActor @Test func gutterChevronTapTogglesFold() {
    let textView = makeLaidOutTextView(sample)
    let controller = textView.textLayoutManager!.textViewportLayoutController
    controller.layoutViewport()
    let gutter = textView.gutterView
    guard let line = gutter.lines.first(where: { $0.foldMarker?.headingLocation == 0 }) else {
        Issue.record("no fold marker for heading A")
        return
    }
    let point = CGPoint(x: 8, y: line.yInTextView - gutter.contentOffsetY + 4)
    if let headingLocation = gutter.foldMarkerHeadingLocation(atPoint: point) {
        gutter.onToggleFold?(headingLocation)
    }
    #expect(textView.isFolded(at: 0))
    controller.layoutViewport()
    #expect(gutter.lines.first(where: { $0.foldMarker?.headingLocation == 0 })?.foldMarker?.isFolded == true)
    #expect(gutter.lines.map(\.number) == [1, 4, 5])
}

@MainActor @Test func togglingFoldingEnabledRefreshesGutterMarkersWithNoActiveFold() {
    let textView = makeLaidOutTextView(sample)
    let controller = textView.textLayoutManager!.textViewportLayoutController
    controller.layoutViewport()
    let gutter = textView.gutterView
    #expect(!gutter.lines.compactMap(\.foldMarker).isEmpty)
    textView.isFoldingEnabled = false
    controller.layoutViewport()
    #expect(gutter.lines.compactMap(\.foldMarker).isEmpty)
    textView.isFoldingEnabled = true
    controller.layoutViewport()
    #expect(!gutter.lines.compactMap(\.foldMarker).isEmpty)
}
#endif
