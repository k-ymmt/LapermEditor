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

@MainActor @Test func codeBlockBackgroundSpansTheTextContainerWidth() throws {
    let textView = makeCodeBlockTextView("x\n\n```\nshort\n```\n\ny")
    let container = textView.textContainer!
    let fragments = codeBlockFragments(in: textView)
    try #require(fragments.count == 3)
    for fragment in fragments {
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

@MainActor @Test func codeBlockBoxLeavesTheLineSpacingAboveItsFirstLineOutside() throws {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    var theme = textView.theme
    theme.lineSpacing = 6
    textView.theme = theme
    textView.string = "x\n\n```\na\nb\n```\n\ny"
    textView.highlightAll()
    let fragments = codeBlockFragments(in: textView)
    let first = try #require(fragments.first)
    #expect(fragments.count == 4)
    // 先頭段落: 上余白(4)の上にさらに行間(6)が入るが、箱は行間の下から始まる
    #expect(first.textLineFragments.first?.typographicBounds.minY == 6 + theme.codeBlockVerticalPadding)
    #expect(first.backgroundRect.minY == 6)
    #expect(first.backgroundRect.maxY == first.layoutFragmentFrame.height)
    // 途中・末尾の段落は上端から塗って隣と隙間なく連なる
    for fragment in fragments.dropFirst() { #expect(fragment.backgroundRect.minY == 0) }
    // 行番号はテキスト行(行間 + 上余白の下)に揃う
    let line = try #require(textView.engine.gutterLine(for: first))
    #expect(line.yInTextView == first.layoutFragmentFrame.minY + 6 + theme.codeBlockVerticalPadding
            + textView.textContainerOrigin.y)
}

@MainActor @Test func codeBlockBoxEndingTheDocumentWithANewlineStopsBeforeTheExtraLinesSpacing() throws {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    var theme = textView.theme
    theme.lineSpacing = 6
    textView.theme = theme
    textView.string = "x\n\n```\na\n```\n"
    textView.highlightAll()
    let last = try #require(codeBlockFragments(in: textView).last)
    let extra = try #require(last.trailingExtraLineFragment)
    let fenceBottom = try #require(last.textLineFragments.first).typographicBounds.maxY
    // 追加行の上には「下余白 + 行間」が入る。箱は下余白までで、行間は外に出す
    #expect(extra.typographicBounds.minY == fenceBottom + theme.codeBlockVerticalPadding + 6)
    #expect(last.backgroundRect.maxY == fenceBottom + theme.codeBlockVerticalPadding)
}

@MainActor @Test func blockquoteBarAndTableBackgroundStartBelowTheLineSpacingOnlyAtTheBlockStart() throws {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    var theme = textView.theme
    theme.lineSpacing = 6
    textView.theme = theme
    textView.string = "x\n\n> one\n> two\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\ny"
    textView.highlightAll()
    let quotes = layoutFragments(in: textView).compactMap { $0 as? BlockquoteFragment }
    let rows = layoutFragments(in: textView).compactMap { $0 as? TableBackgroundFragment }
    #expect(quotes.count == 2)
    #expect(rows.count == 3)
    // 先頭段落だけ行間ぶん下げ、続く段落は上端から描いて隣と隙間なく連なる
    #expect(quotes.map(\.decorationRect.minY) == [6, 0])
    #expect(rows.map(\.decorationRect.minY) == [6, 0, 0])
    for fragment in quotes + rows {
        #expect(fragment.decorationRect.maxY == fragment.layoutFragmentFrame.height)
    }
}

// MARK: - 引用の縦バー

@MainActor @Test func blockquoteParagraphsAreIndentedByTheThemeWithoutTouchingStorage() throws {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    var theme = textView.theme
    theme.blockquoteIndent = 20
    textView.theme = theme
    textView.string = "plain\n\n> one\n> two words that wrap when the line is long enough to need it\n\nafter"
    textView.highlightAll()
    let fragments = layoutFragments(in: textView)
    let padding = textView.textContainer!.lineFragmentPadding
    let quotes = fragments.compactMap { $0 as? BlockquoteFragment }
    try #require(quotes.count == 2)
    // 引用の段落は行頭ごと indent ぶん右へ(折り返した行も同じ)。通常段落は動かない
    for quote in quotes {
        #expect(quote.layoutFragmentFrame.minX == padding + 20)
        for line in quote.textLineFragments { #expect(line.typographicBounds.minX == 0) }
    }
    #expect(quotes[1].textLineFragments.count > 1)
    #expect(fragments.first?.layoutFragmentFrame.minX == padding)
    #expect(fragments.last?.layoutFragmentFrame.minX == padding)
    // 表示用の段落だけに段落スタイルが付き、textStorage の属性は変わらない
    let storage = textView.textStorage!
    storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
        let style = value as? NSParagraphStyle
        #expect((style?.headIndent ?? 0) == 0)
        #expect((style?.firstLineHeadIndent ?? 0) == 0)
    }
}

@MainActor @Test func blockquoteBarKeepsOneXAcrossLinesAndLeavesAGapBeforeTheText() throws {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    // Live Preview で ">" が隠れると、行の先頭の字形(j / i / ` / 何もない)でインク境界が行ごとに変わる
    textView.isLivePreviewEnabled = true
    textView.string = "> jjj\n> *italic*\n> `code`\n>\n> **bold**\n\nplain"
    textView.highlightAll()
    textView.engine.editorFocusDidChange(false)
    textView.highlightNow()
    let layoutManager = textView.textLayoutManager!
    // 前提: マーカー "> " が実際に隠れている(隠れていなければ字形のずれを再現できない)
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: layoutManager).width < 0.1)
    let quotes = layoutFragments(in: textView).compactMap { $0 as? BlockquoteFragment }
    try #require(quotes.count == 5)
    let padding = textView.textContainer!.lineFragmentPadding
    let indent = textView.theme.blockquoteIndent
    // コンテナ座標のバー x は全段落で同じ: コンテナ左端 + lineFragmentPadding + barInset
    let containerXs = Set(quotes.map { $0.layoutFragmentFrame.minX + $0.barRect.minX })
    #expect(containerXs == [padding + BlockquoteFragment.barInset])
    for quote in quotes {
        let bar = quote.barRect
        // バーは indent の余白の中(左端から barInset)にあり、本文(x = 0)との間が空く
        #expect(bar.minX == -indent + BlockquoteFragment.barInset)
        #expect(bar.width == BlockquoteFragment.barWidth)
        #expect(bar.maxX <= -8)
        #expect(bar.minY == quote.decorationRect.minY)
        #expect(bar.maxY == quote.decorationRect.maxY)
        // 描画面がバーを含む(UITextView はこの境界でクリップする)
        #expect(quote.renderingSurfaceBounds.contains(bar))
    }
}

