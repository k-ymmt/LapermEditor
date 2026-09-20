#if canImport(UIKit)
import UIKit
import LapermCore

/// TextKit2 ベースの Markdown エディタビュー(UIKit)。
/// 警告: このクラス(および利用側)は `layoutManager` プロパティに絶対にアクセスしないこと。
/// アクセスした瞬間に TextKit1 互換モードへフォールバックし、全機能が壊れる。
///
/// ハイライト・折畳・画像プレビューのロジックは AppKit 版と共有の
/// `MarkdownEditorEngine` にあり、このクラスは UIKit 固有の入力・描画・座標系を担う。
/// - 行番号ガターはサブビューとして可視領域にピン留めし、`textContainerInset.left` で
///   テキストを右へ逃がす(UIKit に NSRulerView 相当が無いため)。
/// - リンクは編集メニュー「リンクを開く」(editMenu(forTextIn:suggestedActions:) を delegate から
///   返す)と、ハードウェアキーボードの Cmd+タップで開く。iPad のポインタでは Cmd+ホバーで下線を出す。
/// - macOS 版の TextInputInterceptor / insertionPointStyle は提供しない。
@MainActor
public final class MarkdownTextView: UITextView {
    let engine: MarkdownEditorEngine
    private let gutter = LineNumberGutterView()
    private let imageOverlay = ImagePreviewOverlayView()
    private let linkHoverOverlay = LinkHoverOverlayView()
    private var collectedLines: [GutterLine] = []
    private var collectedImageEntries: [ImagePreviewOverlayEntry] = []
    private var lastImageContainerWidth: CGFloat = 0
    private var hoveredLinkRange: NSRange?
    private var lastHoverPoint: CGPoint?
    private var commandKeyHeld = false
    private let tapDelegate = EditorTapGestureDelegate()

    /// テスト用: 共有エンジンのコンポーネントへの近道
    var markdownHighlighter: Highlighter { engine.highlighter }
    var imagePreviewController: ImagePreviewController { engine.imagePreviewController }
    var foldingController: FoldingController { engine.foldingController }
    /// テスト用: ガター(サブビュー)
    var gutterView: LineNumberGutterView { gutter }
    /// テスト用: 現在ホバー中のリンクレンジ。
    var debugHoveredLinkRange: NSRange? { hoveredLinkRange }
    /// テスト用: ホバー下線オーバーレイに設定されている矩形群(テキストビュー座標)。
    var debugLinkHoverUnderlineRects: [CGRect] {
        linkHoverOverlay.underlineRects.map { $0.offsetBy(dx: bounds.minX, dy: bounds.minY) }
    }
    /// テスト用: 直近のビューポートレイアウトで収集したオーバーレイ配置。
    var debugImageEntries: [ImagePreviewOverlayEntry] { collectedImageEntries }

    public var theme: MarkdownTheme {
        get { engine.theme }
        set {
            engine.theme = newValue
            backgroundColor = newValue.backgroundColor
            font = newValue.bodyFont
            textColor = newValue.bodyColor
            engine.applyThemeChange()
        }
    }

    /// 行番号ガターの表示(デフォルト true)。
    public var showsLineNumbers: Bool = true {
        didSet {
            guard showsLineNumbers != oldValue else { return }
            updateGutterLayout()
        }
    }

    /// 編集支援機能の設定(デフォルト全 ON)
    public var editingOptions = EditingOptions()

    /// リンク操作の設定。`opensOnCommandClick` は iOS では「リンクを開く操作全体
    /// (長押しメニュー・Cmd+タップ・Cmd+ホバー下線)」の有効/無効として扱う。
    public var linkOptions = LinkOptions()

    /// リンクを開く前のフック。true を返すと消費し、デフォルト動作
    /// (UIApplication.shared.open)を行わない。
    public var onOpenLink: ((URL) -> Bool)?

    /// 画像プレビューの設定。baseURL / allowsRemoteImages の変更は全ロードをやり直す。
    public var imagePreviewOptions: ImagePreviewOptions {
        get { engine.imagePreviewOptions }
        set { engine.imagePreviewOptions = newValue }
    }

    /// 画像ローダー。差し替えると全ロードをやり直す。
    public var imageLoader: any ImageLoader {
        get { engine.imageLoader }
        set { engine.imageLoader = newValue }
    }

