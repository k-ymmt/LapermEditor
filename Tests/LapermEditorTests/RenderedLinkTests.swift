#if os(macOS)
import AppKit
import Testing
@testable import LapermEditor
@testable import LapermCore

// Live Preview で描かれたリンクのクリックと、リンクのメニュー(Laperm ADR 0031 / issue #2)。

@MainActor
private func makeFocusedTextView(_ markdown: String, livePreview: Bool = true) -> (NSWindow, MarkdownTextView) {
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    scrollView.frame = CGRect(x: 0, y: 0, width: 500, height: 400)
    let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = scrollView
    textView.string = markdown
    textView.highlightAll()
    textView.isLivePreviewEnabled = livePreview
    #expect(window.makeFirstResponder(textView))
    return (window, textView)
}

/// 文字範囲の最初の行の矩形の中央(ビュー座標)。
@MainActor
private func center(of range: NSRange, in textView: MarkdownTextView) throws -> CGPoint {
    let frame = try #require(textView.engine.segmentFrames(for: range)?.first)
    return CGPoint(x: frame.midX, y: frame.midY)
}

// MARK: - 部品

@Test func urlRangesFindHTTPURLsAndDropTrailingPunctuation() {
    let text = "see https://example.com/a, and http://x.y. but not https:// or ftp://z"
    #expect(PreviewLinks.urlRanges(in: text) == [NSRange(location: 4, length: 21), NSRange(location: 31, length: 10)])
    #expect(PreviewLinks.urlRanges(in: "(https://a.example/b)") == [NSRange(location: 1, length: 19)])
    #expect(PreviewLinks.urlRanges(in: "plain text").isEmpty)
    // 対応する開き括弧のある閉じ括弧は URL の一部(本文の裸の URL と同じ)。短いホストも URL
    let wiki = "https://en.wikipedia.org/wiki/Swift_(programming_language)"
    #expect(PreviewLinks.urlRanges(in: wiki + ".") == [NSRange(location: 0, length: (wiki as NSString).length)])
    #expect(PreviewLinks.urlRanges(in: "(see \(wiki))") == [NSRange(location: 5, length: (wiki as NSString).length)])
    #expect(PreviewLinks.urlRanges(in: "http://x") == [NSRange(location: 0, length: 8)])
}

/// 右から左の文字が混ざる行でも、URL のどの文字も見た目の位置で当たる(論理順の隣の文字の境界で判定しない)。
@MainActor @Test func characterIndexFollowsTheVisualOrderInBidirectionalText() {
    let font = NSFont.systemFont(ofSize: 14)
    let string = "אבג https://a.example דהו"
    let text = NSAttributedString(string: string, attributes: [.font: font])
    let width = text.size().width + 20
    let url = (string as NSString).range(of: "https://a.example")
    var hits = Set<Int>()
    var x: CGFloat = 0
    while x < width {
        if let index = PreviewLinks.characterIndex(in: text, width: width, at: CGPoint(x: x, y: 8)) { hits.insert(index) }
        x += 0.5
    }
    for index in url.location..<NSMaxRange(url) where (string as NSString).character(at: index) != 0x20 {
        #expect(hits.contains(index), "URL character \(index) should be reachable")
    }
}

