import SwiftUI

/// MarkdownTextView の SwiftUI ラッパー。
public struct MarkdownEditorView: NSViewRepresentable {
    @Binding private var text: String
    private var theme: MarkdownTheme
    private var showsLineNumbers = true
    private var inputInterceptor: (any TextInputInterceptor)?
    private var insertionPointStyle: InsertionPointStyle = .bar
    private var imagePreviewOptions = ImagePreviewOptions()
    private var imageLoader: (any ImageLoader)?
    private var onOutlineChange: (([OutlineItem]) -> Void)?
    private var foldingEnabled = true
    private var proxy: MarkdownEditorProxy?

    public init(text: Binding<String>, theme: MarkdownTheme = .default) {
        self._text = text
        self.theme = theme
    }

    public func showsLineNumbers(_ flag: Bool) -> MarkdownEditorView {
        var copy = self
        copy.showsLineNumbers = flag
        return copy
    }

    /// キー入力のインターセプタを設定する。MarkdownTextView 側は weak 保持のため、
    /// 呼び出し側がインターセプタの所有権を持つこと(@State 等)。
    public func inputInterceptor(_ interceptor: (any TextInputInterceptor)?) -> MarkdownEditorView {
        var copy = self
        copy.inputInterceptor = interceptor
        return copy
    }

    /// カーソル形状を設定する。
    public func insertionPointStyle(_ style: InsertionPointStyle) -> MarkdownEditorView {
        var copy = self
        copy.insertionPointStyle = style
        return copy
    }

    /// 画像プレビューの設定(baseURL・最大高さ・リモート許可など)。
    public func imagePreviewOptions(_ options: ImagePreviewOptions) -> MarkdownEditorView {
        var copy = self
        copy.imagePreviewOptions = options
        return copy
    }

    /// 画像ローダーを差し替える(キャッシュ戦略・認証付き取得などの注入点)。
    public func imageLoader(_ loader: any ImageLoader) -> MarkdownEditorView {
        var copy = self
        copy.imageLoader = loader
        return copy
    }

    /// アウトライン変化の通知を受け取る(パース確定時、実変化があったときだけ)。
    public func onOutlineChange(
        _ action: @escaping ([OutlineItem]) -> Void
    ) -> MarkdownEditorView {
        var copy = self
        copy.onOutlineChange = action
        return copy
    }

    /// セクション折りたたみの有効/無効(デフォルト有効)。
    public func foldingEnabled(_ enabled: Bool) -> MarkdownEditorView {
        var copy = self
        copy.foldingEnabled = enabled
        return copy
    }

    /// 命令的 API(scrollToHeading / fold 等)の呼び出し口を接続する。
    public func editorProxy(_ proxy: MarkdownEditorProxy) -> MarkdownEditorView {
        var copy = self
        copy.proxy = proxy
        return copy
    }

    /// make / update 共通の反映処理(テストの継ぎ目)
    func apply(to textView: MarkdownTextView) {
        textView.inputInterceptor = inputInterceptor
        textView.insertionPointStyle = insertionPointStyle
        textView.imagePreviewOptions = imagePreviewOptions
        if let imageLoader { textView.imageLoader = imageLoader }
        // SwiftUI のビュー更新中(makeNSView / updateNSView 内の highlightAll)に同期発火すると
        // 利用側の @State 更新が破棄されるため、次のランループへ遅延して届ける
        textView.onOutlineChange = onOutlineChange.map { callback in
            { items in DispatchQueue.main.async { callback(items) } }
        }
        textView.isFoldingEnabled = foldingEnabled
        proxy?.textView = textView
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MarkdownTextView.scrollableMarkdownEditor(theme: theme)
        let textView = scrollView.documentView as! MarkdownTextView
        textView.delegate = context.coordinator
        apply(to: textView)
        textView.string = text
        textView.highlightAll()
        textView.showsLineNumbers = showsLineNumbers
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! MarkdownTextView
        context.coordinator.text = $text
        if textView.string != text {
            context.coordinator.isUpdatingFromSwiftUI = true
            textView.string = text
            textView.highlightAll()
            context.coordinator.isUpdatingFromSwiftUI = false
        }
        if textView.theme != theme {
            textView.theme = theme
        }
        textView.showsLineNumbers = showsLineNumbers
        apply(to: textView)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var isUpdatingFromSwiftUI = false

        init(text: Binding<String>) {
            self.text = text
        }

        public func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromSwiftUI,
                  let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
