import SwiftUI

/// MarkdownTextView の SwiftUI ラッパー(macOS: NSViewRepresentable / iOS: UIViewRepresentable)。
public struct MarkdownEditorView {
    @Binding private var text: String
    private var theme: MarkdownTheme
    private var showsLineNumbers = true
    #if os(macOS)
    private var inputInterceptor: (any TextInputInterceptor)?
    private var insertionPointStyle: InsertionPointStyle = .bar
    #endif
    private var imagePreviewOptions = ImagePreviewOptions()
    private var imageLoader: (any ImageLoader)?
    private var linkOptions = LinkOptions()
    private var onOpenLink: ((URL) -> Bool)?
    private var onOutlineChange: (([OutlineItem]) -> Void)?
    private var onFoldingChange: (([Int]) -> Void)?
    private var foldingEnabled = true
    private var editingOptions = EditingOptions()
    private var proxy: MarkdownEditorProxy?
    #if canImport(UIKit)
    private var keyboardAccessory: AnyView?
    #endif

    public init(text: Binding<String>, theme: MarkdownTheme = .default) {
        self._text = text
        self.theme = theme
    }

    public func showsLineNumbers(_ flag: Bool) -> MarkdownEditorView {
        var copy = self
        copy.showsLineNumbers = flag
        return copy
    }

    #if os(macOS)
    /// キー入力のインターセプタを設定する(macOS のみ)。MarkdownTextView 側は weak 保持のため、
    /// 呼び出し側がインターセプタの所有権を持つこと(@State 等)。
    public func inputInterceptor(_ interceptor: (any TextInputInterceptor)?) -> MarkdownEditorView {
        var copy = self
        copy.inputInterceptor = interceptor
        return copy
    }

    /// カーソル形状を設定する(macOS のみ)。
    public func insertionPointStyle(_ style: InsertionPointStyle) -> MarkdownEditorView {
        var copy = self
        copy.insertionPointStyle = style
        return copy
    }
    #endif

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

    /// リンク操作の設定(Cmd+クリックで開く・相対パスの baseURL)。
    public func linkOptions(_ options: LinkOptions) -> MarkdownEditorView {
        var copy = self
        copy.linkOptions = options
        return copy
    }

    /// リンクを開く前のフック。true を返すと消費(デフォルトの NSWorkspace.open を行わない)。
    public func onOpenLink(_ handler: @escaping (URL) -> Bool) -> MarkdownEditorView {
        var copy = self
        copy.onOpenLink = handler
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

    /// 折りたたまれている見出しの集合が変わったときの通知を受け取る(折りたたまれている見出し位置、昇順)。
    /// ガターのクリックや編集による自動展開も含む。
    public func onFoldingChange(
        _ action: @escaping ([Int]) -> Void
    ) -> MarkdownEditorView {
        var copy = self
        copy.onFoldingChange = action
        return copy
    }

    /// セクション折りたたみの有効/無効(デフォルト有効)。
    public func foldingEnabled(_ enabled: Bool) -> MarkdownEditorView {
        var copy = self
        copy.foldingEnabled = enabled
        return copy
    }

    /// 編集支援(リスト継続・括弧補完など)の個別 ON/OFF(デフォルトは全部有効)。
    public func editingOptions(_ options: EditingOptions) -> MarkdownEditorView {
        var copy = self
        copy.editingOptions = options
        return copy
    }

    /// 命令的 API(scrollToHeading / fold 等)の呼び出し口を接続する。
    public func editorProxy(_ proxy: MarkdownEditorProxy) -> MarkdownEditorView {
        var copy = self
        copy.proxy = proxy
        return copy
    }

    #if canImport(UIKit)
    /// キーボードの上に出すアクセサリ(iOS)。UITextView の `inputAccessoryView` に SwiftUI ビューを載せる。
    /// SwiftUI の `.toolbar(placement: .keyboard)` は UIViewRepresentable のテキストビューには付かないための口。
    /// 背景は透明で、高さはコンテンツの固有サイズから決まる。親の SwiftUI 環境(Environment)は引き継がない。
    public func keyboardAccessory<Content: View>(@ViewBuilder _ content: () -> Content) -> MarkdownEditorView {
        var copy = self
        copy.keyboardAccessory = AnyView(content())
        return copy
    }
    #endif

    /// make / update 共通の反映処理(テストの継ぎ目)
    @MainActor
    func apply(to textView: MarkdownTextView) {
        #if os(macOS)
        textView.inputInterceptor = inputInterceptor
        textView.insertionPointStyle = insertionPointStyle
        #endif
        textView.imagePreviewOptions = imagePreviewOptions
        if let imageLoader { textView.imageLoader = imageLoader }
        textView.linkOptions = linkOptions
        textView.onOpenLink = onOpenLink
        // SwiftUI のビュー更新中(makeNSView / updateNSView 内の highlightAll)に同期発火すると
        // 利用側の @State 更新が破棄されるため、次のランループへ遅延して届ける
        textView.onOutlineChange = onOutlineChange.map { callback in
            { items in DispatchQueue.main.async { callback(items) } }
        }
        textView.onFoldingChange = onFoldingChange.map { callback in
            { locations in DispatchQueue.main.async { callback(locations) } }
        }
        textView.isFoldingEnabled = foldingEnabled
        textView.editingOptions = editingOptions
        proxy?.textView = textView
    }
}

#if os(macOS)
extension MarkdownEditorView: NSViewRepresentable {
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
        if context.coordinator.needsTextReplacement(with: text, current: textView.string) {
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
        /// 直近にビューから binding へ書いた文字列(同一インスタンス判定用)
        var lastPushedText: String?

        init(text: Binding<String>) {
            self.text = text
        }

        public func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromSwiftUI,
                  let textView = notification.object as? NSTextView else { return }
            let string = textView.string
            lastPushedText = string
            text.wrappedValue = string
        }

