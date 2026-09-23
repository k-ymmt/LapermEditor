#if os(macOS)
import AppKit

/// Live Preview の Front Matter の表を描く非ヒットテストのオーバーレイ。クリックはテキストビューが
/// `mouseDown` で拾ってブロックを展開する(`MarkdownEditorEngine.frontMatterLineRange(atPoint:)`)。
final class FrontMatterTableView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private(set) var entry: FrontMatterTableEntry? {
        didSet {
            isHidden = entry == nil
            if let entry {
                if frame != entry.frame { frame = entry.frame }
                if entry != oldValue { needsDisplay = true }
            }
        }
    }

    func update(entry: FrontMatterTableEntry?) { self.entry = entry }

    override func draw(_ dirtyRect: NSRect) {
        guard let entry, let context = NSGraphicsContext.current?.cgContext else { return }
        FrontMatterTableRenderer.draw(entry.layout, appearance: entry.appearance, in: context)
    }
}
#endif
