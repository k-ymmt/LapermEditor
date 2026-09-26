#if canImport(UIKit)
import UIKit

/// Live Preview で折りたたんだブロック(テーブルの表 / コードブロックの箱)を描く非ヒットテストのオーバーレイ
/// (UIKit、ADR 0019 / 0020)。ブロックごとに 1 つのアイテムビューを使い回す。タップはテキストビューのタップ
/// ジェスチャが拾ってブロックを展開する。
final class BlockPreviewOverlayView<Entry: BlockPreviewOverlayEntry>: UIView {
    private var itemViews: [Int: BlockPreviewItemView<Entry>] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BlockPreviewOverlayView does not support NSCoder")
    }

    /// ビューポートレイアウトパスの結果を反映する。一覧にないブロック(ビューポート外・展開)は取り外す。
    func update(entries: [Entry]) {
        var seen: Set<Int> = []
        for entry in entries {
            seen.insert(entry.location)
            let view: BlockPreviewItemView<Entry>
            if let existing = itemViews[entry.location] {
                view = existing
            } else {
                view = BlockPreviewItemView<Entry>()
                itemViews[entry.location] = view
                addSubview(view)
            }
            view.entry = entry
        }
        for (key, view) in itemViews where !seen.contains(key) {
            view.removeFromSuperview()
            itemViews[key] = nil
        }
    }
}

final class BlockPreviewItemView<Entry: BlockPreviewOverlayEntry>: UIView {
    var entry: Entry? {
        didSet {
            guard let entry else { return }
            if frame != entry.frame { frame = entry.frame }
            if entry != oldValue { setNeedsDisplay() }
        }
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
        fatalError("BlockPreviewItemView does not support NSCoder")
    }

    override func draw(_ rect: CGRect) {
        guard let entry, let context = UIGraphicsGetCurrentContext() else { return }
        entry.draw(in: context, visibleRect: rect)
    }
}

typealias TablePreviewOverlayView = BlockPreviewOverlayView<TablePreviewEntry>
typealias CodeBlockPreviewOverlayView = BlockPreviewOverlayView<CodeBlockPreviewEntry>
#endif
