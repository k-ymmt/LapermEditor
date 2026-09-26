#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import LapermCore

/// Live Preview の表に描くテーブル 1 つの中身(Laperm ADR 0019): 列の揃えと、セルごとの属性付き文字列。
/// テキストストレージの属性(フォント、打ち消し線 = Source と同じ強調 / コードのフォント)を土台に、Theme の色を
/// 計画のスパンから重ね、Live Preview が隠す Syntax Marker(強調やリンクの記号)と `\|` のバックスラッシュを
/// 取り除いたもの。位置はすべてテーブルの先頭からの相対値(前の編集で表が動いても使い回せる)。純粋な値で、
/// レイアウトのキャッシュのキーになる。
struct TablePreviewModel: Equatable {
    struct Cell: Equatable {
        var text: NSAttributedString
        /// 表のクリックでキャレットを置く位置(セルの内容の末尾。テーブルの先頭からの相対値)
        var caretOffset: Int
    }

    struct Row: Equatable {
        var cells: [Cell]
        /// この行(改行を含まない。テーブルの先頭からの相対値)
        var lineOffsetRange: NSRange
    }

    var alignments: [MarkdownTable.Alignment]
    var header: Row
    var rows: [Row]

    /// `table` の中身を `storage`(ハイライト適用済みのテキストストレージ)から組み立てる。`spans` は色を重ねるスパン、
    /// `markers` は隠すマーカー(どちらも文書座標で、テーブルと交差するものだけ渡す)。テーブルがストレージの外を
    /// 指していれば nil。
    @MainActor
    static func make(
        table: MarkdownTable, storage: NSAttributedString, spans: [HighlightSpan], markers: [NSRange], theme: MarkdownTheme
    ) -> TablePreviewModel? {
        guard NSMaxRange(table.range) <= storage.length else { return nil }
        // 色を付けるスパンだけ(テーマに色の無い種類と Syntax Marker は除く: パイプ 1 本ごとのマーカーが巨大な表では
        // スパンの大半で、セルの中のマーカーは隠す対象なのでどのみち取り除かれる)。セルごとの検索は区間の索引で。
        let colouredSpans = spans.filter { $0.kind != .syntaxMarker && theme.renderingColor(for: $0.kind) != nil }
        let spanIndex = RangeIndex(colouredSpans.map { ($0.range, $0) })
        let markerIndex = RangeIndex(markers.map { ($0, $0) })
        let origin = table.range.location
        func cell(_ cell: MarkdownTable.Cell) -> Cell {
            Cell(
                text: cellText(
                    range: cell.range, storage: storage, spans: spanIndex.elements(intersecting: cell.range),
                    markers: markerIndex.elements(intersecting: cell.range), theme: theme),
                caretOffset: NSMaxRange(cell.range) - origin)
        }
        func row(_ row: MarkdownTable.Row) -> Row {
            Row(cells: row.cells.map(cell), lineOffsetRange: NSRange(location: row.lineRange.location - origin, length: row.lineRange.length))
        }
        return TablePreviewModel(alignments: table.alignments, header: row(table.header), rows: table.rows.map(row))
    }

    /// セル 1 つの表示用文字列。`spans` / `markers` はセルと交差するものだけ(文書座標)。
    @MainActor
    static func cellText(
        range: NSRange, storage: NSAttributedString, spans: [HighlightSpan], markers: [NSRange], theme: MarkdownTheme
    ) -> NSAttributedString {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return NSAttributedString() }
        let text = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        let full = NSRange(location: 0, length: text.length)
        // 段落の属性(引用のインデント、画像の予約高さ)はセルには持ち込まない。フォントが無い文字は本文フォント。
        text.removeAttribute(.paragraphStyle, range: full)
        text.removeAttribute(ImagePreviewController.spacingAttribute, range: full)
        text.enumerateAttribute(.font, in: full) { value, run, _ in
            if value == nil { text.addAttribute(.font, value: theme.bodyFont, range: run) }
        }
        // 色: 本文色の上に、セルと交差するスパンの色を計画順(ブロック → インライン → マーカー)で重ねる。
        // macOS では色は renderingAttributes(ストレージに無い)、iOS ではストレージにもあるが、同じ経路で揃える。
        text.addAttribute(.foregroundColor, value: theme.bodyColor, range: full)
        for span in spans {
            let overlap = NSIntersectionRange(span.range, range)
            guard overlap.length > 0, let color = theme.renderingColor(for: span.kind) else { continue }
            text.addAttribute(.foregroundColor, value: color, range: NSRange(location: overlap.location - range.location, length: overlap.length))
        }
        // 隠す Syntax Marker と `\|` のバックスラッシュを取り除く。重なる範囲(`\|` を含むリンクの閉じ側など)は
        // 先に 1 つにまとめ、後ろから消す(前の位置がずれないように)。
        var removals: [NSRange] = markers.compactMap { marker in
            let overlap = NSIntersectionRange(marker, range)
            return overlap.length > 0 ? NSRange(location: overlap.location - range.location, length: overlap.length) : nil
        }
        let string = text.string as NSString
        var i = 0
        while i + 1 < string.length {
            if string.character(at: i) == 0x5C /* \ */, string.character(at: i + 1) == 0x7C /* | */ {
                removals.append(NSRange(location: i, length: 1))
                i += 2
            } else {
                i += 1
            }
        }
        for removal in merged(removals).reversed() where NSMaxRange(removal) <= text.length {
            text.deleteCharacters(in: removal)
        }
        return text
    }

    /// 位置順に並べ、重なる / 隣り合うレンジを 1 つにまとめる。
    static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) where range.length > 0 {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

/// レンジ付きの要素を開始位置で並べ、レンジと交差する要素を二分探索で絞る索引(`BlockFragmentProvider` の装飾の
/// 索引と同じ形: 各位置までの終端の最大値が単調増加なので下限を二分探索できる)。
struct RangeIndex<Element> {
    private let sorted: [(range: NSRange, element: Element)]
    private let prefixMaxEnd: [Int]

    init(_ items: [(NSRange, Element)]) {
        sorted = items.map { (range: $0.0, element: $0.1) }.sorted { $0.range.location < $1.range.location }
        var maxEnd = Int.min
        prefixMaxEnd = sorted.map { item in
            maxEnd = max(maxEnd, NSMaxRange(item.range))
            return maxEnd
        }
    }

    /// `range` と交差する要素(元の並びではなく開始位置順)。
    func elements(intersecting range: NSRange) -> [Element] {
        guard !sorted.isEmpty else { return [] }
        var low = 0
        var high = prefixMaxEnd.count
        while low < high {
            let mid = (low + high) / 2
            if prefixMaxEnd[mid] > range.location { high = mid } else { low = mid + 1 }
        }
        let start = low
        let limit = range.length > 0 ? NSMaxRange(range) : range.location + 1
        high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid].range.location >= limit { high = mid } else { low = mid + 1 }
        }
        guard start < low else { return [] }
        return sorted[start..<low].compactMap { NSIntersectionRange($0.range, range).length > 0 ? $0.element : nil }
    }
}
