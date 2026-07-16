import AppKit
import LapermCore

/// SyntaxKind を具体的なフォント・色に対応付けるテーマ。
/// NSFont / NSColor はイミュータブルでスレッドセーフのため @unchecked Sendable。
public struct MarkdownTheme: Equatable, @unchecked Sendable {
    public struct Style: Equatable, @unchecked Sendable {
        /// レイアウトに影響する属性(textStorage へ適用)
        public var font: NSFont?
        /// レイアウトに影響しない属性(renderingAttributes へ適用)
        public var foregroundColor: NSColor?
        /// 打ち消し線。レイアウトには影響しないが、TextKit2 の renderingAttributes では
        /// 描画されないため textStorage 側属性として適用する(実機検証で確認)
        public var strikethrough: Bool

        public init(font: NSFont? = nil, foregroundColor: NSColor? = nil, strikethrough: Bool = false) {
            self.font = font
            self.foregroundColor = foregroundColor
            self.strikethrough = strikethrough
        }
    }

    public var bodyFont: NSFont
    public var bodyColor: NSColor
    public var backgroundColor: NSColor
    public var codeBlockBackgroundColor: NSColor
    public var blockquoteBarColor: NSColor
    public var thematicBreakLineColor: NSColor
    public var styles: [SyntaxKind: Style]
    public var tableBackgroundColor: NSColor

    public init(
        bodyFont: NSFont,
        bodyColor: NSColor,
        backgroundColor: NSColor,
        codeBlockBackgroundColor: NSColor,
        blockquoteBarColor: NSColor,
        thematicBreakLineColor: NSColor,
        styles: [SyntaxKind: Style],
        tableBackgroundColor: NSColor = .quaternarySystemFill
    ) {
        self.bodyFont = bodyFont
        self.bodyColor = bodyColor
        self.backgroundColor = backgroundColor
        self.codeBlockBackgroundColor = codeBlockBackgroundColor
        self.blockquoteBarColor = blockquoteBarColor
        self.thematicBreakLineColor = thematicBreakLineColor
        self.styles = styles
        self.tableBackgroundColor = tableBackgroundColor
    }

    public func style(for kind: SyntaxKind) -> Style? {
        styles[kind]
    }

    public static let `default`: MarkdownTheme = {
        let bodySize: CGFloat = 14
        let body = NSFont.monospacedSystemFont(ofSize: bodySize, weight: .regular)
        let italicBody = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)

        var styles: [SyntaxKind: Style] = [:]
        let headingSizes: [CGFloat] = [26, 22, 19, 17, 15, 14]
        for level in 1...6 {
            styles[.heading(level: level)] = Style(
                font: .systemFont(ofSize: headingSizes[level - 1], weight: .bold)
            )
        }
        styles[.strong] = Style(font: .monospacedSystemFont(ofSize: bodySize, weight: .bold))
        styles[.emphasis] = Style(font: italicBody)
        styles[.inlineCode] = Style(foregroundColor: .systemPink)
        styles[.codeBlock] = Style(foregroundColor: .textColor)
        styles[.blockquote] = Style(foregroundColor: .secondaryLabelColor)
        styles[.listMarker] = Style(foregroundColor: .systemOrange)
        styles[.link] = Style(foregroundColor: .linkColor)
        styles[.image] = Style(foregroundColor: .linkColor)
        styles[.thematicBreak] = Style(foregroundColor: .tertiaryLabelColor)
        styles[.strikethrough] = Style(foregroundColor: .secondaryLabelColor, strikethrough: true)
        styles[.taskChecked] = Style(foregroundColor: .tertiaryLabelColor)
        styles[.syntaxMarker] = Style(foregroundColor: .tertiaryLabelColor)
        styles[.tableHeader] = Style(font: .monospacedSystemFont(ofSize: bodySize, weight: .bold))

        return MarkdownTheme(
            bodyFont: body,
            bodyColor: .textColor,
            backgroundColor: .textBackgroundColor,
            codeBlockBackgroundColor: .quaternarySystemFill,
            blockquoteBarColor: .systemGray,
            thematicBreakLineColor: .separatorColor,
            styles: styles
        )
    }()
}

extension MarkdownTheme {
    var bodyLayoutAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont]
    }

    func layoutFont(for kind: SyntaxKind) -> NSFont? {
        style(for: kind)?.font
    }

    /// kind に適用する textStorage 側属性(フォント・打ち消し線)。
    /// 打ち消し線はレイアウトに影響しないが、TextKit2 の renderingAttributes では
    /// 描画されないため textStorage 側で適用する(実機検証で確認)。
    func storageAttributes(for kind: SyntaxKind) -> [NSAttributedString.Key: Any] {
        guard let style = style(for: kind) else { return [:] }
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let font = style.font { attributes[.font] = font }
        if style.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            if let color = style.foregroundColor { attributes[.strikethroughColor] = color }
        }
        return attributes
    }

    func renderingColor(for kind: SyntaxKind) -> NSColor? {
        style(for: kind)?.foregroundColor
    }

    /// kind に適用するレンダリング属性(色)。renderingAttributes へ適用する。
    func renderingAttributes(for kind: SyntaxKind) -> [NSAttributedString.Key: Any] {
        guard let style = style(for: kind) else { return [:] }
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let color = style.foregroundColor {
            attributes[.foregroundColor] = color
        }
        return attributes
    }
}
