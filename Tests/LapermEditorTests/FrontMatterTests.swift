#if os(macOS)
import AppKit
import Testing
@testable import LapermEditor
@testable import LapermCore

// テキスト: "---\n"(0-3) "title: Foo\n"(4-14) "tags:\n"(15-20) "  - a\n"(21-26) "  - b\n"(27-32) "---\n"(33-36) "# H\n"(37-40) "body"(41-44)
private let sample = "---\ntitle: Foo\ntags:\n  - a\n  - b\n---\n# H\nbody"

// MARK: - FrontMatterController

@MainActor @Test func controllerCollapsesOnlyWhenEnabledUnfocusedOrCaretOutside() throws {
    let controller = FrontMatterController(theme: .default)
    let fm = try #require(FrontMatterParser.parse(sample))
    controller.containerWidthDidChange(400)
    controller.update(frontMatter: fm, text: sample as NSString)
    #expect(!controller.isCollapsed, "Source(無効)では展開")
    #expect(controller.takePendingDirtyRanges().isEmpty)

    // 有効にする: キャレットは既定で空(どこにも触れない)→ 折りたたむ。ブロック全体(閉じの改行まで)を作り直す
    controller.setEnabled(true)
    #expect(controller.isCollapsed)
    #expect(controller.takePendingDirtyRanges() == [NSRange(location: 0, length: 37)])
    #expect(controller.layout?.rows.count == 2)
    #expect(controller.layout?.reservedHeight ?? 0 > 0)

    // キャレットが本文にある: 折りたたみのまま(変化なし → 作り直し無し)
    controller.selectionDidChange([NSRange(location: 42, length: 0)])
    #expect(controller.isCollapsed)
    #expect(controller.takePendingDirtyRanges().isEmpty)

    // キャレットが閉じの --- の行末(36)に来る: ブロックに触れる → 展開
    controller.selectionDidChange([NSRange(location: 36, length: 0)])
    #expect(!controller.isCollapsed)
    #expect(controller.layout == nil)
    #expect(controller.takePendingDirtyRanges() == [NSRange(location: 0, length: 37)])
    // 閉じの改行の次(37 = 本文の行頭)は触れない
    controller.selectionDidChange([NSRange(location: 37, length: 0)])
    #expect(controller.isCollapsed)
    _ = controller.takePendingDirtyRanges()
    // ブロックの途中から始まる選択も触れる
    controller.selectionDidChange([NSRange(location: 10, length: 40)])
    #expect(!controller.isCollapsed)
    _ = controller.takePendingDirtyRanges()

    // フォーカスを失うとキャレットがブロック内でも折りたたむ、戻ると展開
    controller.editorFocusDidChange(false)
    #expect(controller.isCollapsed)
    controller.editorFocusDidChange(true)
    #expect(!controller.isCollapsed)
    _ = controller.takePendingDirtyRanges()

    // 無効化で展開
    controller.selectionDidChange([NSRange(location: 42, length: 0)])
    #expect(controller.isCollapsed)
    controller.setEnabled(false)
    #expect(!controller.isCollapsed)
}

@MainActor @Test func controllerNeverCollapsesAnEmptyFrontMatterOrMissingOne() throws {
    let controller = FrontMatterController(theme: .default)
    controller.setEnabled(true)
    controller.containerWidthDidChange(400)
    controller.update(frontMatter: nil, text: "body")
    #expect(!controller.isCollapsed)
    let empty = try #require(FrontMatterParser.parse("---\n---\nbody"))
    controller.update(frontMatter: empty, text: "---\n---\nbody")
    #expect(!controller.isCollapsed, "Property が 0 件なら折りたたまない")
    let comments = try #require(FrontMatterParser.parse("---\n# only a comment\n---\n"))
    controller.update(frontMatter: comments, text: "---\n# only a comment\n---\n")
    #expect(!controller.isCollapsed)
    #expect(controller.takePendingDirtyRanges().isEmpty)
}

