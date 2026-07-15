import AppKit
import LapermCore

/// TextKit2 ベースの Markdown エディタビュー。
/// 警告: このクラス(および利用側)は `layoutManager` プロパティに絶対にアクセスしないこと。
/// アクセスした瞬間に TextKit1 互換モードへフォールバックし、全機能が壊れる。
@MainActor
public final class MarkdownTextView: NSTextView {
    let markdownHighlighter: Highlighter
    private var highlightScheduled = false
    private var fragmentProvider: BlockFragmentProvider!
    weak var gutterView: LineNumberGutterView?
    private var lineIndex: LineIndex?
    private var collectedLines: [LineNumberGutterView.Line] = []

    public var theme: MarkdownTheme {
        get { markdownHighlighter.theme }
        set {
            markdownHighlighter.theme = newValue
            backgroundColor = newValue.backgroundColor
            font = newValue.bodyFont
            fragmentProvider.theme = newValue
            highlightAll()
        }
    }

    public var showsLineNumbers: Bool = true {
        didSet { enclosingScrollView?.rulersVisible = showsLineNumbers }
    }

    /// 編集支援機能の設定(デフォルト全 ON)
    public var editingOptions = EditingOptions()

    public convenience init(theme: MarkdownTheme = .default) {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: 1_000_000))
        container.widthTracksTextView = true
        layoutManager.textContainer = container
        self.init(frame: .zero, textContainer: container, theme: theme)
    }

    init(frame frameRect: NSRect, textContainer container: NSTextContainer?, theme: MarkdownTheme) {
        self.markdownHighlighter = Highlighter(theme: theme)
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("MarkdownTextView does not support NSCoder")
    }

    private func configure() {
        isRichText = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        font = markdownHighlighter.theme.bodyFont
        drawsBackground = true
        backgroundColor = markdownHighlighter.theme.backgroundColor
        // NSTextContentStorage は NSTextStorageObserving 経由で storage を監視するため
        // delegate スロットは空いている
        textStorage?.delegate = self

        let provider = BlockFragmentProvider(theme: markdownHighlighter.theme)
        provider.fallbackDelegate = textLayoutManager?.delegate
        textLayoutManager?.delegate = provider
        fragmentProvider = provider

        // バックグラウンドパース完了経路も IME 変換中の属性適用を避けるため、
        // highlightNow() と同じガードをここでも効かせる。
        markdownHighlighter.shouldDeferApply = { [weak self] in self?.hasMarkedText() ?? false }
        markdownHighlighter.applyDeferred = { [weak self] in self?.scheduleHighlight() }
    }

    /// 全文を再ハイライトする。`string` をプログラムで差し替えた後に呼ぶこと。
    public func highlightAll() {
        guard let contentStorage = textContentStorage,
              let layoutManager = textLayoutManager else { return }
        markdownHighlighter.rehighlightAll(
            contentStorage: contentStorage, layoutManager: layoutManager)
        updateBlockDecorations()
    }

    /// 保留中の編集を即時処理する(通常は didProcessEditing からの遅延実行で呼ばれる)。
    func highlightNow() {
        // 日本語変換中(IME マークテキスト表示中)はフラッシュを遅延する。
        // 変換中の下線付きテキストはまだ確定しておらず、ここで textStorage に
        // 属性を適用すると変換セッションが乱れる恐れがあるため、確定(コミット)後に
        // 改めてスケジュールし直す。
        guard !hasMarkedText() else {
            highlightScheduled = false
            scheduleHighlight()
            return
        }
        highlightScheduled = false
        guard let contentStorage = textContentStorage,
              let layoutManager = textLayoutManager else { return }
        markdownHighlighter.flushPendingHighlight(
            contentStorage: contentStorage, layoutManager: layoutManager)
        updateBlockDecorations()
    }

    private func updateBlockDecorations() {
        guard let contentStorage = textContentStorage,
              let layoutManager = textLayoutManager else { return }
        fragmentProvider.update(
            plan: markdownHighlighter.currentPlan,
            contentManager: contentStorage,
            layoutManager: layoutManager
        )
    }

    func scheduleHighlight() {
        guard !highlightScheduled else { return }
        highlightScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.highlightNow()
        }
    }

    public override func textViewportLayoutControllerWillLayout(
        _ textViewportLayoutController: NSTextViewportLayoutController
    ) {
        super.textViewportLayoutControllerWillLayout(textViewportLayoutController)
        collectedLines.removeAll(keepingCapacity: true)
    }

    public override func textViewportLayoutController(
        _ textViewportLayoutController: NSTextViewportLayoutController,
        configureRenderingSurfaceFor textLayoutFragment: NSTextLayoutFragment
    ) {
        super.textViewportLayoutController(
            textViewportLayoutController,
            configureRenderingSurfaceFor: textLayoutFragment
        )
        guard gutterView != nil,
            let contentManager = textLayoutManager?.textContentManager
        else { return }
        let offset = contentManager.offset(
            from: contentManager.documentRange.location,
            to: textLayoutFragment.rangeInElement.location
        )
        let index = lineIndex ?? LineIndex(text: string)
        lineIndex = index
        collectedLines.append(
            .init(
                number: index.lineNumber(at: offset),
                yInTextView: textLayoutFragment.layoutFragmentFrame.minY
            ))
    }

    public override func textViewportLayoutControllerDidLayout(
        _ textViewportLayoutController: NSTextViewportLayoutController
    ) {
        super.textViewportLayoutControllerDidLayout(textViewportLayoutController)
        gutterView?.lines = collectedLines
    }

    /// ガター付きの推奨構成。documentView は MarkdownTextView。
    public static func scrollableMarkdownEditor(theme: MarkdownTheme = .default) -> NSScrollView {
        let textView = MarkdownTextView(theme: theme)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // maxSize を明示しないと frame 変更時に frame サイズへ追従してしまい、
        // 文書がクリップ領域より高くなっても伸びられずスクロール不能になる
        textView.minSize = .zero
        textView.maxSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true

        let gutter = LineNumberGutterView(scrollView: scrollView)
        gutter.clientView = textView
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = textView.showsLineNumbers
        textView.gutterView = gutter
        return scrollView
    }

    // MARK: - 編集支援

    public override func insertNewline(_ sender: Any?) {
        if editingOptions.continuesLists,
            let command = EditingAssistant.newline(
                text: string as NSString, selection: selectedRange()),
            apply(command) {
            return
        }
        super.insertNewline(sender)
    }

    public override func insertTab(_ sender: Any?) {
        if editingOptions.indentsListItems,
            let command = EditingAssistant.indent(
                text: string as NSString, selection: selectedRange()),
            apply(command) {
            return
        }
        super.insertTab(sender)
    }

    public override func insertBacktab(_ sender: Any?) {
        if editingOptions.indentsListItems,
            let command = EditingAssistant.outdent(
                text: string as NSString, selection: selectedRange()),
            apply(command) {
            return
        }
        super.insertBacktab(sender)
    }

    public override func insertText(_ insertString: Any, replacementRange: NSRange) {
        // IME 変換中・属性付き文字列・置換指定付きの挿入(IME 確定等)は対象外
        if editingOptions.completesPairs, !hasMarkedText(),
            replacementRange.location == NSNotFound,
            let typed = insertString as? String,
            let command = EditingAssistant.insertion(
                text: string as NSString, selection: selectedRange(), typing: typed),
            apply(command) {
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    public override func mouseDown(with event: NSEvent) {
        if editingOptions.togglesCheckboxOnClick,
            event.clickCount == 1,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
            toggleCheckbox(atPoint: convert(event.locationInWindow, from: nil)) {
            return
        }
        super.mouseDown(with: event)
    }

    /// point(ビュー座標)のクリックでチェックボックスをトグルする。トグルしたら true。
    /// mouseDown から分離してあるのはテストで座標を直接渡せるようにするため。
    func toggleCheckbox(atPoint point: NSPoint) -> Bool {
        let offset = characterIndexForInsertion(at: point)
        guard let command = EditingAssistant.toggleCheckbox(
            text: string as NSString, at: offset) else { return false }
        // 同長 1 文字の置換なので選択座標はずれない — 適用前の選択を復元する
        let selectionBefore = selectedRanges
        guard apply(command) else { return false }
        selectedRanges = selectionBefore
        return true
    }

    /// EditCommand を undo 対応の経路で適用する。
    /// shouldChangeText / didChangeText を通すことで NSTextView 標準の undo に乗り、
    /// 既存の NSTextStorageDelegate 経由で再ハイライトも自動で走る。
    private func apply(_ command: EditCommand) -> Bool {
        // 純粋なカーソル移動(タイプオーバー)は置換なしで選択だけ動かす
        if command.replacementRange.length == 0, command.replacementString.isEmpty {
            setSelectedRange(command.selectedRange)
            return true
        }
        guard shouldChangeText(
                in: command.replacementRange, replacementString: command.replacementString),
            let textStorage else { return false }
        textStorage.replaceCharacters(
            in: command.replacementRange, with: command.replacementString)
        didChangeText()
        setSelectedRange(command.selectedRange)
        return true
    }
}

extension MarkdownTextView: NSTextStorageDelegate {
    public func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        // 属性のみの編集(自分自身のハイライト適用)には反応しない — 無限ループ防止
        guard editedMask.contains(.editedCharacters) else { return }
        lineIndex = nil
        markdownHighlighter.noteEdit(editedRange: editedRange, changeInLength: delta)
        scheduleHighlight()
    }
}
