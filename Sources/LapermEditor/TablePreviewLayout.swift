#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import LapermCore

/// Live Preview でテーブルを描く格子のレイアウト(Laperm ADR 0019)。純粋な計算で、表の左上を原点とする座標を
/// 持つ。描画は `TablePreviewRenderer`、配置はエンジンのビューポートレイアウトパスが行う。
///
/// - 列の幅はセルの自然な幅(折り返し無し)。合計が `maxWidth` に収まらなければ、各列に最低幅を残して
///   余りを自然な幅に比例して配り、セルを折り返す。表の幅は列の合計(内容が少なければ狭い)。
/// - 行の高さは折り返した中で最も高いセル。ヘッダー行が先頭(Source と同じく `tableHeader` のフォント)。
struct TablePreviewLayout: Equatable {
    struct Cell: Equatable {
        /// セルの矩形(表座標)。罫線はこの辺に引く。
        var frame: CGRect
        /// 文字を描く矩形(パディングの内側)
        var textFrame: CGRect
        /// 揃えを段落スタイルに持たせた表示用の文字列
        var text: NSAttributedString
        /// クリックでキャレットを置く位置(テーブルの先頭からの相対値)
        var caretOffset: Int
    }

    struct Row: Equatable {
        var frame: CGRect
        var cells: [Cell]
        /// この行(テーブルの先頭からの相対値)
        var lineOffsetRange: NSRange
        var isHeader: Bool
    }

    /// ヘッダー行が先頭
    var rows: [Row]
    var columnWidths: [CGFloat]
    var size: CGSize

    static let cellHorizontalPadding: CGFloat = 8
    static let cellVerticalPadding: CGFloat = 4
    /// 折り返すときに列に必ず残す幅(パディング込み)
    static let minimumColumnWidth: CGFloat = 48
    static let cornerRadius: CGFloat = 4
    /// 隠したヘッダー行と表の間の余白。予約高さに含める。
    static let topMargin: CGFloat = 2
    /// 表の下と本文の間に空ける余白。予約高さに含める。
    static let bottomMargin: CGFloat = 8
    /// 幅が決まっていない(0 や非有限)ときに使う幅
    static let fallbackWidth: CGFloat = 320

    /// ヘッダー行の段落に予約する高さ(上余白 + 表 + 下余白)。
    var reservedHeight: CGFloat { Self.topMargin + size.height + Self.bottomMargin }

    /// テーマから引く見た目。文字のフォントと色はセルの文字列が持つ(`TablePreviewModel`)。
    struct Appearance: Equatable {
        var background: PlatformColor
        var border: PlatformColor
        /// 空セルと最小の行の高さに使うフォント
        var bodyFont: PlatformFont

        init(theme: MarkdownTheme) {
            background = theme.tableBackgroundColor
            border = theme.thematicBreakLineColor
            bodyFont = theme.bodyFont
        }
    }

    static func make(model: TablePreviewModel, maxWidth: CGFloat, appearance: Appearance) -> TablePreviewLayout {
        let maxWidth = maxWidth.isFinite && maxWidth > 0 ? maxWidth : fallbackWidth
        let columns = model.alignments.count
        let allRows = [model.header] + model.rows
        let hPad = cellHorizontalPadding
        let vPad = cellVerticalPadding
        // 表示用の文字列(揃えを段落スタイルで持たせる)
        let texts: [[NSAttributedString]] = allRows.map { row in
            (0..<columns).map { column in
                guard column < row.cells.count else { return NSAttributedString() }
                return aligned(row.cells[column].text, alignment: model.alignments[column])
            }
        }
        // 列の自然な幅(折り返し無し)
        var natural = [CGFloat](repeating: minimumColumnWidth, count: columns)
        for row in texts {
            for (column, text) in row.enumerated() where text.length > 0 {
                natural[column] = max(natural[column], ceil(measure(text, width: .greatestFiniteMagnitude).width) + hPad * 2)
            }
        }
        let widths = distribute(natural: natural, available: maxWidth)
        let width = widths.reduce(0, +)
        let lineHeight = FrontMatterTableLayout.lineHeight(of: appearance.bodyFont)

        var rows: [Row] = []
        var y: CGFloat = 0
        for (rowIndex, row) in allRows.enumerated() {
            var contentHeight = lineHeight
            var measured: [CGSize] = []
            for (column, text) in texts[rowIndex].enumerated() {
                let textWidth = max(1, widths[column] - hPad * 2)
                let size = text.length > 0 ? measure(text, width: textWidth) : CGSize(width: 0, height: lineHeight)
                measured.append(size)
                contentHeight = max(contentHeight, size.height)
            }
            let rowHeight = ceil(contentHeight + vPad * 2)
            var x: CGFloat = 0
            var cells: [Cell] = []
            for column in 0..<columns {
                let frame = CGRect(x: x, y: y, width: widths[column], height: rowHeight)
                cells.append(Cell(
                    frame: frame,
                    textFrame: CGRect(x: x + hPad, y: y + vPad, width: max(1, widths[column] - hPad * 2), height: contentHeight),
                    text: texts[rowIndex][column],
                    caretOffset: column < row.cells.count ? row.cells[column].caretOffset : NSMaxRange(row.lineOffsetRange)))
                x += widths[column]
            }
            rows.append(Row(
                frame: CGRect(x: 0, y: y, width: width, height: rowHeight), cells: cells,
                lineOffsetRange: row.lineOffsetRange, isHeader: rowIndex == 0))
            y += rowHeight
        }
        return TablePreviewLayout(rows: rows, columnWidths: widths, size: CGSize(width: width, height: y))
    }