@MainActor @Test func controllerRegeneratesOnlyTheOpeningParagraphWhenTheHeightChanges() throws {
    let controller = FrontMatterController(theme: .default)
    let text = "---\ntags: [alpha, beta, gamma, delta, epsilon, zeta, eta, theta, iota, kappa]\n---\nbody"
    let fm = try #require(FrontMatterParser.parse(text))
    controller.setEnabled(true)
    controller.containerWidthDidChange(600)
    controller.update(frontMatter: fm, text: text as NSString)
    #expect(controller.isCollapsed)
    let wide = try #require(controller.layout?.reservedHeight)
    _ = controller.takePendingDirtyRanges()
    // 幅を狭めるとチップが折り返して高くなる → 開きの段落(0..<3)だけ作り直す
    controller.containerWidthDidChange(200)
    let narrow = try #require(controller.layout?.reservedHeight)
    #expect(narrow > wide)
    #expect(controller.takePendingDirtyRanges() == [NSRange(location: 0, length: 3)])
    // 同じ幅なら何もしない
    controller.containerWidthDidChange(200)
    #expect(controller.takePendingDirtyRanges().isEmpty)
    #expect(!controller.takeNeedsRedraw())
}

@MainActor @Test func controllerHidesInnerParagraphsAndBuildsTheOpeningDisplayParagraph() throws {
    let controller = FrontMatterController(theme: .default)
    let fm = try #require(FrontMatterParser.parse(sample))
    controller.setEnabled(true)
    controller.containerWidthDidChange(400)
    controller.update(frontMatter: fm, text: sample as NSString)
    #expect(controller.shouldEnumerate(paragraphStartingAt: 0))
    for offset in [4, 15, 21, 27, 33] { #expect(!controller.shouldEnumerate(paragraphStartingAt: offset)) }
    #expect(controller.shouldEnumerate(paragraphStartingAt: 37))
    #expect(controller.reservedHeight(forParagraph: NSRange(location: 0, length: 4)) == controller.layout?.reservedHeight)
    #expect(controller.reservedHeight(forParagraph: NSRange(location: 4, length: 11)) == nil)

    let contentStorage = NSTextContentStorage()
    contentStorage.textStorage?.setAttributedString(NSAttributedString(string: sample, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
    let paragraph = try #require(controller.textParagraph(with: NSRange(location: 0, length: 4), in: contentStorage))
    #expect(paragraph.attributedString.string == "---\n")
    #expect((paragraph.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == LivePreviewConcealer.hiddenFontSize)
    let style = try #require(paragraph.attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
    #expect(style.paragraphSpacing == controller.layout?.reservedHeight)
    #expect(controller.textParagraph(with: NSRange(location: 4, length: 11), in: contentStorage) == nil)

    // 表座標 → Property の行。1 行目は title、2 行目は tags(リストの行は末尾の項目まで)
    let layout = try #require(controller.layout)
    #expect(controller.lineRange(atTablePoint: CGPoint(x: 10, y: layout.rows[0].frame.midY)) == NSRange(location: 4, length: 10))
    #expect(controller.lineRange(atTablePoint: CGPoint(x: 10, y: layout.rows[1].frame.midY)) == NSRange(location: 15, length: 17))
    #expect(controller.lineRange(atTablePoint: CGPoint(x: 10, y: layout.size.height + 50)) == nil)
}

// MARK: - FrontMatterTableLayout

@MainActor @Test func layoutBuildsRowsChipsAndRawLines() throws {
    let text = "---\ntitle: Foo\ntags: [a, b]\n  nested: x\nempty:\n---\n"
    let fm = try #require(FrontMatterParser.parse(text))
    let layout = FrontMatterTableLayout.make(frontMatter: fm, width: 400, appearance: .init(theme: .default))
    #expect(layout.rows.count == 4)
    #expect(layout.size.width == 400)
    #expect(layout.rows[0].key?.string == "title")
    #expect(layout.rows[0].value?.string == "Foo")
    #expect(layout.rows[0].chips.isEmpty)
    #expect(layout.rows[1].chips.map(\.text.string) == ["a", "b"])
    #expect(layout.rows[1].value == nil)
    #expect(layout.rows[2].key == nil, "解釈できない行はキー列が空")
    #expect(layout.rows[2].value?.string == "  nested: x")
    #expect(layout.rows[3].value?.string == "")
    // 行は隙間なく縦に並び、値の列はキーの列の右
    #expect(layout.rows[1].frame.minY == layout.rows[0].frame.maxY)
    #expect(layout.size.height == layout.rows.last!.frame.maxY)
    #expect(layout.rows[0].valueFrame.minX > layout.rows[0].keyFrame.maxX)
    #expect(layout.rows[1].chips[1].frame.minX > layout.rows[1].chips[0].frame.maxX)
    #expect(layout.rows.allSatisfy { $0.frame.height >= FrontMatterTableLayout.lineHeight(of: MarkdownTheme.default.bodyFont) })
    #expect(layout.reservedHeight == layout.size.height + FrontMatterTableLayout.bottomMargin)
    // 幅が無いときは既定幅
    #expect(FrontMatterTableLayout.make(frontMatter: fm, width: 0, appearance: .init(theme: .default)).size.width == FrontMatterTableLayout.fallbackWidth)
    // 行の間・外の判定
    #expect(layout.row(at: CGPoint(x: 5, y: layout.rows[2].frame.minY + 1))?.lineRange == fm.properties[2].lineRange)
    #expect(layout.row(at: CGPoint(x: 5, y: -20)) == nil)
    #expect(layout.row(at: CGPoint(x: 5, y: -2))?.lineRange == fm.properties[0].lineRange)
}

@MainActor @Test func layoutWrapsChipsAndLongValuesWithinTheValueColumn() throws {
    let text = "---\ntags: [alpha, beta, gamma, delta, epsilon, zeta, eta, theta]\ndescription: " + String(repeating: "word ", count: 40) + "\n---\n"
    let fm = try #require(FrontMatterParser.parse(text))
    let layout = FrontMatterTableLayout.make(frontMatter: fm, width: 240, appearance: .init(theme: .default))
    let chips = layout.rows[0].chips
    #expect(Set(chips.map(\.frame.minY)).count > 1, "チップは折り返す")
    #expect(chips.allSatisfy { $0.frame.maxX <= layout.rows[0].valueFrame.maxX + 0.5 })
    #expect(layout.rows[1].valueFrame.height > FrontMatterTableLayout.lineHeight(of: MarkdownTheme.default.bodyFont) * 2)
}

// MARK: - MarkdownTextView(AppKit)

@MainActor
private func makeFocusedTextView(_ markdown: String, livePreview: Bool = true) -> (NSWindow, MarkdownTextView) {
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    scrollView.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = scrollView
    textView.string = markdown
    textView.highlightAll()
    textView.isLivePreviewEnabled = livePreview
    #expect(window.makeFirstResponder(textView))
    return (window, textView)
}

@MainActor
private func enumeratedOffsets(_ textView: MarkdownTextView) -> [Int] {
    let contentManager = textView.textLayoutManager!.textContentManager!
    var offsets: [Int] = []
    contentManager.enumerateTextElements(from: contentManager.documentRange.location) { element in
        if let location = element.elementRange?.location {
            offsets.append(contentManager.offset(from: contentManager.documentRange.location, to: location))
        }
        return true
    }
    return offsets
}

@MainActor
private func layoutFragments(_ textView: MarkdownTextView) -> [NSTextLayoutFragment] {
    let layoutManager = textView.textLayoutManager!
    layoutManager.ensureLayout(for: layoutManager.documentRange)
    var fragments: [NSTextLayoutFragment] = []
    layoutManager.enumerateTextLayoutFragments(from: nil, options: []) { fragments.append($0); return true }
    return fragments
}

@MainActor @Test func textViewCollapsesFrontMatterIntoATableAndExpandsWhenTheCaretEnters() throws {
    let (window, textView) = makeFocusedTextView(sample)
    defer { withExtendedLifetime(window) {} }
    textView.setSelectedRange(NSRange(location: 42, length: 0))  // body
    textView.layoutSubtreeIfNeeded()
    #expect(textView.frontMatterController.isCollapsed)

    // 開きの --- 以外のブロックの段落は列挙されない
    let offsets = enumeratedOffsets(textView)
    #expect(offsets.contains(0))
    #expect(!offsets.contains(4) && !offsets.contains(15) && !offsets.contains(33))
    #expect(offsets.contains(37))

    // 開きの段落のフラグメントは高さほぼ 0 の行 + 表の予約高さ。本文はその下から始まる
    let fragments = layoutFragments(textView)
    let opening = try #require(fragments.first)
    let reserved = try #require(textView.frontMatterController.layout?.reservedHeight)
    let textLinesBottom = opening.textLineFragments.reduce(0) { max($0, $1.typographicBounds.maxY) }
    #expect(textLinesBottom < 1, "極小フォントの行は高さほぼ 0")
    #expect(abs(opening.layoutFragmentFrame.height - (textLinesBottom + reserved)) < 1)
    let heading = try #require(fragments.dropFirst().first)
    #expect(heading.layoutFragmentFrame.minY >= opening.layoutFragmentFrame.maxY - 0.5)

    // ビューポートレイアウトで表が置かれる
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    let entry = try #require(textView.debugFrontMatterEntry)
    #expect(entry.layout.rows.count == 2)
    #expect(entry.frame.minY >= opening.layoutFragmentFrame.minY)
    #expect(entry.frame.height == entry.layout.size.height)

    // 表の 2 行目(tags)をクリック: その行末にキャレットが置かれ、ブロックが展開される
    let clickPoint = CGPoint(x: entry.frame.minX + 20, y: entry.frame.minY + entry.layout.rows[1].frame.midY)
    #expect(textView.expandFrontMatter(atPoint: clickPoint))
    #expect(textView.selectedRange() == NSRange(location: 20, length: 0))  // "tags:" の行末
    #expect(!textView.frontMatterController.isCollapsed)
    #expect(Set(enumeratedOffsets(textView)).isSuperset(of: [0, 4, 15, 21, 27, 33, 37]))
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    #expect(textView.debugFrontMatterEntry == nil)
    // 展開中は開きの段落が普通の高さで見える(Source と同じ)
    let expanded = try #require(layoutFragments(textView).first)
    #expect(expanded.textLineFragments.first!.typographicBounds.height > 5)
    // 表の外のクリックは何もしない
    #expect(!textView.expandFrontMatter(atPoint: CGPoint(x: 10, y: 250)))

    // キャレットが本文へ戻ると再び折りたたまれる
    textView.setSelectedRange(NSRange(location: 42, length: 0))
    #expect(textView.frontMatterController.isCollapsed)
    #expect(!enumeratedOffsets(textView).contains(4))
    #expect(textView.string == sample, "テキストは終始そのまま")
}

@MainActor @Test func textViewCollapsesWhenTheEditorLosesFocusEvenWithTheCaretInside() throws {
    let (window, textView) = makeFocusedTextView(sample)
    defer { withExtendedLifetime(window) {} }
    textView.setSelectedRange(NSRange(location: 6, length: 0))  // title の行
    #expect(!textView.frontMatterController.isCollapsed)
    #expect(window.makeFirstResponder(nil))
    #expect(textView.frontMatterController.isCollapsed)
    #expect(!enumeratedOffsets(textView).contains(4))
    #expect(window.makeFirstResponder(textView))
    #expect(!textView.frontMatterController.isCollapsed)
}

@MainActor @Test func textViewNeverCollapsesInSourceAndFollowsTheToggle() throws {
    let (window, textView) = makeFocusedTextView(sample, livePreview: false)
    defer { withExtendedLifetime(window) {} }
    textView.setSelectedRange(NSRange(location: 42, length: 0))
    #expect(!textView.frontMatterController.isCollapsed)
    #expect(enumeratedOffsets(textView).contains(4))
    textView.isLivePreviewEnabled = true
    #expect(textView.frontMatterController.isCollapsed)
    #expect(!enumeratedOffsets(textView).contains(4))
    textView.isLivePreviewEnabled = false
    #expect(!textView.frontMatterController.isCollapsed)
    #expect(enumeratedOffsets(textView).contains(4))
}

@MainActor @Test func textViewFollowsEditsThatCreateOrDestroyTheFrontMatter() throws {
    let (window, textView) = makeFocusedTextView("# H\nbody")
    defer { withExtendedLifetime(window) {} }
    textView.setSelectedRange(NSRange(location: 6, length: 0))
    #expect(!textView.frontMatterController.isCollapsed)
    // 先頭に Front Matter を挿入(キャレットは本文): 再パース後に折りたたまれる
    textView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 0), with: "---\na: 1\n---\n")
    textView.setSelectedRange(NSRange(location: 18, length: 0))
    textView.highlightNow()
    #expect(textView.frontMatterController.isCollapsed)
    #expect(!enumeratedOffsets(textView).contains(4))
    // 閉じの --- を壊す(キャレットをブロック内に置いてから編集 = 展開中の編集)
    textView.setSelectedRange(NSRange(location: 12, length: 0))
    #expect(!textView.frontMatterController.isCollapsed)
    textView.textStorage!.replaceCharacters(in: NSRange(location: 9, length: 3), with: "--")
    textView.highlightNow()
    #expect(textView.markdownHighlighter.currentPlan.frontMatter == nil)
    textView.setSelectedRange(NSRange(location: 15, length: 0))
    #expect(!textView.frontMatterController.isCollapsed)
    #expect(enumeratedOffsets(textView).contains(4))
}

@MainActor @Test func frontMatterBlockIsDecoratedLikeACodeBlockInSource() throws {
    let (window, textView) = makeFocusedTextView(sample, livePreview: false)
    defer { withExtendedLifetime(window) {} }
    let fragments = layoutFragments(textView)
    let opening = try #require(fragments.first as? CodeBlockFragment)
    #expect(opening.roundsTop && !opening.roundsBottom)
    #expect(opening.fillColor == MarkdownTheme.default.frontMatterBackgroundColor)
    let closing = try #require(fragments[5] as? CodeBlockFragment)
    #expect(!closing.roundsTop && closing.roundsBottom)
    #expect(!(fragments[6] is CodeBlockFragment))
    // キーは frontMatterKey の色、両端の --- は syntaxMarker
    let layoutManager = textView.textLayoutManager!
    #expect(renderingColor(at: 4, layoutManager) == MarkdownTheme.default.renderingColor(for: .frontMatterKey))
    #expect(renderingColor(at: 0, layoutManager) == MarkdownTheme.default.renderingColor(for: .syntaxMarker))
    #expect(renderingColor(at: 11, layoutManager) == MarkdownTheme.default.bodyColor, "値は本文色")
}

@MainActor
private func renderingColor(at offset: Int, _ layoutManager: NSTextLayoutManager) -> NSColor? {
    guard let contentManager = layoutManager.textContentManager,
          let location = contentManager.location(contentManager.documentRange.location, offsetBy: offset)
    else { return nil }
    var color: NSColor?
    layoutManager.enumerateRenderingAttributes(from: location, reverse: false) { _, attributes, _ in
        color = attributes[.foregroundColor] as? NSColor
        return false
    }
    return color
}

@MainActor @Test func themeFallsBackToTheCodeBlockBackground() {
    let theme = MarkdownTheme(
        bodyFont: .systemFont(ofSize: 12), bodyColor: .black, backgroundColor: .white,
        codeBlockBackgroundColor: .red, blockquoteBarColor: .gray, thematicBreakLineColor: .gray, styles: [:])
    #expect(theme.frontMatterBackgroundColor == .red)
    let explicit = MarkdownTheme(
        bodyFont: .systemFont(ofSize: 12), bodyColor: .black, backgroundColor: .white,
        codeBlockBackgroundColor: .red, blockquoteBarColor: .gray, thematicBreakLineColor: .gray, styles: [:],
        frontMatterBackgroundColor: .blue)
    #expect(explicit.frontMatterBackgroundColor == .blue)
}
#endif
