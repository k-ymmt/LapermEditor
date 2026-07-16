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
    let imagePreviewController = ImagePreviewController()
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

    /// キー入力のインターセプタ(weak 保持)。Vim モード等のモーダル編集の実装点。
    /// IME 変換中(marked text)は変換セッションを優先し、呼ばれない。
    public weak var inputInterceptor: (any TextInputInterceptor)?

    /// カーソル形状。bar 以外ではシステムの挿入ポイントを消してオーバーレイで描く。
    /// 注意: 現状オーバーレイはフォーカス状態を見ない(非フォーカスでも表示される)
    /// bar 以外のスタイル中は `insertionPointColor` を外部から設定しないこと(システムキャレットの再表示と、bar 復帰時の保存色復元により設定が失われるため)。
    public var insertionPointStyle: InsertionPointStyle = .bar {
        didSet {
            guard insertionPointStyle != oldValue else { return }
            // システムのインジケータ(NSTextInsertionIndicator)はサブビュー構成に
            // 依存しないよう色で消し、bar に戻すとき元色を復元する
            if insertionPointStyle == .bar {
                if let color = barInsertionPointColor { insertionPointColor = color }
                barInsertionPointColor = nil
            } else if barInsertionPointColor == nil {
                barInsertionPointColor = insertionPointColor
                insertionPointColor = .clear
            }
            updateInsertionPointOverlay()
        }
    }

    /// 画像プレビューの設定。baseURL / allowsRemoteImages の変更は全ロードをやり直す。
    public var imagePreviewOptions: ImagePreviewOptions {
        get { imagePreviewController.options }
        set {
            guard imagePreviewController.options != newValue else { return }
            imagePreviewController.options = newValue
            imagePreviewController.resetLoads()
            updateImagePreviews()
        }
    }

    /// 画像ローダー。差し替えると全ロードをやり直す。
    public var imageLoader: any ImageLoader {
        get { imagePreviewController.loader }
        set {
            guard imagePreviewController.loader !== newValue else { return }
            imagePreviewController.loader = newValue
            imagePreviewController.resetLoads()
            updateImagePreviews()
        }
    }

    private var barInsertionPointColor: NSColor?
    private let insertionPointOverlay = InsertionPointOverlayView()
    private let imageOverlay = ImagePreviewOverlayView()
    private var collectedImageEntries: [ImagePreviewOverlayEntry] = []
    private var lastImageContainerWidth: CGFloat = 0

    /// テスト用: 直近のビューポートレイアウトで収集したオーバーレイ配置。
    var debugImageEntries: [ImagePreviewOverlayEntry] { collectedImageEntries }

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

        imageOverlay.autoresizingMask = [.width, .height]
        addSubview(imageOverlay)

        imagePreviewController.onStateChange = { [weak self] in
            guard let self else { return }
            if self.hasMarkedText() {
                // IME 変換中は spacing 変更を遅延(highlightNow と同じガードに乗せる)
                self.scheduleHighlight()
            } else {
                self.updateImagePreviews()
            }
        }
    }

    /// 全文を再ハイライトする。`string` をプログラムで差し替えた後に呼ぶこと。
    public func highlightAll() {
        guard let contentStorage = textContentStorage,
              let layoutManager = textLayoutManager else { return }
        markdownHighlighter.rehighlightAll(
            contentStorage: contentStorage, layoutManager: layoutManager)
        updateBlockDecorations()
        updateImagePreviews()
        updateInsertionPointOverlay()
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
        updateImagePreviews()
        updateInsertionPointOverlay()
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

    /// 画像プレビューの状態を最新プランに同期し、スペーシングを適用する。
    /// 注意: バックグラウンドパース経路では currentPlan の更新が非同期になるため、
    /// ブロック装飾と同様に 1 サイクル遅延する(v1 で許容済みの設計)。
    private func updateImagePreviews() {
        guard let contentStorage = textContentStorage else { return }
        imagePreviewController.update(references: markdownHighlighter.currentPlan.images)
        imagePreviewController.applySpacings(
            contentStorage: contentStorage, containerWidth: imageContainerWidth)
    }

    /// このフラグメント(1 テキスト段落)に属する画像のオーバーレイ配置を収集する。
    private func collectImagePreviews(for fragment: NSTextLayoutFragment) {
        let references = imagePreviewController.references
        guard !references.isEmpty,
              let contentManager = textLayoutManager?.textContentManager,
              let elementRange = fragment.textElement?.elementRange
        else { return }
        let start = contentManager.offset(
            from: contentManager.documentRange.location, to: elementRange.location)
        let end = contentManager.offset(
            from: contentManager.documentRange.location, to: elementRange.endLocation)
        let paragraphReferences = references
            .filter { $0.paragraphRange.location >= start && $0.paragraphRange.location < end }
            .sorted { $0.range.location < $1.range.location }
        guard !paragraphReferences.isEmpty else { return }
        let width = imageContainerWidth
        let sizes = paragraphReferences.map {
            imagePreviewController.displaySize(for: $0, containerWidth: width)
        }
        let origin = textContainerOrigin
        // テキスト行群の下端(フラグメント原点からの相対値)。予約領域はここから下に伸びる。
        // textLineFragments が空(レイアウト未確定)のときは reduce の初期値 0 のままになる。
        let textLinesBottom = fragment.textLineFragments
            .reduce(0) { max($0, $1.typographicBounds.maxY) }
        let items = ImagePreviewLayout.itemFrames(
            references: paragraphReferences,
            sizes: sizes,
            fragmentFrame: fragment.layoutFragmentFrame,
            textLinesBottom: textLinesBottom,
            leadingInset: textContainer?.lineFragmentPadding ?? 0,
            padding: ImagePreviewController.padding)
        for item in items {
            guard let state = imagePreviewController.state(for: item.reference) else { continue }
            collectedImageEntries.append(ImagePreviewOverlayEntry(
                reference: item.reference,
                frame: item.frame.offsetBy(dx: origin.x, dy: origin.y),
                state: state))
        }
    }

    /// プレビューが使える幅 = テキストコンテナの実効幅(lineFragmentPadding を除く)
    var imageContainerWidth: CGFloat {
        guard let container = textContainer else { return max(0, bounds.width) }
        return max(0, container.size.width - container.lineFragmentPadding * 2)
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
        collectedImageEntries.removeAll(keepingCapacity: true)
    }

    public override func textViewportLayoutController(
        _ textViewportLayoutController: NSTextViewportLayoutController,
        configureRenderingSurfaceFor textLayoutFragment: NSTextLayoutFragment
    ) {
        super.textViewportLayoutController(
            textViewportLayoutController,
            configureRenderingSurfaceFor: textLayoutFragment
        )
        collectImagePreviews(for: textLayoutFragment)
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
        imageOverlay.update(entries: collectedImageEntries)
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

    // MARK: - 入力インターセプト

    public override func keyDown(with event: NSEvent) {
        if interceptsKeyDown(event) { return }
        super.keyDown(with: event)
    }

    /// keyDown をインターセプタが消費すべきなら true。
    /// mouseDown / toggleCheckbox と同様、テストから直接呼べるよう分離してある。
    func interceptsKeyDown(_ event: NSEvent) -> Bool {
        guard let interceptor = inputInterceptor,
            !hasMarkedText(),
            let input = KeyInput(event: event)
        else { return false }
        return interceptor.textView(self, handle: input) == .handled
    }

    // MARK: - カーソル形状

    public override func setSelectedRanges(
        _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateInsertionPointOverlay()
    }

    public override func didChangeText() {
        super.didChangeText()
        updateInsertionPointOverlay()
    }

    public override func layout() {
        super.layout()
        updateInsertionPointOverlay()
        imageOverlay.frame = bounds
        if imageContainerWidth != lastImageContainerWidth {
            lastImageContainerWidth = imageContainerWidth
            // 幅が変わると loaded 画像のフィット高さが変わるため spacing を再計算
            updateImagePreviews()
        }
    }

    private func updateInsertionPointOverlay() {
        guard insertionPointStyle != .bar,
            selectedRange().length == 0,
            let frame = caretOverlayFrame()
        else {
            insertionPointOverlay.removeFromSuperview()
            return
        }
        if insertionPointOverlay.superview !== self {
            addSubview(insertionPointOverlay)
        }
        insertionPointOverlay.style = insertionPointStyle
        insertionPointOverlay.color = barInsertionPointColor ?? .textInsertionPointColor
        insertionPointOverlay.frame = frame
        insertionPointOverlay.needsDisplay = true
    }

    /// カーソル位置の文字を覆う矩形(textView 座標)。行末・空行では等幅 1 文字ぶんの幅。
    private func caretOverlayFrame() -> NSRect? {
        guard let layoutManager = textLayoutManager,
            let contentManager = layoutManager.textContentManager
        else { return nil }
        let text = string as NSString
        let caret = selectedRange().location
        guard caret != NSNotFound, caret <= text.length else { return nil }
        var characterRange = NSRange(location: caret, length: 0)
        if caret < TextMotions.lineEnd(text: text, at: caret) {
            characterRange = text.rangeOfComposedCharacterSequence(at: caret)
        }
        guard let start = contentManager.location(
                contentManager.documentRange.location, offsetBy: characterRange.location),
            let end = contentManager.location(start, offsetBy: characterRange.length),
            let textRange = NSTextRange(location: start, end: end)
        else { return nil }
        // キーストロークごとに呼ばれるため、レイアウト保証はキャレット周辺のみに絞る
        // (documentRange 全体だとビューポート単位の増分レイアウトが無効化される)
        layoutManager.ensureLayout(for: textRange)
        var segmentFrame = CGRect.null
        layoutManager.enumerateTextSegments(
            in: textRange, type: .standard, options: [.rangeNotRequired]
        ) { _, frame, _, _ in
            segmentFrame = frame
            return false
        }
        guard !segmentFrame.isNull else { return nil }
        var frame = segmentFrame
        if frame.width < 1 {
            // キャレットのみ(行末・空行)は等幅 1 文字ぶんの幅を与える
            frame.size.width = ("M" as NSString)
                .size(withAttributes: [.font: theme.bodyFont]).width
        }
        let origin = textContainerOrigin
        return NSRect(
            x: frame.minX + origin.x, y: frame.minY + origin.y,
            width: frame.width, height: frame.height)
    }

    // MARK: - 編集支援

    public override func insertNewline(_ sender: Any?) {
        if editingOptions.continuesLists,
            let command = EditingAssistant.newline(
                text: string as NSString, selection: selectedRange()),
            perform(command) {
            return
        }
        super.insertNewline(sender)
    }

    public override func insertTab(_ sender: Any?) {
        if editingOptions.indentsListItems,
            let command = EditingAssistant.indent(
                text: string as NSString, selection: selectedRange()),
            perform(command) {
            return
        }
        super.insertTab(sender)
    }

    public override func insertBacktab(_ sender: Any?) {
        if editingOptions.indentsListItems,
            let command = EditingAssistant.outdent(
                text: string as NSString, selection: selectedRange()),
            perform(command) {
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
            perform(command) {
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    public override func deleteBackward(_ sender: Any?) {
        // 空ペアの間で Backspace したら両側をまとめて削除(ペア補完の対になる操作)
        if editingOptions.completesPairs, !hasMarkedText(),
            let command = EditingAssistant.deleteBackward(
                text: string as NSString, selection: selectedRange()),
            perform(command) {
            return
        }
        super.deleteBackward(sender)
    }

    public override func mouseDown(with event: NSEvent) {
        if editingOptions.togglesCheckboxOnClick,
            event.clickCount == 1,
            // deviceIndependentFlagsMask は capsLock を含み、Caps Lock 中は常時セットされるため
            // 実際に押されうる修飾キーだけを見る
            event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty,
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
        guard perform(command) else { return false }
        selectedRanges = selectionBefore
        return true
    }

    /// EditCommand を undo 対応の経路で適用する。
    /// shouldChangeText / didChangeText を通すことで NSTextView 標準の undo に乗り、
    /// 既存の NSTextStorageDelegate 経由で再ハイライトも自動で走る。
    /// 範囲が文書外のコマンドは適用せず false を返す。
    /// IME 変換中(`hasMarkedText()` が true)の呼び出しは変換セッションを乱す恐れがあるため避けること。
    @discardableResult
    public func perform(_ command: EditCommand) -> Bool {
        let length = (string as NSString).length
        guard command.replacementRange.location != NSNotFound,
            NSMaxRange(command.replacementRange) <= length
        else { return false }
        // 適用後の文書長で selectedRange を検証(範囲外だと NSTextView が例外を投げる)
        let newLength = length - command.replacementRange.length
            + (command.replacementString as NSString).length
        guard command.selectedRange.location != NSNotFound,
            NSMaxRange(command.selectedRange) <= newLength
        else { return false }
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
