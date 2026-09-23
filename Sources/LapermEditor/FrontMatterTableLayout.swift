#if canImport(AppKit)
import AppKit
typealias StringDrawingOptions = NSString.DrawingOptions
#elseif canImport(UIKit)
import UIKit
typealias StringDrawingOptions = NSStringDrawingOptions
#endif
import LapermCore

/// Live Preview で Front Matter を描く「キー / 値」2 列の表のレイアウト(ADR 0016)。純粋な計算で、
/// 表の左上を原点とする座標を持つ。描画は `FrontMatterTableRenderer`、配置はエンジンのビューポート
/// レイアウトパスが行う。
///
/// - 行 = Property 1 つ。値が文字列なら折り返すテキスト、リストなら Obsidian 風のチップを横に並べて折り返す、
///   解釈できない行はキー列を空にして原文を等幅フォントで載せる。
/// - 高さは行数と折り返しに応じた可変(上限なし)。見出し行は付けない。
struct FrontMatterTableLayout: Equatable {
    struct Chip: Equatable {
        var text: NSAttributedString
        var frame: CGRect
    }

    struct Row: Equatable {
        /// 行の矩形(表座標)。区切り線はこの下辺に引く。
        var frame: CGRect
        var key: NSAttributedString?
        var keyFrame: CGRect
        /// 文字列の値、または解釈できない行の原文
        var value: NSAttributedString?
        var valueFrame: CGRect
        /// リストの値
        var chips: [Chip]
        /// この行に対応する Property の行(文書座標)。クリックでキャレットを置く先。
        var lineRange: NSRange
    }

    var rows: [Row]
    var size: CGSize

    static let horizontalPadding: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 6
    static let columnGap: CGFloat = 16
    static let minimumKeyColumnWidth: CGFloat = 48
    static let maximumKeyColumnFraction: CGFloat = 0.4
    static let chipHorizontalPadding: CGFloat = 8
    static let chipVerticalPadding: CGFloat = 2
    static let chipGap: CGFloat = 6
    static let cornerRadius: CGFloat = 6
    /// 表の下と本文の間に空ける余白。予約高さに含める。
    static let bottomMargin: CGFloat = 10
    /// 幅が決まっていない(0 や非有限)ときに使う幅
    static let fallbackWidth: CGFloat = 320

    /// 開きの段落に予約する高さ(表 + 下余白)。
    var reservedHeight: CGFloat { size.height + Self.bottomMargin }

    /// テーマから引く見た目(フォントと色)。
    struct Appearance: Equatable {
        var keyFont: PlatformFont
        var keyColor: PlatformColor
        var valueFont: PlatformFont
        var valueColor: PlatformColor
        var rawFont: PlatformFont
        var rawColor: PlatformColor
        var background: PlatformColor
        var separator: PlatformColor
        var chipFill: PlatformColor

        init(theme: MarkdownTheme) {
            keyFont = theme.layoutFont(for: .frontMatterKey) ?? theme.bodyFont
            // Source(ハイライト)と同じフォールバック: `frontMatterKey` の色が無ければ本文色
            keyColor = theme.renderingColor(for: .frontMatterKey) ?? theme.bodyColor
            valueFont = theme.bodyFont
            valueColor = theme.bodyColor
            rawFont = theme.layoutFont(for: .codeBlock)
                ?? .monospacedSystemFont(ofSize: theme.bodyFont.pointSize, weight: .regular)
            rawColor = theme.renderingColor(for: .codeBlock) ?? theme.bodyColor
            background = theme.frontMatterBackgroundColor
            separator = theme.thematicBreakLineColor
            chipFill = theme.backgroundColor
        }
    }

