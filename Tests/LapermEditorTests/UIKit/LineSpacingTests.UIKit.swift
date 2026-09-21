#if canImport(UIKit)
import Testing
import UIKit
@testable import LapermEditor

/// `MarkdownTheme.lineSpacing` は UITextView(TextKit 2)でも段落スタイルとして届き、
/// 行送りが広がる。TextKit 2 は行間を「文書の最初の行を除く各行の上」に置く。
@MainActor @Test func lineSpacingWidensTheLinePitchOnUIKit() {
    func lineTops(lineSpacing: CGFloat) -> [CGFloat] {
        let textView = MarkdownTextView()
        textView.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        var theme = textView.theme
        theme.lineSpacing = lineSpacing
        textView.theme = theme
        textView.text = "one\ntwo\nthree"
        textView.highlightAll()
        textView.layoutIfNeeded()
        let layoutManager = textView.textLayoutManager!
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var tops: [CGFloat] = []
        layoutManager.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            tops.append(frame.minY + (fragment.textLineFragments.first?.typographicBounds.minY ?? 0))
            return true
        }
        return tops
    }
    let plain = lineTops(lineSpacing: 0)
    let spaced = lineTops(lineSpacing: 6)
    #expect(plain.count == 3 && spaced.count == 3)
    #expect(abs((spaced[1] - spaced[0]) - (plain[1] - plain[0]) - 6) < 0.5, "\(plain) \(spaced)")
    #expect(abs((spaced[2] - spaced[1]) - (plain[2] - plain[1]) - 6) < 0.5, "\(plain) \(spaced)")
}

@MainActor @Test func codeBlockBoxStartsBelowTheLineSpacingOnUIKit() {
    let textView = MarkdownTextView()
    textView.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    var theme = textView.theme
    theme.lineSpacing = 6
    textView.theme = theme
    textView.text = "x\n\n```\na\n```\n\ny"
    textView.highlightAll()
    textView.layoutIfNeeded()
    let layoutManager = textView.textLayoutManager!
    layoutManager.ensureLayout(for: layoutManager.documentRange)
    var fragments: [CodeBlockFragment] = []
    layoutManager.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
        if let fragment = fragment as? CodeBlockFragment { fragments.append(fragment) }
        return true
    }
    #expect(fragments.count == 3)
    #expect(fragments.first?.backgroundRect.minY == 6)
    #expect(fragments.dropFirst().allSatisfy { $0.backgroundRect.minY == 0 })
}
#endif
