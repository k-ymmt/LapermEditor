#if os(macOS)
import AppKit
import Testing
@testable import LapermEditor
@testable import LapermCore

@MainActor
private func layoutFragments(in textView: MarkdownTextView) -> [NSTextLayoutFragment] {
    let layoutManager = textView.textLayoutManager!
    layoutManager.ensureLayout(for: layoutManager.documentRange)
    var fragments: [NSTextLayoutFragment] = []
    layoutManager.enumerateTextLayoutFragments(
        from: layoutManager.documentRange.location, options: []
    ) { fragment in
        fragments.append(fragment)
        return true
    }
    return fragments
}

@MainActor @Test func codeBlockParagraphGetsCodeBlockFragment() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "plain\n\n```\nlet x = 1\n```"
    textView.highlightAll()
    let fragments = layoutFragments(in: textView)
    #expect(fragments.contains { $0 is CodeBlockFragment })
    // 先頭の "plain" 段落は通常フラグメント
    #expect(!(fragments.first is CodeBlockFragment))
}

@MainActor @Test func blockquoteParagraphGetsBlockquoteFragment() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "> quoted"
    textView.highlightAll()
    #expect(layoutFragments(in: textView).contains { $0 is BlockquoteFragment })
}

@MainActor @Test func thematicBreakGetsThematicBreakFragment() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "a\n\n---\n\nb"
    textView.highlightAll()
    #expect(layoutFragments(in: textView).contains { $0 is ThematicBreakFragment })
}

@MainActor @Test func editingIntoCodeBlockSwapsFragment() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    // 注: 元のブリーフでは末尾に閉じフェンス "```\ntail" を含む文字列だったが、
    // CommonMark ではフェンスコードブロックは段落を中断できるため、開始フェンスを
    // 壊しても閉じフェンス行が単独で新たな(EOF まで続く)コードブロックの開始行として
    // 再解釈されてしまい、「コードブロック消滅」という意図が検証できなかった。
    // 閉じフェンスを持たない(EOF まで続く単一の)コードブロックに変更し、開始フェンスを
    // 壊した際に文書中に "```" が一つも残らないようにして意図通りの検証を行う。
    textView.string = "```\ncode\ntail"
    textView.highlightAll()
    #expect(layoutFragments(in: textView).contains { $0 is CodeBlockFragment })
    // 開始フェンスを壊す → コードブロック消滅
    textView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 1), with: "x")
    textView.highlightNow()
    #expect(!layoutFragments(in: textView).contains { $0 is CodeBlockFragment })
}

@MainActor @Test func tableGetsTableBackgroundFragment() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "| a | b |\n|---|---|\n| c | d |"
    textView.highlightAll()
    #expect(layoutFragments(in: textView).contains { $0 is TableBackgroundFragment })
}

@MainActor @Test func breakingTableRemovesTableFragment() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "| a |\n|---|"
    textView.highlightAll()
    #expect(layoutFragments(in: textView).contains { $0 is TableBackgroundFragment })
    // 区切り行の先頭を壊す → テーブル消滅
    textView.textStorage!.replaceCharacters(in: NSRange(location: 6, length: 1), with: "x")
    textView.highlightNow()
    #expect(!layoutFragments(in: textView).contains { $0 is TableBackgroundFragment })
}
#endif

#if os(macOS)
@MainActor @Test func indentedCodeBlockFirstLineGetsCodeBlockFragment() {
    // インデント型コードブロックの装飾レンジはインデント後から始まる。段落先頭オフセットだけで
    // 判定すると先頭行のフラグメントが装飾されない
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "para\n\n\tcode\n\tmore\n"
    textView.highlightAll()
    let fragments = layoutFragments(in: textView)
    // 段落: "para\n", "\n", "\tcode\n", "\tmore\n", ""
    #expect(fragments.count >= 4)
    #expect(fragments[2] is CodeBlockFragment)
    #expect(fragments[3] is CodeBlockFragment)
    #expect(!(fragments[0] is CodeBlockFragment))
}

@MainActor @Test func editBeforeDecorationsKeepsThemWithoutInvalidatingAll() {
    // 装飾より前の編集で装飾レンジは平行移動するだけなので、update は差分なし扱いになる
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "x\n\n```\ncode\n```\n\n> quote"
    textView.highlightAll()
    let before = layoutFragments(in: textView)
    #expect(before.contains { $0 is CodeBlockFragment })
    #expect(before.contains { $0 is BlockquoteFragment })
    textView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 0), with: "yy")
    textView.highlightNow()
    let after = layoutFragments(in: textView)
    #expect(after.contains { $0 is CodeBlockFragment })
    #expect(after.contains { $0 is BlockquoteFragment })
}
#endif