    // MARK: - アウトライン / 折りたたみ

    /// 現在のアウトライン(パース確定時に更新される)
    public var outline: [OutlineItem] { engine.outline }

    /// アウトラインが実際に変化したときだけ呼ばれる(Equatable 比較)
    public var onOutlineChange: (([OutlineItem]) -> Void)? {
        get { engine.onOutlineChange }
        set { engine.onOutlineChange = newValue }
    }

    /// 折りたたまれている見出しの集合が変わったときに、その見出し位置(昇順)で呼ばれる。
    /// API 呼び出し・ガターのクリック・編集による自動展開・見出しの消失のどれでも通知する
    public var onFoldingChange: (([Int]) -> Void)? {
        get { engine.onFoldingChange }
        set { engine.onFoldingChange = newValue }
    }

    /// 折りたたまれている見出しの位置(昇順)
    public var foldedHeadingLocations: [Int] { engine.foldedHeadingLocations }

    /// 折りたたみ機能の有効/無効。無効化すると全折畳を解除し、以後の折畳操作を無視する
    public var isFoldingEnabled: Bool {
        get { engine.isFoldingEnabled }
        set { engine.isFoldingEnabled = newValue }
    }

    /// headingLocation(OutlineItem.headingLocation)のセクションを折りたたむ
    public func fold(at headingLocation: Int) { engine.fold(at: headingLocation) }
    public func unfold(at headingLocation: Int) { engine.unfold(at: headingLocation) }
    public func toggleFold(at headingLocation: Int) { engine.toggleFold(at: headingLocation) }
    public func unfoldAll() { engine.unfoldAll() }
    public func isFolded(at headingLocation: Int) -> Bool { engine.isFolded(at: headingLocation) }

    /// 見出しへスクロールする。祖先セクションが折畳中なら先に展開する
    public func scrollToHeading(at headingLocation: Int) {
        engine.unfoldAll(intersecting: NSRange(location: headingLocation, length: 0))
        scrollRangeToVisible(NSRange(location: headingLocation, length: 0))
    }

    // MARK: - 初期化

    public convenience init(theme: MarkdownTheme = .default) {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        // 高さは 1e7 にする(AppKit 版と同じ理由: 小さい高さは TextKit2 の
        // ビューポート遅延レイアウトを無効化して全段落をレイアウトさせる)。
        let container = NSTextContainer(size: CGSize(width: 0, height: 10_000_000))
        container.widthTracksTextView = true
        layoutManager.textContainer = container
        self.init(frame: .zero, textContainer: container, theme: theme)
    }

    init(frame: CGRect, textContainer container: NSTextContainer?, theme: MarkdownTheme) {
        self.engine = MarkdownEditorEngine(theme: theme)
        super.init(frame: frame, textContainer: container)
        configure()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("MarkdownTextView does not support NSCoder")
    }

