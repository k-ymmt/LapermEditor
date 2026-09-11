#if os(macOS)
import AppKit
import LapermCore

/// SwiftUI(MarkdownEditorView)から MarkdownTextView の命令的 API
/// (scrollToHeading / fold 等)を呼ぶための橋。`.editorProxy(_:)` で接続する。
/// 利用側(@State 等)が所有権を持ち、ビューは weak 参照のみ保持する。
@MainActor
public final class MarkdownEditorProxy {
    public internal(set) weak var textView: MarkdownTextView?

    public init() {}

    public func scrollToHeading(at headingLocation: Int) {
        textView?.scrollToHeading(at: headingLocation)
    }
    public func fold(at headingLocation: Int) { textView?.fold(at: headingLocation) }
    public func unfold(at headingLocation: Int) { textView?.unfold(at: headingLocation) }
    public func toggleFold(at headingLocation: Int) { textView?.toggleFold(at: headingLocation) }
    public func unfoldAll() { textView?.unfoldAll() }
}
#endif
