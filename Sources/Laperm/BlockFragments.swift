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
