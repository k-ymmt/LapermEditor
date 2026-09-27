#if os(macOS)
import AppKit
import Testing
@testable import LapermEditor
@testable import LapermCore

@MainActor
private func makeTextView(_ markdown: String) -> MarkdownTextView {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = markdown
    textView.highlightAll()
    return textView
}

@MainActor
private func renderingColor(at offset: Int, in textView: MarkdownTextView) -> NSColor? {
    let layoutManager = textView.textLayoutManager!
    let contentManager = layoutManager.textContentManager!
    guard let location = contentManager.location(contentManager.documentRange.location, offsetBy: offset) else { return nil }
    var color: NSColor?
    layoutManager.enumerateRenderingAttributes(from: location, reverse: false) { _, attributes, _ in
        color = attributes[.foregroundColor] as? NSColor
        return false
    }
    return color
}

@MainActor @Test func commandClickOnWikiLinkPassesTheReferenceToTheHost() {
    let textView = makeTextView("See [[Some Note#Sec|label]] now.")
    var opened: WikiLinkReference?
    textView.onOpenWikiLink = { opened = $0; return true }
    var urlOpened = false
    textView.onOpenLink = { _ in urlOpened = true; return true }
    let point = midpoint(of: NSRange(location: 6, length: 4), in: textView)
    #expect(textView.openLink(atPoint: point))
    #expect(opened?.target == "Some Note")
    #expect(opened?.heading == "Sec")
    #expect(opened?.alias == "label")
    #expect(!urlOpened)
}

@MainActor @Test func commandClickOnWikiLinkWithoutHostHookDoesNothing() {
    let textView = makeTextView("[[Note]]")
    var urlOpened = false
    textView.onOpenLink = { _ in urlOpened = true; return true }
    let point = midpoint(of: NSRange(location: 2, length: 4), in: textView)
    #expect(!textView.openLink(atPoint: point))
    #expect(!urlOpened)
}

@MainActor @Test func commandClickOutsideWikiLinkDoesNotOpen() {
    let textView = makeTextView("See [[Note]] now.")
    var opened: WikiLinkReference?
    textView.onOpenWikiLink = { opened = $0; return true }
    let point = midpoint(of: NSRange(location: 0, length: 3), in: textView)
    #expect(!textView.openLink(atPoint: point))
    #expect(opened == nil)
}

@MainActor @Test func commandHoverUnderlinesWikiLink() {
    let textView = makeTextView("See [[Note]] now.")
    let range = NSRange(location: 4, length: 8)
    textView.refreshLinkHover(atPoint: midpoint(of: NSRange(location: 6, length: 4), in: textView), commandHeld: true)
    #expect(textView.debugHoveredLinkRange == range)
    textView.refreshLinkHover(atPoint: midpoint(of: NSRange(location: 6, length: 4), in: textView), commandHeld: false)
    #expect(textView.debugHoveredLinkRange == nil)
}

@MainActor @Test func unresolvedWikiLinkIsDrawnInTheUnresolvedColorAndMarkersKeepTheirs() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.wikiLinkResolver = { $0.target == "Missing" ? .unresolved : .resolved }
    textView.string = "[[Missing]] and [[Present]]"
    textView.highlightAll()
    let theme = textView.theme
    #expect(renderingColor(at: 3, in: textView) == theme.effectiveUnresolvedLinkColor)
    #expect(renderingColor(at: 18, in: textView) == theme.style(for: .wikiLink)?.foregroundColor)
    // `[[` は Syntax Marker の色のまま(Wiki Link の色で上書きされない)
    #expect(renderingColor(at: 0, in: textView) == theme.style(for: .syntaxMarker)?.foregroundColor)
}

@MainActor @Test func refreshWikiLinkResolutionRecolorsWithoutReparsing() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    var existing: Set<String> = []
    textView.wikiLinkResolver = { existing.contains($0.target) ? .resolved : .unresolved }
    textView.string = "x [[New Note]] y"
    textView.highlightAll()
    let theme = textView.theme
    #expect(renderingColor(at: 5, in: textView) == theme.effectiveUnresolvedLinkColor)
    existing.insert("New Note")
    textView.refreshWikiLinkResolution()
    #expect(renderingColor(at: 5, in: textView) == theme.style(for: .wikiLink)?.foregroundColor)
    #expect(renderingColor(at: 2, in: textView) == theme.style(for: .syntaxMarker)?.foregroundColor)
    existing.remove("New Note")
    textView.refreshWikiLinkResolution()
    #expect(renderingColor(at: 5, in: textView) == theme.effectiveUnresolvedLinkColor)
}

