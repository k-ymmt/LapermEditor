import Foundation
import Markdown

/// 公開エントリポイント。Markdown テキストからハイライト計画を生成する。
public struct MarkdownParser: Sendable {
    public init() {}

    public func highlightPlan(for text: String) -> HighlightPlan {
        // `NSTextStorage.string` のように NSString を包んだ非連続(foreign)表現の String は
        // UTF-8 インデックス操作(`utf8.index(_:offsetBy:)` 等)が 1 バイトごとの ObjC 呼び出しに
        // なり、SourceLocationConverter のノードごとのオフセット計算が行長に比例して
        // 「行内ノード数 × 行長」の二乗コストになる(2,000 語 1 行で 0.5 秒超)。
        // 先頭で 1 回だけネイティブ表現へコピーして、以降の処理を全て O(1) インデックスにする。
        // 返す NSRange は UTF-16 オフセットなので表現の違いは結果に影響しない。
        var text = text
        text.makeContiguousUTF8()
        let document = Document(parsing: text)
        return HighlightMapper.plan(for: document, in: text)
    }
}
