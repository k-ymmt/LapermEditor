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

@MainActor @Test func proxyShowFindIgnoresAMissingTextView() {
    let proxy = MarkdownEditorProxy()
    proxy.showFind(replace: false)
}
#endif
