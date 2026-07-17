import AppKit

/// Cmd+ホバー中のリンク下線を描く軽量オーバーレイ。ヒットテスト対象外。
///
/// `NSTextLayoutManager.addRenderingAttribute(.underlineStyle, ...)` は
/// 実機検証の結果、TextKit2 のビューポート再レイアウトを強制しても描画に反映されない
/// (`.backgroundColor` など他のレンダリング属性は反映されるため、下線特有の制約と判断)。
/// そのため InsertionPointOverlayView と同じ「座標を計算してオーバーレイに描く」方式を使う。
final class LinkHoverOverlayView: NSView {
    var color: NSColor = .textColor { didSet { needsDisplay = true } }
    /// 下線を引く矩形群(このビュー自身のローカル座標)。複数行に渡るリンクでは行ごとに 1 矩形。
    var underlineRects: [NSRect] = [] { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        for rect in underlineRects {
            NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
        }
    }
}
