#if os(macOS)
import AppKit

/// Live Preview のテーブルの表を描く非ヒットテストのオーバーレイ(ADR 0019)。テーブルごとに 1 つの
/// アイテムビューを使い回す(画像プレビューと同じ)。クリックはテキストビューが `mouseDown` で拾って
/// ブロックを展開する(`MarkdownEditorEngine.tableCaretRange(atPoint:)`)。
final class TablePreviewOverlayView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var itemViews: [Int: TablePreviewItemView] = [:]

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

final class TablePreviewItemView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var entry: TablePreviewEntry? {
        didSet {
            guard let entry else { return }
            if frame != entry.frame { frame = entry.frame }
            if entry != oldValue { needsDisplay = true }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let entry, let context = NSGraphicsContext.current?.cgContext else { return }
        TablePreviewRenderer.draw(entry.layout, appearance: entry.appearance, in: context)
    }
}
#endif
