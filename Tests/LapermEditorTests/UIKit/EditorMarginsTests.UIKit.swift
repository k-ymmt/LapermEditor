#if canImport(UIKit)
import Testing
import UIKit
@testable import LapermEditor

@MainActor @Test func readableMarginsInsetTheTextContainer() {
    let textView = MarkdownTextView()
    textView.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
    textView.margins = .readable
    // iPhone 幅: 左はガター、右は最小余白。上下の inset は UITextView の既定のまま。
    #expect(textView.textContainerInset == UIEdgeInsets(top: 8, left: 44, bottom: 8, right: 20))
    textView.showsLineNumbers = false
    #expect(textView.textContainerInset == UIEdgeInsets(top: 8, left: 20, bottom: 8, right: 20))
}

@MainActor @Test func readableMarginsCenterTheTextOnAWideView() {
    let textView = MarkdownTextView()
    var theme = textView.theme
    theme.bodyFont = .systemFont(ofSize: 17)
    textView.theme = theme
    textView.margins = .readable
    textView.frame = CGRect(x: 0, y: 0, width: 1024, height: 600)
    textView.layoutIfNeeded()
    // 幅が変わると中央寄せし直す: (1024 − 40 × 17) / 2。ガターは余白に収まるので表示・非表示で本文は動かない。
    #expect(textView.textContainerInset.left == 172)
    #expect(textView.textContainerInset.right == 172)
    textView.showsLineNumbers = false
    #expect(textView.textContainerInset.left == 172)
    #expect(textView.textContainerInset.right == 172)
    // コンテナ幅は inset を引いた 1024 − 172 × 2
    #expect(textView.textContainer.size.width == 680)
}

@MainActor @Test func marginsFollowTheThemeFontSize() {
    let textView = MarkdownTextView()
    textView.margins = .readable
    textView.frame = CGRect(x: 0, y: 0, width: 1024, height: 600)
    textView.layoutIfNeeded()
    var theme = textView.theme
    theme.bodyFont = .systemFont(ofSize: 17)
    textView.theme = theme
    #expect(textView.textContainerInset.left == 172)
    theme.bodyFont = .systemFont(ofSize: 14)
    textView.theme = theme
    #expect(textView.textContainerInset.left == 232)
    #expect(textView.textContainerInset.right == 232)
}

@MainActor @Test func gutterLinesUseTheMarginInset() {
    // ガターの行情報はコンテナ原点(textContainerInset)基準なので、余白を入れても y は上端から始まる。
    let textView = MarkdownTextView()
    textView.margins = .readable
    textView.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
    textView.text = "a\nb"
    textView.highlightAll()
    textView.layoutIfNeeded()
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    #expect(textView.gutterView.lines.map(\.number) == [1, 2])
    #expect(textView.gutterView.lines.first?.yInTextView == textView.textContainerInset.top)
}
#endif
