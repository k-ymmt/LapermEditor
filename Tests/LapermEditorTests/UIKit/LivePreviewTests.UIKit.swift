#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import LapermEditor

/// range の表示矩形(テキストコンテナ座標、折り返しがあれば合成)。
@MainActor
private func segmentFrame(of range: NSRange, in textView: MarkdownTextView) -> CGRect {
    let layoutManager = textView.textLayoutManager!
    let contentManager = layoutManager.textContentManager!
    layoutManager.ensureLayout(for: layoutManager.documentRange)
    let start = contentManager.location(contentManager.documentRange.location, offsetBy: range.location)!
    let end = contentManager.location(start, offsetBy: range.length)!
    var frame = CGRect.null
    layoutManager.enumerateTextSegments(in: NSTextRange(location: start, end: end)!, type: .standard, options: []) { _, segment, _, _ in
        frame = frame.union(segment)
        return true
    }
    if frame.isNull { Issue.record("no text segment for \(range)") }
    return frame
}

@MainActor @Test func livePreviewHidesMarkersOffTheCaretLineAndKeepsText() {
    let markdown = "# Title\n\nsome **bold** [link](https://x.y)\n"
    let textView = makeLaidOutTextView(markdown)
    textView.isLivePreviewEnabled = true
    textView.selectedRange = NSRange(location: 0, length: 0)

    // キャレットは見出し行: 見出しのマーカーは見え、3 行目のマーカーは隠れる
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: textView).width > 5)
    #expect(segmentFrame(of: NSRange(location: 14, length: 2), in: textView).width < 0.1)
    #expect(segmentFrame(of: NSRange(location: 23, length: 1), in: textView).width < 0.1)   // "["
    #expect(segmentFrame(of: NSRange(location: 28, length: 14), in: textView).width < 0.1)  // "](https://x.y)"
    #expect(segmentFrame(of: NSRange(location: 24, length: 4), in: textView).width > 5)     // "link"

    // キャレットを 3 行目へ(UITextInput 経由と同じ selectedRange の didSet で追従する)
    textView.selectedRange = NSRange(location: 12, length: 0)
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: textView).width < 0.1)
    #expect(segmentFrame(of: NSRange(location: 14, length: 2), in: textView).width > 5)

    // 切ると全部見える。文字列は終始そのまま
    textView.isLivePreviewEnabled = false
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: textView).width > 5)
    #expect(textView.text == markdown)
}

@MainActor @Test func livePreviewFollowsSelectedTextRangeAndLeavesUndoAlone() {
    let textView = makeLaidOutTextView("**a**\n\nplain\n")
    textView.isLivePreviewEnabled = true
    textView.selectedRange = NSRange(location: 8, length: 0)
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: textView).width < 0.1)
    let canUndoBefore = textView.undoManager?.canUndo ?? false

    // UITextInput 経由の選択変更(selectedTextRange の didSet)でも追従する
    let position = textView.position(from: textView.beginningOfDocument, offset: 1)!
    textView.selectedTextRange = textView.textRange(from: position, to: position)
    #expect(textView.selectedRange == NSRange(location: 1, length: 0))
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: textView).width > 5)
    // 段落の再生成は undo 履歴に載らない
    #expect((textView.undoManager?.canUndo ?? false) == canUndoBefore)
    #expect(textView.text == "**a**\n\nplain\n")
}

@MainActor @Test func livePreviewKeepsMarkerOnlyQuoteLineHeight() {
    let textView = makeLaidOutTextView("> a\n>\n> b\n")
    textView.isLivePreviewEnabled = true
    textView.selectedRange = NSRange(location: 10, length: 0)
    let layoutManager = textView.textLayoutManager!
    layoutManager.ensureLayout(for: layoutManager.documentRange)
    var heights: [CGFloat] = []
    layoutManager.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
        heights.append(fragment.layoutFragmentFrame.height)
        return true
    }
    #expect(heights.count >= 3)
    #expect(heights[1] > 10)
    #expect(abs(heights[1] - heights[0]) < 0.5)
    #expect(segmentFrame(of: NSRange(location: 4, length: 1), in: textView).width < 0.1)
}
#endif