    private func configure() {
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        font = engine.theme.bodyFont
        textColor = engine.theme.bodyColor
        backgroundColor = engine.theme.backgroundColor
        alwaysBounceVertical = true

        engine.host = self
        if let contentStorage = textContentStorage, let layoutManager = textLayoutManager {
            engine.attach(contentStorage: contentStorage, layoutManager: layoutManager)
        }

        gutter.onToggleFold = { [weak self] headingLocation in
            self?.toggleFold(at: headingLocation)
        }
        addSubview(gutter)
        addSubview(imageOverlay)
        updateGutterLayout()

        // 注意: delegate はビュー自身にしない。UIScrollView は panGestureRecognizer の delegate を
        // 自分自身にしているため、ビューを UIGestureRecognizerDelegate に準拠させると
        // shouldReceive(touch:) がパンにも適用されてスクロールできなくなる(実機検証で確認)。
        tapDelegate.owner = self
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleEditorTap(_:)))
        tap.delegate = tapDelegate
        addGestureRecognizer(tap)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
    }

    /// TextKit2 のコンテンツストレージ(UITextView は AppKit と違い直接公開していない)
    var textContentStorage: NSTextContentStorage? {
        textLayoutManager?.textContentManager as? NSTextContentStorage
    }

    /// 全文を再ハイライトする。`text` をプログラムで差し替えた後に呼ぶこと。
    public func highlightAll() { engine.highlightAll() }

    /// 保留中の編集を即時処理する(テストの継ぎ目)。
    func highlightNow() { engine.highlightNow() }
    func scheduleHighlight() { engine.scheduleHighlight() }

    // MARK: - 選択変更の監視

    /// キャレットが折畳の隠し領域に入ったら自動展開する。
    /// `delegate` は利用側(SwiftUI の Coordinator 等)のものなので横取りせず、
    /// selectedRange / selectedTextRange の didSet で拾う(プログラムからの設定・UITextInput 経由の
    /// ユーザー操作の両方がここを通る)。編集による解除は MarkdownEditorHost.editorTextDidChange で行う。
    public override var selectedRange: NSRange {
        didSet { engine.autoExpandFolds(atSelectedRanges: [selectedRange]) }
    }

    public override var selectedTextRange: UITextRange? {
        didSet { engine.autoExpandFolds(atSelectedRanges: [selectedRange]) }
    }

    /// IME 変換の終了。変換中に見送ったハイライト適用(highlightNow は marked text 中は
    /// 何もしない)を、確定で文字が変化しなかった場合でも確実に再開する。
    public override func unmarkText() {
        super.unmarkText()
        engine.scheduleHighlight()
    }

    // MARK: - レイアウト

    /// プレビューが使える幅 = テキストコンテナの実効幅(lineFragmentPadding を除く)
    var imageContainerWidth: CGFloat {
        let container = textContainer
        return max(0, container.size.width - container.lineFragmentPadding * 2)
    }

    private var gutterWidth: CGFloat { showsLineNumbers ? LineNumberGutterView.width : 0 }

    private func updateGutterLayout() {
        gutter.isHidden = !showsLineNumbers
        var inset = textContainerInset
        inset.left = gutterWidth
        textContainerInset = inset
        setNeedsLayout()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // サブビューはコンテンツ座標に置かれるため、可視領域 = bounds(origin は contentOffset)。
        // ガターと下線オーバーレイは描画バッキングを持つので可視領域にピン留めし、
        // 画像オーバーレイは描画しない(子ビューだけ)のでコンテンツ全体に広げる。
        gutter.frame = CGRect(x: bounds.minX, y: bounds.minY, width: gutterWidth, height: bounds.height)
        gutter.contentOffsetY = bounds.minY
        imageOverlay.frame = CGRect(
            x: 0, y: 0, width: bounds.width, height: max(contentSize.height, bounds.height))
        updateLinkHoverOverlay()
        if imageContainerWidth != lastImageContainerWidth {
            lastImageContainerWidth = imageContainerWidth
            engine.imageContainerWidthDidChange()
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
        collectedImageEntries.append(contentsOf: engine.imagePreviewEntries(for: textLayoutFragment))
        guard showsLineNumbers, let line = engine.gutterLine(for: textLayoutFragment) else { return }
        collectedLines.append(line)
    }

    public override func textViewportLayoutControllerDidLayout(
        _ textViewportLayoutController: NSTextViewportLayoutController
    ) {
        super.textViewportLayoutControllerDidLayout(textViewportLayoutController)
        gutter.lines = collectedLines
        imageOverlay.update(entries: collectedImageEntries)
    }

    // MARK: - 座標

    /// point(ビュー座標)に最も近い文字の UTF-16 オフセット
    func characterIndex(at point: CGPoint) -> Int {
        guard let position = closestPosition(to: point) else { return 0 }
        return offset(from: beginningOfDocument, to: position)
    }

    // MARK: - タップ(チェックボックス / Cmd+タップでリンク)

    @objc private func handleEditorTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: self)
        let modifiers = recognizer.modifierFlags.intersection([.shift, .control, .alternate, .command])
        if modifiers == [.command], openLink(atPoint: point) { return }
        if editingOptions.togglesCheckboxOnClick, modifiers.isEmpty {
            _ = toggleCheckbox(atPoint: point)
        }
    }

    /// point(ビュー座標)がチェックボックス、または Cmd 押下中のリンク上なら true。
    /// タップ認識をこの場合に限定し、それ以外は UITextView 標準のタップ(キャレット移動)に流す。
    func shouldInterceptTap(atPoint point: CGPoint, modifiers: UIKeyModifierFlags) -> Bool {
        let actual = modifiers.intersection([.shift, .control, .alternate, .command])
        if actual == [.command] {
            return linkOptions.opensOnCommandClick && linkReference(atScreenPoint: point) != nil
        }
        guard actual.isEmpty, editingOptions.togglesCheckboxOnClick else { return false }
        return EditingAssistant.toggleCheckbox(
            text: text as NSString, at: characterIndex(at: point)) != nil
    }

    /// point(ビュー座標)のタップでチェックボックスをトグルする。トグルしたら true。
    /// ジェスチャから分離してあるのはテストで座標を直接渡せるようにするため。
    func toggleCheckbox(atPoint point: CGPoint) -> Bool {
        let offset = characterIndex(at: point)
        guard let command = EditingAssistant.toggleCheckbox(
            text: text as NSString, at: offset) else { return false }
        // 同長 1 文字の置換なので選択座標はずれない — 適用前の選択を復元する
        let selectionBefore = selectedRange
        guard perform(command) else { return false }
        selectedRange = selectionBefore
        return true
    }

    // MARK: - リンク

    /// point(ビュー座標)のリンクを開く。開いたら true。
    /// ジェスチャから分離してあるのはテストで座標を直接渡せるようにするため。
    func openLink(atPoint point: CGPoint) -> Bool {
        guard linkOptions.opensOnCommandClick,
              let reference = linkReference(atScreenPoint: point) else { return false }
        return open(reference)
    }

    /// offset(UTF-16)を含むリンクを開く。開いたら true。編集メニューから使う。
    func openLink(at offset: Int) -> Bool {
        guard linkOptions.opensOnCommandClick,
              let reference = engine.linkReference(at: offset) else { return false }
        return open(reference)
    }

    private func open(_ reference: LinkReference) -> Bool {
        guard let url = LinkURLResolver.resolve(
            destination: reference.destination, baseURL: linkOptions.baseURL)
        else { return false }
        if onOpenLink?(url) == true { return true }
        UIApplication.shared.open(url)
        return true
    }

    /// point(ビュー座標)にオンスクリーンで実際に重なっているリンク参照を返す。
    private func linkReference(atScreenPoint point: CGPoint) -> LinkReference? {
        engine.linkReference(atPoint: point, characterIndex: characterIndex(at: point))
    }

    /// 編集メニュー(キャレットのタップ・単語選択)用: range の先頭がリンク上なら「リンクを開く」を
    /// 先頭に足した UIMenu を返す。リンク上でなければ suggestedActions だけの標準メニューを返す。
    ///
    /// UITextView の編集メニューは delegate の
    /// `textView(_:editMenuForTextIn:suggestedActions:)` で決まるため、MarkdownEditorView
    /// (SwiftUI)の Coordinator はこれを呼んで返す。UITextView を直接使う場合は、自前の
    /// UITextViewDelegate の同メソッドからこの関数を呼ぶこと(delegate は横取りしない)。
    public func editMenu(forTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu {
        guard linkOptions.opensOnCommandClick,
              engine.linkReference(at: range.location) != nil
        else { return UIMenu(children: suggestedActions) }
        let offset = range.location
        let action = UIAction(
            title: String(localized: "Open Link", bundle: .module),
            image: UIImage(systemName: "link")
        ) { [weak self] _ in
            _ = self?.openLink(at: offset)
        }
        return UIMenu(children: [action] + suggestedActions)
    }

    // MARK: - ホバー(iPad ポインタ)

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            let point = recognizer.location(in: self)
            lastHoverPoint = point
            commandKeyHeld = recognizer.modifierFlags.contains(.command)
            refreshLinkHover(atPoint: point, commandHeld: commandKeyHeld)
        default:
            lastHoverPoint = nil
            clearLinkHover()
        }
    }

    /// Cmd キーの押下/解放時はポインタが動かなくてもホバー状態を更新する
    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesBegan(presses, with: event)
        updateCommandKey(from: presses, pressed: true)
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        updateCommandKey(from: presses, pressed: false)
    }

    public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesCancelled(presses, with: event)
        updateCommandKey(from: presses, pressed: false)
    }

    private func updateCommandKey(from presses: Set<UIPress>, pressed: Bool) {
        let isCommand = presses.contains {
            $0.key?.keyCode == .keyboardLeftGUI || $0.key?.keyCode == .keyboardRightGUI
        }
        guard isCommand else { return }
        commandKeyHeld = pressed
        if let point = lastHoverPoint {
            refreshLinkHover(atPoint: point, commandHeld: pressed)
        }
    }

    /// Cmd+ホバーの下線を更新する。ジェスチャから分離してあるのはテストで直接呼べるようにするため。
    func refreshLinkHover(atPoint point: CGPoint, commandHeld: Bool) {
        var newRange: NSRange?
        if commandHeld, linkOptions.opensOnCommandClick, bounds.contains(point) {
            newRange = linkReference(atScreenPoint: point)?.range
        }
        guard newRange != hoveredLinkRange else { return }
        hoveredLinkRange = newRange
        updateLinkHoverOverlay()
    }

    /// 編集でレンジがずれるため、ホバー状態は編集のたびに破棄する。
    private func clearLinkHover() {
        guard hoveredLinkRange != nil else { return }
        hoveredLinkRange = nil
        updateLinkHoverOverlay()
    }

    private func updateLinkHoverOverlay() {
        guard let range = hoveredLinkRange,
              let rects = engine.segmentFrames(for: range),
              !rects.isEmpty
        else {
            linkHoverOverlay.underlineRects = []
            linkHoverOverlay.removeFromSuperview()
            return
        }
        if linkHoverOverlay.superview !== self {
            addSubview(linkHoverOverlay)
        }
        // 可視領域にピン留めし、矩形はそのローカル座標に直す
        linkHoverOverlay.frame = bounds
        linkHoverOverlay.color = theme.style(for: .link)?.foregroundColor ?? .link
        linkHoverOverlay.underlineRects = rects.map { $0.offsetBy(dx: -bounds.minX, dy: -bounds.minY) }
    }

    // MARK: - 編集支援

    public override func insertText(_ insertString: String) {
        // IME 変換中(marked text)は変換セッションを優先し、編集支援を挟まない
        if markedTextRange == nil {
            if insertString == "\n", editingOptions.continuesLists,
               let command = EditingAssistant.newline(
                text: text as NSString, selection: selectedRange),
               perform(command) {
                return
            }
            if insertString == "\t", editingOptions.indentsListItems,
               let command = EditingAssistant.indent(
                text: text as NSString, selection: selectedRange),
               perform(command) {
                return
            }
            if editingOptions.completesPairs,
               let command = EditingAssistant.insertion(
                text: text as NSString, selection: selectedRange, typing: insertString),
               perform(command) {
                return
            }
        }
        super.insertText(insertString)
    }

    public override func deleteBackward() {
        // 空ペアの間で Backspace したら両側をまとめて削除(ペア補完の対になる操作)
        if editingOptions.completesPairs, markedTextRange == nil,
           let command = EditingAssistant.deleteBackward(
            text: text as NSString, selection: selectedRange),
           perform(command) {
            return
        }
        super.deleteBackward()
    }

    /// Shift+Tab(ハードウェアキーボード)でリスト項目のネストを下げる
    public override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        let backtab = UIKeyCommand(
            input: "\t", modifierFlags: .shift, action: #selector(handleBacktab(_:)))
        backtab.wantsPriorityOverSystemBehavior = true
        commands.append(backtab)
        return commands
    }

    @objc private func handleBacktab(_ sender: Any?) {
        guard editingOptions.indentsListItems, markedTextRange == nil,
              let command = EditingAssistant.outdent(
                text: text as NSString, selection: selectedRange)
        else { return }
        perform(command)
    }

    public override func paste(_ sender: Any?) {
        if let pasted = UIPasteboard.general.string, applyLinkifiedPaste(pasted) {
            return
        }
        super.paste(sender)
    }

    /// ペースト文字列がリンク化条件を満たせば適用して true。
    /// paste から分離してあるのはテストでペースト文字列を直接渡せるようにするため。
    func applyLinkifiedPaste(_ pasted: String) -> Bool {
        guard editingOptions.linkifiesPastedURL, markedTextRange == nil,
              let command = EditingAssistant.linkifyPaste(
                text: text as NSString, selection: selectedRange, pasted: pasted)
        else { return false }
        return perform(command)
    }

    /// 選択範囲(なければカーソル位置の単語)のボールド / イタリックを切り替える(EditingAssistant.toggleEmphasis)。
    /// IME 変換中は何もしない。適用できたら true。
    @discardableResult
    public func toggleEmphasis(_ style: EmphasisStyle) -> Bool {
        guard !editorHasMarkedText,
              let command = EditingAssistant.toggleEmphasis(
                text: editorText as NSString, selection: editorSelectedRanges[0], style: style)
        else { return false }
        return perform(command)
    }

    /// EditCommand を undo 対応の経路で適用する。
    /// UITextInput.replace(_:withText:) を通すことで UITextView 標準の undo と
    /// textViewDidChange 通知に乗り、NSTextStorageDelegate 経由で再ハイライトも自動で走る。
    /// 範囲が文書外のコマンドは適用せず false を返す。
    /// IME 変換中(`markedTextRange != nil`)の呼び出しは変換セッションを乱す恐れがあるため避けること。
    @discardableResult
    public func perform(_ command: EditCommand) -> Bool {
        let length = (text as NSString).length
        guard command.replacementRange.location != NSNotFound,
              NSMaxRange(command.replacementRange) <= length
        else { return false }
        // 適用後の文書長で selectedRange を検証
        let newLength = length - command.replacementRange.length
            + (command.replacementString as NSString).length
        guard command.selectedRange.location != NSNotFound,
              NSMaxRange(command.selectedRange) <= newLength
        else { return false }
        // 純粋なカーソル移動(タイプオーバー)は置換なしで選択だけ動かす
        if command.replacementRange.length == 0, command.replacementString.isEmpty {
            selectedRange = command.selectedRange
            return true
        }
        guard let start = position(from: beginningOfDocument, offset: command.replacementRange.location),
              let end = position(from: start, offset: command.replacementRange.length),
              let range = textRange(from: start, to: end)
        else { return false }
        replace(range, withText: command.replacementString)
        selectedRange = command.selectedRange
        return true
    }
}