@MainActor @Test func blockquoteBarSitsOnTheTrailingSideOfRightToLeftQuotes() throws {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "> שלום\n> עולם ארוך מאוד שנשבר לשורה שנייה בתוך המסגרת הזאת בטח\n> hello"
    textView.highlightAll()
    let quotes = layoutFragments(in: textView).compactMap { $0 as? BlockquoteFragment }
    try #require(quotes.count == 3)
    let container = textView.textContainer!
    let padding = container.lineFragmentPadding
    let indent = textView.theme.blockquoteIndent
    // RTL の段落は右寄せで、フラグメント原点が段落ごとに違う(短い行ほど右)
    #expect(quotes[0].layoutFragmentFrame.minX > quotes[1].layoutFragmentFrame.minX)
    #expect(quotes[2].layoutFragmentFrame.minX == padding + indent)
    // RTL の段落: バーは右端(コンテナ右端 - padding - barInset - barWidth)。LTR の段落は左端
    let right = container.size.width - padding - BlockquoteFragment.barInset - BlockquoteFragment.barWidth
    let containerXs = quotes.map { $0.layoutFragmentFrame.minX + $0.barRect.minX }
    #expect(containerXs[0] == right)
    #expect(containerXs[1] == right)
    #expect(containerXs[2] == padding + BlockquoteFragment.barInset)
    for quote in quotes {
        #expect(quote.renderingSurfaceBounds.contains(quote.barRect))
    }
}