@MainActor @Test func unknownResolutionUsesTheNormalLinkColor() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.wikiLinkResolver = { _ in .unknown }
    textView.string = "[[Note]]"
    textView.highlightAll()
    #expect(renderingColor(at: 3, in: textView) == textView.theme.style(for: .wikiLink)?.foregroundColor)
}

@MainActor @Test func highlightPlanChangeDeliversWikiLinks() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    var plans: [(HighlightPlan, String)] = []
    textView.onHighlightPlanChange = { plans.append(($0, $1)) }
    textView.string = "[[A]] and [[B]]"
    textView.highlightAll()
    #expect(plans.last?.0.wikiLinks.map(\.target) == ["A", "B"])
    #expect(plans.last?.1 == "[[A]] and [[B]]")
}

@Test func unresolvedLinkColorFallsBackToTranslucentLinkColor() {
    let theme = MarkdownTheme.default
    let link = theme.style(for: .wikiLink)!.foregroundColor!
    #expect(theme.effectiveUnresolvedLinkColor == link.withAlphaComponent(0.5))
    var custom = theme
    custom.unresolvedLinkColor = .systemRed
    #expect(custom.effectiveUnresolvedLinkColor == .systemRed)
    #expect(custom.unresolvedWikiLinkRenderingAttributes()[.foregroundColor] as? NSColor == .systemRed)
}
#endif

#if os(macOS)
@MainActor @Test func refreshWikiLinkResolutionWaitsWhileIMEIsComposing() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    var existing: Set<String> = []
    textView.wikiLinkResolver = { existing.contains($0.target) ? .resolved : .unresolved }
    textView.string = "[[Note]] "
    textView.highlightAll()
    let theme = textView.theme
    #expect(renderingColor(at: 3, in: textView) == theme.effectiveUnresolvedLinkColor)
    // 変換中(marked text)は色を触らない
    textView.setSelectedRange(NSRange(location: 9, length: 0))
    textView.setMarkedText("か", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: 9, length: 0))
    existing.insert("Note")
    textView.refreshWikiLinkResolution()
    #expect(renderingColor(at: 3, in: textView) == theme.effectiveUnresolvedLinkColor)
    // 確定後の flush(確定で入った編集のパース)で付け直される
    textView.unmarkText()
    textView.engine.highlightNow()
    #expect(renderingColor(at: 3, in: textView) == theme.style(for: .wikiLink)?.foregroundColor)
}
#endif

#if os(macOS)
// MARK: - codex レビュー後

@MainActor @Test func refreshKeepsSiblingSpansAndMarkersUntouched() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    var existing: Set<String> = []
    textView.wikiLinkResolver = { existing.contains($0.target) ? .resolved : .unresolved }
    textView.string = "# [[Note]] and [site](https://example.org)\n> [[Note]] quoted"
    textView.highlightAll()
    let theme = textView.theme
    let linkColor = theme.style(for: .link)?.foregroundColor
    let markerColor = theme.style(for: .syntaxMarker)?.foregroundColor
    #expect(renderingColor(at: 4, in: textView) == theme.effectiveUnresolvedLinkColor)
    #expect(renderingColor(at: 16, in: textView) == linkColor)  // "site"
    #expect(renderingColor(at: 0, in: textView) == markerColor)  // "#"
    existing.insert("Note")
    textView.refreshWikiLinkResolution()
    #expect(renderingColor(at: 4, in: textView) == theme.style(for: .wikiLink)?.foregroundColor)
    #expect(renderingColor(at: 16, in: textView) == linkColor, "the sibling Markdown Link keeps its colour")
    #expect(renderingColor(at: 0, in: textView) == markerColor, "the heading marker keeps its colour")
    #expect(renderingColor(at: 2, in: textView) == markerColor, "[[ keeps the marker colour")
    let quoteStart = ("# [[Note]] and [site](https://example.org)\n" as NSString).length
    #expect(renderingColor(at: quoteStart + 4, in: textView) == theme.style(for: .wikiLink)?.foregroundColor)
    #expect(renderingColor(at: quoteStart + 11, in: textView) == theme.style(for: .blockquote)?.foregroundColor, "quoted text after the link keeps the blockquote colour")
}