    /// 列の幅を決める。合計が `available` に収まればそのまま。収まらなければ、公平な取り分(残りの幅を残りの列数で
    /// 割ったもの)に収まる列は自然な幅のままにし(短い列を潰さない)、溢れる列だけで残りの幅を自然な幅に比例して
    /// 分ける。溢れる列にも `minimumColumnWidth`(自然な幅がそれより狭ければ自然な幅)は残す。最低幅の合計が
    /// `available` を超えるときは最低幅のまま(表は右にはみ出す)。
    static func distribute(natural: [CGFloat], available: CGFloat) -> [CGFloat] {
        let total = natural.reduce(0, +)
        guard total > available, !natural.isEmpty else { return natural }
        var flexible = Set(natural.indices)
        var remaining = available
        // 公平な取り分に収まる列を固定する(固定すると取り分が増えるので、増えなくなるまで繰り返す)
        while true {
            let share = remaining / CGFloat(flexible.count)
            let fits = flexible.filter { natural[$0] <= share }
            if fits.isEmpty { break }
            for index in fits {
                flexible.remove(index)
                remaining -= natural[index]
            }
            if flexible.isEmpty { break }
        }
        var widths = natural
        guard !flexible.isEmpty else { return widths }
        // 比例配分が最低幅を割る列は最低幅で固定し、その分を他の列から差し引く(固定すると他の列の取り分が減るので、
        // 割る列が無くなるまで繰り返す)
        while true {
            let flexibleTotal = flexible.reduce(0) { $0 + natural[$1] }
            let below = flexible.filter { index in
                remaining * natural[index] / flexibleTotal < min(natural[index], minimumColumnWidth)
            }
            if below.isEmpty { break }
            for index in below {
                widths[index] = min(natural[index], minimumColumnWidth)
                remaining -= widths[index]
                flexible.remove(index)
            }
            if flexible.isEmpty { return widths }
        }
        let flexibleTotal = flexible.reduce(0) { $0 + natural[$1] }
        let sorted = flexible.sorted()
        var assigned: CGFloat = 0
        for index in sorted {
            widths[index] = (remaining * natural[index] / flexibleTotal).rounded(.down)
            assigned += widths[index]
        }
        // 切り捨てで余った端数は最後の伸びる列へ(合計を available に揃える)
        if let last = sorted.last, assigned < remaining {
            widths[last] += remaining - assigned
        }
        return widths
    }

    /// `alignment` を段落スタイルにした文字列(折り返しは単語単位)。
    static func aligned(_ text: NSAttributedString, alignment: MarkdownTable.Alignment) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        switch alignment {
        case .none, .left: style.alignment = .left
        case .center: style.alignment = .center
        case .right: style.alignment = .right
        }
        let result = NSMutableAttributedString(attributedString: text)
        result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// 表座標の点にあるセル。行の外(上下 4pt の遊びの外)なら nil。列の外は最も近い列。
    func cell(at point: CGPoint) -> Cell? {
        guard !rows.isEmpty, CGRect(origin: .zero, size: size).insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        let row = rows.first { $0.frame.minY <= point.y && point.y < $0.frame.maxY }
            ?? (point.y < 0 ? rows.first : rows.last)
        guard let row, !row.cells.isEmpty else { return nil }
        return row.cells.first { $0.frame.minX <= point.x && point.x < $0.frame.maxX }
            ?? (point.x < 0 ? row.cells.first : row.cells.last)
    }

    static func measure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
        FrontMatterTableLayout.measure(text, width: width)
    }
}

/// オーバーレイに渡す表の配置(frame はテキストビュー座標)。両 OS 共通。
struct TablePreviewEntry: Equatable {
    /// テーブルのブロックの先頭(ヘッダー行の行頭。文書座標)。オーバーレイがビューを使い回す鍵。
    var location: Int
    var layout: TablePreviewLayout
    var appearance: TablePreviewLayout.Appearance
    var frame: CGRect
}

/// 表の描画。両 OS のオーバーレイが `draw(_:)` から呼ぶ(座標は y 下向き、原点は表の左上)。`visibleRect`(描く必要の
/// ある矩形)を渡すと、それに掛からない行の罫線と文字は描かない(数千行の表でも見えている行ぶんの描画で済む)。
enum TablePreviewRenderer {
    static func draw(
        _ layout: TablePreviewLayout, appearance: TablePreviewLayout.Appearance, in context: CGContext,
        visibleRect: CGRect? = nil
    ) {
        let bounds = CGRect(origin: .zero, size: layout.size)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let visible = visibleRect ?? bounds
        context.saveGState()
        let radius = TablePreviewLayout.cornerRadius
        let outline = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(outline)
        context.setFillColor(appearance.background.cgColor)
        context.fillPath()

        context.setFillColor(appearance.border.cgColor)
        for (index, row) in layout.rows.enumerated() where row.frame.intersects(visible) {
            if index < layout.rows.count - 1 {
                context.fill(CGRect(x: 0, y: row.frame.maxY - 0.5, width: bounds.width, height: 1))
            }
            for cell in row.cells.dropLast() {
                context.fill(CGRect(x: cell.frame.maxX - 0.5, y: row.frame.minY, width: 1, height: row.frame.height))
            }
        }
        context.addPath(outline)
        context.setStrokeColor(appearance.border.cgColor)
        context.setLineWidth(1)
        context.strokePath()

        for row in layout.rows where row.frame.intersects(visible) {
            for cell in row.cells where cell.text.length > 0 {
                cell.text.draw(with: cell.textFrame, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            }
        }
        context.restoreGState()
    }
}
