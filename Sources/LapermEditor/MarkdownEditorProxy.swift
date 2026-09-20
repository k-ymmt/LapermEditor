#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import LapermCore

/// SwiftUI(MarkdownEditorView)から MarkdownTextView の命令的 API
/// (scrollToHeading / fold 等)を呼ぶための橋。`.editorProxy(_:)` で接続する。
/// 利用側(@State 等)が所有権を持ち、ビューは weak 参照のみ保持する。
@MainActor
public final class MarkdownEditorProxy {
    /// 通常は `.editorProxy(_:)` が接続する。テストや独自ホストは直接設定してよい。
    public weak var textView: MarkdownTextView?

    public init() {}

    public func scrollToHeading(at headingLocation: Int) {
        textView?.scrollToHeading(at: headingLocation)
    }
    public func fold(at headingLocation: Int) { textView?.fold(at: headingLocation) }
    public func unfold(at headingLocation: Int) { textView?.unfold(at: headingLocation) }
    public func toggleFold(at headingLocation: Int) { textView?.toggleFold(at: headingLocation) }
    public func unfoldAll() { textView?.unfoldAll() }

    /// 選択範囲(なければカーソル位置の単語)のボールド / イタリックを切り替える。適用できたら true。
    @discardableResult
    public func toggleEmphasis(_ style: EmphasisStyle) -> Bool {
        textView?.toggleEmphasis(style) ?? false
    }

    /// テキストビューの undo マネージャ(ビュー未接続なら nil)。
    /// 実行可否の監視には `NSUndoManager` の通知(checkpoint / didUndo / didRedo / didCloseUndoGroup)を使う。
    public var undoManager: UndoManager? { textView?.undoManager }

    public var canUndo: Bool { undoManager?.canUndo ?? false }
    public var canRedo: Bool { undoManager?.canRedo ?? false }

    public func undo() { undoManager?.undo() }
    public func redo() { undoManager?.redo() }

    #if canImport(UIKit)
    /// キーボードを閉じる(ファーストレスポンダを外す)。
    public func dismissKeyboard() {
        _ = textView?.resignFirstResponder()
    }
    #endif
}

