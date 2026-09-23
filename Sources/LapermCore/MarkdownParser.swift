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
        // Front Matter(文書先頭の `---` … `---`)は Markdown として解釈しない。cmark は `---` を
        // 水平線や Setext 見出しの下線として読むので、その領域を(改行だけ残して)空白に置き換えた
        // テキストを swift-markdown に渡す。UTF-16 の長さは変わらないので、返る NSRange は原文に対して
        // そのまま有効になる。
        let frontMatter = FrontMatterParser.parse(text)
        let original = text
        if let frontMatter {
            text = Self.blanking(frontMatter.range, in: text)
        }
        // swift-markdown は既定で cmark のスマート約物(`...`→`…`、`---`→`—`、引用符の曲線化)を
        // 有効にする。ハイライトでは原文の位置だけが必要で、変換後の Text ノードは
        // (1) SourceLocationConverter が継続行の桁補正を原文と照合する際に不一致を生んで
        //     補正を無効化し(強調が消える/ずれる)、
        // (2) LinkReference.text / ImageReference.altText が原文と異なる文字列になる
        // ため、無効化する。
        let document = Document(parsing: text, options: [.disableSmartOpts])
        var plan = HighlightMapper.plan(for: document, in: text)
        if let frontMatter {
            plan.frontMatter = frontMatter
            plan.spans = Self.frontMatterSpans(frontMatter, text: original as NSString) + plan.spans
        }
        return plan
    }

    /// Front Matter のスタイル: ブロック全体(背景)、キー名、両端の `---`(Syntax Marker。Live Preview で
    /// 隠す対象には入れない: ブロックは展開中は Source と同じ見た目で見せる)。
    static func frontMatterSpans(_ frontMatter: FrontMatter, text: NSString) -> [HighlightSpan] {
        var spans = [HighlightSpan(range: frontMatter.range, kind: .frontMatter)]
        for property in frontMatter.properties {
            guard let key = property.key else { continue }
            let line = NSIntersectionRange(property.lineRange, NSRange(location: 0, length: text.length))
            let found = text.range(of: key, options: [.anchored], range: line)
            guard found.location != NSNotFound else { continue }
            spans.append(HighlightSpan(range: found, kind: .frontMatterKey))
        }
        spans.append(HighlightSpan(range: frontMatter.openingFenceRange, kind: .syntaxMarker))
        spans.append(HighlightSpan(range: frontMatter.closingFenceRange, kind: .syntaxMarker))
        return spans
    }

    /// `range` の改行以外の文字を空白に置き換えた文字列(UTF-16 単位で同じ長さ)。
    static func blanking(_ range: NSRange, in text: String) -> String {
        let ns = text as NSString
        let clipped = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        guard clipped.length > 0 else { return text }
        var characters = [unichar](repeating: 0, count: ns.length)
        ns.getCharacters(&characters, range: NSRange(location: 0, length: ns.length))
        for i in clipped.location..<NSMaxRange(clipped)
        where characters[i] != ASCII.newline && characters[i] != ASCII.carriageReturn {
            characters[i] = ASCII.space
        }
        var result = String(utf16CodeUnits: characters, count: characters.count)
        result.makeContiguousUTF8()
        return result
    }
}
