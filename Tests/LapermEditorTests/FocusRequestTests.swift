#if os(macOS)
import AppKit
import Testing
@testable import LapermEditor

/// フォーカスを持てるだけのビュー(`NSTextField` だとフィールドエディタが first responder になり、比べにくい)。
private final class ResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor private func makeWindow() -> (NSWindow, NSView) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    let other = ResponderView()
    window.contentView = NSView()
    window.contentView?.addSubview(other)
    window.makeFirstResponder(other)
    return (window, other)
}

@MainActor @Test func focusInAWindowMakesTheTextViewFirstResponderAtOnce() {
    let (window, _) = makeWindow()
    let textView = MarkdownTextView()
    window.contentView?.addSubview(textView)
    let proxy = MarkdownEditorProxy()
    proxy.textView = textView
    proxy.focus()
    #expect(window.firstResponder === textView)
}

/// SwiftUI はテキストビューを作ってからウィンドウに載せる: その間の要求は、載ったときに効く。
@MainActor @Test func focusBeforeTheViewIsInAWindowTakesEffectOnceItIs() async throws {
    let (window, other) = makeWindow()
    let textView = MarkdownTextView()
    textView.focus()
    #expect(window.firstResponder === other)
    window.contentView?.addSubview(textView)
    // ウィンドウへの挿入の最中には替えない(次のターン)。待つ間は main queue が回る(入れ子のランループでは回らない)。
    try await waitUntil { window.firstResponder === textView }

    // 要求は 1 回きり: 外して載せ直してもフォーカスは奪わない
    window.makeFirstResponder(other)
    textView.removeFromSuperview()
    window.contentView?.addSubview(textView)
    try await Task.sleep(for: .milliseconds(100))
    #expect(window.firstResponder === other)
}
#endif