/// 組版の高さを打ち切らない: 長い値の最後の文字にも当たる。
@MainActor @Test func characterIndexReachesTheEndOfAVeryTallText() throws {
    let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    let string = String(repeating: "abcdefgh ", count: 7_000)
    let text = NSAttributedString(string: string, attributes: [.font: font])
    let size = text.boundingRect(with: CGSize(width: 100, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).size
    #expect(size.height > 100_000)
    let index = try #require(PreviewLinks.characterIndex(in: text, width: 100, at: CGPoint(x: 3, y: size.height - 8)))
    #expect(index > (string as NSString).length - 20)
}

@MainActor @Test func characterIndexFindsTheCharacterUnderThePoint() {
    let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    let text = NSAttributedString(string: "abc def", attributes: [.font: font])
    let advance = text.attributedSubstring(from: NSRange(location: 0, length: 1)).size().width
    let lineHeight = font.ascender - font.descender
    #expect(PreviewLinks.characterIndex(in: text, width: 1000, at: CGPoint(x: advance * 4.5, y: lineHeight / 2)) == 4)
    #expect(PreviewLinks.characterIndex(in: text, width: 1000, at: CGPoint(x: advance * 0.5, y: lineHeight / 2)) == 0)
    // 行の右の余白、行の下は文字の上ではない
    #expect(PreviewLinks.characterIndex(in: text, width: 1000, at: CGPoint(x: advance * 20, y: lineHeight / 2)) == nil)
    #expect(PreviewLinks.characterIndex(in: text, width: 1000, at: CGPoint(x: advance, y: lineHeight * 3)) == nil)
    // 折り返した 2 行目
    #expect(PreviewLinks.characterIndex(in: text, width: advance * 4.2, at: CGPoint(x: advance * 0.5, y: lineHeight * 1.5)) == 4)
}

@MainActor @Test func copyableTextResolvesURLsAndKeepsWikiSyntax() throws {
    let (window, textView) = makeFocusedTextView("See [[Note|Alias]] and [doc](docs/a.md)\n")
    defer { withExtendedLifetime(window) {} }
    let base = URL(filePath: "/vault/", directoryHint: .isDirectory)
    #expect(textView.engine.copyableText(for: .url(destination: "docs/a.md"), baseURL: base) == "file:///vault/docs/a.md")
    #expect(textView.engine.copyableText(for: .url(destination: "https://x.example/"), baseURL: nil) == "https://x.example/")
    let wiki = try #require(textView.engine.wikiLinkReference(at: 6))
    #expect(textView.engine.copyableText(for: .wiki(wiki), baseURL: nil) == "[[Note|Alias]]")
}

// MARK: - 本文のリンク

@MainActor @Test func bodyLinksOpenOnClickOnlyWhereTheyAreRenderedAsLinks() throws {
    let markdown = "Go [site](https://s.example) now\n\nplain\n"
    let (window, textView) = makeFocusedTextView(markdown)
    defer { withExtendedLifetime(window) {} }
    var opened: [URL] = []
    textView.onOpenLink = { opened.append($0); return true }
    // キャレットは別の段落: リンクの段落は描かれている(記号が隠れている)
    textView.setSelectedRange(NSRange(location: 36, length: 0))
    textView.layoutSubtreeIfNeeded()
    let onSite = try center(of: NSRange(location: 4, length: 4), in: textView)
    let hit = try #require(textView.linkHit(atPoint: onSite))
    #expect(hit.target == .url(destination: "https://s.example"))
    #expect(hit.isRendered)
    #expect(textView.openRenderedLink(atPoint: onSite))
    #expect(opened == [URL(string: "https://s.example")!])
    // リンクの外(同じ段落の "now")は開かない
    #expect(!textView.openRenderedLink(atPoint: try center(of: NSRange(location: 29, length: 3), in: textView)))

    // キャレットのある段落では記号が見えているので、クリックはキャレットを置く(メニューの対象にはなる)
    textView.setSelectedRange(NSRange(location: 1, length: 0))
    textView.layoutSubtreeIfNeeded()
    let onSiteEditing = try center(of: NSRange(location: 4, length: 4), in: textView)
    #expect(textView.linkHit(atPoint: onSiteEditing)?.isRendered == false)
    #expect(!textView.openRenderedLink(atPoint: onSiteEditing))

    // エディタがフォーカスを失うと全段落が描かれた状態になり、キャレットの段落のリンクも開く
    #expect(window.makeFirstResponder(nil))
    textView.layoutSubtreeIfNeeded()
    #expect(textView.linkHit(atPoint: try center(of: NSRange(location: 4, length: 4), in: textView))?.isRendered == true)

    // Source ではどこも描かれたリンクではない(Cmd+クリックだけ)
    textView.isLivePreviewEnabled = false
    textView.layoutSubtreeIfNeeded()
    #expect(textView.linkHit(atPoint: try center(of: NSRange(location: 4, length: 4), in: textView))?.isRendered == false)
    #expect(opened.count == 1)
    // 設定で切れる
    textView.isLivePreviewEnabled = true
    #expect(window.makeFirstResponder(textView))
    textView.setSelectedRange(NSRange(location: 36, length: 0))
    textView.linkOptions.opensRenderedLinksOnClick = false
    textView.layoutSubtreeIfNeeded()
    #expect(!textView.openRenderedLink(atPoint: try center(of: NSRange(location: 4, length: 4), in: textView)))
}

/// 複数の段落にまたがるリンクは、押した文字の段落が描かれているかで決まる(キャレットの無い段落の部分だけ開く)。
@MainActor @Test func aLinkAcrossParagraphsIsRenderedPerParagraph() throws {
    let markdown = "[first\nsecond](https://example.com)\n\nplain\n"
    let (window, textView) = makeFocusedTextView(markdown)
    defer { withExtendedLifetime(window) {} }
    textView.setSelectedRange(NSRange(location: 2, length: 0))  // 1 行目
    textView.layoutSubtreeIfNeeded()
    #expect(textView.linkHit(atPoint: try center(of: NSRange(location: 1, length: 5), in: textView))?.isRendered == false)
    let second = try #require(textView.linkHit(atPoint: try center(of: NSRange(location: 7, length: 6), in: textView)))
    #expect(second.isRendered, "the second line has no caret, so its part of the link is drawn as a link")
}

@MainActor @Test func renderedWikiLinksOpenThroughTheHost() throws {
    let (window, textView) = makeFocusedTextView("See [[Note]] here\n\nplain\n")
    defer { withExtendedLifetime(window) {} }
    var opened: [String] = []
    textView.onOpenWikiLink = { opened.append($0.target); return true }
    textView.setSelectedRange(NSRange(location: 20, length: 0))
    textView.layoutSubtreeIfNeeded()
    #expect(textView.openRenderedLink(atPoint: try center(of: NSRange(location: 6, length: 4), in: textView)))
    #expect(opened == ["Note"])
}

@MainActor @Test func linkMenuOffersOpenCopyAndEditAboveTheStandardItems() throws {
    let (window, textView) = makeFocusedTextView("Go [site](https://s.example) now\n\nplain\n")
    defer { withExtendedLifetime(window) {} }
    var opened: [URL] = []
    textView.onOpenLink = { opened.append($0); return true }
    textView.setSelectedRange(NSRange(location: 36, length: 0))
    textView.layoutSubtreeIfNeeded()
    let hit = try #require(textView.linkHit(atPoint: try center(of: NSRange(location: 4, length: 4), in: textView)))
    let base = NSMenu()
    base.addItem(NSMenuItem(title: "Cut", action: nil, keyEquivalent: ""))
    let menu = textView.linkMenu(for: hit, appendingItemsOf: base)
    #expect(menu.items.map(\.title) == [LinkMenuTitle.open, LinkMenuTitle.copy, LinkMenuTitle.edit, "", "Cut"])
    #expect(menu.items[3].isSeparatorItem)
    func run(_ index: Int) {
        let item = menu.items[index]
        _ = (item.target as AnyObject?)?.perform(item.action, with: item)
    }
    run(0)
    #expect(opened == [URL(string: "https://s.example")!])
    // 「編集」はクリックした位置にキャレットを置く(記号が現れて編集できる)
    run(2)
    #expect(textView.selectedRange() == hit.editCaret)
    #expect(NSLocationInRange(hit.editCaret.location, NSRange(location: 3, length: 25)))
}

// MARK: - Front Matter の表

@MainActor @Test func frontMatterTableLinksURLValuesAndChips() throws {
    let markdown = "---\nsource: https://example.com/a\ntags: [x, https://b.example]\nplain: text\npair: [https://a.example https://c.example]\n---\n\nbody\n"
    let (window, textView) = makeFocusedTextView(markdown)
    defer { withExtendedLifetime(window) {} }
    var opened: [URL] = []
    textView.onOpenLink = { opened.append($0); return true }
    textView.setSelectedRange(NSRange(location: (markdown as NSString).length - 2, length: 0))
    textView.layoutSubtreeIfNeeded()
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    let entry = try #require(textView.debugFrontMatterEntry)
    let rows = entry.layout.rows
    try #require(rows.count == 4)
    // URL の値はリンクの色と印を持つ
    let value = try #require(rows[0].value)
    #expect(value.attribute(PreviewLinkAttribute.url, at: 0, effectiveRange: nil) as? String == "https://example.com/a")
    #expect(value.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == entry.appearance.linkColor)
    #expect(rows[2].value?.attribute(PreviewLinkAttribute.url, at: 0, effectiveRange: nil) == nil)

    func tablePoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: entry.frame.minX + x, y: entry.frame.minY + y) }
    let onURL = tablePoint(rows[0].valueFrame.minX + 10, rows[0].valueFrame.midY)
    let hit = try #require(textView.linkHit(atPoint: onURL))
    #expect(hit.target == .url(destination: "https://example.com/a"))
    #expect(hit.isRendered)
    #expect(hit.editCaret == NSRange(location: 33, length: 0))  // "source:" の行末
    #expect(textView.openRenderedLink(atPoint: onURL))
    #expect(opened == [URL(string: "https://example.com/a")!])
    // リストの URL のチップ
    let chip = rows[1].chips[1]
    #expect(textView.linkHit(atPoint: tablePoint(chip.frame.midX, chip.frame.midY))?.target == .url(destination: "https://b.example"))
    // 1 つのチップに URL が 2 つあれば、押した方の URL
    let pair = rows[3].chips[0]
    let pairText = pair.frame.insetBy(dx: FrontMatterTableLayout.chipHorizontalPadding, dy: FrontMatterTableLayout.chipVerticalPadding)
    let firstWidth = pair.text.attributedSubstring(from: NSRange(location: 0, length: 18)).size().width
    #expect(textView.linkHit(atPoint: tablePoint(pairText.minX + 10, pairText.midY))?.target == .url(destination: "https://a.example"))
    #expect(textView.linkHit(atPoint: tablePoint(pairText.minX + firstWidth + 10, pairText.midY))?.target == .url(destination: "https://c.example"))
    // URL でない値・キー・URL でないチップはリンクではない(従来どおりクリックで展開)
    #expect(textView.linkHit(atPoint: tablePoint(rows[2].valueFrame.minX + 5, rows[2].valueFrame.midY)) == nil)
    #expect(textView.linkHit(atPoint: tablePoint(rows[0].keyFrame.minX + 5, rows[0].keyFrame.midY)) == nil)
    #expect(textView.linkHit(atPoint: tablePoint(rows[1].chips[0].frame.midX, rows[1].chips[0].frame.midY)) == nil)
    #expect(textView.frontMatterController.isCollapsed, "opening a link does not expand the table")
}

