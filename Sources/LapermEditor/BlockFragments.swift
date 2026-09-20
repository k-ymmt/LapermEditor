#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

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

/// コードブロック: テキストコンテナの全幅を段落の高さぶん塗る。
///
/// 1 つのコードブロックは段落(= 行)ごとのフラグメントに分かれるが、隣り合う段落の
/// 矩形を隙間なく連ね、ブロック先頭の段落だけ上の角、末尾の段落だけ下の角を丸めることで
/// 全体が 1 つの角丸の箱に見えるようにする。上下の内側余白はフラグメント側では作らず、
/// `BlockFragmentProvider` が先頭 / 末尾段落の段落スタイル(paragraphSpacingBefore /
/// paragraphSpacing)で確保した高さを、ここではそのまま塗るだけにする
/// (行の位置をずらすとキャレットやヒットテストとずれるため)。
final class CodeBlockFragment: ReservingTextLayoutFragment {
    static let cornerRadius: CGFloat = 4

    var fillColor: PlatformColor = .quaternarySystemFill
    /// ブロックの先頭段落(上の角を丸める)
    var roundsTop = false
    /// ブロックの末尾段落(下の角を丸める)
    var roundsBottom = false

    /// 背景矩形(フラグメント原点基準)。`layoutFragmentFrame` はテキストの使用幅しか持たず、
    /// 原点 x は lineFragmentPadding ぶんずれているので、コンテナ左端(x = -frame.minX)から
    /// コンテナ幅ぶんを塗る。高さは段落スタイルの上下余白・予約領域込みのフレーム高。
    var backgroundRect: CGRect {
        let frame = layoutFragmentFrame
        let containerWidth = textLayoutManager?.textContainer?.size.width ?? frame.width
        return CGRect(x: -frame.minX, y: 0, width: containerWidth, height: frame.height)
    }

    /// 描画面を背景矩形まで広げる。UITextView はフラグメントごとの描画面をこの境界で
    /// クリップするため、これを広げないと文字の周囲しか塗れない。
    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(backgroundRect)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        // 段落ごとの矩形が隣接するので、辺をデバイスピクセルに揃えてアンチエイリアスの
        // 継ぎ目(薄い線)が出ないようにする。
        let rect = Self.pixelAligned(backgroundRect, in: context)
        let path = CGPath.blockBackground(
            in: rect, cornerRadius: Self.cornerRadius,
            roundsTop: roundsTop, roundsBottom: roundsBottom)
        context.setFillColor(fillColor.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }

    /// rect の各辺をデバイスピクセル境界に丸めたもの(ユーザー座標で返す)。
    static func pixelAligned(_ rect: CGRect, in context: CGContext) -> CGRect {
        let device = context.convertToDeviceSpace(rect).standardized
        let snapped = CGRect(
            x: device.minX.rounded(), y: device.minY.rounded(),
            width: device.maxX.rounded() - device.minX.rounded(),
            height: device.maxY.rounded() - device.minY.rounded())
        return context.convertToUserSpace(snapped).standardized
    }
}

extension CGPath {
    /// 上下の角を個別に丸められる矩形パス(y 下向きのフラグメント座標を前提に、
    /// minY 側を「上」として扱う)。
    static func blockBackground(
        in rect: CGRect, cornerRadius: CGFloat, roundsTop: Bool, roundsBottom: Bool
    ) -> CGPath {
        let radius = max(0, min(cornerRadius, rect.width / 2, rect.height / 2))
        let top = roundsTop ? radius : 0
        let bottom = roundsBottom ? radius : 0
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        if top > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                tangent2End: CGPoint(x: rect.maxX, y: rect.minY + top), radius: top)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        if bottom > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.maxX - bottom, y: rect.maxY), radius: bottom)
        }
        path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        if bottom > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottom), radius: bottom)
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top))
        if top > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                tangent2End: CGPoint(x: rect.minX + top, y: rect.minY), radius: top)
        }
        path.closeSubpath()
        return path
    }
}

/// 引用: 行頭側に縦のアクセントバー
final class BlockquoteFragment: ReservingTextLayoutFragment {
    var barColor: PlatformColor = .systemGray

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
    var lineColor: PlatformColor = .lapermSeparator

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

/// テーブル: テキスト背面に角丸背景
final class TableBackgroundFragment: ReservingTextLayoutFragment {
    var fillColor: PlatformColor = .quaternarySystemFill

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