@MainActor @Test func blockquoteIndentFollowsDecorationChangesInParagraphsThatWereNotEdited() throws {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = "> a\n\nb\nc\n"
    textView.highlightAll()
    let padding = textView.textContainer!.lineFragmentPadding
    let indent = textView.theme.blockquoteIndent
    func fragment(at location: Int) -> NSTextLayoutFragment {
        let layoutManager = textView.textLayoutManager!
        let contentManager = layoutManager.textContentManager!
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        return layoutManager.textLayoutFragment(for: contentManager.location(contentManager.documentRange.location, offsetBy: location)!)!
    }
    // 先頭行の行頭(コンテナ座標)。文書末尾の段落はフレームがインデントの無い追加行まで含むので、フレームでは見ない
    func textStart(at location: Int) -> CGFloat {
        let fragment = fragment(at: location)
        return fragment.layoutFragmentFrame.minX + fragment.textLineFragments.first!.typographicBounds.minX
    }
    #expect(textStart(at: 5) == padding)
    #expect(textStart(at: 7) == padding)

    // 空行を消すと "b" と "c" は引用の継続行(lazy continuation)になる。"c" の段落は編集されていない
    textView.textStorage!.replaceCharacters(in: NSRange(location: 4, length: 1), with: "")
    textView.highlightNow()
    #expect(fragment(at: 4) is BlockquoteFragment)
    #expect(fragment(at: 6) is BlockquoteFragment)
    #expect(textStart(at: 4) == padding + indent)
    #expect(textStart(at: 6) == padding + indent)
    // 末尾段落のバーも(フレームが追加行で左に広がっていても)同じ x
    let last = try #require(fragment(at: 6) as? BlockquoteFragment)
    #expect(last.layoutFragmentFrame.minX + last.barRect.minX == padding + BlockquoteFragment.barInset)

    // 空行を戻すと引用から外れ、インデントも消える
    textView.textStorage!.replaceCharacters(in: NSRange(location: 4, length: 0), with: "\n")
    textView.highlightNow()
    #expect(!(fragment(at: 7) is BlockquoteFragment))
    #expect(textStart(at: 5) == padding)
    #expect(textStart(at: 7) == padding)
}

@MainActor @Test func negativeBlockquoteIndentAssignedAfterInitDrawsTheBarAtTheLineStart() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    var theme = textView.theme
    theme.blockquoteIndent = -16
    #expect(theme.blockquoteIndent == 0)
    textView.theme = theme
    textView.string = "> a"
    textView.highlightAll()
    let quote = layoutFragments(in: textView).compactMap { $0 as? BlockquoteFragment }.first
    #expect(quote?.layoutFragmentFrame.minX == textView.textContainer!.lineFragmentPadding)
    #expect(quote?.barRect.minX == 0)
}

@Test func blockquoteBarStaysInsideANarrowIndent() {
    // 余白が十分: 余白の左端 + barInset
    #expect(BlockquoteFragment.barInset(indent: 16) == 1)
    // 余白がバーより少し広いだけ: はみ出さない範囲で寄せる
    #expect(BlockquoteFragment.barInset(indent: 3.5) == 0.5)
    // 余白がバー以下 / 余白なし: 余白の左端(行頭に重ねる)
    #expect(BlockquoteFragment.barInset(indent: 2) == 0)
    #expect(BlockquoteFragment.barInset(indent: 0) == 0)
    #expect(BlockquoteFragment.barInset(indent: -5) == 0)
}