        /// binding の値をビューへ書き戻す必要があるか。
        /// キーストロークごとに textDidChange → binding 更新 → updateNSView と戻ってくるが、
        /// そのたびに `textView.string != text` で文書全体を比較すると 10k 行で約 17ms かかる
        /// (NSTextView.string は毎回別インスタンスの非連続 String を返し、比較が低速経路に落ちる)。
        /// 自分が binding へ書いた String と同一インスタンスなら(String の == は
        /// バッファ同一で O(1))ビューは既にその内容なので比較を省く。
        func needsTextReplacement(with binding: String, current: @autoclosure () -> String) -> Bool {
            if let lastPushedText, lastPushedText == binding { return false }
            return current() != binding
        }
    }
}
#elseif canImport(UIKit)
extension MarkdownEditorView: UIViewRepresentable {
    public func makeUIView(context: Context) -> MarkdownTextView {
        let textView = MarkdownTextView(theme: theme)
        textView.delegate = context.coordinator
        apply(to: textView)
        applyKeyboardAccessory(to: textView, coordinator: context.coordinator)
        textView.text = text
        textView.highlightAll()
        textView.showsLineNumbers = showsLineNumbers
        return textView
    }

    public func updateUIView(_ textView: MarkdownTextView, context: Context) {
        context.coordinator.text = $text
        if context.coordinator.needsTextReplacement(with: text, current: textView.text) {
            context.coordinator.isUpdatingFromSwiftUI = true
            textView.text = text
            textView.highlightAll()
            context.coordinator.isUpdatingFromSwiftUI = false
        }
        if textView.theme != theme {
            textView.theme = theme
        }
        textView.showsLineNumbers = showsLineNumbers
        apply(to: textView)
        applyKeyboardAccessory(to: textView, coordinator: context.coordinator)
    }

    /// アクセサリの SwiftUI ビューをホスティングして inputAccessoryView に付ける(なければ外す)。
    /// 表示中に変わったときは reloadInputViews で反映する。
    @MainActor
    func applyKeyboardAccessory(to textView: MarkdownTextView, coordinator: Coordinator) {
        guard let keyboardAccessory else {
            guard coordinator.accessoryHost != nil else { return }
            coordinator.accessoryHost = nil
            textView.inputAccessoryView = nil
            if textView.isFirstResponder { textView.reloadInputViews() }
            return
        }
        if let host = coordinator.accessoryHost {
            host.rootView = keyboardAccessory
            return
        }
        let host = UIHostingController(rootView: keyboardAccessory)
        host.view.backgroundColor = .clear
        // 高さは SwiftUI の固有サイズから。UIKit は autoresizing を使わない inputAccessoryView の
        // 固有サイズ(自動レイアウト)を尊重する。
        host.sizingOptions = .intrinsicContentSize
        host.view.translatesAutoresizingMaskIntoConstraints = false
        coordinator.accessoryHost = host
        textView.inputAccessoryView = host.view
        if textView.isFirstResponder { textView.reloadInputViews() }
    }

    /// UITextView.sizeThatFits は全文の高さを返すため、デフォルト実装のままだとテキストビューが
    /// コンテンツ全体の高さに引き伸ばされて画面外にはみ出し、スクロールできなくなる。
    /// スクロールビューとして提案サイズをそのまま使う。
    public func sizeThatFits(
        _ proposal: ProposedViewSize, uiView: MarkdownTextView, context: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 240))
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    public final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var isUpdatingFromSwiftUI = false
        /// 直近にビューから binding へ書いた文字列(同一インスタンス判定用)
        var lastPushedText: String?
        /// キーボードアクセサリのホスト(`keyboardAccessory` が設定されているときだけ)
        var accessoryHost: UIHostingController<AnyView>?

        init(text: Binding<String>) {
            self.text = text
        }

        public func textViewDidChange(_ textView: UITextView) {
            guard !isUpdatingFromSwiftUI else { return }
            let string = textView.text ?? ""
            lastPushedText = string
            text.wrappedValue = string
        }

        /// binding の値をビューへ書き戻す必要があるか(macOS 版と同じ理由で全文比較を省く)。
        func needsTextReplacement(with binding: String, current: @autoclosure () -> String) -> Bool {
            if let lastPushedText, lastPushedText == binding { return false }
            return current() != binding
        }

        /// 編集メニューにリンク項目を足す(リンク上のときだけ)
        public func textView(
            _ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            (textView as? MarkdownTextView)?
                .editMenu(forTextIn: range, suggestedActions: suggestedActions)
        }
    }
}
#endif
