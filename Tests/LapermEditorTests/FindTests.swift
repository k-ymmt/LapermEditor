#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import LapermEditor
@testable import LapermCore

// Find(Laperm ADR 0052): システムの Find バー。テキスト: "# A\n"(0-3) "body1\n"(4-9) "body2\n"(10-15) "# B\n"(16-19) "after"(20-24)
private let sample = "# A\nbody1\nbody2\n# B\nafter"

@MainActor
private func makeEditorInWindow() -> (NSWindow, NSScrollView, MarkdownTextView) {
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    textView.string = sample
    textView.highlightAll()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = scrollView
    window.layoutIfNeeded()
    return (window, scrollView, textView)
}

/// Find バーの見えている入力欄(探す欄 / 置換欄)。バーは両方の欄を持ち、置換欄は Find だけのときは隠れている。
@MainActor
private func visibleTextFields(in view: NSView?) -> [NSTextField] {
    guard let view, !view.isHidden else { return [] }
    return view.subviews.flatMap { subview -> [NSTextField] in
        (subview as? NSTextField).map { $0.isHiddenOrHasHiddenAncestor ? [] : [$0] } ?? visibleTextFields(in: subview)
    }
}

@MainActor @Test func theEditorUsesTheFindBarWithIncrementalSearching() {
    let textView = MarkdownTextView()
    #expect(textView.usesFindBar)
    #expect(textView.isIncrementalSearchingEnabled)
}

@MainActor @Test func showFindShowsTheFindBarAndFocusesTheEditorFirst() {
    let (window, scrollView, textView) = makeEditorInWindow()
    #expect(!scrollView.isFindBarVisible)
    textView.showFind(replace: false)
    #expect(scrollView.isFindBarVisible, "⌘F の相当: Find バーが出る")
    #expect(visibleTextFields(in: scrollView.findBarView).count == 1, "探す欄だけ")
    _ = window
}

@MainActor @Test func showFindWithReplaceShowsTheReplaceFieldToo() {
    let (window, scrollView, textView) = makeEditorInWindow()
    textView.showFind(replace: true)
    #expect(scrollView.isFindBarVisible)
    #expect(visibleTextFields(in: scrollView.findBarView).count == 2, "探す欄と置換欄")
    _ = window
}

@MainActor @Test func showFindWithoutAScrollViewDoesNothing() {
    let textView = MarkdownTextView()
    textView.string = sample
    textView.showFind(replace: false)  // Find バーの置き場が無い: 落ちない
    #expect(textView.enclosingScrollView == nil)
}

/// NSTextFinder は一致へ移るときに `setSelectedRanges` を使う: 折畳中の本文の一致はそこで展開される(ADR 0052「移動時に展開」)。
@MainActor @Test func selectingAMatchInsideAFoldedSectionUnfoldsIt() {
    let (window, _, textView) = makeEditorInWindow()
    textView.fold(at: 0)
    #expect(textView.isFolded(at: 0))
    textView.setSelectedRange(NSRange(location: 10, length: 5))  // "body2"、折畳中
    #expect(!textView.isFolded(at: 0))
    #expect(textView.selectedRange() == NSRange(location: 10, length: 5))
    _ = window
}

/// システムの Find が畳まれた本文の一致を見つけて展開することは、このプロセスでは確かめられない: NSTextFinder はテストの
/// ウィンドウ(キーになれない)では探さない(Find ペーストボード + nextMatch、バーを出してから、欄に入れて action、自前の
/// NSTextFinder は NSTextView が Swift から NSTextFinderClient に見えず不可: 2026-11-02 に 8 通り試した)。Laperm の macOS
/// XCUITest(testFindBarFindsAndReplacesInsideTheOpenNote)が実アプリで畳んだ本文の一致へ移って展開することを見る。

@MainActor @Test func proxyShowFindForwardsToTheTextViewAndIgnoresAMissingOne() {
    let proxy = MarkdownEditorProxy()
    proxy.showFind(replace: false)  // 未接続: 何も起きない
    let (window, scrollView, textView) = makeEditorInWindow()
    proxy.textView = textView
    proxy.showFind(replace: false)
    #expect(scrollView.isFindBarVisible)
    _ = window
}
#endif
