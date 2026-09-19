#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import LapermCore

/// エンジンがビュー(MarkdownTextView)から取り出す情報と、ビューへ返す再同期の要求。
/// AppKit / UIKit のテキストビューが共通で満たす最小のインターフェース。
@MainActor
protocol MarkdownEditorHost: AnyObject {
    var editorContentStorage: NSTextContentStorage? { get }
    var editorLayoutManager: NSTextLayoutManager? { get }
    /// 文書全体の文字列(NSTextView.string / UITextView.text)
    var editorText: String { get }
    /// IME 変換中(marked text 表示中)なら true
    var editorHasMarkedText: Bool { get }
    /// テキストコンテナ座標 → ビュー座標の平行移動量
    var editorTextContainerOrigin: CGPoint { get }
    /// 行の左右パディング(NSTextContainer.lineFragmentPadding)
    var editorLineFragmentPadding: CGFloat { get }
    /// 画像プレビューが使える幅(テキストコンテナの実効幅)
    var imageContainerWidth: CGFloat { get }
    /// ハイライト適用後の再同期(カーソル・ホバー等のオーバーレイ更新)を求める
    func editorDidResync()
    /// 文字が編集された直後(didProcessEditing)に呼ばれる。編集でレンジがずれる状態の破棄に使う
    func editorTextDidChange()
    /// 折畳・装飾の変化でビューポート再レイアウトとガター再描画を求める
    func editorNeedsViewportRelayout()
    /// 現在の選択範囲(キャレットは length 0)。複数選択は AppKit のみ
    var editorSelectedRanges: [NSRange] { get }
    /// 選択範囲を差し替える(折畳で隠れた領域からキャレットを退避させるために使う)
    func editorSelect(_ range: NSRange)
}

/// AppKit / UIKit の MarkdownTextView が共有する編集ロジック。
/// ハイライト・ブロック装飾・折畳・画像プレビューの各コントローラを束ね、
/// TextKit2 スタック(NSTextContentStorage / NSTextLayoutManager)に対して動作する。
/// ビュー固有の処理(描画・入力・座標系)は MarkdownEditorHost 経由で委譲する。
@MainActor
final class MarkdownEditorEngine: NSObject {
    let highlighter: Highlighter
    let imagePreviewController = ImagePreviewController()
    let foldingController = FoldingController()
    let fragmentProvider: BlockFragmentProvider
    weak var host: (any MarkdownEditorHost)?

    private var highlightScheduled = false
    private var lineIndex: LineIndex?

    /// アウトラインが実際に変化したときだけ呼ばれる(Equatable 比較)
    var onOutlineChange: (([OutlineItem]) -> Void)?

    var theme: MarkdownTheme {
        get { highlighter.theme }
        set {
            highlighter.theme = newValue
            fragmentProvider.theme = newValue
        }
    }

    init(theme: MarkdownTheme) {
        highlighter = Highlighter(theme: theme)
        fragmentProvider = BlockFragmentProvider(theme: theme)
        super.init()

        foldingController.onOutlineChanged = { [weak self] in
            guard let self else { return }
            self.onOutlineChange?(self.foldingController.outline)
        }

        // バックグラウンドパース完了経路も IME 変換中の属性適用を避けるため、
        // highlightNow() と同じガードをここでも効かせる。
        highlighter.shouldDeferApply = { [weak self] in self?.host?.editorHasMarkedText ?? false }
        highlighter.applyDeferred = { [weak self] in self?.scheduleHighlight() }
        // バックグラウンドパースの applyFlush は非同期に完了するため、highlightNow が
        // その場で行う再同期(装飾・アウトライン・画像プレビュー)には間に合わない。
        // 巨大文書で「次の編集までアウトラインが更新されない」問題を防ぐため、
        // 完了通知を受けてここで同じ再同期を行う。
        highlighter.onBackgroundFlushApplied = { [weak self] in
            self?.resyncAfterHighlight()
        }

        imagePreviewController.onStateChange = { [weak self] in
            guard let self else { return }
            if self.host?.editorHasMarkedText == true {
                // IME 変換中は spacing 変更を遅延(highlightNow と同じガードに乗せる)
                self.scheduleHighlight()
            } else {
                self.updateImagePreviews()
            }
        }
    }

