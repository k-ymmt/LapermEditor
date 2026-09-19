#if canImport(UIKit)
import UIKit

/// Cmd+ホバー(iPad ポインタ)中のリンク下線を描く軽量オーバーレイ(UIKit)。ヒットテスト対象外。
/// macOS 版と同じく、TextKit2 の下線レンダリング属性に頼らず座標を計算して描く。
final class LinkHoverOverlayView: UIView {
    var color: UIColor = .label { didSet { setNeedsDisplay() } }
    /// 下線を引く矩形群(このビュー自身のローカル座標)。複数行に渡るリンクでは行ごとに 1 矩形。
    var underlineRects: [CGRect] = [] { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LinkHoverOverlayView does not support NSCoder")
    }

    override func draw(_ rect: CGRect) {
        color.setFill()
        for underline in underlineRects {
            UIRectFill(CGRect(
                x: underline.minX, y: underline.maxY - 1, width: underline.width, height: 1))
        }
    }
}
#endif
