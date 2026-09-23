#if os(macOS)
import AppKit
import LapermCore

/// TextKit2 ベースの Markdown エディタビュー(AppKit)。
/// 警告: このクラス(および利用側)は `layoutManager` プロパティに絶対にアクセスしないこと。
/// アクセスした瞬間に TextKit1 互換モードへフォールバックし、全機能が壊れる。
///
/// ハイライト・折畳・画像プレビューのロジックは UIKit 版と共有の
/// `MarkdownEditorEngine` にあり、このクラスは AppKit 固有の入力・描画・座標系を担う。
@MainActor
public final class MarkdownTextView: NSTextView {
    let engine: MarkdownEditorEngine
    weak var gutterView: LineNumberGutterView?
    private var collectedLines: [GutterLine] = []

    /// テスト用: 共有エンジンのコンポーネントへの近道
    var markdownHighlighter: Highlighter { engine.highlighter }
    var imagePreviewController: ImagePreviewController { engine.imagePreviewController }
    var foldingController: FoldingController { engine.foldingController }

    public var theme: MarkdownTheme {
        get { engine.theme }
        set {
            engine.theme = newValue
            backgroundColor = newValue.backgroundColor
            font = newValue.bodyFont
            engine.applyThemeChange()
            updateTextInsets()
        }
    }

    public var showsLineNumbers: Bool = true {
        didSet { enclosingScrollView?.rulersVisible = showsLineNumbers }
    }

    /// 本文の左右余白(デフォルトは余白なし)。行番号ガターはルーラー(このビューの外)なので、
    /// 余白は左右対称で、ガターの表示・非表示でビュー自体の幅が変わる。
    public var margins: EditorMargins = .none {
        didSet {
            guard margins != oldValue else { return }
            updateTextInsets()
        }
    }

    /// 本文の上に置くヘッダ(サブビュー)。スクロールの内容に含まれ、本文と一緒にスクロールする。本文は
    /// `headerHeight` だけ下から始まり(`textContainerInset.height`。NSTextView では上下同値なので同じ余白が
    /// 下にも付く)、ヘッダはテキストコンテナと同じ左右位置(余白 + lineFragmentPadding)に `layout()` で置かれる。
    public var headerView: NSView? {
        didSet {
            guard headerView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let headerView { addSubview(headerView) }
            updateHeaderInset()
            needsLayout = true
        }
    }

    /// ヘッダの高さ(`headerView` が無ければ使われない)。
    public var headerHeight: CGFloat = 0 {
        didSet {
            guard headerHeight != oldValue else { return }
            updateHeaderInset()
            needsLayout = true
        }
    }

    /// 編集支援機能の設定(デフォルト全 ON)
    public var editingOptions = EditingOptions()

    /// リンク操作の設定(デフォルト: Cmd+クリックで開く)
    public var linkOptions = LinkOptions()

    /// リンクを開く前のフック。true を返すと消費し、デフォルト動作
    /// (NSWorkspace.shared.open)を行わない。
    public var onOpenLink: ((URL) -> Bool)?

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

