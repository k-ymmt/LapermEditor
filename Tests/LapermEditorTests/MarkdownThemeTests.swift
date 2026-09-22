#if os(macOS)
import AppKit
import Testing
@testable import LapermEditor

@Test func defaultThemeStylesAllHeadingLevels() {
    let theme = MarkdownTheme.default
    var previousSize = CGFloat.greatestFiniteMagnitude
    for level in 1...6 {
        let font = theme.style(for: .heading(level: level))?.font
        #expect(font != nil, "見出しレベル \(level) にフォントがない")
        let size = font!.pointSize
        #expect(size <= previousSize, "見出しサイズはレベルが下がるほど小さい")
        previousSize = size
    }
}

@Test func defaultThemeDimsSyntaxMarkers() {
    #expect(MarkdownTheme.default.renderingColor(for: .syntaxMarker) != nil)
}

@Test func layoutAndRenderingAttributesAreSeparated() {
    let theme = MarkdownTheme.default
    // 見出しはフォント(レイアウト属性)を持つ
    #expect(theme.layoutFont(for: .heading(level: 1)) != nil)
    // syntaxMarker は色のみ(フォント変更なし)
    #expect(theme.layoutFont(for: .syntaxMarker) == nil)
}

@Test func themesDifferingOnlyInStylesAreNotEqual() {
    let a = MarkdownTheme.default
    var b = MarkdownTheme.default
    #expect(a == b)
    b.styles[.strong] = MarkdownTheme.Style(font: .systemFont(ofSize: 99))
    #expect(a != b)
}

@Test func defaultThemeStrikesThroughStrikethrough() {
    let theme = MarkdownTheme.default
    // 打ち消し線は textStorage 側属性(TextKit2 の renderingAttributes では描画されない)
    let storageAttributes = theme.storageAttributes(for: .strikethrough)
    #expect(storageAttributes[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)
    // renderingAttributes 側は色のみ(打ち消し線を持たない)
    let renderingAttributes = theme.renderingAttributes(for: .strikethrough)
    #expect(renderingAttributes[.strikethroughStyle] == nil)
    #expect(renderingAttributes[.foregroundColor] != nil)
    // フォント変更なし(レイアウト非影響)
    #expect(theme.layoutFont(for: .strikethrough) == nil)
}

@Test func defaultThemeDimsCheckedTasks() {
    let theme = MarkdownTheme.default
    #expect(theme.renderingColor(for: .taskChecked) != nil)
    #expect(theme.layoutFont(for: .taskChecked) == nil)
}

@Test func defaultThemeBoldsTableHeaderOnly() {
    let theme = MarkdownTheme.default
    // ヘッダー行は太字(レイアウト属性)
    #expect(theme.layoutFont(for: .tableHeader) != nil)
    // テーブル全体はフォント変更なし(デフォルトテーマの本文は元から等幅)
    #expect(theme.layoutFont(for: .table) == nil)
}

@Test func lineSpacingZeroAddsNoParagraphStyle() {
    let theme = MarkdownTheme.default
    #expect(theme.lineSpacing == 0)
    #expect(theme.baseParagraphStyle == nil)
    #expect(theme.bodyLayoutAttributes[.paragraphStyle] == nil)
}

@Test func lineSpacingBecomesTheBodyParagraphStyle() {
    var theme = MarkdownTheme.default
    theme.lineSpacing = 6
    let style = theme.bodyLayoutAttributes[.paragraphStyle] as? NSParagraphStyle
    #expect(style?.lineSpacing == 6)
    #expect(style?.paragraphSpacing == 0)
    // 負値は 0 に丸める(init 経由)
    #expect(MarkdownTheme(
        bodyFont: theme.bodyFont, bodyColor: theme.bodyColor, backgroundColor: theme.backgroundColor,
        codeBlockBackgroundColor: theme.codeBlockBackgroundColor, blockquoteBarColor: theme.blockquoteBarColor,
        thematicBreakLineColor: theme.thematicBreakLineColor, styles: [:], lineSpacing: -3
    ).lineSpacing == 0)
}

@Test func blockquoteIndentDefaultsAndClampsToZero() {
    #expect(MarkdownTheme.default.blockquoteIndent == 16)
    let theme = MarkdownTheme.default
    #expect(MarkdownTheme(
        bodyFont: theme.bodyFont, bodyColor: theme.bodyColor, backgroundColor: theme.backgroundColor,
        codeBlockBackgroundColor: theme.codeBlockBackgroundColor, blockquoteBarColor: theme.blockquoteBarColor,
        thematicBreakLineColor: theme.thematicBreakLineColor, styles: [:], blockquoteIndent: -3
    ).blockquoteIndent == 0)
}
#endif
