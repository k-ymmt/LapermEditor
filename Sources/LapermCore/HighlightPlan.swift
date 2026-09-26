import Foundation

/// 「この UTF-16 レンジにこの SyntaxKind」という 1 スタイル指定。
public struct HighlightSpan: Hashable, Sendable {
    public var range: NSRange
    public var kind: SyntaxKind

    public init(range: NSRange, kind: SyntaxKind) {
        self.range = range
        self.kind = kind
    }
}

/// 文書全体のハイライト計画。spans は適用順(ブロック → インライン → マーカー)。
public struct HighlightPlan: Equatable, Sendable {
    public var spans: [HighlightSpan]
    /// 画像記法の出現一覧(プレビュー表示用)
    public var images: [ImageReference]
    /// リンクの出現一覧(クリック処理用)
    public var links: [LinkReference]
    /// Live Preview がフォーカスの無い行で隠す Syntax Marker のレンジ(`spans` の `.syntaxMarker` の
    /// 部分集合: 見出しの `#`、強調・打ち消し線・インラインコードの記号、リンク・画像の括弧、引用の `>`)。
    /// コードフェンス・チェックボックス・テーブルの記号は含まない(Source と同じ表示のまま)。
    public var concealableMarkers: [NSRange]
    /// 文書先頭の Front Matter(無ければ nil)。Live Preview が表として描くために使う。
    public var frontMatter: FrontMatter?
    /// GFM のテーブル(出現順)。Live Preview が表として描くために使う(Laperm ADR 0019)。
    public var tables: [MarkdownTable]

    public init(
        spans: [HighlightSpan] = [], images: [ImageReference] = [], links: [LinkReference] = [],
        concealableMarkers: [NSRange] = [], frontMatter: FrontMatter? = nil, tables: [MarkdownTable] = []
    ) {
        self.spans = spans
        self.images = images
        self.links = links
        self.concealableMarkers = concealableMarkers
        self.frontMatter = frontMatter
        self.tables = tables
    }

    /// 編集(NSTextStorageDelegate の didProcessEditing 相当の情報)に合わせて
    /// スパン位置を平行移動する。編集レンジと交差するスパンは破棄する
    /// (次のパース結果から再生成されるため)。
    public func shifted(byEditAt editedRange: NSRange, changeInLength delta: Int) -> HighlightPlan {
        // editedRange は編集「後」のレンジ。編集「前」に影響を受けた領域は
        // {editedRange.location, editedRange.length - delta}
        let preEditRange = NSRange(
            location: editedRange.location,
            length: max(0, editedRange.length - delta)
        )
        var resultSpans: [HighlightSpan] = []
        resultSpans.reserveCapacity(spans.count)
        for span in spans {
            guard let range = Self.shift(span.range, preEditRange: preEditRange, delta: delta)
            else { continue }
            var moved = span
            moved.range = range
            resultSpans.append(moved)
        }
        var resultImages: [ImageReference] = []
        resultImages.reserveCapacity(images.count)
        for image in images {
            // range と paragraphRange の両方が編集と交差しない場合のみ残す
            guard let range = Self.shift(image.range, preEditRange: preEditRange, delta: delta),
                  let paragraphRange = Self.shift(
                      image.paragraphRange, preEditRange: preEditRange, delta: delta)
            else { continue }
            var moved = image
            moved.range = range
            moved.paragraphRange = paragraphRange
            resultImages.append(moved)
        }
        var resultLinks: [LinkReference] = []
        resultLinks.reserveCapacity(links.count)
        for link in links {
            guard let range = Self.shift(link.range, preEditRange: preEditRange, delta: delta)
            else { continue }
            var moved = link
            moved.range = range
            resultLinks.append(moved)
        }
        var resultMarkers: [NSRange] = []
        resultMarkers.reserveCapacity(concealableMarkers.count)
        for marker in concealableMarkers {
            guard let range = Self.shift(marker, preEditRange: preEditRange, delta: delta) else { continue }
            resultMarkers.append(range)
        }
        // Front Matter は文書先頭に固定なので平行移動できない。ブロック(閉じの `---` の行末を含む)に
        // 触る編集、またはそれより前の編集では破棄する(次のパース結果から再生成される)。
        let resultFrontMatter = frontMatter.flatMap { preEditRange.location > NSMaxRange($0.range) ? $0 : nil }
        // テーブルはスパンと同じ規約: 編集より前なら不変、後なら平行移動、交差なら破棄(次のパースで再生成)。
        let resultTables = tables.compactMap { table -> MarkdownTable? in
            guard let range = Self.shift(table.range, preEditRange: preEditRange, delta: delta) else { return nil }
            return range == table.range ? table : table.shifted(by: delta)
        }
        return HighlightPlan(
            spans: resultSpans, images: resultImages, links: resultLinks, concealableMarkers: resultMarkers,
            frontMatter: resultFrontMatter, tables: resultTables)
    }

    /// 編集より前なら不変、後なら delta 平行移動、交差なら nil(破棄)。
    private static func shift(_ range: NSRange, preEditRange: NSRange, delta: Int) -> NSRange? {
        if NSMaxRange(range) <= preEditRange.location {
            return range
        }
        if range.location >= NSMaxRange(preEditRange) {
            return NSRange(location: range.location + delta, length: range.length)
        }
        return nil
    }
}