@MainActor @Test func themeWithoutWikiLinkStyleFallsBackToLinkAndRecoversFromUnresolved() {
    var theme = MarkdownTheme.default
    theme.styles[.wikiLink] = nil
    let textView = MarkdownTextView(theme: theme)
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    var existing: Set<String> = []
    textView.wikiLinkResolver = { existing.contains($0.target) ? .resolved : .unresolved }
    textView.string = "[[Note]]"
    textView.highlightAll()
    #expect(theme.style(for: .wikiLink)?.foregroundColor == theme.style(for: .link)?.foregroundColor)
    #expect(renderingColor(at: 3, in: textView) == theme.effectiveUnresolvedLinkColor)
    existing.insert("Note")
    textView.refreshWikiLinkResolution()
    #expect(renderingColor(at: 3, in: textView) == theme.style(for: .link)?.foregroundColor)
}

@MainActor @Test func refreshDeferredDuringIMEIsAppliedAfterComposition() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    var existing: Set<String> = []
    textView.wikiLinkResolver = { existing.contains($0.target) ? .resolved : .unresolved }
    textView.string = "[[Note]]\n\nother"
    textView.highlightAll()
    let theme = textView.theme
    textView.setSelectedRange(NSRange(location: 10, length: 0))
    textView.setMarkedText("か", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: 10, length: 0))
    existing.insert("Note")
    textView.refreshWikiLinkResolution()
    #expect(renderingColor(at: 3, in: textView) == theme.effectiveUnresolvedLinkColor)
    // 確定(unmarkText → scheduleHighlight → highlightNow)で、明示的に refresh を呼び直さなくても付け直される
    textView.unmarkText()
    textView.engine.highlightNow()
    #expect(renderingColor(at: 3, in: textView) == theme.style(for: .wikiLink)?.foregroundColor)
}

@MainActor @Test func highlightPlanChangeIsNotSentForThemeChanges() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    var count = 0
    textView.onHighlightPlanChange = { _, _ in count += 1 }
    textView.string = "[[A]]"
    textView.highlightAll()
    #expect(count == 1)
    var theme = textView.theme
    theme.lineSpacing = 3
    textView.theme = theme
    #expect(count == 1, "a theme change reuses the plan and must not notify")
}

@MainActor @Test func hoverUnderlineUsesTheResolvedWikiLinkColor() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.wikiLinkResolver = { $0.target == "Missing" ? .unresolved : .resolved }
    textView.string = "[[Missing]] [[Present]] [site](https://example.org)"
    textView.highlightAll()
    let theme = textView.theme
    textView.refreshLinkHover(atPoint: midpoint(of: NSRange(location: 2, length: 7), in: textView), commandHeld: true)
    #expect(textView.debugLinkHoverColor == theme.effectiveUnresolvedLinkColor)
    textView.refreshLinkHover(atPoint: midpoint(of: NSRange(location: 14, length: 7), in: textView), commandHeld: true)
    #expect(textView.debugLinkHoverColor == theme.style(for: .wikiLink)?.foregroundColor)
    textView.refreshLinkHover(atPoint: midpoint(of: NSRange(location: 25, length: 4), in: textView), commandHeld: true)
    #expect(textView.debugLinkHoverColor == theme.style(for: .link)?.foregroundColor)
}

@MainActor @Test func collapsedTableCellShowsTheUnresolvedColor() {
    let md = "| h |\n|---|\n| [[Missing]] |\n"
    let plan = MarkdownParser().highlightPlan(for: md)
    let table = plan.tables[0]
    let theme = MarkdownTheme.default
    let storage = NSMutableAttributedString(string: md)
    let unresolved = plan.wikiLinks.map(\.range)
    let model = TablePreviewModel.make(table: table, storage: storage, spans: plan.spans, markers: plan.concealableMarkers, unresolvedWikiLinks: unresolved, theme: theme)!
    let cell = model.rows[0].cells[0].text
    #expect(cell.string == "Missing")
    #expect(cell.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == theme.effectiveUnresolvedLinkColor)
    let resolved = TablePreviewModel.make(table: table, storage: storage, spans: plan.spans, markers: plan.concealableMarkers, theme: theme)!
    #expect(resolved.rows[0].cells[0].text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == theme.style(for: .wikiLink)?.foregroundColor)
}
#endif

