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
}