// MARK: - MarkdownEditorHost

extension MarkdownTextView: MarkdownEditorHost {
    var editorContentStorage: NSTextContentStorage? { textContentStorage }
    var editorLayoutManager: NSTextLayoutManager? { textLayoutManager }
    var editorText: String { text }
    var editorHasMarkedText: Bool { markedTextRange != nil }
    var editorTextContainerOrigin: CGPoint {
        CGPoint(x: textContainerInset.left, y: textContainerInset.top)
    }
    var editorLineFragmentPadding: CGFloat { textContainer.lineFragmentPadding }

    func editorDidResync() {
        updateLinkHoverOverlay()
    }

    func editorTextDidChange() {
        // textViewDidChange はユーザー操作由来の変更にしか届かないため、
        // プログラムからの編集(perform / textStorage 直接編集)もここで拾う
        clearLinkHover()
    }

    func editorNeedsViewportRelayout() {
        gutter.setNeedsDisplay()
        setNeedsLayout()
    }

    var editorSelectedRanges: [NSRange] { [selectedRange] }

    func editorSelect(_ range: NSRange) {
        selectedRange = range
    }
}

// MARK: - タップ認識の delegate(チェックボックス / Cmd+タップ)

/// 編集用タップの UIGestureRecognizerDelegate。ビュー自身を delegate にすると UIScrollView 内蔵の
/// パン(delegate = scrollView 自身)にまで shouldReceive(touch:) が及んでしまうため、別オブジェクトにする。
@MainActor
private final class EditorTapGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var owner: MarkdownTextView?
    private var pendingTouchModifiers: UIKeyModifierFlags = []

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent
    ) -> Bool {
        pendingTouchModifiers = event.modifierFlags
        return true
    }

    /// チェックボックス上、または Cmd 押下中のリンク上のタッチだけ受け取る。
    /// それ以外は UITextView 標準のタップ(キャレット移動)に流す。
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        guard let owner else { return false }
        return owner.shouldInterceptTap(atPoint: touch.location(in: owner), modifiers: pendingTouchModifiers)
    }

    /// 自分のタップが成立するまで UITextView 標準のタップ(キャレット移動)を待たせる。
    /// 自分が受け取らない(shouldReceive touch が false の)タッチでは即座に標準処理へ進む。
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        otherGestureRecognizer is UITapGestureRecognizer
    }
}
#endif
