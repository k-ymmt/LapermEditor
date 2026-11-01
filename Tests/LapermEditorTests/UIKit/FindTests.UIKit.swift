#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import LapermEditor
@testable import LapermCore

// Find(Laperm ADR 0052): システムの Find ナビゲータ(UIFindInteraction)。
private let sample = "# A\nbody1\nbody2\n# B\nafter"

@MainActor @Test func theEditorEnablesTheFindInteraction() {
    let textView = MarkdownTextView()
    #expect(textView.isFindInteractionEnabled)
    #expect(textView.findInteraction != nil)
}

@MainActor @Test func showFindPresentsTheFindNavigator() {
    let textView = makeLaidOutTextView(sample)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
    window.addSubview(textView)
    window.makeKeyAndVisible()
    #expect(textView.findInteraction?.isFindNavigatorVisible == false)
    textView.showFind(replace: false)
    #expect(textView.findInteraction?.isFindNavigatorVisible == true)
    textView.findInteraction?.dismissFindNavigator()
    _ = window
}

@MainActor @Test func showFindWithoutAWindowDoesNotCrash() {
    let textView = MarkdownTextView()
    textView.text = sample
    textView.showFind(replace: true)
    #expect(textView.findInteraction?.isFindNavigatorVisible != true)
}

/// UIKit の Find は一致へ移るときに `selectedTextRange` を変える: 折畳中の本文の一致はそこで展開される(ADR 0052「移動時に展開」)。
@MainActor @Test func selectingAMatchInsideAFoldedSectionUnfoldsIt() {
    let textView = makeLaidOutTextView(sample)
    textView.fold(at: 0)
    #expect(textView.isFolded(at: 0))
    textView.selectedRange = NSRange(location: 10, length: 5)  // "body2"、折畳中
    #expect(!textView.isFolded(at: 0))
}

/// システムの Find そのものが折畳中の本文の一致を見つけ、Next で選ぶとそこが展開される(codex review of Laperm 27f1fa7)。
@MainActor @Test func findNextFindsAMatchInsideAFoldedSectionAndUnfoldsIt() async throws {
    let textView = makeLaidOutTextView(sample)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
    window.addSubview(textView)
    window.makeKeyAndVisible()
    textView.fold(at: 0)
    #expect(textView.isFolded(at: 0))
    textView.selectedRange = NSRange(location: 0, length: 0)
    textView.showFind(replace: false)
    let interaction = try #require(textView.findInteraction)
    interaction.searchText = "body2"
    interaction.findNext()
    // UIFindInteraction は検索と選択を main queue に積む
    for _ in 0..<20 where textView.selectedRange != NSRange(location: 10, length: 5) {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(textView.selectedRange == NSRange(location: 10, length: 5), "Find found the match in the folded body: \(textView.selectedRange)")
    #expect(!textView.isFolded(at: 0), "moving to it unfolded the section")
    interaction.dismissFindNavigator()
    _ = window
}

@MainActor @Test func proxyShowFindIgnoresAMissingTextView() {
    let proxy = MarkdownEditorProxy()
    proxy.showFind(replace: false)
}
#endif
