import Foundation
import Markdown

/// 公開エントリポイント。Markdown テキストからハイライト計画を生成する。
public struct MarkdownParser: Sendable {
    public init() {}

    public func highlightPlan(for text: String) -> HighlightPlan {
        let document = Document(parsing: text)
        return HighlightMapper.plan(for: document, in: text)
    }
}
