#if os(macOS)
import AppKit
@testable import Laperm

/// characterRange の表示フレーム中心点(textView 座標)を求める
@MainActor
func midpoint(of characterRange: NSRange, in textView: MarkdownTextView) -> NSPoint {
    let layoutManager = textView.textLayoutManager!
    let contentManager = layoutManager.textContentManager!
    layoutManager.ensureLayout(for: layoutManager.documentRange)
    let start = contentManager.location(
        contentManager.documentRange.location, offsetBy: characterRange.location)!
    let end = contentManager.location(start, offsetBy: characterRange.length)!
    let textRange = NSTextRange(location: start, end: end)!
    var frame = CGRect.zero
    layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) {
        _, segmentFrame, _, _ in
        frame = segmentFrame
        return false
    }
    let origin = textView.textContainerOrigin
    return NSPoint(x: frame.midX + origin.x, y: frame.midY + origin.y)
}

/// keyDown 系イベントを合成する(テスト共用。context は現行 SDK で nil 固定)
@MainActor
func keyEvent(
    _ characters: String, ignoringModifiers: String? = nil,
    modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0,
    type: NSEvent.EventType = .keyDown
) -> NSEvent {
    NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: 0, context: nil, characters: characters,
        charactersIgnoringModifiers: ignoringModifiers ?? characters,
        isARepeat: false, keyCode: keyCode)!
}

/// NSTextView は window か delegate から undoManager を取るため、テストでは delegate で供給する
@MainActor final class UndoManagerProvider: NSObject, NSTextViewDelegate {
    let manager = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}
#endif
