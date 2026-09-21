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
            updateTextInsets()
        }
    }

    /// 行番号ガターの表示(デフォルト true)。
    public var showsLineNumbers: Bool = true {
        didSet {
            guard showsLineNumbers != oldValue else { return }
            updateTextInsets()
            // 広いビューでは余白がガターを覆うので inset が変わらず、レイアウトが走らない。ガターの
            // 幅(0 ↔ 44)と、非表示中は集めていない行情報を次のレイアウトで取り直す。
            gutterNeedsViewportRefresh = true
            setNeedsLayout()
        }
    }

    /// 次の `layoutSubviews` でビューポートのレイアウトをやり直してガターの行情報を集め直す。
    private var gutterNeedsViewportRefresh = false

    /// 本文の左右余白(デフォルトは余白なし)。ガターの幅は左余白に含まれる。
    public var margins: EditorMargins = .none {
        didSet {
            guard margins != oldValue else { return }
            updateTextInsets()
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
        updateTextInsets()

        // 注意: delegate はビュー自身にしない。UIScrollView は panGestureRecognizer の delegate を
        // 自分自身にしているため、ビューを UIGestureRecognizerDelegate に準拠させると
        // shouldReceive(touch:) がパンにも適用されてスクロールできなくなる(実機検証で確認)。
        tapDelegate.owner = self
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleEditorTap(_:)))
        tap.delegate = tapDelegate
        addGestureRecognizer(tap)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)

        // selector 版は dealloc 時に自動で解除されるので deinit 不要。
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    // MARK: - キーボード回避

    /// キーボード(`inputAccessoryView` を含む)に隠れる分だけ `contentInset.bottom` と
    /// スクロールインジケータの余白を増やす。利用側が設定した余白には足し引きするだけで上書きしない。
    /// SwiftUI 側は `.ignoresSafeArea(.keyboard)` でビューを縮めさせないことで、本文がアクセサリの下まで
    /// 伸び、ガラス越しに本文が見える。対象はビューの下端を覆うドックされたキーボードだけで、
    /// iPad の浮動・分割キーボードは無視する。`false` にするとキーボード分の余白を外して何もしない
    /// (利用側が自前で回避するとき)。
    public var adjustsContentInsetForKeyboard = true {
        didSet {
            guard oldValue != adjustsContentInsetForKeyboard else { return }
            if adjustsContentInsetForKeyboard {
                updateKeyboardInset()
            } else {
                applyKeyboardInset(0, animationDuration: 0, curve: 0)
            }
        }
    }

    /// 画面ごとの直近のキーボード終了フレーム(スクリーン座標)。キーボードが出たまま作られたビュー
    /// (Note の切り替えなど)が、ウィンドウに付いた時点で追いつくための共有キャッシュ。
    /// iOS 16.1 以降、通知の `object` はキーボードが出ている `UIScreen`。
    private static var keyboardFramesByScreen: [ObjectIdentifier: CGRect] = [:]
    /// このビューが最後に受けたキーボード終了フレーム(スクリーン座標)と、その画面。
    /// 回転などでレイアウトが変わったときの再計算用。画面が nil なら通知に画面情報がなかった。
    private var keyboardFrameOnScreen: CGRect?
    private weak var keyboardScreen: UIScreen?
    /// 今かけているキーボード分の下余白(テスト用に読める)。
    private(set) var keyboardInset: CGFloat = 0

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        let screen = notification.object as? UIScreen
        if let screen { Self.keyboardFramesByScreen[ObjectIdentifier(screen)] = frame }
        guard isKeyboardNotificationForThisScreen(screen) else { return }
        keyboardFrameOnScreen = frame
        keyboardScreen = screen
        updateKeyboardInset(animationDuration: Self.animationDuration(of: notification), curve: Self.animationCurve(of: notification))
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        let screen = notification.object as? UIScreen
        if let screen { Self.keyboardFramesByScreen[ObjectIdentifier(screen)] = nil }
        guard isKeyboardNotificationForThisScreen(screen) else { return }
        keyboardFrameOnScreen = nil
        keyboardScreen = nil
        applyKeyboardInset(0, animationDuration: Self.animationDuration(of: notification), curve: Self.animationCurve(of: notification))
    }

    /// 別画面(外部ディスプレイ)のキーボードの通知は無視する。画面が分からない通知、
    /// ウィンドウにまだ付いていないビューは受け入れて、レイアウト時に画面を照合する。
    private func isKeyboardNotificationForThisScreen(_ screen: UIScreen?) -> Bool {
        guard let screen, let window else { return true }
        return screen === window.screen
    }

    private static func animationDuration(of notification: Notification) -> Double {
        notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
    }

    private static func animationCurve(of notification: Notification) -> Int {
        notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? 0
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window else { return }
        // キーボードが出たまま作られた / 付け替えられたビューは画面のキャッシュに追いつく。
        // キャッシュがなければ(キーボードが出ていない)、別画面で受けたフレームは捨てる。
        if let cached = Self.keyboardFramesByScreen[ObjectIdentifier(window.screen)] {
            keyboardFrameOnScreen = cached
            keyboardScreen = window.screen
        } else if let keyboardScreen, keyboardScreen !== window.screen {
            keyboardFrameOnScreen = nil
            self.keyboardScreen = nil
        }
        setNeedsLayout()
    }

    /// 直近のキーボードフレームから下余白を計算し直して適用する(ウィンドウ外なら何もしない)。
    private func updateKeyboardInset(animationDuration: Double = 0, curve: Int = 0) {
        guard adjustsContentInsetForKeyboard, let window else { return }
        guard let keyboardFrameOnScreen, keyboardScreen == nil || keyboardScreen === window.screen else {
            applyKeyboardInset(0, animationDuration: animationDuration, curve: curve)
            return
        }
        let keyboardFrame = convert(keyboardFrameOnScreen, from: window.screen.coordinateSpace)
        let inset = Self.keyboardBottomInset(
            bounds: bounds, keyboardFrame: keyboardFrame, safeAreaBottom: safeAreaBottomAlreadyInset)
        applyKeyboardInset(inset, animationDuration: animationDuration, curve: curve)
    }

    /// adjustedContentInset に既に足されている safe area の下端(behavior が .never のときは 0)。
    private var safeAreaBottomAlreadyInset: CGFloat {
        contentInsetAdjustmentBehavior == .never ? 0 : safeAreaInsets.bottom
    }

    /// ビューの下端がキーボードに隠れる高さ(ビュー座標。bounds.origin = contentOffset なので
    /// スクロール量には依存しない)。safe area 分は既に余白に入っているので差し引く。
    /// ビューの下端を覆っていないキーボード(浮動・分割、横に外れている、下端より下)は 0:
    /// 浮動キーボードの下の空き領域まで余白にすると、本文が不要に押し上げられる。
    static func keyboardBottomInset(bounds: CGRect, keyboardFrame: CGRect, safeAreaBottom: CGFloat) -> CGFloat {
        guard keyboardFrame.minX < bounds.maxX, keyboardFrame.maxX > bounds.minX,
            keyboardFrame.minY < bounds.maxY, keyboardFrame.maxY >= bounds.maxY
        else { return 0 }
        return max(0, bounds.maxY - max(bounds.minY, keyboardFrame.minY) - safeAreaBottom)
    }

    private func applyKeyboardInset(_ inset: CGFloat, animationDuration: Double, curve: Int) {
        let delta = inset - keyboardInset
        guard delta != 0 else { return }
        // 余白が増えてキャレットが隠れるときだけ追従する。見えているキャレットや、候補バーの出入りで
        // 高さが少し変わっただけのときに読んでいる位置を動かさない。指で動かしている最中も触らない。
        let revealsCaret = delta > 0 && isFirstResponder && !isTracking && !isDragging && !isDecelerating
            && caretIsHidden(byBottomInset: inset)
        // 追従のスクロールは余白と同じアニメーションブロックで contentOffset を動かす。
        // `scrollRangeToVisible` は UITextView 独自の長さ・カーブで、タイマー駆動の毎フレーム更新
        // (そのたびに layoutSubviews とビューポートのレイアウト)になるので、キーボードより遅れて
        // カクつく。ブロック内の代入は bounds の変更として Core Animation が補間するので、
        // キーボードと同じカーブで一体に動き、レイアウトは最終位置で一度だけ走る。
        var targetOffset = revealsCaret ? contentOffsetRevealingCaret(bottomInset: inset) : nil
        keyboardInset = inset
        // 一画面より遠いキャレット(復元された選択が画面外にあるなど)へはアニメーションせずに移る:
        // 通過範囲をビューポートに足すと文書の大半を同期レイアウトすることになる。
        if let target = targetOffset, animationDuration > 0, abs(target.y - bounds.minY) > bounds.height {
            UIView.performWithoutAnimation { contentOffset = target }
            targetOffset = nil
        }
        let apply = {
            self.contentInset.bottom += delta
            self.verticalScrollIndicatorInsets.bottom += delta
            if let targetOffset { self.contentOffset = targetOffset }
        }
        guard animationDuration > 0 else {
            apply()
            return
        }
        // 補間中のフレームは最終位置のビューポートしかレイアウトされていないので、通過する範囲
        // (開始時の bounds)を終わるまでビューポート(とガター)に足しておく。でないと出発側が
        // 一瞬白く抜ける。完了ハンドラで外すが、描画されないウィンドウ(テストホストなど)では
        // 呼ばれないので期限も持たせる。
        let traversal: Int? = targetOffset.map { _ in
            keyboardScrollTraversal = (
                bounds: (keyboardScrollTraversedBounds ?? bounds).union(bounds),
                until: CACurrentMediaTime() + animationDuration + 0.1)
            keyboardScrollTraversalGeneration += 1
            gutterNeedsViewportRefresh = true
            return keyboardScrollTraversalGeneration
        }
        // 通知のカーブは UIViewAnimationCurve の生値(キーボードは非公開の 7)。外側のアニメーション
        // ブロックの中で通知を処理しても、キーボードの長さとカーブで動かす。
        let options = UIView.AnimationOptions(rawValue: UInt(curve) << 16)
        UIView.animate(
            withDuration: animationDuration, delay: 0,
            options: [
                options, .beginFromCurrentState, .allowUserInteraction,
                .overrideInheritedDuration, .overrideInheritedCurve,
            ], animations: apply
        ) { [weak self] _ in
            guard let self, let traversal, traversal == keyboardScrollTraversalGeneration else { return }
            keyboardScrollTraversal = nil
            // ビューポートとガターを可視領域に戻す
            gutterNeedsViewportRefresh = true
            setNeedsLayout()
        }
    }

    private var keyboardScrollTraversal: (bounds: CGRect, until: CFTimeInterval)?
    private var keyboardScrollTraversalGeneration = 0

    /// キーボード追従のスクロールアニメーションが通過する範囲(ビュー座標)。アニメーション中だけ非 nil。
    var keyboardScrollTraversedBounds: CGRect? {
        guard let keyboardScrollTraversal, CACurrentMediaTime() < keyboardScrollTraversal.until else { return nil }
        return keyboardScrollTraversal.bounds
    }

    /// ビューポート(可視領域 + overdraw)。キーボード追従のアニメーション中は通過範囲も含める。
    public override func viewportBounds(for textViewportLayoutController: NSTextViewportLayoutController) -> CGRect {
        let viewport = super.viewportBounds(for: textViewportLayoutController)
        guard let traversed = keyboardScrollTraversedBounds else { return viewport }
        return viewport.union(traversed)
    }

    /// キーボード分の下余白を `inset` にしたあとの adjustedContentInset.bottom(ホストの余白 + safe area
    /// + キーボード)。`keyboardInset` を更新する前に呼ぶこと。
    private func adjustedBottomInset(afterKeyboardInset inset: CGFloat) -> CGFloat {
        adjustedContentInset.bottom - keyboardInset + inset
    }

    /// キャレットが、キーボード分の下余白を `inset` にしたあとの可視領域(ホストの余白と safe area も
    /// 除いた領域)からはみ出すか。
    func caretIsHidden(byBottomInset inset: CGFloat) -> Bool {
        guard let end = selectedTextRange?.end else { return false }
        let caret = caretRect(for: end)
        return caret.maxY > bounds.maxY - adjustedBottomInset(afterKeyboardInset: inset)
    }

    /// キーボード分の下余白を `inset` にしたあとキャレットが見える contentOffset(キャレットがなければ
    /// nil)。今の bounds(= contentOffset)と余白変更後のコンテンツの端から計算するので、
    /// アニメーションブロックの中で余白と一緒に設定できる。`keyboardInset` を更新する前に呼ぶこと。
    func contentOffsetRevealingCaret(bottomInset inset: CGFloat) -> CGPoint? {
        guard let end = selectedTextRange?.end else { return nil }
        let caret = caretRect(for: end)
        let bottom = adjustedBottomInset(afterKeyboardInset: inset)
        let y = Self.contentOffsetY(
            revealing: caret, bounds: bounds, bottomInset: bottom, contentHeight: contentSize.height,
            adjustedInsets: (top: adjustedContentInset.top, bottom: bottom))
        return CGPoint(x: contentOffset.x, y: y)
    }

    /// キャレット(ビュー座標)の下に 1 行分の余裕を取って、可視領域の下端(`bounds.maxY - bottomInset`)
    /// より上に収める contentOffset.y。上へは動かさず、コンテンツの端(`adjustedInsets` は余白変更後の
    /// adjustedContentInset)を越えて空白を見せない。
    static func contentOffsetY(
        revealing caret: CGRect, bounds: CGRect, bottomInset: CGFloat, contentHeight: CGFloat,
        adjustedInsets: (top: CGFloat, bottom: CGFloat)
    ) -> CGFloat {
        let visibleBottom = bounds.maxY - bottomInset
        let overshoot = caret.maxY + caret.height - visibleBottom
        guard overshoot > 0 else { return bounds.minY }
        let minY = -adjustedInsets.top
        let maxY = max(minY, contentHeight + adjustedInsets.bottom - bounds.height)
        return min(max(bounds.minY + overshoot, minY), maxY)
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
        didSet { selectionDidChange() }
    }

    public override var selectedTextRange: UITextRange? {
        didSet { selectionDidChange() }
    }

    private func selectionDidChange() {
        engine.autoExpandFolds(atSelectedRanges: [selectedRange])
        engine.selectionDidChangeForLivePreview()
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

    /// ガターの表示と `margins` から左右の `textContainerInset` を決める(上下は触らない)。
    /// 中央寄せはビュー幅に依るので、幅が変わる `layoutSubviews` からも呼ぶ。値が同じなら何もしない
    /// (inset の変更はレイアウトを無効化するので、layoutSubviews からの再入で無限にならないように)。
    private func updateTextInsets() {
        gutter.isHidden = !showsLineNumbers
        let insets = margins.horizontalInsets(
            viewWidth: bounds.width, gutterWidth: gutterWidth, fontSize: engine.theme.bodyFont.pointSize)
        var inset = textContainerInset
        inset.left = insets.leading
        inset.right = insets.trailing
        if inset != textContainerInset {
            textContainerInset = inset
            setNeedsLayout()
        }
    }

    public override func layoutSubviews() {
        // UITextView はこのパスでテキストコンテナの幅を inset から決めるので、その前に余白を確定する。
        updateTextInsets()
        super.layoutSubviews()
        // サブビューはコンテンツ座標に置かれるため、可視領域 = bounds(origin は contentOffset)。
        // ガターと下線オーバーレイは描画バッキングを持つので可視領域にピン留めし、
        // 画像オーバーレイは描画しない(子ビューだけ)のでコンテンツ全体に広げる。
        // キーボード追従のアニメーション中は通過範囲まで広げてコンテンツと一緒に動かす(ピン留めの
        // フレームは最終位置に置かれるので、途中のフレームで出発側の行番号が欠け、数字が本文とずれる)。
        let gutterRange = keyboardScrollTraversedBounds.map { bounds.union($0) } ?? bounds
        gutter.frame = CGRect(x: bounds.minX, y: gutterRange.minY, width: gutterWidth, height: gutterRange.height)
        gutter.contentOffsetY = gutterRange.minY
        if gutterNeedsViewportRefresh {
            gutterNeedsViewportRefresh = false
            textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
        imageOverlay.frame = CGRect(
            x: 0, y: 0, width: bounds.width, height: max(contentSize.height, bounds.height))
        updateLinkHoverOverlay()
        if imageContainerWidth != lastImageContainerWidth {
            lastImageContainerWidth = imageContainerWidth
            engine.imageContainerWidthDidChange()
        }
        // 回転やウィンドウの付け替えでキーボードとの重なりが変わる(値が同じなら何もしない)。
        if keyboardFrameOnScreen != nil { updateKeyboardInset() }
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
