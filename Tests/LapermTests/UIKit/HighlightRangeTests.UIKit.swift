#if canImport(UIKit)
import Testing
import UIKit
@testable import Laperm
@testable import LapermCore

/// CJK 文字がマークアップより前にある行で、フォント(storage)と色(rendering)が
/// 正しい UTF-16 位置に適用されること(シミュレータ検証で色ズレが疑われたための回帰確認)。
@MainActor @Test func cjkBeforeMarkupKeepsAttributeRangesAligned() {
    // 本0 文1 sp2 *3 *4 強5 調6 *7 *8 sp9 `10 c11 o12 d13 e14 `15
    let textView = makeLaidOutTextView("本文 **強調** `code`")
    let storage = textView.textContentStorage!.textStorage!
    let strong = MarkdownTheme.default.style(for: .strong)?.font
    #expect(storage.attribute(.font, at: 5, effectiveRange: nil) as? UIFont == strong)
    #expect(storage.attribute(.font, at: 6, effectiveRange: nil) as? UIFont == strong)
    #expect(storage.attribute(.font, at: 11, effectiveRange: nil) as? UIFont == MarkdownTheme.default.bodyFont)
    let plan = textView.markdownHighlighter.currentPlan
    #expect(plan.spans.contains { $0.kind == .strong && $0.range == NSRange(location: 3, length: 6) }
            || plan.spans.contains { $0.kind == .strong && $0.range == NSRange(location: 5, length: 2) },
            "\(plan.spans)")
    #expect(plan.spans.contains { $0.kind == .inlineCode && $0.range.location == 10 }, "\(plan.spans)")

    // iOS では色も storage 側属性(UITextView の renderingAttributes 描画ズレ回避)
    func color(at offset: Int) -> UIColor? {
        storage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? UIColor
    }
    #expect(color(at: 3) == MarkdownTheme.default.renderingColor(for: .syntaxMarker))
    #expect(color(at: 11) == MarkdownTheme.default.renderingColor(for: .inlineCode), "\(String(describing: color(at: 11)))")
    #expect(color(at: 5) == MarkdownTheme.default.bodyColor)
}

@MainActor @Test func linkWithCJKTextGetsLinkColorAcrossWholeRange() {
    let md = "[インラインリンク](https://example.com/inline)"
    let textView = makeLaidOutTextView(md)
    let plan = textView.markdownHighlighter.currentPlan
    #expect(plan.links.first?.range == NSRange(location: 0, length: (md as NSString).length), "\(plan.links)")
    let storage = textView.textContentStorage!.textStorage!
    var runs: [(NSRange, UIColor?)] = []
    storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
        runs.append((range, value as? UIColor))
    }
    #expect(runs.allSatisfy { $0.1 == MarkdownTheme.default.renderingColor(for: .link) }, "\(runs)")
}
#endif

#if canImport(UIKit)
/// ExampleiOS の UI テスト文書(複数行 + CJK)で、3 行目以降の属性位置がずれないこと。
@MainActor @Test func multiLineCJKDocumentKeepsAttributeRangesAligned() {
    // 注: リスト直後に空行なしで段落を続けると遅延継続行になり、swift-markdown の列ずれ
    //(LapermCoreTests.lazyContinuationLineSpansAreAligned 参照)で失敗する。ここでは空行を挟む。
    let md = """
    # 見出し
    - [ ] タスク

    本文 **強調** `code`
    [インラインリンク](https://example.com/inline)
    > 引用

    ## 次の見出し
    末尾
    """
    let textView = makeLaidOutTextView(md)
    let ns = md as NSString
    let storage = textView.textContentStorage!.textStorage!
    #expect(storage.string == md)
    let strongRange = ns.range(of: "強調")
    let codeRange = ns.range(of: "code")
    let linkRange = ns.range(of: "インラインリンク")
    let strong = MarkdownTheme.default.style(for: .strong)?.font
    #expect(storage.attribute(.font, at: strongRange.location, effectiveRange: nil) as? UIFont == strong)
    #expect(storage.attribute(.font, at: strongRange.location + 1, effectiveRange: nil) as? UIFont == strong)
    #expect(storage.attribute(.font, at: codeRange.location, effectiveRange: nil) as? UIFont == MarkdownTheme.default.bodyFont)
    #expect(storage.attribute(.foregroundColor, at: codeRange.location, effectiveRange: nil) as? UIColor
            == MarkdownTheme.default.renderingColor(for: .inlineCode))
    #expect(storage.attribute(.foregroundColor, at: strongRange.location + 1, effectiveRange: nil) as? UIColor
            == MarkdownTheme.default.bodyColor)
    #expect(storage.attribute(.foregroundColor, at: linkRange.location + 2, effectiveRange: nil) as? UIColor
            == MarkdownTheme.default.renderingColor(for: .link))
    var runs: [String] = []
    storage.enumerateAttributes(in: ns.range(of: "本文 **強調** `code`")) { attributes, range, _ in
        let font = (attributes[.font] as? UIFont)?.fontName ?? "-"
        let color = (attributes[.foregroundColor] as? UIColor).map { "\($0)" } ?? "-"
        runs.append("\(ns.substring(with: range)) font=\(font) color=\(color)")
    }
    #expect(runs.count >= 5, Comment(rawValue: runs.joined(separator: "\n")))
}
#endif