@MainActor @Test func gutterLinesKeepAnEvenPitchAcrossEmptyLinesWithLineSpacing() throws {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    var theme = textView.theme
    theme.lineSpacing = 6
    textView.theme = theme
    textView.string = "a\n\nb\n\n\nc"
    textView.highlightAll()
    let fragments = layoutFragments(in: textView)
    #expect(fragments.count == 6)
    let tops = try fragments.map { try #require(textView.engine.gutterLine(for: $0)).yInTextView }
    // 空段落(2・4・5 行目)は TextKit 2 が行間を高さに畳み込むが、行番号の位置は文字行と同じ間隔で並ぶ
    let pitches = zip(tops, tops.dropFirst()).map { $1 - $0 }
    #expect(pitches.count == 5)
    for pitch in pitches { #expect(abs(pitch - pitches[0]) < 0.5, "\(pitches)") }
    #expect(pitches[0] > 17, "行間ぶん広がる: \(pitches)")
}

@MainActor @Test func gutterDoesNotLowerAParagraphThatHasNoLineSpacingYet() throws {
    // ハイライト前(段落スタイル未適用)の非空段落は行間 0 でレイアウトされる。テーマの行間で
    // 判定すると minY 0 を空段落と誤認して行番号を下げてしまう → 実際に付いているスタイルで判定する
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    var theme = textView.theme
    theme.lineSpacing = 6
    textView.theme = theme
    textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "a\nb\n\nc")
    textView.textLayoutManager?.ensureLayout(for: textView.textLayoutManager!.documentRange)
    let fragments = layoutFragments(in: textView)
    #expect(fragments.count == 4)
    for fragment in fragments {
        let line = try #require(textView.engine.gutterLine(for: fragment))
        let firstLineTop = try #require(fragment.textLineFragments.first).typographicBounds.minY
        #expect(line.yInTextView == fragment.layoutFragmentFrame.minY + firstLineTop + textView.textContainerOrigin.y)
    }
}

@MainActor @Test func codeBlockBoxAtTheDocumentStartHasNoTopInset() throws {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    var theme = textView.theme
    theme.lineSpacing = 6
    textView.theme = theme
    textView.string = "```\na\n```\n\ny"
    textView.highlightAll()
    let first = try #require(codeBlockFragments(in: textView).first)
    // 文書の最初の行には行間も paragraphSpacingBefore も付かない
    #expect(first.textLineFragments.first?.typographicBounds.minY == 0)
    #expect(first.backgroundRect.minY == 0)
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
@Test func backgroundWidthFallsBackToTheTextForUnlimitedContainers() {
    // 通常の折り返しコンテナ幅はそのまま
    #expect(CodeBlockFragment.backgroundWidth(containerWidth: 300, textRightEdge: 80) == 300)
    // 0(無制限)・非有限・無制限相当の巨大値はコンテナ左端〜テキスト右端に落とす
    #expect(CodeBlockFragment.backgroundWidth(containerWidth: 0, textRightEdge: 80) == 80)
    #expect(CodeBlockFragment.backgroundWidth(containerWidth: .infinity, textRightEdge: 80) == 80)
    #expect(CodeBlockFragment.backgroundWidth(containerWidth: 10_000_000, textRightEdge: 80) == 80)
    #expect(CodeBlockFragment.backgroundWidth(containerWidth: nil, textRightEdge: 80) == 80)
}

@MainActor @Test func trailingExtraLineStaysOutsideTheCodeBlockBox() throws {
    // 改行で終わる文書では、最後の段落のフラグメントに文字数ゼロの「追加行」が同居する。
    // 追加行はブロックの外(次に入力する行)なので、背景も予約もその手前で止める。
    let withNewline = makeCodeBlockTextView("x\n\n```\ncode\n```\n")
    let padding = withNewline.theme.codeBlockVerticalPadding
    let last = try #require(codeBlockFragments(in: withNewline).last)
    try #require(last.textLineFragments.count == 2)
    let fenceLine = last.textLineFragments[0].typographicBounds
    let extraLine = last.textLineFragments[1].typographicBounds
    #expect(last.roundsBottom)
    // 段落スタイルの下余白はフェンス行と追加行の間に入っている
    #expect(extraLine.minY == fenceLine.maxY + padding)
    // 背景は追加行の手前まで、フレームは追加行の下端まで(予約で余計に伸ばさない)
    #expect(last.backgroundRect.height == extraLine.minY)
    #expect(last.layoutFragmentFrame.height == extraLine.maxY)
    #expect(last.reservationApplies == false)

    // 改行なしで終わる文書は追加行がなく、落ちる paragraphSpacing を予約で補う
    let withoutNewline = makeCodeBlockTextView("x\n\n```\ncode\n```")
    let end = try #require(codeBlockFragments(in: withoutNewline).last)
    #expect(end.textLineFragments.count == 1)
    #expect(end.reservationApplies)
    #expect(end.backgroundRect.height == end.textLinesBottom + padding)
    #expect(end.layoutFragmentFrame.height == end.textLinesBottom + padding)
}

@MainActor @Test func movingTheClosingFenceMovesTheBottomEdge() throws {
    let textView = makeCodeBlockTextView("x\n\n```\na\n```\n\ny")
    let padding = textView.theme.codeBlockVerticalPadding
    // 閉じフェンスの手前に行を足す → 末尾段落が変わる
    let fence = (textView.string as NSString).range(of: "```", options: .backwards).location
    textView.textStorage!.replaceCharacters(in: NSRange(location: fence, length: 0), with: "b\n")
    textView.highlightNow()
    let fragments = codeBlockFragments(in: textView)
    try #require(fragments.count == 4)
    #expect(fragments.map(\.roundsBottom) == [false, false, false, true])
    #expect(fragments.map(\.roundsTop) == [true, false, false, false])
    // 余白も新しい末尾段落だけに付く
    #expect(paragraphStyle(of: fragments[2]) == nil)
    #expect(paragraphStyle(of: fragments[3])?.paragraphSpacing == padding)
}

@MainActor @Test func newlinesAfterTheClosingFenceDoNotInheritThePadding() throws {
    // 閉じフェンス直後で Return を 2 回 → "```\n" は末尾段落のまま、その後の空段落は通常段落
    let textView = makeCodeBlockTextView("x\n\n```\na\n```")
    let padding = textView.theme.codeBlockVerticalPadding
    let end = textView.textStorage!.length
    textView.textStorage!.replaceCharacters(in: NSRange(location: end, length: 0), with: "\n\n")
    textView.highlightNow()
    let all = layoutFragments(in: textView)
    let code = all.compactMap { $0 as? CodeBlockFragment }
    try #require(code.count == 3)
    #expect(code[2].roundsBottom)
    #expect(paragraphStyle(of: code[2])?.paragraphSpacing == padding)
    // 閉じフェンスの後の空段落("\n")は装飾もスタイルもない
    let blank = try #require(all.first {
        ($0.textElement as? NSTextParagraph)?.attributedString.string == "\n"
            && $0.rangeInElement.location.compare(code[2].rangeInElement.endLocation) != .orderedAscending
    })
    #expect(!(blank is CodeBlockFragment))
    #expect(paragraphStyle(of: blank) == nil)
}

