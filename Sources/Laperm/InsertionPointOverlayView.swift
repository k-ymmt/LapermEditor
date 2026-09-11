#if os(macOS)
import AppKit

/// bar 以外のカーソル形状を描く軽量オーバーレイ。ヒットテスト対象外。
final class InsertionPointOverlayView: NSView {
    var style: InsertionPointStyle = .bar { didSet { needsDisplay = true } }
    var color: NSColor = .textInsertionPointColor { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .bar:
            break
        case .block:
            // 半透明にして下の文字が読めるようにする
            color.withAlphaComponent(0.4).setFill()
            bounds.fill()
        case .underline:
            color.setFill()
            NSRect(x: 0, y: bounds.maxY - 2, width: bounds.width, height: 2).fill()
        }
    }
}
#endif
