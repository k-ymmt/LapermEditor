#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import LapermCore

/// Live Preview の表に描くテーブル 1 つの中身(Laperm ADR 0019): 列の揃えと、セルごとの属性付き文字列。
/// テキストストレージの属性(フォント、打ち消し線 = Source と同じ強調 / コードのフォント)を土台に、Theme の色を
/// 計画のスパンから重ね、Live Preview が隠す Syntax Marker(強調やリンクの記号)と `\|` のバックスラッシュを
/// 取り除いたもの。純粋な値で、レイアウトのキャッシュのキーになる。
struct TablePreviewModel: Equatable {
    struct Cell: Equatable {
        var text: NSAttributedString
        /// 表のクリックでキャレットを置く位置(セルの内容の末尾。文書座標)
        var caretLocation: Int
    }

    struct Row: Equatable {
        var cells: [Cell]
        /// この行(改行を含まない。文書座標)。セルの外(列の無い所)のクリックの退避先。
        var lineRange: NSRange
    }

    var alignments: [MarkdownTable.Alignment]
    var header: Row
    var rows: [Row]

    /// `table` の中身を `storage`(ハイライト適用済みのテキストストレージ)と `plan`(色とマーカー)から組み立てる。
    /// テーブルがストレージの外を指していれば nil。
    @MainActor
    static func make(
        table: MarkdownTable, storage: NSAttributedString, plan: HighlightPlan, theme: MarkdownTheme
    ) -> TablePreviewModel? {
        guard NSMaxRange(table.range) <= storage.length else { return nil }
        let tableSpans = plan.spans.filter { NSIntersectionRange($0.range, table.range).length > 0 }
        let markers = plan.concealableMarkers.filter { NSIntersectionRange($0, table.range).length > 0 }
        func cell(_ cell: MarkdownTable.Cell) -> Cell {
            Cell(
                text: cellText(range: cell.range, storage: storage, spans: tableSpans, markers: markers, theme: theme),
                caretLocation: NSMaxRange(cell.range))
        }
        func row(_ row: MarkdownTable.Row) -> Row {
            Row(cells: row.cells.map(cell), lineRange: row.lineRange)
        }
        return TablePreviewModel(alignments: table.alignments, header: row(table.header), rows: table.rows.map(row))
    }

    /// セル 1 つの表示用文字列。
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
        // 隠す Syntax Marker と `\|` のバックスラッシュを後ろから取り除く(前の位置がずれないように)
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
        for removal in removals.sorted(by: { $0.location > $1.location }) where NSMaxRange(removal) <= text.length {
            text.deleteCharacters(in: removal)
        }
        return text
    }
}