    /// Live Preview の有効/無効(既定は無効 = Source)。有効なら、キャレットのある行と選択範囲が触れる行を
    /// 除いて Syntax Marker(見出しの `#`、強調・打ち消し線・インラインコードの記号、リンク・画像の括弧、
    /// 引用の `>`)を幅ゼロで隠す。テキストストレージには触れない(コピーすれば Markdown がそのまま取れる)。
    public var isLivePreviewEnabled: Bool {
        get { engine.isLivePreviewEnabled }
        set { engine.isLivePreviewEnabled = newValue }
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

    private var barInsertionPointColor: NSColor?
    private var hoveredLinkRange: NSRange?
    private var linkTrackingArea: NSTrackingArea?

    /// テスト用: 現在ホバー中のリンクレンジ。
    var debugHoveredLinkRange: NSRange? { hoveredLinkRange }

    /// テスト用: ホバー下線オーバーレイに設定されている矩形群。空ならオーバーレイ非表示相当。
    var debugLinkHoverUnderlineRects: [NSRect] { linkHoverOverlay.underlineRects }

    private let insertionPointOverlay = InsertionPointOverlayView()
    private let linkHoverOverlay = LinkHoverOverlayView()
    private let imageOverlay = ImagePreviewOverlayView()
    private var collectedImageEntries: [ImagePreviewOverlayEntry] = []
    private var lastImageContainerWidth: CGFloat = 0
    private let frontMatterTableView = FrontMatterTableView()
    private var collectedFrontMatterEntry: FrontMatterTableEntry?

    /// テスト用: 直近のビューポートレイアウトで収集したオーバーレイ配置。
    var debugImageEntries: [ImagePreviewOverlayEntry] { collectedImageEntries }
    /// テスト用: 直近のビューポートレイアウトで置いた Front Matter の表(折りたたまれていなければ nil)。
    var debugFrontMatterEntry: FrontMatterTableEntry? { collectedFrontMatterEntry }
    /// テスト用: Front Matter の折りたたみ状態。
    var frontMatterController: FrontMatterController { engine.frontMatter }

    public convenience init(theme: MarkdownTheme = .default) {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        // 高さは Apple の NSTextView(usingTextLayoutManager:) と同じ 1e7 にする。これより小さい高さ
        // (1,000,000 など)を与えると TextKit2 は
        // ビューポート単位の遅延レイアウトをやめて全段落をレイアウトしてしまい、
        // 初回表示・キーストロークごとの invalidateLayout が文書全体に比例するコストになる
        // (10k 行で 1 キーストローク数秒 → 数十 ms。ベンチで確認)。
        let container = NSTextContainer(size: CGSize(width: 0, height: 10_000_000))
        container.widthTracksTextView = true
        layoutManager.textContainer = container
        self.init(frame: .zero, textContainer: container, theme: theme)
    }

    init(frame frameRect: NSRect, textContainer container: NSTextContainer?, theme: MarkdownTheme) {
        self.engine = MarkdownEditorEngine(theme: theme)
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
        font = engine.theme.bodyFont
        drawsBackground = true
        backgroundColor = engine.theme.backgroundColor

        engine.host = self
        if let contentStorage = textContentStorage, let layoutManager = textLayoutManager {
            engine.attach(contentStorage: contentStorage, layoutManager: layoutManager)
        }

        imageOverlay.autoresizingMask = [.width, .height]
        addSubview(imageOverlay)
        frontMatterTableView.isHidden = true
        addSubview(frontMatterTableView)
        syncEditorFocus()
    }

    // MARK: - フォーカス(Live Preview)

    /// first responder の変化をエンジンへ流す。Live Preview はフォーカスを失うと全行のマーカーを隠し
    ///(閲覧表示)、戻るとキャレットの行を見せる。ウィンドウが key でなくなるだけでは変えない。
    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        syncEditorFocus()
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { engine.editorFocusDidChange(false) }
        return resigned
    }

    /// ウィンドウの first responder と突き合わせる(become / resign を経ない付け外しにも追従する)。
    private func syncEditorFocus() {
        engine.editorFocusDidChange(window?.firstResponder === self)
    }

    /// 全文を再ハイライトする。`string` をプログラムで差し替えた後に呼ぶこと。
    public func highlightAll() { engine.highlightAll() }

    /// 保留中の編集を即時処理する(テストの継ぎ目)。
    func highlightNow() { engine.highlightNow() }
    func scheduleHighlight() { engine.scheduleHighlight() }

    /// プレビューが使える幅 = テキストコンテナの実効幅(lineFragmentPadding を除く)
    var imageContainerWidth: CGFloat {
        guard let container = textContainer else { return max(0, bounds.width) }
        return max(0, container.size.width - container.lineFragmentPadding * 2)
    }

    public override func textViewportLayoutControllerWillLayout(
        _ textViewportLayoutController: NSTextViewportLayoutController
    ) {
        super.textViewportLayoutControllerWillLayout(textViewportLayoutController)
        collectedLines.removeAll(keepingCapacity: true)
        collectedImageEntries.removeAll(keepingCapacity: true)
        collectedFrontMatterEntry = nil
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
        if let entry = engine.frontMatterTableEntry(for: textLayoutFragment) { collectedFrontMatterEntry = entry }
        guard gutterView != nil, let line = engine.gutterLine(for: textLayoutFragment) else { return }
        collectedLines.append(line)
    }

