/// Markdown 要素の意味的スタイル種別。テーマがこれを具体的な属性に変換する。
public enum SyntaxKind: Hashable, Sendable {
    case heading(level: Int)
    case emphasis
    case strong
    case inlineCode
    case codeBlock
    case blockquote
    case listMarker
    case link
    case image
    case thematicBreak
    case strikethrough
    case taskChecked
    case table
    case tableHeader
    case syntaxMarker
    /// Front Matter のブロック全体(背景の装飾。中身は Markdown として解釈されない)
    case frontMatter
    /// Front Matter の Property のキー名
    case frontMatterKey
}