// MARK: - テーブルの格子

@MainActor @Test func tableGridCellLinksOpenAndTheRestOfTheTableStillExpands() throws {
    let markdown = "intro\n\n| a | b |\n|---|---|\n| [site](https://s.example) | [[Note]] |\n\nafter\n"
    let (window, textView) = makeFocusedTextView(markdown)
    defer { withExtendedLifetime(window) {} }
    var opened: [URL] = []
    var openedNotes: [String] = []
    textView.onOpenLink = { opened.append($0); return true }
    textView.onOpenWikiLink = { openedNotes.append($0.target); return true }
    textView.setSelectedRange(NSRange(location: (markdown as NSString).length - 2, length: 0))
    textView.layoutSubtreeIfNeeded()
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    let entry = try #require(textView.debugTableEntries.first)
    let body = entry.layout.rows[1]
    func onText(of cell: TablePreviewLayout.Cell) -> CGPoint {
        CGPoint(x: entry.frame.minX + cell.textFrame.minX + 4, y: entry.frame.minY + cell.textFrame.midY)
    }
    let hit = try #require(textView.linkHit(atPoint: onText(of: body.cells[0])))
    #expect(hit.target == .url(destination: "https://s.example"))
    #expect(hit.isRendered)
    #expect(textView.openRenderedLink(atPoint: onText(of: body.cells[0])))
    #expect(opened == [URL(string: "https://s.example")!])
    #expect(textView.openRenderedLink(atPoint: onText(of: body.cells[1])))
    #expect(openedNotes == ["Note"])
    #expect(textView.tablePreviewController.isCollapsed(tableAt: 7), "opening a link does not expand the table")
    // リンクの無いセル(ヘッダー)は従来どおり展開する
    let header = entry.layout.rows[0].cells[0]
    #expect(textView.linkHit(atPoint: onText(of: header)) == nil)
    #expect(textView.expandTable(atPoint: onText(of: header)))
}
#endif
