#if canImport(UIKit)
import UIKit
import LapermCore

/// 画像・プレースホルダー・エラー枠を載せる非ヒットテストのオーバーレイ(UIKit)。
/// レイアウト計算は両 OS 共通の ImagePreviewLayout が担う。
final class ImagePreviewOverlayView: UIView {
    private var itemViews: [ImageReference: ImagePreviewItemView] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ImagePreviewOverlayView does not support NSCoder")
    }

    /// ビューポートレイアウトパスの結果を反映する。ビューは参照単位で使い回し、
    /// 一覧にない参照(ビューポート外・消滅)は取り外す。
    func update(entries: [ImagePreviewOverlayEntry]) {
        var seen: Set<ImageReference> = []
        for entry in entries {
            seen.insert(entry.reference)
            let view: ImagePreviewItemView
            if let existing = itemViews[entry.reference] {
                view = existing
            } else {
                view = ImagePreviewItemView()
                itemViews[entry.reference] = view
                addSubview(view)
            }
            view.frame = entry.frame
            view.state = entry.state
            view.altText = entry.reference.altText
        }
        for (key, view) in itemViews where !seen.contains(key) {
            view.removeFromSuperview()
            itemViews[key] = nil
        }
    }
}

/// 1 画像ぶんの表示(実画像 / ⏳ プレースホルダー / ⚠ エラー枠)。
final class ImagePreviewItemView: UIView {
    var state: ImagePreviewController.State = .loading {
        didSet { if state != oldValue { setNeedsDisplay() } }
    }
    var altText: String = "" {
        didSet { if altText != oldValue { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ImagePreviewItemView does not support NSCoder")
    }

    override func draw(_ rect: CGRect) {
        switch state {
        case .loaded(let image):
            image.draw(in: bounds)
        case .loading:
            drawPlaceholder(text: "⏳")
        case .failed:
            drawPlaceholder(text: "⚠ " + altText)
        }
    }

    private func drawPlaceholder(text: String) {
        let path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 6)
        UIColor.quaternarySystemFill.setFill()
        path.fill()
        UIColor.separator.setStroke()
        path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12),
            .foregroundColor: UIColor.secondaryLabel,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: 12, y: (bounds.height - size.height) / 2),
            withAttributes: attributes)
    }
}
#endif
