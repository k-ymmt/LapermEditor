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
    var plans: [HighlightPlan] = []
    textView.onHighlightPlanChange = { plans.append($0) }
    textView.string = "[[A]] and [[B]]"
    textView.highlightAll()
    #expect(plans.last?.wikiLinks.map(\.target) == ["A", "B"])
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