#if os(macOS)
// MARK: - codex レビュー第 2 ラウンド後

@MainActor @Test func refreshDeferredDuringIMEIsAppliedAfterABackgroundParse() async {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    var existing: Set<String> = []
    textView.wikiLinkResolver = { existing.contains($0.target) ? .resolved : .unresolved }
    textView.string = "[[Note]]\n\nother"
    textView.highlightAll()
    let theme = textView.theme
    textView.markdownHighlighter.backgroundParseThreshold = .zero  // 以後の flush は背景経路
    textView.setSelectedRange(NSRange(location: 10, length: 0))
    textView.setMarkedText("か", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: 10, length: 0))
    existing.insert("Note")
    textView.refreshWikiLinkResolution()
    #expect(renderingColor(at: 3, in: textView) == theme.effectiveUnresolvedLinkColor)
    textView.unmarkText()
    textView.engine.highlightNow()  // → .deferredToBackground
    #expect(renderingColor(at: 3, in: textView) == theme.effectiveUnresolvedLinkColor, "still pending while the background parse runs")
    await textView.markdownHighlighter.activeBackgroundParse?.value
    #expect(renderingColor(at: 3, in: textView) == theme.style(for: .wikiLink)?.foregroundColor, "the deferred refresh is drained after the background parse")
}

@MainActor @Test func refreshWaitsForPendingEditsSoHeadingFontsSurvive() {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    var existing: Set<String> = []
    textView.wikiLinkResolver = { existing.contains($0.target) ? .resolved : .unresolved }
    textView.string = "# [[A]] title"
    textView.highlightAll()
    let theme = textView.theme
    let headingFont = theme.style(for: .heading(level: 1))?.font
    // "title" を編集: 見出しスパンは捨てられ、次の flush までパース待ち
    textView.setSelectedRange(NSRange(location: 13, length: 0))
    textView.insertText("Z", replacementRange: NSRange(location: 13, length: 0))
    existing.insert("A")
    textView.refreshWikiLinkResolution()
    let storage = textView.textStorage!
    #expect(storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont == headingFont, "the wiki link keeps the heading font while the parse is pending")
    textView.engine.highlightNow()
    #expect(storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont == headingFont)
    #expect(renderingColor(at: 4, in: textView) == theme.style(for: .wikiLink)?.foregroundColor, "the deferred refresh is applied by the flush")
}

@MainActor @Test func tableResolutionOnlyAsksForLinksInsideTables() {
    var asked: [String] = []
    let highlighter = Highlighter(theme: .default)
    highlighter.wikiLinkResolver = { asked.append($0.target); return .unresolved }
    let (contentStorage, layoutManager) = makeStack("[[Outside]]\n\n| h |\n|---|\n| [[Inside]] |\n\n[[After]]")
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)
    asked = []
    #expect(highlighter.unresolvedWikiLinkRanges(within: []).isEmpty)
    #expect(asked.isEmpty, "no tables: the resolver is not called")
    let ranges = highlighter.unresolvedWikiLinkRanges(within: highlighter.currentPlan.tables.map(\.range))
    #expect(asked == ["Inside"])
    #expect(ranges.count == 1)
}

@MainActor
private func makeStack(_ text: String) -> (NSTextContentStorage, NSTextLayoutManager) {
    let contentStorage = NSTextContentStorage()
    let layoutManager = NSTextLayoutManager()
    contentStorage.addTextLayoutManager(layoutManager)
    layoutManager.textContainer = NSTextContainer(size: CGSize(width: 400, height: 0))
    contentStorage.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
    return (contentStorage, layoutManager)
}

@MainActor @Test func collapsedTableCellColorsUnresolvedLinksEvenWithoutAWikiLinkColor() {
    var theme = MarkdownTheme.default
    theme.styles[.wikiLink] = MarkdownTheme.Style(font: theme.bodyFont)
    theme.styles[.link] = nil
    theme.unresolvedLinkColor = .systemRed
    let md = "| h |\n|---|\n| [[Missing]] |\n"
    let plan = MarkdownParser().highlightPlan(for: md)
    let model = TablePreviewModel.make(
        table: plan.tables[0], storage: NSAttributedString(string: md), spans: plan.spans, markers: plan.concealableMarkers,
        unresolvedWikiLinks: plan.wikiLinks.map(\.range), theme: theme)!
    #expect(model.rows[0].cells[0].text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemRed)
}
#endif