    public override func textViewportLayoutControllerDidLayout(
        _ textViewportLayoutController: NSTextViewportLayoutController
    ) {
        super.textViewportLayoutControllerDidLayout(textViewportLayoutController)
        gutterView?.lines = collectedLines
        imageOverlay.update(entries: collectedImageEntries)
        frontMatterTableView.update(entry: collectedFrontMatterEntry)
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
        gutter.onToggleFold = { [weak textView] headingLocation in
            textView?.toggleFold(at: headingLocation)
        }
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = textView.showsLineNumbers
        textView.gutterView = gutter
        return scrollView
    }

    // MARK: - リンクホバー

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncEditorFocus()
        // NSTrackingArea に .mouseMoved を指定していても、ウィンドウ側が
        // mouseMoved イベントを受け取る設定になっていないと配送されないことがある
        // (特に SwiftUI がホストするウィンドウ)。Cmd+ホバーの下線表示のために明示的に有効化する。
        window?.acceptsMouseMovedEvents = true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = linkTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        linkTrackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        refreshLinkHover(
            atPoint: convert(event.locationInWindow, from: nil),
            commandHeld: event.modifierFlags.contains(.command))
    }

    public override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        // Cmd の押下/解放時はポインタが動かなくてもホバー状態を更新する
        let location = window?.mouseLocationOutsideOfEventStream ?? .zero
        refreshLinkHover(
            atPoint: convert(location, from: nil),
            commandHeld: event.modifierFlags.contains(.command))
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearLinkHoverOnExit()
    }

    /// ポインタがビュー外へ出たときのホバー解除(下線とカーソル形状の両方を戻す)。
    /// mouseExited から分離してあるのはテストで直接呼べるようにするため。
    func clearLinkHoverOnExit() {
        guard hoveredLinkRange != nil else { return }
        clearLinkHover()
        NSCursor.iBeam.set()
    }

    /// Cmd+ホバーの下線・カーソル形状を更新する。
    /// mouseMoved / flagsChanged から分離してあるのはテストで直接呼べるようにするため。
    ///
    /// `flagsChanged` は `window?.mouseLocationOutsideOfEventStream` を使ってポインタ位置を
    /// 取得するが、この値はウィンドウ内のどこでもありうる(サイドバー・ガター・ウィンドウ外)。
    /// そのためまずポイントが `visibleRect` 内かどうかを確認し、外なら新規ホバーを作らない
    /// (既存ホバーの解除処理は下の共通パスで通す)。
    func refreshLinkHover(atPoint point: NSPoint, commandHeld: Bool) {
        var newRange: NSRange?
        if commandHeld, linkOptions.opensOnCommandClick, visibleRect.contains(point) {
            newRange = linkReference(atScreenPoint: point)?.range
        }
        guard newRange != hoveredLinkRange else { return }
        hoveredLinkRange = newRange
        updateLinkHoverOverlay()
        if newRange != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    /// 編集でレンジがずれるため、ホバー状態は編集のたびに破棄する。
    private func clearLinkHover() {
        hoveredLinkRange = nil
        updateLinkHoverOverlay()
    }

    /// ホバー中リンクの下線オーバーレイを配置する。
    ///
    /// `NSTextLayoutManager.addRenderingAttribute(.underlineStyle, ...)` を使う実装を
    /// 実機の GUI 検証で試したが、ビューポート再レイアウトを強制しても描画に反映されなかった
    /// (`.backgroundColor` など他のレンダリング属性は同じ手順で反映されるため、TextKit2 の
    /// 下線レンダリング属性特有の制約と判断した)。InsertionPointOverlayView と同じ
    /// 「座標を計算してオーバーレイに描く」方式に置き換えている。
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
        linkHoverOverlay.frame = bounds
        linkHoverOverlay.color = theme.style(for: .link)?.foregroundColor ?? .linkColor
        linkHoverOverlay.underlineRects = rects
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
        engine.autoExpandFolds(atSelectedRanges: selectedRanges.map(\.rangeValue))
        engine.selectionDidChangeForLivePreview()
    }

    public override func didChangeText() {
        super.didChangeText()
        clearLinkHover()
        updateInsertionPointOverlay()
    }

    /// IME 変換の終了。変換中に見送ったハイライト適用(highlightNow は marked text 中は
    /// 何もしない)を、確定で文字が変化しなかった場合でも確実に再開する。
    public override func unmarkText() {
        super.unmarkText()
        engine.scheduleHighlight()
    }

    /// `margins` からテキストコンテナの左右 inset を決める(上下は触らない)。中央寄せはビュー幅に
    /// 依るので、幅が変わる `setFrameSize` からも呼ぶ。`NSTextView.textContainerInset` は左右同値。
    private func updateTextInsets() {
        let horizontal = margins.symmetricHorizontalInset(
            viewWidth: frame.width, fontSize: engine.theme.bodyFont.pointSize)
        let inset = NSSize(width: horizontal, height: textContainerInset.height)
        if inset != textContainerInset {
            textContainerInset = inset
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTextInsets()
    }

    /// ヘッダの分だけ本文を下げる(左右は `updateTextInsets` が持つ)。有限でない高さは 0 として扱う。
    private func updateHeaderInset() {
        let top = headerView == nil || !headerHeight.isFinite ? 0 : max(0, headerHeight)
        let inset = NSSize(width: textContainerInset.width, height: top)
        if inset != textContainerInset {
            textContainerInset = inset
        }
    }

    /// NSTextView(AXTextArea)は子要素を公開しないので、ヘッダの中のコントロール(ボタン・テキストフィールド)を
    /// 支援技術と XCUITest から見えるように、ヘッダを子として返す。
    public override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        if let headerView {
            children.append(contentsOf: NSAccessibility.unignoredChildren(from: [headerView]))
        }
        return children
    }

    /// ヘッダをテキストコンテナの左右位置に合わせて上端に置く。
    private func layoutHeader() {
        guard let headerView else { return }
        let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
        let frame = NSRect(x: x, y: 0, width: max(0, bounds.width - 2 * x), height: textContainerInset.height)
        if headerView.frame != frame { headerView.frame = frame }
    }

    /// `layout()` の実行中か。その中で立てた `needsLayout` は AppKit が `layout()` の後で下ろすので、
    /// 中から要求された再レイアウト(幅の変化で Front Matter の表を作り直すなど)は次のランループで改めて要求する。
    private var isPerformingLayout = false

    public override func layout() {
        isPerformingLayout = true
        defer { isPerformingLayout = false }
        super.layout()
        layoutHeader()
        updateInsertionPointOverlay()
        updateLinkHoverOverlay()
        imageOverlay.frame = bounds
        if imageContainerWidth != lastImageContainerWidth {
            lastImageContainerWidth = imageContainerWidth
            engine.imageContainerWidthDidChange()
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
        let text = string as NSString
        let caret = selectedRange().location
        guard caret != NSNotFound, caret <= text.length else { return nil }
        var characterRange = NSRange(location: caret, length: 0)
        if caret < TextMotions.lineEnd(text: text, at: caret) {
            characterRange = text.rangeOfComposedCharacterSequence(at: caret)
        }
        // キーストロークごとに呼ばれるため、レイアウト保証はキャレット周辺のみに絞る
        // (documentRange 全体だとビューポート単位の増分レイアウトが無効化される)
        guard var frame = engine.segmentFrames(for: characterRange)?.first else { return nil }
        if frame.width < 1 {
            // キャレットのみ(行末・空行)は等幅 1 文字ぶんの幅を与える
            frame.size.width = ("M" as NSString)
                .size(withAttributes: [.font: theme.bodyFont]).width
        }
        return frame
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

    public override func paste(_ sender: Any?) {
        if let pasted = NSPasteboard.general.string(forType: .string),
            applyLinkifiedPaste(pasted) {
            return
        }
        super.paste(sender)
    }

    /// ペースト文字列がリンク化条件を満たせば適用して true。
    /// paste から分離してあるのはテストでペースト文字列を直接渡せるようにするため。
    func applyLinkifiedPaste(_ pasted: String) -> Bool {
        guard editingOptions.linkifiesPastedURL, !hasMarkedText(),
            let command = EditingAssistant.linkifyPaste(
                text: string as NSString, selection: selectedRange(), pasted: pasted)
        else { return false }
        return perform(command)
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // deviceIndependentFlagsMask は capsLock を含み、Caps Lock 中は常時セットされるため
        // 実際に押されうる修飾キーだけを見る
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if event.clickCount == 1, modifiers == [.command], openLink(atPoint: point) {
            return
        }
        if event.clickCount == 1, modifiers.isEmpty, expandFrontMatter(atPoint: point) {
            return
        }
        if editingOptions.togglesCheckboxOnClick,
            event.clickCount == 1,
            modifiers.isEmpty,
            toggleCheckbox(atPoint: point) {
            return
        }
        super.mouseDown(with: event)
    }

    /// point(ビュー座標)が Live Preview の Front Matter の表の上なら、その Property の行末にキャレットを置いて
    /// ブロックを展開する(ADR 0016)。展開したら true。mouseDown から分離してあるのはテストで座標を直接渡せるようにするため。
    @discardableResult
    func expandFrontMatter(atPoint point: NSPoint) -> Bool {
        guard let caret = engine.frontMatterCaretRange(atPoint: point) else { return false }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        setSelectedRange(caret)
        return true
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

    /// point(ビュー座標)の Cmd+クリックでリンクを開く。開いたら true。
    /// mouseDown から分離してあるのはテストで座標を直接渡せるようにするため。
    func openLink(atPoint point: NSPoint) -> Bool {
        guard linkOptions.opensOnCommandClick else { return false }
        guard let reference = linkReference(atScreenPoint: point),
            let url = LinkURLResolver.resolve(
                destination: reference.destination, baseURL: linkOptions.baseURL)
        else { return false }
        if onOpenLink?(url) == true { return true }
        NSWorkspace.shared.open(url)
        return true
    }

    /// point(ビュー座標)にオンスクリーンで実際に重なっているリンク参照を返す。
    /// `characterIndexForInsertion` は最寄りの文字へクランプするため、リンクを含む行の
    /// 末尾より右や次行の余白をクリック/ホバーしても、そのままではリンクにヒットしてしまう。
    /// エンジン側で実際の描画矩形と照合して除外する。
    private func linkReference(atScreenPoint point: NSPoint) -> LinkReference? {
        engine.linkReference(atPoint: point, characterIndex: characterIndexForInsertion(at: point))
    }

    /// 選択範囲(なければカーソル位置の単語)のボールド / イタリックを切り替える(EditingAssistant.toggleEmphasis)。
    /// IME 変換中と複数選択のときは何もしない。適用できたら true。
    @discardableResult
    public func toggleEmphasis(_ style: EmphasisStyle) -> Bool {
        let ranges = editorSelectedRanges
        guard !editorHasMarkedText, ranges.count == 1,
              let command = EditingAssistant.toggleEmphasis(
                text: editorText as NSString, selection: ranges[0], style: style)
        else { return false }
        return perform(command)
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

extension MarkdownTextView: MarkdownEditorHost {
    var editorContentStorage: NSTextContentStorage? { textContentStorage }
    var editorLayoutManager: NSTextLayoutManager? { textLayoutManager }
    var editorText: String { string }
    var editorHasMarkedText: Bool { hasMarkedText() }
    var editorTextContainerOrigin: CGPoint { textContainerOrigin }
    var editorLineFragmentPadding: CGFloat { textContainer?.lineFragmentPadding ?? 0 }

    func editorDidResync() {
        updateInsertionPointOverlay()
    }

    func editorTextDidChange() {
        // NSTextView は didChangeText でも解除するが、textStorage 直接編集の経路も同じ扱いにする
        clearLinkHover()
    }

    func editorNeedsViewportRelayout() {
        gutterView?.needsDisplay = true
        needsLayout = true
        if isPerformingLayout {
            // 幅の変化を layout() の中で受け取って作り直した場合、この needsLayout は layout() の終わりで下ろされ、
            // Note を開いた直後は他の契機が無いまま古いフラグメント(初期の極小幅で計測した Front Matter の表)が
            // 残る(Laperm で確認)。次のランループでビューポートを直接レイアウトし直す。
            RunLoop.main.perform { [weak self] in
                guard let self else { return }
                self.textLayoutManager?.textViewportLayoutController.layoutViewport()
                self.gutterView?.needsDisplay = true
                self.needsDisplay = true
            }
        }
    }

    var editorSelectedRanges: [NSRange] { selectedRanges.map(\.rangeValue) }

    func editorSelect(_ range: NSRange) {
        setSelectedRange(range)
    }
}
#endif
