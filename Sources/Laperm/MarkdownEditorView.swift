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

    /// make / update 共通の反映処理(テストの継ぎ目)
    func apply(to textView: MarkdownTextView) {
        textView.inputInterceptor = inputInterceptor
        textView.insertionPointStyle = insertionPointStyle
        textView.imagePreviewOptions = imagePreviewOptions
        if let imageLoader { textView.imageLoader = imageLoader }
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MarkdownTextView.scrollableMarkdownEditor(theme: theme)
        let textView = scrollView.documentView as! MarkdownTextView
        textView.delegate = context.coordinator
        textView.string = text
        textView.highlightAll()
        textView.showsLineNumbers = showsLineNumbers
        apply(to: textView)
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
