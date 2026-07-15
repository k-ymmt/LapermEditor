import AppKit
@testable import Laperm

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