    /// TextKit2 スタックへデリゲートを接続する。ビューの初期化時に一度だけ呼ぶ。
    func attach(contentStorage: NSTextContentStorage, layoutManager: NSTextLayoutManager) {
        // NSTextContentStorage は NSTextStorageObserving 経由で storage を監視するため
        // delegate スロットは空いている
        contentStorage.textStorage?.delegate = self
        // NSTextContentStorage の delegate は未使用なので折畳コントローラが使う。
        // shouldEnumerate で折畳中の本体段落を列挙から除外する(ストレージ無変更)。
        contentStorage.delegate = foldingController
        fragmentProvider.fallbackDelegate = layoutManager.delegate
        layoutManager.delegate = fragmentProvider
    }

    // MARK: - ハイライト

    /// 全文を再ハイライトする。テキストをプログラムで差し替えた後に呼ぶ。
    /// 巨大文書ではパースがバックグラウンドへ回り、完了時に onBackgroundFlushApplied で再同期される。
    func highlightAll() {
        guard let contentStorage = host?.editorContentStorage,
              let layoutManager = host?.editorLayoutManager else { return }
        // バックグラウンドへ回った場合、currentPlan は「パース待ちの空」であって「見出しの無い文書」ではない。
        // ここで再同期すると折りたたみが全部消え、画像のロード状態も捨てられるので、完了通知まで待つ。
        guard highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager) != .deferredToBackground else { return }
        resyncAfterHighlight()
    }

    /// テーマ変更を反映する。再パースせず、現在の計画に新しい属性を適用し直す。
    func applyThemeChange() {
        guard let contentStorage = host?.editorContentStorage,
              let layoutManager = host?.editorLayoutManager else { return }
        highlighter.reapplyTheme(contentStorage: contentStorage, layoutManager: layoutManager)
        resyncAfterHighlight()
    }

    /// 保留中の編集を即時処理する(通常は didProcessEditing からの遅延実行で呼ばれる)。
    func highlightNow() {
        highlightScheduled = false
        // 日本語変換中(IME マークテキスト表示中)はフラッシュを見送る。
        // 変換中の下線付きテキストはまだ確定しておらず、ここで textStorage に
        // 属性を適用すると変換セッションが乱れる恐れがあるため。
        // ここで再スケジュールしてはいけない: DispatchQueue.main.async の即時再登録は
        // 変換中ずっと highlightNow を回し続けるビジーループになる(メインキュー 100%)。
        // 確定・取消は文字編集(didProcessEditing)か unmarkText を必ず伴い、
        // そこで scheduleHighlight が呼ばれるので保留分は取りこぼさない。
        guard host?.editorHasMarkedText != true else { return }
        guard let contentStorage = host?.editorContentStorage,
              let layoutManager = host?.editorLayoutManager else { return }
        let outcome = highlighter.flushPendingHighlight(
            contentStorage: contentStorage, layoutManager: layoutManager)
        // バックグラウンドパースへ回した場合、currentPlan はまだ編集分をシフトしただけの
        // 旧計画なので、ここで再同期しても装飾・アウトラインは古いまま(見出しが一瞬欠ける等)
        // で、パース完了時の onBackgroundFlushApplied で改めて同期される。二重の作業を省く。
        guard outcome != .deferredToBackground else { return }
        resyncAfterHighlight()
    }

    func scheduleHighlight() {
        guard !highlightScheduled else { return }
        highlightScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.highlightNow()
        }
    }

    private func resyncAfterHighlight() {
        updateBlockDecorations()
        syncFolding()
        updateImagePreviews()
        host?.editorDidResync()
    }

    private func updateBlockDecorations() {
        guard let contentStorage = host?.editorContentStorage,
              let layoutManager = host?.editorLayoutManager else { return }
        fragmentProvider.update(
            plan: highlighter.currentPlan,
            contentManager: contentStorage,
            layoutManager: layoutManager
        )
    }

    // MARK: - 折畳 / アウトライン

    var outline: [OutlineItem] { foldingController.outline }

    var isFoldingEnabled: Bool {
        get { foldingController.isEnabled }
        set {
            guard foldingController.isEnabled != newValue else { return }
            if !newValue { foldingController.unfoldAll() }
            foldingController.isEnabled = newValue
            applyFoldingChanges()
            // 折畳の有無に関わらずビューポート再レイアウトを無条件で要求する。
            // 折畳が 1 件もない(dirty レンジが空)場合 applyFoldingChanges は早期リターンし
            // 再レイアウトが起きないため、ガターは古い collectedLines(旧有効状態の
            // foldMarker)を描き続けてしまう(シェブロンが消えない/現れないバグ)。
            requestViewportRelayout()
        }
    }

    func fold(at headingLocation: Int) {
        if foldingController.fold(at: headingLocation) {
            applyFoldingChanges()
            moveSelectionOutOfFold(at: headingLocation)
        }
    }

    func unfold(at headingLocation: Int) {
        if foldingController.unfold(at: headingLocation) { applyFoldingChanges() }
    }

    func toggleFold(at headingLocation: Int) {
        if foldingController.toggleFold(at: headingLocation) {
            applyFoldingChanges()
            moveSelectionOutOfFold(at: headingLocation)
        }
    }

    /// 折畳の本体にキャレット(または選択)が含まれていたら見出し行末へ退避させる。
    /// 隠れた位置に選択が残ると、レイアウトフラグメントのない場所にキャレットが描かれ、
    /// 次のキー入力が見えないテキストへ挿入される(UIKit ではキーボードも出たまま)。
    private func moveSelectionOutOfFold(at headingLocation: Int) {
        guard let host,
              let fold = foldingController.state.folds.first(where: { $0.headingLocation == headingLocation }),
              fold.bodyRange.length > 0,
              host.editorSelectedRanges.contains(where: { range in
                  range.length == 0
                      ? NSLocationInRange(range.location, fold.bodyRange)
                      : NSIntersectionRange(range, fold.bodyRange).length > 0
              })
        else { return }
        // bodyRange の直前は見出し(最終)行の改行。その行の contentsEnd = 見出し行末。
        // アウトラインは次の flush まで旧座標のことがある(IME 中の flush 遅延など)ので、
        // 文書外を指していたら何もしない(getLineStart の NSRangeException 防止)。
        let text = host.editorText as NSString
        let terminatorLocation = fold.bodyRange.location - 1
        guard terminatorLocation >= 0, terminatorLocation < text.length else { return }
        host.editorSelect(NSRange(location: TextMotions.lineEnd(text: text, at: terminatorLocation), length: 0))
    }

    func unfoldAll() {
        if foldingController.unfoldAll() { applyFoldingChanges() }
    }

    func isFolded(at headingLocation: Int) -> Bool {
        foldingController.isFolded(headingLocation: headingLocation)
    }

    /// range と交差する折畳をすべて解除する。解除したら true。
    /// (見出しへのスクロール前・キャレットが隠し領域に入ったときの自動展開に使う)
    @discardableResult
    func unfoldAll(intersecting range: NSRange) -> Bool {
        guard foldingController.unfoldAll(intersecting: range) else { return false }
        applyFoldingChanges()
        return true
    }

    /// キャレット(選択)が折畳の隠し領域に入ったら自動展開する。
    /// IME 変換中は変換セッションを乱さないよう見送る(確定後の選択変更で再評価される)。
    func autoExpandFolds(atSelectedRanges ranges: [NSRange]) {
        guard isFoldingEnabled, !foldingController.state.isEmpty,
              host?.editorHasMarkedText != true
        else { return }
        var changed = false
        for range in ranges where foldingController.unfoldAll(intersecting: range) {
            changed = true
        }
        if changed { applyFoldingChanges() }
    }

    /// パース確定後にアウトライン・折畳状態を最新プランへ同期する。
    /// バックグラウンドパース経路ではパース完了(onBackgroundFlushApplied)後に呼ばれる。
    private func syncFolding() {
        foldingController.sync(plan: highlighter.currentPlan, text: host?.editorText ?? "")
        applyFoldingChanges()
    }

    /// 折畳状態の変化をレイアウトへ反映する。BlockFragmentProvider.update と同じく
    /// recordEditAction で要素再生成を強制し、ビューポートへ再レイアウトを要求する。
    private func applyFoldingChanges() {
        let dirtyRanges = foldingController.takePendingDirtyRanges()
        guard !dirtyRanges.isEmpty,
              let contentStorage = host?.editorContentStorage,
              let layoutManager = host?.editorLayoutManager else { return }
        let textRanges = dirtyRanges.compactMap { contentStorage.textRange(for: $0) }
        contentStorage.performEditingTransaction {
            for textRange in textRanges {
                contentStorage.recordEditAction(in: textRange, newTextRange: textRange)
            }
        }
        for textRange in textRanges {
            layoutManager.invalidateLayout(for: textRange)
        }
        requestViewportRelayout()
    }

    private func requestViewportRelayout() {
        if let layoutManager = host?.editorLayoutManager {
            let controller = layoutManager.textViewportLayoutController
            controller.delegate?.textViewportLayoutControllerReceivedSetNeedsLayout?(controller)
        }
        host?.editorNeedsViewportRelayout()
    }

    /// [start, end) の段落にアウトラインの見出しがあればシェブロン情報を返す。
    /// 本体のない見出し(折畳不可)にはシェブロンを出さない。
    func foldMarker(inParagraphFrom start: Int, to end: Int) -> GutterFoldMarker? {
        guard isFoldingEnabled else { return nil }
        guard let item = foldingController.outline.first(where: {
            $0.headingLocation >= start && $0.headingLocation < end && $0.bodyRange.length > 0
        }) else { return nil }
        return GutterFoldMarker(
            headingLocation: item.headingLocation,
            isFolded: foldingController.isFolded(headingLocation: item.headingLocation))
    }

    // MARK: - 行番号

    /// UTF-16 オフセットの 1-based 行番号。行インデックスは編集で破棄され、次回必要時に作り直す。
    func lineNumber(atOffset offset: Int) -> Int {
        let index = lineIndex ?? LineIndex(text: host?.editorText ?? "")
        lineIndex = index
        return index.lineNumber(at: offset)
    }

    /// このフラグメント(1 テキスト段落)のガター行情報を返す。ビューポートレイアウトパスから呼ぶ。
    /// フラグメント frame はテキストコンテナ座標なので、コンテナ原点(textContainerInset 等)
    /// ぶんずらしてテキストビュー座標にする(AppKit / UIKit 共通)。
    func gutterLine(for fragment: NSTextLayoutFragment) -> GutterLine? {
        guard let host, let contentManager = host.editorLayoutManager?.textContentManager else { return nil }
        let offset = contentManager.offset(
            from: contentManager.documentRange.location,
            to: fragment.rangeInElement.location)
        let endOffset = contentManager.offset(
            from: contentManager.documentRange.location,
            to: fragment.rangeInElement.endLocation)
        return GutterLine(
            number: lineNumber(atOffset: offset),
            yInTextView: fragment.layoutFragmentFrame.minY + host.editorTextContainerOrigin.y,
            heightInTextView: fragment.layoutFragmentFrame.height,
            foldMarker: foldMarker(inParagraphFrom: offset, to: endOffset))
    }

    // MARK: - 画像プレビュー

    var imagePreviewOptions: ImagePreviewOptions {
        get { imagePreviewController.options }
        set {
            guard imagePreviewController.options != newValue else { return }
            imagePreviewController.options = newValue
            imagePreviewController.resetLoads()
            updateImagePreviews()
        }
    }

    var imageLoader: any ImageLoader {
        get { imagePreviewController.loader }
        set {
            guard imagePreviewController.loader !== newValue else { return }
            imagePreviewController.loader = newValue
            imagePreviewController.resetLoads()
            updateImagePreviews()
        }
    }

    /// 画像プレビューの状態を最新プランに同期し、スペーシングを適用する。
    /// バックグラウンドパース経路ではパース完了(onBackgroundFlushApplied)後に呼ばれる。
    func updateImagePreviews() {
        guard let host, let contentStorage = host.editorContentStorage else { return }
        imagePreviewController.update(references: highlighter.currentPlan.images)
        imagePreviewController.applySpacings(
            contentStorage: contentStorage, containerWidth: host.imageContainerWidth)
    }

    /// コンテナ幅が変わったときに呼ぶ。loaded 画像のフィット高さが変わるため spacing を再計算する。
    /// ただし IME 変換中に直接 storage を触ると変換セッションを乱すため、
    /// onStateChange と同じガードに乗せて確定後に回す。
    func imageContainerWidthDidChange() {
        if host?.editorHasMarkedText == true {
            scheduleHighlight()
        } else {
            updateImagePreviews()
        }
    }

    /// このフラグメント(1 テキスト段落)に属する画像のオーバーレイ配置(ビュー座標)を返す。
    func imagePreviewEntries(for fragment: NSTextLayoutFragment) -> [ImagePreviewOverlayEntry] {
        let references = imagePreviewController.references
        guard !references.isEmpty,
              let host,
              let contentManager = host.editorLayoutManager?.textContentManager,
              let elementRange = fragment.textElement?.elementRange
        else { return [] }
        let start = contentManager.offset(
            from: contentManager.documentRange.location, to: elementRange.location)
        let end = contentManager.offset(
            from: contentManager.documentRange.location, to: elementRange.endLocation)
        let paragraphReferences = references
            .filter { $0.paragraphRange.location >= start && $0.paragraphRange.location < end }
            .sorted { $0.range.location < $1.range.location }
        guard !paragraphReferences.isEmpty else { return [] }
        let width = host.imageContainerWidth
        let sizes = paragraphReferences.map {
            imagePreviewController.displaySize(for: $0, containerWidth: width)
        }
        let origin = host.editorTextContainerOrigin
        // テキスト行群の下端(フラグメント原点からの相対値)。予約領域はここから下に伸びる。
        // textLineFragments が空(レイアウト未確定)のときは reduce の初期値 0 のままになる。
        let textLinesBottom = fragment.textLineFragments
            .reduce(0) { max($0, $1.typographicBounds.maxY) }
        let items = ImagePreviewLayout.itemFrames(
            references: paragraphReferences,
            sizes: sizes,
            fragmentFrame: fragment.layoutFragmentFrame,
            textLinesBottom: textLinesBottom,
            leadingInset: host.editorLineFragmentPadding,
            padding: ImagePreviewController.padding)
        return items.compactMap { item in
            guard let state = imagePreviewController.state(for: item.reference) else { return nil }
            return ImagePreviewOverlayEntry(
                reference: item.reference,
                frame: item.frame.offsetBy(dx: origin.x, dy: origin.y),
                state: state)
        }
    }

    // MARK: - リンク

    /// offset を含むリンク参照(パース確定済みの currentPlan から検索)
    func linkReference(at offset: Int) -> LinkReference? {
        highlighter.currentPlan.links.first { NSLocationInRange(offset, $0.range) }
    }

    /// range(NSRange)をビュー座標の矩形群に変換する。折返しがあれば行ごとに 1 矩形。
    /// レイアウト未確定の場合はそのレンジだけレイアウトを保証する。
    func segmentFrames(for range: NSRange) -> [CGRect]? {
        guard let host,
              let layoutManager = host.editorLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let textRange = contentManager.textRange(for: range)
        else { return nil }
        layoutManager.ensureLayout(for: textRange)
        var frames: [CGRect] = []
        let origin = host.editorTextContainerOrigin
        layoutManager.enumerateTextSegments(
            in: textRange, type: .standard, options: [.rangeNotRequired]
        ) { _, frame, _, _ in
            guard !frame.isNull else { return true }
            frames.append(frame.offsetBy(dx: origin.x, dy: origin.y))
            return true
        }
        return frames
    }

    /// point(ビュー座標)にオンスクリーンで実際に重なっているリンク参照を返す。
    /// 最寄り文字へのクランプでリンクにヒットしてしまうのを防ぐため、候補が見つかった後に
    /// 実際の描画矩形群を取得し、point がそのいずれかに含まれる場合のみ採用する
    /// (取りこぼし防止に小さな許容誤差を持たせる)。
    func linkReference(atPoint point: CGPoint, characterIndex: Int) -> LinkReference? {
        guard let reference = linkReference(at: characterIndex),
              let rects = segmentFrames(for: reference.range)
        else { return nil }
        let tolerance: CGFloat = -2
        return rects.contains { $0.insetBy(dx: tolerance, dy: tolerance).contains(point) }
            ? reference : nil
    }
}

/// 見出し行に表示する折畳インジケータ(ガター描画用)
struct GutterFoldMarker: Equatable {
    var headingLocation: Int
    var isFolded: Bool
}

/// ガターに描く 1 行ぶんの情報(ビューポートレイアウトパスから供給)
struct GutterLine: Equatable {
    var number: Int
    /// テキストビュー座標系でのフラグメント上端 y
    var yInTextView: CGFloat
    /// フラグメントの高さ(ヒット判定の行窓に使う)
    var heightInTextView: CGFloat = 0
    var foldMarker: GutterFoldMarker? = nil
}

extension MarkdownEditorEngine: NSTextStorageDelegate {
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: TextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        // 属性のみの編集(自分自身のハイライト適用)には反応しない — 無限ループ防止
        guard editedMask.contains(.editedCharacters) else { return }
        lineIndex = nil
        highlighter.noteEdit(editedRange: editedRange, changeInLength: delta)
        foldingController.noteEdit(editedRange: editedRange, changeInLength: delta)
        fragmentProvider.noteEdit(editedRange: editedRange, changeInLength: delta)
        scheduleHighlight()
        host?.editorTextDidChange()
    }
}
