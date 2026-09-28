#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import LapermEditor
@testable import LapermCore

// テキスト: "# A\n"(0-3) "body1\n"(4-9) "body2\n"(10-15) "# B\n"(16-19) "after"(20-24)
private let sample = "# A\nbody1\nbody2\n# B\nafter"

@MainActor
private func makeTextView() -> MarkdownTextView {
    let textView = MarkdownTextView()
    textView.string = sample
    textView.highlightAll()
    return textView
}

@MainActor @Test func selectSetsTheSelectionAndUnfoldsTheSectionAroundIt() {
    let textView = makeTextView()
    textView.fold(at: 0)
    textView.select(NSRange(location: 10, length: 5))  // "body2"、折畳中の本文
    #expect(textView.selectedRange() == NSRange(location: 10, length: 5))
    #expect(!textView.isFolded(at: 0))
}

@MainActor @Test func selectClampsTheRangeToTheText() {
    let textView = makeTextView()
    textView.select(NSRange(location: 20, length: 100))
    #expect(textView.selectedRange() == NSRange(location: 20, length: 5))
    textView.select(NSRange(location: 99, length: 3))
    #expect(textView.selectedRange() == NSRange(location: 25, length: 0))
    #expect(MarkdownTextView.clamp(NSRange(location: -4, length: 6), toLength: 10) == NSRange(location: 0, length: 2))
}

@MainActor @Test func proxySelectForwardsToTheTextViewAndIgnoresAMissingOne() {
    let proxy = MarkdownEditorProxy()
    proxy.select(NSRange(location: 1, length: 1))  // 未接続: 何も起きない
    let textView = makeTextView()
    proxy.textView = textView
    proxy.select(NSRange(location: 4, length: 5))
    #expect(textView.selectedRange() == NSRange(location: 4, length: 5))
}
#endif
