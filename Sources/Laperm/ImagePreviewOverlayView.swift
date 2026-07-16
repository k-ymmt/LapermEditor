import AppKit
import LapermCore

/// 予約領域(paragraphSpacing)内に画像を積むレイアウト計算。純粋関数。
enum ImagePreviewLayout {
    struct Item: Equatable {
        var reference: ImageReference
        var frame: CGRect
    }

    /// テキスト行の下端(`textLinesBottom`、テキストコンテナ座標)を予約領域の
    /// 先頭として、段落内の画像をソース順で縦に積む。各画像はスロット(高さ + padding)
    /// の中央に置く。
    ///
    /// 起点を `fragmentFrame.maxY - totalHeight` ではなくテキスト行の下端にするのは、
    /// TextKit2 が文書末尾の段落について trailing paragraphSpacing を
    /// layoutFragmentFrame に含めないことがあり、その場合 maxY 起点だと予約領域が
    /// テキストの上に食い込んでしまうため。テキスト行下端を起点にすれば、
    /// frame に spacing が含まれるか否かに関わらず常にテキストの下へ積める。
    static func itemFrames(
        references: [ImageReference],
        sizes: [CGSize],
        fragmentFrame: CGRect,
        textLinesBottom: CGFloat,
        leadingInset: CGFloat,
        padding: CGFloat
    ) -> [Item] {
        var y = fragmentFrame.minY + textLinesBottom
        var items: [Item] = []
        for (reference, size) in zip(references, sizes) {
            items.append(Item(
                reference: reference,
                frame: CGRect(
                    x: fragmentFrame.minX + leadingInset,
                    y: y + padding / 2,
                    width: size.width,
                    height: size.height)))
            y += size.height + padding
        }
        return items
    }
}

/// オーバーレイに渡す 1 画像ぶんの表示指示(frame は textView 座標)。
struct ImagePreviewOverlayEntry {
    var reference: ImageReference
    var frame: NSRect
    var state: ImagePreviewController.State
}

/// 画像・プレースホルダー・エラー枠を載せる非ヒットテストのオーバーレイ。
/// 将来はアイテムビューの中身を AVPlayerView 等に差し替えて動画に拡張する。
final class ImagePreviewOverlayView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var itemViews: [ImageReference: ImagePreviewItemView] = [:]

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
final class ImagePreviewItemView: NSView {
    var state: ImagePreviewController.State = .loading {
        didSet { if state != oldValue { needsDisplay = true } }
    }
    var altText: String = "" {
        didSet { if altText != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        switch state {
        case .loaded(let image):
            image.draw(
                in: bounds, from: .zero, operation: .sourceOver,
                fraction: 1, respectFlipped: true, hints: nil)
        case .loading:
            drawPlaceholder(text: "⏳")
        case .failed:
            drawPlaceholder(text: "⚠ " + altText)
        }
    }

    private func drawPlaceholder(text: String) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.quaternarySystemFill.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: 12, y: (bounds.height - size.height) / 2),
            withAttributes: attributes)
    }
}
