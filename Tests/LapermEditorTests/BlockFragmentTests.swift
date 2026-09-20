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

// MARK: - コードブロックのブロック背景

#if os(macOS)
@MainActor
private func codeBlockFragments(in textView: MarkdownTextView) -> [CodeBlockFragment] {
    layoutFragments(in: textView).compactMap { $0 as? CodeBlockFragment }
}

@MainActor
private func makeCodeBlockTextView(_ string: String) -> MarkdownTextView {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = string
    textView.highlightAll()
    return textView
}

@MainActor
private func paragraphStyle(of fragment: NSTextLayoutFragment) -> NSParagraphStyle? {
    guard let paragraph = fragment.textElement as? NSTextParagraph,
          paragraph.attributedString.length > 0 else { return nil }
    return paragraph.attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
}

@MainActor @Test func codeBlockFragmentsRoundOnlyTheBlockEnds() {
    let textView = makeCodeBlockTextView("x\n\n```\na\nb\n```\n\ny")
    let fragments = codeBlockFragments(in: textView)
    // 段落: "```\n", "a\n", "b\n", "```\n"
    #expect(fragments.count == 4)
    #expect(fragments.map(\.roundsTop) == [true, false, false, false])
    #expect(fragments.map(\.roundsBottom) == [false, false, false, true])
}

@MainActor @Test func singleParagraphCodeBlockRoundsBothEnds() {
    // インデント型コードブロック 1 行: 装飾レンジはインデント後から始まり改行を含まない
    let textView = makeCodeBlockTextView("x\n\n\tcode\n\ny")
    let fragments = codeBlockFragments(in: textView)
    #expect(fragments.count == 1)
    #expect(fragments.first?.roundsTop == true)
    #expect(fragments.first?.roundsBottom == true)
}

@MainActor @Test func codeBlockBackgroundSpansTheTextContainerWidth() {
    let textView = makeCodeBlockTextView("x\n\n```\nshort\n```\n\ny")
    let container = textView.textContainer!
    for fragment in codeBlockFragments(in: textView) {
        let rect = fragment.backgroundRect
        // フラグメント原点は lineFragmentPadding ぶん右にあるので、コンテナ左端は負の x
        #expect(rect.minX == -fragment.layoutFragmentFrame.minX)
        #expect(rect.minX == -container.lineFragmentPadding)
        #expect(rect.width == container.size.width)
        #expect(rect.height == fragment.layoutFragmentFrame.height)
        // 描画面が背景矩形を含む(UITextView はこの境界でクリップする)
        #expect(fragment.renderingSurfaceBounds.contains(rect))
    }
}

@MainActor @Test func codeBlockEdgeParagraphsGetVerticalPaddingWithoutTouchingStorage() {
    let textView = makeCodeBlockTextView("x\n\n```\na\nb\n```\n\ny")
    let padding = textView.theme.codeBlockVerticalPadding
    let fragments = codeBlockFragments(in: textView)
    #expect(fragments.count == 4)
    let lineHeight = fragments[1].textLinesBottom
    // 先頭段落: 上余白ぶん高く、テキスト行は余白の下から始まる
    #expect(fragments[0].layoutFragmentFrame.height == lineHeight + padding)
    #expect(fragments[0].textLineFragments.first?.typographicBounds.minY == padding)
    #expect(paragraphStyle(of: fragments[0])?.paragraphSpacingBefore == padding)
    // 中間段落: 余白なし
    #expect(fragments[1].layoutFragmentFrame.height == lineHeight)
    #expect(paragraphStyle(of: fragments[1]) == nil)
    // 末尾段落: 下余白ぶん高い
    #expect(fragments[3].layoutFragmentFrame.height == lineHeight + padding)
    #expect(paragraphStyle(of: fragments[3])?.paragraphSpacing == padding)
    // 余白は表示用段落だけに付き、textStorage には段落スタイルが入らない
    //(タイピング属性として次の段落へ余白が引き継がれないように)
    var found = false
    textView.textStorage!.enumerateAttribute(
        .paragraphStyle, in: NSRange(location: 0, length: textView.textStorage!.length)
    ) { value, _, _ in
        if value != nil { found = true }
    }
    #expect(!found)
    // 直後の通常段落には余白が付かない
    let all = layoutFragments(in: textView)
    let after = all.first { ($0.textElement as? NSTextParagraph)?.attributedString.string == "y" }
    #expect(after != nil)
    #expect(after.flatMap(paragraphStyle(of:)) == nil)
}

@MainActor @Test func codeBlockAtDocumentEndReservesBottomPadding() {
    // 文書末尾の段落は trailing paragraphSpacing がフレームに算入されないので予約で補う
    let textView = makeCodeBlockTextView("x\n\n```\ncode")
    let padding = textView.theme.codeBlockVerticalPadding
    let last = codeBlockFragments(in: textView).last!
    #expect(last.roundsBottom)
    #expect(last.reservedBottomHeight == padding)
    #expect(last.layoutFragmentFrame.height == last.textLinesBottom + padding)
}

@MainActor @Test func breakingCodeBlockRemovesPaddingAndBackground() {
    let textView = makeCodeBlockTextView("x\n\n```\ncode\ntail")
    #expect(!codeBlockFragments(in: textView).isEmpty)
    // 開始フェンスを壊す → 段落スタイルも装飾フラグメントも消える
    textView.textStorage!.replaceCharacters(in: NSRange(location: 3, length: 1), with: "x")
    textView.highlightNow()
    let fragments = layoutFragments(in: textView)
    #expect(codeBlockFragments(in: textView).isEmpty)
    #expect(fragments.allSatisfy { paragraphStyle(of: $0) == nil })
}

@MainActor @Test func gutterLineAlignsWithTheFirstTextLineOfPaddedCodeBlock() {
    let textView = makeCodeBlockTextView("x\n\n```\ncode\n```\n\ny")
    let padding = textView.theme.codeBlockVerticalPadding
    let first = codeBlockFragments(in: textView).first!
    let line = textView.engine.gutterLine(for: first)!
    let originY = textView.textContainerOrigin.y
    // 行番号は上余白の下(テキスト行の上端)に揃う
    #expect(line.yInTextView == first.layoutFragmentFrame.minY + padding + originY)
    #expect(line.heightInTextView == first.layoutFragmentFrame.height - padding)
}

@Test func blockBackgroundPathRoundsOnlyRequestedCorners() {
    let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
    let corners = [
        CGPoint(x: 0.3, y: 0.3), CGPoint(x: 99.7, y: 0.3),      // 上の 2 隅
        CGPoint(x: 0.3, y: 49.7), CGPoint(x: 99.7, y: 49.7),    // 下の 2 隅
    ]
    let topOnly = CGPath.blockBackground(in: rect, cornerRadius: 4, roundsTop: true, roundsBottom: false)
    #expect(corners.map { topOnly.contains($0) } == [false, false, true, true])
    let bottomOnly = CGPath.blockBackground(in: rect, cornerRadius: 4, roundsTop: false, roundsBottom: true)
    #expect(corners.map { bottomOnly.contains($0) } == [true, true, false, false])
    let square = CGPath.blockBackground(in: rect, cornerRadius: 4, roundsTop: false, roundsBottom: false)
    #expect(corners.allSatisfy { square.contains($0) })
    let both = CGPath.blockBackground(in: rect, cornerRadius: 4, roundsTop: true, roundsBottom: true)
    #expect(corners.allSatisfy { !both.contains($0) })
    #expect(both.contains(CGPoint(x: 50, y: 25)))
    #expect(both.boundingBox == rect)
}
#endif
