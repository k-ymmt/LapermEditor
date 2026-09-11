#if os(macOS)
import AppKit

/// 予約領域(reservedBottomHeight)を layoutFragmentFrame に確実に含める共通基底クラス。
/// TextKit2 は文書末尾の段落について trailing paragraphSpacing を
/// layoutFragmentFrame / usageBoundsForTextContainer に算入しないため、
/// 画像プレビューの予約がその段落の末尾に確保されないことがある
/// (装飾付き段落 = コードブロック/引用/水平線/テーブルであっても同様)。
/// テキスト行の下に reservedBottomHeight ぶんの高さを補うことで、
/// 文書末尾でも通常段落と同じ予約高さになるようにする。
/// `BlockFragmentProvider` が返すすべてのフラグメントの共通基底とすることで、
/// 「装飾の有無」と「画像予約の有無」を独立に組み合わせられるようにしている。
class ReservingTextLayoutFragment: NSTextLayoutFragment {
    /// この段落の末尾に確保すべき追加の高さ(画像プレビューの予約高さなど)。
    /// nil の場合は通常の `NSTextLayoutFragment` と同じ挙動になる。
    var reservedBottomHeight: CGFloat?

    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        guard let reservedBottomHeight else { return frame }
        let needed = textLinesBottom + reservedBottomHeight
        if frame.height < needed { frame.size.height = needed }
        return frame
    }

    /// テキスト行群の下端(フラグメント原点からの相対値)。
    var textLinesBottom: CGFloat {
        textLineFragments.reduce(0) { max($0, $1.typographicBounds.maxY) }
    }
}

/// コードブロック: テキスト背面に角丸背景
final class CodeBlockFragment: ReservingTextLayoutFragment {
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
final class BlockquoteFragment: ReservingTextLayoutFragment {
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
final class ThematicBreakFragment: ReservingTextLayoutFragment {
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
final class TableBackgroundFragment: ReservingTextLayoutFragment {
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
#endif
