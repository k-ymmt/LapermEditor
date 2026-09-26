#if os(macOS)
import AppKit

/// Live Preview で折りたたんだブロック(テーブルの表 / コードブロックの箱)を描く非ヒットテストのオーバーレイ
/// (ADR 0019 / 0020)。ブロックごとに 1 つのアイテムビューを使い回す(画像プレビューと同じ)。クリックはテキスト
/// ビューが `mouseDown` で拾ってブロックを展開する(`MarkdownEditorEngine.tableCaretRange(atPoint:)` /
/// `codeBlockCaretRange(atPoint:)`)。
final class BlockPreviewOverlayView<Entry: BlockPreviewOverlayEntry>: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var itemViews: [Int: BlockPreviewItemView<Entry>] = [:]

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

final class BlockPreviewItemView<Entry: BlockPreviewOverlayEntry>: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var entry: Entry? {
        didSet {
            guard let entry else { return }
            if frame != entry.frame { frame = entry.frame }
            if entry != oldValue { needsDisplay = true }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let entry, let context = NSGraphicsContext.current?.cgContext else { return }
        entry.draw(in: context, visibleRect: dirtyRect)
    }
}

typealias TablePreviewOverlayView = BlockPreviewOverlayView<TablePreviewEntry>
typealias CodeBlockPreviewOverlayView = BlockPreviewOverlayView<CodeBlockPreviewEntry>
#endif