@MainActor @Test func codeBlockEdgesAreAppliedAfterBackgroundParse() async throws {
    // 長い文書の初回表示はバックグラウンドでパースされ、完了通知で装飾が同期される。
    // その経路でも先頭 / 末尾段落の判定と余白が付くこと。
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.engine.highlighter.backgroundParseLengthThreshold = 4
    textView.string = "x\n\n```\na\nb\n```\n\ny"
    textView.highlightAll()
    #expect(codeBlockFragments(in: textView).isEmpty)
    for _ in 0..<300 where codeBlockFragments(in: textView).count < 4 {
        try await Task.sleep(for: .milliseconds(10))
    }
    let fragments = codeBlockFragments(in: textView)
    try #require(fragments.count == 4)
    let padding = textView.theme.codeBlockVerticalPadding
    #expect(fragments.map(\.roundsTop) == [true, false, false, false])
    #expect(fragments.map(\.roundsBottom) == [false, false, false, true])
    #expect(paragraphStyle(of: fragments[0])?.paragraphSpacingBefore == padding)
    #expect(paragraphStyle(of: fragments[3])?.paragraphSpacing == padding)
}

@MainActor @Test func decorationLookupMatchesTheLinearScan() {
    // 索引付き検索が、素朴な「開始位置順(同位置なら計画順)で最初に交差する装飾」と一致する。
    // 入れ子(引用の中のコードブロック)・隣接・空段落・計画順が開始位置順でない場合を含める。
    let spans: [HighlightSpan] = [
        HighlightSpan(range: NSRange(location: 10, length: 40), kind: .blockquote),
        HighlightSpan(range: NSRange(location: 20, length: 10), kind: .codeBlock),
        HighlightSpan(range: NSRange(location: 20, length: 5), kind: .table),
        HighlightSpan(range: NSRange(location: 50, length: 3), kind: .thematicBreak),
        HighlightSpan(range: NSRange(location: 53, length: 7), kind: .codeBlock),
        HighlightSpan(range: NSRange(location: 5, length: 3), kind: .codeBlock),
        HighlightSpan(range: NSRange(location: 90, length: 0), kind: .codeBlock),
        HighlightSpan(range: NSRange(location: 70, length: 4), kind: .emphasis),  // 装飾にならない
    ]
    let provider = BlockFragmentProvider(theme: .default)
    let contentStorage = NSTextContentStorage()
    contentStorage.textStorage = NSTextStorage(string: String(repeating: "a", count: 120))
    let layoutManager = NSTextLayoutManager()
    contentStorage.addTextLayoutManager(layoutManager)
    provider.update(plan: HighlightPlan(spans: spans), contentManager: contentStorage, layoutManager: layoutManager)

    let expected: [Decoration] = spans.enumerated().compactMap { index, span in
        let kind: BlockDecoration? = switch span.kind {
        case .codeBlock: .codeBlock
        case .blockquote: .blockquote
        case .thematicBreak: .thematicBreak
        case .table: .table
        default: nil
        }
        return kind.map { (index, Decoration(range: span.range, kind: $0)) }
    }.sorted { ($0.0 < $1.0) }.map(\.1)
    let ordered = expected.enumerated().sorted { ($0.element.range.location, $0.offset) < ($1.element.range.location, $1.offset) }.map(\.element)
    func linear(_ paragraph: NSRange) -> Decoration? {
        ordered.first { NSLocationInRange(paragraph.location, $0.range) || NSIntersectionRange(paragraph, $0.range).length > 0 }
    }
    var generator = SystemRandomNumberGenerator()
    var checked = 0
    for location in 0...120 {
        for length in [0, 1, 2, 5, 12, 30, 60] where location + length <= 120 {
            let paragraph = NSRange(location: location, length: length)
            #expect(provider.decoration(forParagraph: paragraph) == linear(paragraph), "\(paragraph)")
            checked += 1
        }
    }
    for _ in 0..<500 {
        let location = Int.random(in: 0...120, using: &generator)
        let length = Int.random(in: 0...(120 - location), using: &generator)
        let paragraph = NSRange(location: location, length: length)
        #expect(provider.decoration(forParagraph: paragraph) == linear(paragraph), "\(paragraph)")
        checked += 1
    }
    #expect(checked > 500)
}

