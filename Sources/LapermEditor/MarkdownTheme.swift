#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import LapermCore

/// SyntaxKind を具体的なフォント・色に対応付けるテーマ。
/// PlatformFont / PlatformColor(UIFont / UIColor)はイミュータブルでスレッドセーフのため @unchecked Sendable。
public struct MarkdownTheme: Equatable, @unchecked Sendable {
    public struct Style: Equatable, @unchecked Sendable {
        /// レイアウトに影響する属性(textStorage へ適用)
        public var font: PlatformFont?
        /// レイアウトに影響しない属性(renderingAttributes へ適用)
        public var foregroundColor: PlatformColor?
        /// 打ち消し線。レイアウトには影響しないが、TextKit2 の renderingAttributes では
        /// 描画されないため textStorage 側属性として適用する(実機検証で確認)
        public var strikethrough: Bool

        public init(font: PlatformFont? = nil, foregroundColor: PlatformColor? = nil, strikethrough: Bool = false) {
            self.font = font
            self.foregroundColor = foregroundColor
            self.strikethrough = strikethrough
        }
    }

    public var bodyFont: PlatformFont
    public var bodyColor: PlatformColor
    public var backgroundColor: PlatformColor
    public var codeBlockBackgroundColor: PlatformColor
    public var blockquoteBarColor: PlatformColor
    public var thematicBreakLineColor: PlatformColor
    public var styles: [SyntaxKind: Style]
    public var tableBackgroundColor: PlatformColor
    /// コードブロックの箱の内側に取る上下の余白(先頭行の上・末尾行の下)。
    /// 段落スタイル(paragraphSpacingBefore / paragraphSpacing)で確保するため、
    /// 文書の先頭段落から始まるコードブロックには上の余白が付かない(TextKit の仕様)。
    public var codeBlockVerticalPadding: CGFloat

    public init(
        bodyFont: PlatformFont,
        bodyColor: PlatformColor,
        backgroundColor: PlatformColor,
        codeBlockBackgroundColor: PlatformColor,
        blockquoteBarColor: PlatformColor,
        thematicBreakLineColor: PlatformColor,
        styles: [SyntaxKind: Style],
        tableBackgroundColor: PlatformColor = .quaternarySystemFill,
        codeBlockVerticalPadding: CGFloat = 4
    ) {
        self.bodyFont = bodyFont
        self.bodyColor = bodyColor
        self.backgroundColor = backgroundColor
        self.codeBlockBackgroundColor = codeBlockBackgroundColor
        self.blockquoteBarColor = blockquoteBarColor
        self.thematicBreakLineColor = thematicBreakLineColor
        self.styles = styles
        self.tableBackgroundColor = tableBackgroundColor
        self.codeBlockVerticalPadding = codeBlockVerticalPadding
    }

    public func style(for kind: SyntaxKind) -> Style? {
        styles[kind]
    }

    public static let `default`: MarkdownTheme = {
        let bodySize: CGFloat = 14
        let body = PlatformFont.monospacedSystemFont(ofSize: bodySize, weight: .regular)
        let italicBody = body.lapermItalic()

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
        styles[.codeBlock] = Style(foregroundColor: .lapermLabel)
        styles[.blockquote] = Style(foregroundColor: .lapermSecondaryLabel)
        styles[.listMarker] = Style(foregroundColor: .systemOrange)
        styles[.link] = Style(foregroundColor: .lapermLink)
        styles[.image] = Style(foregroundColor: .lapermLink)
        styles[.thematicBreak] = Style(foregroundColor: .lapermTertiaryLabel)
        styles[.strikethrough] = Style(foregroundColor: .lapermSecondaryLabel, strikethrough: true)
        styles[.taskChecked] = Style(foregroundColor: .lapermTertiaryLabel)
        styles[.syntaxMarker] = Style(foregroundColor: .lapermTertiaryLabel)
        styles[.tableHeader] = Style(font: .monospacedSystemFont(ofSize: bodySize, weight: .bold))

        return MarkdownTheme(
            bodyFont: body,
            bodyColor: .lapermLabel,
            backgroundColor: .lapermTextBackground,
            codeBlockBackgroundColor: .quaternarySystemFill,
            blockquoteBarColor: .systemGray,
            thematicBreakLineColor: .lapermSeparator,
            styles: styles
        )
    }()
}

extension MarkdownTheme {
    var bodyLayoutAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont]
    }

    func layoutFont(for kind: SyntaxKind) -> PlatformFont? {
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

    func renderingColor(for kind: SyntaxKind) -> PlatformColor? {
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

