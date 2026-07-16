import AppKit

/// コードブロック: テキスト背面に角丸背景
final class CodeBlockFragment: NSTextLayoutFragment {
    var fillColor: NSColor = .quaternarySystemFill

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        let rect = renderingSurfaceBounds.insetBy(dx: 2, dy: 0)
        let path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.setFillColor(fillColor.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

/// 引用: 行頭側に縦のアクセントバー
final class BlockquoteFragment: NSTextLayoutFragment {
    var barColor: NSColor = .systemGray

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        let bounds = renderingSurfaceBounds
        context.setFillColor(barColor.cgColor)
        context.fill(CGRect(x: bounds.minX + 2, y: bounds.minY, width: 3, height: bounds.height))
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

/// 水平線: "---" テキストに重ねて罫線を描画
final class ThematicBreakFragment: NSTextLayoutFragment {
    var lineColor: NSColor = .separatorColor

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        let bounds = renderingSurfaceBounds
        context.setStrokeColor(lineColor.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: bounds.minX, y: bounds.midY))
        context.addLine(to: CGPoint(x: bounds.maxX, y: bounds.midY))
        context.strokePath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

/// 画像段落: 末尾の予約領域(paragraphSpacing)を layoutFragmentFrame に確実に含める。
/// TextKit2 は文書末尾の段落について trailing paragraphSpacing を
/// layoutFragmentFrame / usageBoundsForTextContainer に算入しないため、
/// 最終行が画像行のときプレビュー領域が確保されず、オーバーレイが上にずれる/切れる。
/// テキスト行の下に spacing ぶんの高さを補うことで、末尾でも通常段落と同じ予約高さにする。
final class ImageParagraphFragment: NSTextLayoutFragment {
    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        let needed = textLinesBottom + reservedSpacing
        if frame.height < needed { frame.size.height = needed }
        return frame
    }

    /// テキスト行群の下端(フラグメント原点からの相対値)。
    var textLinesBottom: CGFloat {
        textLineFragments.reduce(0) { max($0, $1.typographicBounds.maxY) }
    }

    /// この段落に適用された paragraphSpacing(= 予約高さ)。属性から読む。
    private var reservedSpacing: CGFloat {
        guard let paragraph = textElement as? NSTextParagraph else { return 0 }
        let attributed = paragraph.attributedString
        guard attributed.length > 0,
              let style = attributed.attribute(
                .paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        else { return 0 }
        return style.paragraphSpacing
    }
}

/// テーブル: テキスト背面に角丸背景(コードブロックと同型)
final class TableBackgroundFragment: NSTextLayoutFragment {
    var fillColor: NSColor = .quaternarySystemFill

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        let rect = renderingSurfaceBounds.insetBy(dx: 2, dy: 0)
        let path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.setFillColor(fillColor.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}