// MARK: - 実描画(ピクセル検査)

/// テキストビューをオフスクリーン描画し、テキストビュー座標(pt)の点の色を返す。
@MainActor
private func renderedColor(of textView: MarkdownTextView, at point: CGPoint) throws -> NSColor {
    let rep = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
    textView.cacheDisplay(in: textView.bounds, to: rep)
    let scaleX = CGFloat(rep.pixelsWide) / textView.bounds.width
    let scaleY = CGFloat(rep.pixelsHigh) / textView.bounds.height
    // NSTextView は flipped なので y は上から数える。ピクセル中心を拾う。
    let color = try #require(rep.colorAt(x: Int(point.x * scaleX), y: Int(point.y * scaleY)))
    return try #require(color.usingColorSpace(.sRGB))
}

private func isClose(_ color: NSColor, to expected: NSColor, tolerance: CGFloat = 0.15) -> Bool {
    guard let expected = expected.usingColorSpace(.sRGB) else { return false }
    return abs(color.redComponent - expected.redComponent) <= tolerance
        && abs(color.greenComponent - expected.greenComponent) <= tolerance
        && abs(color.blueComponent - expected.blueComponent) <= tolerance
}

@MainActor @Test func codeBlockBackgroundIsActuallyDrawnAcrossTheFullWidth() throws {
    // fillPath を消しても座標テストは通るので、実際に描いた画素を検査する。
    var theme = MarkdownTheme.default
    theme.backgroundColor = .white
    theme.bodyColor = .black
    theme.codeBlockBackgroundColor = .red
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
    textView.theme = theme
    textView.string = "x\n\n```\na\nb\n```\n\ny"
    textView.highlightAll()
    textView.layoutSubtreeIfNeeded()
    let fragments = codeBlockFragments(in: textView)
    try #require(fragments.count == 4)
    let origin = textView.textContainerOrigin
    let container = textView.textContainer!
    let left = origin.x
    let right = origin.x + container.size.width
    func frame(_ i: Int) -> CGRect { fragments[i].layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y) }
    let lineA = frame(1)
    let lineB = frame(2)
    let box = CGRect(x: left, y: frame(0).minY, width: right - left, height: frame(3).maxY - frame(0).minY)

    // 行の中央の高さで、コンテナの左端・右端・中央が塗られている(文字幅ではなく全幅)
    for x in [left + 1, (left + right) / 2, right - 1] {
        #expect(isClose(try renderedColor(of: textView, at: CGPoint(x: x, y: lineA.midY)), to: .red), "x=\(x)")
    }
    // 段落の継ぎ目(a 行と b 行の境界)に背景色以外の線が出ない
    #expect(isClose(try renderedColor(of: textView, at: CGPoint(x: right - 20, y: lineB.minY)), to: .red))
    #expect(isClose(try renderedColor(of: textView, at: CGPoint(x: right - 20, y: lineB.minY - 0.5)), to: .red))
    // 上余白・下余白の帯も塗られている
    #expect(isClose(try renderedColor(of: textView, at: CGPoint(x: right - 20, y: box.minY + 1)), to: .red))
    #expect(isClose(try renderedColor(of: textView, at: CGPoint(x: right - 20, y: box.maxY - 1)), to: .red))
    // 角は丸いので四隅の画素は背景色、辺の中央から少し内側は塗られている
    for corner in [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX - 1, y: box.minY),
                   CGPoint(x: box.minX, y: box.maxY - 1), CGPoint(x: box.maxX - 1, y: box.maxY - 1)] {
        #expect(isClose(try renderedColor(of: textView, at: corner), to: .white), "corner \(corner)")
    }
    // ブロックの外は背景色
    #expect(isClose(try renderedColor(of: textView, at: CGPoint(x: right - 20, y: box.minY - 2)), to: .white))
    #expect(isClose(try renderedColor(of: textView, at: CGPoint(x: right - 20, y: box.maxY + 2)), to: .white))
}