    static func make(frontMatter: FrontMatter, width: CGFloat, appearance: Appearance) -> FrontMatterTableLayout {
        let width = width.isFinite && width > 0 ? width : fallbackWidth
        let inner = max(0, width - horizontalPadding * 2)
        let keyTexts = frontMatter.properties.map { property -> NSAttributedString? in
            guard let key = property.key else { return nil }
            return NSAttributedString(string: key, attributes: [.font: appearance.keyFont, .foregroundColor: appearance.keyColor])
        }
        let widestKey = keyTexts.compactMap { $0?.size().width }.max() ?? 0
        let keyColumn = min(max(ceil(widestKey), minimumKeyColumnWidth), floor(inner * maximumKeyColumnFraction))
        let valueX = horizontalPadding + keyColumn + columnGap
        let valueWidth = max(1, width - horizontalPadding - valueX)
        let valueLineHeight = lineHeight(of: appearance.valueFont)

        var rows: [Row] = []
        var y: CGFloat = 0
        for (property, keyText) in zip(frontMatter.properties, keyTexts) {
            var value: NSAttributedString?
            var chips: [Chip] = []
            var contentHeight: CGFloat = valueLineHeight
            switch property.value {
            case .text(let string):
                let attributed = NSAttributedString(
                    string: string, attributes: [.font: appearance.valueFont, .foregroundColor: appearance.valueColor])
                value = attributed
                if !string.isEmpty { contentHeight = max(contentHeight, measure(attributed, width: valueWidth).height) }
            case .raw(let string):
                let attributed = NSAttributedString(
                    string: string, attributes: [.font: appearance.rawFont, .foregroundColor: appearance.rawColor])
                value = attributed
                contentHeight = max(contentHeight, measure(attributed, width: valueWidth).height)
            case .list(let items):
                let chipHeight = ceil(valueLineHeight + chipVerticalPadding * 2)
                var chipX: CGFloat = 0
                var chipY: CGFloat = 0
                for item in items {
                    let attributed = NSAttributedString(
                        string: item, attributes: [.font: appearance.valueFont, .foregroundColor: appearance.valueColor])
                    let textWidth = ceil(measure(attributed, width: .greatestFiniteMagnitude).width)
                    let chipWidth = min(valueWidth, textWidth + chipHorizontalPadding * 2)
                    if chipX > 0, chipX + chipWidth > valueWidth {
                        chipX = 0
                        chipY += chipHeight + chipGap
                    }
                    chips.append(Chip(text: attributed, frame: CGRect(x: chipX, y: chipY, width: chipWidth, height: chipHeight)))
                    chipX += chipWidth + chipGap
                }
                contentHeight = items.isEmpty ? valueLineHeight : chipY + chipHeight
            }
            // キーのフォントが本文より大きい Theme でもキーが行からはみ出さないよう、キー側の高さも見る
            let keyHeight = keyText == nil ? 0 : lineHeight(of: appearance.keyFont)
            let rowHeight = ceil(max(contentHeight, keyHeight) + rowVerticalPadding * 2)
            let contentTop = y + rowVerticalPadding
            rows.append(Row(
                frame: CGRect(x: 0, y: y, width: width, height: rowHeight),
                key: keyText,
                keyFrame: CGRect(x: horizontalPadding, y: contentTop, width: keyColumn, height: keyHeight),
                value: value,
                valueFrame: CGRect(x: valueX, y: contentTop, width: valueWidth, height: contentHeight),
                chips: chips.map { chip in
                    var moved = chip
                    moved.frame = chip.frame.offsetBy(dx: valueX, dy: contentTop)
                    return moved
                },
                lineRange: property.lineRange))
            y += rowHeight
        }
        return FrontMatterTableLayout(rows: rows, size: CGSize(width: width, height: y))
    }

    /// 表座標の点を含む行。行の間(パディング)なら最も近い行。表の外なら nil。
    func row(at point: CGPoint) -> Row? {
        guard !rows.isEmpty, CGRect(origin: .zero, size: size).insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        if let hit = rows.first(where: { $0.frame.minY <= point.y && point.y < $0.frame.maxY }) { return hit }
        return point.y < 0 ? rows.first : rows.last
    }

    static func lineHeight(of font: PlatformFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    static func measure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
        let rect = text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }
}

/// オーバーレイに渡す表の配置(frame はテキストビュー座標)。両 OS 共通。
struct FrontMatterTableEntry: Equatable {
    var layout: FrontMatterTableLayout
    var appearance: FrontMatterTableLayout.Appearance
    var frame: CGRect
}

/// 表の描画。両 OS の表ビューが `draw(_:)` から呼ぶ(座標は y 下向き、原点は表の左上)。
enum FrontMatterTableRenderer {
    static func draw(_ layout: FrontMatterTableLayout, appearance: FrontMatterTableLayout.Appearance, in context: CGContext) {
        let bounds = CGRect(origin: .zero, size: layout.size)
        context.saveGState()
        let background = CGPath(
            roundedRect: bounds, cornerWidth: FrontMatterTableLayout.cornerRadius,
            cornerHeight: FrontMatterTableLayout.cornerRadius, transform: nil)
        context.addPath(background)
        context.setFillColor(appearance.background.cgColor)
        context.fillPath()

        for (index, row) in layout.rows.enumerated() {
            if index < layout.rows.count - 1 {
                context.setFillColor(appearance.separator.cgColor)
                context.fill(CGRect(
                    x: FrontMatterTableLayout.horizontalPadding, y: row.frame.maxY - 0.5,
                    width: max(0, row.frame.width - FrontMatterTableLayout.horizontalPadding * 2), height: 1))
            }
            if let key = row.key {
                key.draw(with: row.keyFrame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            }
            if let value = row.value {
                value.draw(with: row.valueFrame, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            }
            for chip in row.chips {
                let path = CGPath(
                    roundedRect: chip.frame.insetBy(dx: 0.5, dy: 0.5), cornerWidth: chip.frame.height / 2,
                    cornerHeight: chip.frame.height / 2, transform: nil)
                context.addPath(path)
                context.setFillColor(appearance.chipFill.cgColor)
                context.fillPath()
                context.addPath(path)
                context.setStrokeColor(appearance.separator.cgColor)
                context.setLineWidth(1)
                context.strokePath()
                let textRect = chip.frame.insetBy(
                    dx: FrontMatterTableLayout.chipHorizontalPadding, dy: FrontMatterTableLayout.chipVerticalPadding)
                chip.text.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            }
        }
        context.restoreGState()
    }
}
