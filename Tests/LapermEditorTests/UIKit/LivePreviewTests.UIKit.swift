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
    let window = hostInWindow(textView)
    defer { withExtendedLifetime(window) {} }
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
    let window = hostInWindow(textView)
    defer { withExtendedLifetime(window) {} }
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

@MainActor @Test func livePreviewHidesEveryLineWhileTheKeyboardIsDismissed() {
    let markdown = "# Title\n\nsome **bold**\n"
    let textView = makeLaidOutTextView(markdown)
    let window = hostInWindow(textView)
    defer { withExtendedLifetime(window) {} }
    #expect(textView.isFirstResponder)
    textView.isLivePreviewEnabled = true
    textView.selectedRange = NSRange(location: 0, length: 0)
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: textView).width > 5)

    // キーボードを閉じる(resignFirstResponder): キャレットの行も隠れて閲覧表示になる
    #expect(textView.resignFirstResponder())
    #expect(!textView.isFirstResponder)
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: textView).width < 0.1)
    #expect(segmentFrame(of: NSRange(location: 14, length: 2), in: textView).width < 0.1)

    // 閉じている間の選択変更では何も見えない。開き直すと新しいキャレットの行だけ見える
    textView.selectedRange = NSRange(location: 14, length: 0)
    #expect(segmentFrame(of: NSRange(location: 14, length: 2), in: textView).width < 0.1)
    #expect(textView.becomeFirstResponder())
    #expect(segmentFrame(of: NSRange(location: 14, length: 2), in: textView).width > 5)
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: textView).width < 0.1)

    // Source ではフォーカスに関わらず全部見える。文字列はそのまま
    #expect(textView.resignFirstResponder())
    textView.isLivePreviewEnabled = false
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: textView).width > 5)
    #expect(textView.text == markdown)

    // ウィンドウに載っていない(first responder でない)ビューで Live Preview を入れると全行隠れる
    let loose = makeLaidOutTextView(markdown)
    loose.isLivePreviewEnabled = true
    loose.selectedRange = NSRange(location: 0, length: 0)
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: loose).width < 0.1)
}

@MainActor @Test func livePreviewFollowsTheViewLeavingAndRejoiningAWindow() {
    let markdown = "# Title\n\nsome **bold**\n"
    let textView = makeLaidOutTextView(markdown)
    let window = hostInWindow(textView)
    defer { withExtendedLifetime(window) {} }
    textView.isLivePreviewEnabled = true
    textView.selectedRange = NSRange(location: 0, length: 0)
    #expect(textView.isFirstResponder)
    #expect(textView.engine.livePreview.isEditorFocused)
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: textView).width > 5)

    // フォーカス中のビューをウィンドウから外す(resign を経ない): first responder でなくなり全行隠れる
    let host = textView.superview!
    textView.removeFromSuperview()
    #expect(textView.window == nil)
    #expect(!textView.isFirstResponder)
    #expect(!textView.engine.livePreview.isEditorFocused)
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: textView).width < 0.1)

    // 戻して first responder にする: キャレットの行だけ見える
    host.addSubview(textView)
    #expect(!textView.engine.livePreview.isEditorFocused, "rejoining a window does not focus by itself")
    #expect(textView.becomeFirstResponder())
    #expect(textView.isFirstResponder)
    #expect(textView.engine.livePreview.isEditorFocused)
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: textView).width > 5)
    #expect(segmentFrame(of: NSRange(location: 14, length: 2), in: textView).width < 0.1)
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
