#if canImport(UIKit)
import UIKit

/// Live Preview のテーブルの表を描く非ヒットテストのオーバーレイ(UIKit、ADR 0019)。テーブルごとに 1 つの
/// アイテムビューを使い回す。タップはテキストビューのタップジェスチャが拾ってブロックを展開する。
final class TablePreviewOverlayView: UIView {
    private var itemViews: [Int: TablePreviewItemView] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TablePreviewOverlayView does not support NSCoder")
    }

    /// ビューポートレイアウトパスの結果を反映する。一覧にないテーブル(ビューポート外・展開)は取り外す。
    func update(entries: [TablePreviewEntry]) {
        var seen: Set<Int> = []
        for entry in entries {
            seen.insert(entry.location)
            let view: TablePreviewItemView
            if let existing = itemViews[entry.location] {
                view = existing
            } else {
                view = TablePreviewItemView()
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

final class TablePreviewItemView: UIView {
    var entry: TablePreviewEntry? {
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
        fatalError("TablePreviewItemView does not support NSCoder")
    }

    override func draw(_ rect: CGRect) {
        guard let entry, let context = UIGraphicsGetCurrentContext() else { return }
        TablePreviewRenderer.draw(entry.layout, appearance: entry.appearance, in: context)
    }
}
#endif