@MainActor @Test func drawHonorsTheGivenOrigin() throws {
    // draw(at:in:) の point は呼び出し側の描画原点。背景もその分ずれて描かれること。
    var theme = MarkdownTheme.default
    theme.codeBlockBackgroundColor = .red
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
    textView.theme = theme
    textView.string = "```\na\n```"
    textView.highlightAll()
    let fragment = try #require(codeBlockFragments(in: textView).first)
    let width = 300, height = 200
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    // TextKit の y 下向き座標に合わせて反転(データの先頭行 = y 0)
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(CGColor.white)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let point = CGPoint(x: 40, y: 60)
    fragment.draw(at: point, in: context)
    let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    func isRed(x: Int, y: Int) -> Bool {
        let p = data + (y * width + x) * 4
        return p[0] > 200 && p[1] < 60 && p[2] < 60
    }
    let rect = fragment.backgroundRect.offsetBy(dx: point.x, dy: point.y)
    #expect(isRed(x: Int(rect.midX), y: Int(rect.midY)))
    #expect(isRed(x: Int(rect.minX) + 2, y: Int(rect.midY)))
    // 原点を無視して描くと (0, 0) 付近が塗られてしまう
    #expect(!isRed(x: 2, y: 2))
    #expect(!isRed(x: Int(rect.midX), y: 2))
}
#endif
