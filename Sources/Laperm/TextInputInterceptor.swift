import AppKit
import LapermCore

/// キー入力をテキストビューの処理前に横取りするインターセプタ。
/// handled を返すとイベントは消費され、テキスト挿入・編集支援・
/// キーバインディング処理のいずれにも到達しない。
/// MarkdownTextView は weak 保持するため、利用側がインターセプタの所有権を持つこと。
@MainActor
public protocol TextInputInterceptor: AnyObject {
    func textView(_ textView: MarkdownTextView, handle input: KeyInput) -> KeyInputResult
}
