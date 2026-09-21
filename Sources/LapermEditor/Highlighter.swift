#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import LapermCore

/// パース結果(HighlightPlan)を TextKit2 スタックへ差分適用するエンジン。
/// フォント(レイアウト属性)は textStorage へ、色は macOS では renderingAttributes へ、
/// iOS では描画位置ズレ回避のため textStorage へ適用する(apply 内のコメント参照)。
@MainActor
public final class Highlighter {
    public var theme: MarkdownTheme {
        didSet {
            storageAttributeCache = [:]
            renderingAttributeCache = [:]
        }
    }
    public private(set) var currentPlan = HighlightPlan()

    /// 直近のパース所要時間がこれを超えていたら、次回の flush はバックグラウンド経路を使う。
    /// spec: 「パースが 16ms を超える巨大文書ではパースをバックグラウンドキューで行う」
    public var backgroundParseThreshold: Duration = .milliseconds(16)

    /// 全文再ハイライト(初回表示・全文置換)で、文書がこの長さ(UTF-16 単位)を超えていたら
    /// メインスレッドで同期パースせず、本文属性だけ先に適用してバックグラウンドでパースする。
    /// 1 万行(約 60 万文字)の同期パースは 90ms 以上かかり、Note を開く操作が固まるため。
    /// 既定値はおよそ 16ms で同期パースできる長さ。
    public var backgroundParseLengthThreshold: Int = 64 * 1024

    /// バックグラウンドパース完了時、今すぐ属性適用してよいかを呼び出し側(エンジン)に問い合わせる。
    /// true を返すと適用を見送る(IME 変換中など)。MarkdownEditorEngine.highlightNow() が持つ
    /// marked text ガードと同じ判断をここでも効かせるためのフック。
    public var shouldDeferApply: (() -> Bool)?
    /// shouldDeferApply が true だった場合に呼ばれる。pendingEditedRanges は
    /// クリアされていないので、呼び出し側はこれをきっかけに再スケジュールし、
    /// ガード解除後の次の flush で確実に適用させること。
    public var applyDeferred: (() -> Void)?

    /// バックグラウンドパース完了で applyFlush が非同期に走ったあとに呼ばれる。
    /// 呼び出し側はこれを装飾・アウトライン・画像プレビューの再同期のきっかけにする
    /// (同期経路では highlightNow が自分で再同期するため呼ばない)。
    public var onBackgroundFlushApplied: (() -> Void)?

    /// flushPendingHighlight の結果。
    public enum FlushOutcome: Equatable, Sendable {
        /// 保留中の編集がなく、何もしなかった
        case nothingPending
        /// 同期でパース・適用まで完了した
        case applied
        /// バックグラウンドパースへ回した(適用は onBackgroundFlushApplied で通知される)
        case deferredToBackground
    }

    private let parser = MarkdownParser()
    private var pendingEditedRanges: [NSRange] = []
    private var lastParseDuration: Duration = .zero
    private var generation = 0
    /// 進行中のバックグラウンドパース(同時実行を 1 本に絞る排他にも使う)。
    /// 世代が一致すれば完了時に適用、不一致(その間に編集が入った)なら破棄して再フラッシュする。
    var activeBackgroundParse: Task<Void, Never>?

    /// kind ごとの属性辞書。スパンごとに辞書を組み立て直すコスト(10k 行の全文適用で
    /// 6 万回)を避けるため、テーマが変わるまでキャッシュする。
    private var storageAttributeCache: [SyntaxKind: [NSAttributedString.Key: Any]] = [:]
    private var renderingAttributeCache: [SyntaxKind: [NSAttributedString.Key: Any]] = [:]

    public init(theme: MarkdownTheme) {
        self.theme = theme
    }

    private func storageAttributes(for kind: SyntaxKind) -> [NSAttributedString.Key: Any] {
        if let cached = storageAttributeCache[kind] { return cached }
        let attributes = theme.storageAttributes(for: kind)
        storageAttributeCache[kind] = attributes
        return attributes
    }

    private func renderingAttributes(for kind: SyntaxKind) -> [NSAttributedString.Key: Any] {
        if let cached = renderingAttributeCache[kind] { return cached }
        let attributes = theme.renderingAttributes(for: kind)
        renderingAttributeCache[kind] = attributes
        return attributes
    }

    /// 全文を再ハイライトする(初期表示・プログラムによる全文置換時)。
    /// テーマだけが変わった場合は再パースの要らない `reapplyTheme` を使う。
    ///
    /// 文書が `backgroundParseLengthThreshold` より長ければ、全文を本文属性に戻してすぐ返り、
    /// パースはバックグラウンドで行って完了時に適用する(`onBackgroundFlushApplied` で通知)。
    /// 巨大な Note を開いたときにメインスレッドを塞がないため。
    @discardableResult
    public func rehighlightAll(
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager
    ) -> FlushOutcome {
        guard let storage = contentStorage.textStorage else { return .nothingPending }
        // 進行中のバックグラウンドパース結果を無効化する。これを怠ると、旧テキストを
        // パースした結果が世代一致のまま新テキストへ適用されてしまう(誤ハイライト)。
        // 無効化されたタスクは破棄経路で flushPendingHighlight を再呼び出しするが、
        // 同期経路では直下で pendingEditedRanges を空にするため無害な no-op になる。
        generation += 1
        let fullRange = NSRange(location: 0, length: storage.length)
        if storage.length > backgroundParseLengthThreshold {
            // 先にプレーンテキスト(本文属性)を見せる。以後の flush もバックグラウンド経路に乗せる。
            apply(spans: [], resetting: [fullRange], contentStorage: contentStorage, layoutManager: layoutManager)
            currentPlan = HighlightPlan()
            pendingEditedRanges = [fullRange]
            lastParseDuration = max(lastParseDuration, backgroundParseThreshold + .milliseconds(1))
            // 進行中のパースがあれば、その破棄経路が flushPendingHighlight を呼んで改めて始める。
            startBackgroundFlush(text: storage.string, contentStorage: contentStorage, layoutManager: layoutManager)
            return .deferredToBackground
        }
        let clock = ContinuousClock()
        var plan = HighlightPlan()
        lastParseDuration = clock.measure { plan = parser.highlightPlan(for: storage.string) }
        apply(
            spans: plan.spans,
            resetting: [fullRange],
            contentStorage: contentStorage,
            layoutManager: layoutManager
        )
        currentPlan = plan
        pendingEditedRanges = []
        return .applied
    }

    /// テーマ変更を現在の計画に適用し直す。再パースはしない(テキストは変わっていないため)。
    /// バックグラウンドパースが進行中なら、その完了時に新テーマで全体が適用される。
    public func reapplyTheme(
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager
    ) {
        guard let storage = contentStorage.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        apply(
            spans: currentPlan.spans,
            resetting: [fullRange],
            contentStorage: contentStorage,
            layoutManager: layoutManager
        )
    }

    /// NSTextStorageDelegate の didProcessEditing(.editedCharacters)から呼ぶ。
    /// storage には触らず、計画のシフトと編集レンジの記録だけを行う。
    public func noteEdit(editedRange: NSRange, changeInLength delta: Int) {
        generation += 1
        // 記録済みの保留レンジも今回の編集分だけシフトする。これを怠ると
        // 複数編集を 1 回の flush でまとめたとき、古い座標のままのレンジが
        // 誤った領域を無効化したり新文書長を超えたりする(clip の assert が発火)。
        // editedRange は編集「後」のレンジ。編集「前」に影響を受けた領域は
        // {editedRange.location, editedRange.length - delta}(HighlightPlan.shifted と同じ規約)。
        let preEditRange = NSRange(
            location: editedRange.location,
            length: max(0, editedRange.length - delta)
        )
        pendingEditedRanges = pendingEditedRanges.map { range in
            if NSMaxRange(range) <= preEditRange.location {
                // 編集より完全に前: そのまま
                return range
            } else if range.location >= NSMaxRange(preEditRange) {
                // 編集より完全に後: delta だけ平行移動
                return NSRange(location: range.location + delta, length: range.length)
            } else {
                // 編集と交差: 旧レンジを編集後座標へ写像し、新編集レンジと合併して拡張。
                // 先頭は編集開始より前ならそのまま、以降は編集開始位置。
                // 末尾は「編集レンジ末尾」と「旧レンジ末尾を delta シフトした位置」の大きい方
                // (旧末尾が pre-edit 領域内なら oldEnd + delta <= editEnd なので editEnd に丸まる)。
                let start = min(range.location, editedRange.location)
                let end = max(NSMaxRange(editedRange), NSMaxRange(range) + delta)
                return NSRange(location: start, length: max(0, end - start))
            }
        }
        // 編集と交差して破棄されるスパン(shifted が捨てる分)の全体レンジも
        // 無効化対象に含める。これを怠ると、スパンの一部だけが編集された場合
        // (例: 打ち消し線の開きチルダだけを削除して構文が壊れた場合)、
        // 非編集領域に残った古い renderingAttributes(打ち消し線など)が
        // 次の flush でリセットされず残留してしまう。
        var widened = editedRange
        for span in currentPlan.spans {
            let intersectsEdit =
                !(NSMaxRange(span.range) <= preEditRange.location
                    || span.range.location >= NSMaxRange(preEditRange))
            guard intersectsEdit else { continue }
            let start = min(widened.location, span.range.location)
            let end = max(NSMaxRange(widened), NSMaxRange(span.range) + delta)
            widened = NSRange(location: start, length: max(0, end - start))
        }
        currentPlan = currentPlan.shifted(byEditAt: editedRange, changeInLength: delta)
        pendingEditedRanges.append(widened)
    }

    /// 保留中の編集をまとめて処理する(ランループの次サイクルで呼ぶ)。
    @discardableResult
    public func flushPendingHighlight(
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager
    ) -> FlushOutcome {
        guard !pendingEditedRanges.isEmpty, let storage = contentStorage.textStorage else {
            return .nothingPending
        }
        if lastParseDuration > backgroundParseThreshold {
            startBackgroundFlush(
                text: storage.string, contentStorage: contentStorage, layoutManager: layoutManager)
            return .deferredToBackground
        }
        let clock = ContinuousClock()
        var newPlan = HighlightPlan()
        lastParseDuration = clock.measure { newPlan = parser.highlightPlan(for: storage.string) }
        applyFlush(newPlan: newPlan, contentStorage: contentStorage, layoutManager: layoutManager)
        return .applied
    }

    /// 差分計算〜適用〜状態更新の共通経路(同期・バックグラウンド完了の両方から呼ぶ)。
    private func applyFlush(
        newPlan: HighlightPlan,
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager
    ) {
        let changes = HighlightDiff.compute(
            old: currentPlan,
            new: newPlan,
            alwaysInvalidating: pendingEditedRanges
        )
        apply(
            spans: changes.spansToApply,
            resetting: changes.invalidatedRanges,
            contentStorage: contentStorage,
            layoutManager: layoutManager
        )
        currentPlan = newPlan
        pendingEditedRanges = []
    }

    /// 巨大文書向けのバックグラウンドパース経路(世代番号方式)。
    /// 同時実行は 1 本のみ(完了時に世代を再チェックし、必要ならこの関数から
    /// 再度 flushPendingHighlight を呼ぶことで取りこぼしを防ぐ)。
    ///
    /// 注意: この経路では apply が非同期に完了するため、MarkdownEditorEngine.highlightNow() は
    /// `.deferredToBackground` を受けて再同期をスキップする。世代一致で applyFlush が
    /// 走った直後に onBackgroundFlushApplied を呼ぶので、エンジン側はそこで装飾・
    /// アウトライン・画像プレビューを再同期する(呼ばれるのは世代一致の適用時のみ。
    /// 破棄経路や同期経路では呼ばない — 二重同期を避けるため)。
    private func startBackgroundFlush(
        text: String,
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager
    ) {
        guard activeBackgroundParse == nil else { return }
        let snapshotGeneration = generation
        let parser = self.parser
        activeBackgroundParse = Task { @MainActor [weak self, weak contentStorage, weak layoutManager] in
            let clock = ContinuousClock()
            let start = clock.now
            let plan = await Task.detached(priority: .userInitiated) {
                parser.highlightPlan(for: text)
            }.value
            guard let self else { return }
            self.activeBackgroundParse = nil
            self.lastParseDuration = clock.now - start
            guard let contentStorage, let layoutManager else { return }
            if self.generation == snapshotGeneration {
                if self.shouldDeferApply?() == true {
                    // IME 変換中など、いま適用できない場合は保留のまま残す。
                    // pendingEditedRanges は残っているので、変換確定後の
                    // 次のフラッシュ(view の scheduleHighlight 経由)で処理される。
                    self.applyDeferred?()
                    return
                }
                self.applyFlush(
                    newPlan: plan, contentStorage: contentStorage, layoutManager: layoutManager)
                self.onBackgroundFlushApplied?()
            } else {
                // 古い結果は破棄。パース中に来た編集の highlightNow は active ガードで
                // 素通りしているため、ここで自分から再フラッシュしないと取りこぼす。
                // 短い旧文書のパースが速く終わっても、長文はバックグラウンド経路に留める
                // (同期経路へ戻るとメインスレッドで全文パースし、IME ガードも通らない)。
                if let storage = contentStorage.textStorage, storage.length > self.backgroundParseLengthThreshold {
                    self.lastParseDuration = max(self.lastParseDuration, self.backgroundParseThreshold + .milliseconds(1))
                }
                if self.shouldDeferApply?() == true {
                    self.applyDeferred?()
                    return
                }
                // 同期で適用できた場合も、エンジンは先の flush で `.deferredToBackground` を受けて
                // 再同期を見送っているので、ここで完了を知らせる。
                if self.flushPendingHighlight(contentStorage: contentStorage, layoutManager: layoutManager) == .applied {
                    self.onBackgroundFlushApplied?()
                }
            }
        }
    }

    /// `range` 内で画像プレビューの予約マーカーが付いた部分に、`base`(行間)の上に
    /// 予約高さを paragraphSpacing として重ねた段落スタイルを付け直す。
    static func restoreImageSpacing(in storage: NSTextStorage, range: NSRange, base: NSParagraphStyle?) {
        storage.enumerateAttribute(ImagePreviewController.spacingAttribute, in: range) { value, run, _ in
            guard let height = value as? CGFloat else { return }
            storage.addAttribute(
                .paragraphStyle, value: ImagePreviewController.spacingStyle(height: height, base: base), range: run)
        }
    }

    // MARK: - 適用

    private func apply(
        spans: [HighlightSpan],
        resetting invalidated: [NSRange],
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager
    ) {
        guard let storage = contentStorage.textStorage else { return }
        let documentLength = storage.length

        // 1) textStorage 側属性(フォント・打ち消し線)— 編集トランザクション内で適用。
        //    属性編集は .editedAttributes しか発火しないため didProcessEditing の
        //    文字編集ガードと組み合わせて再入しない。
        //    リセットは addAttributes(= .font キーのみ上書き)で行う。setAttributes だと
        //    IME の変換下線やスペルチェックなど自前で管理していない属性まで消してしまう
        //    (計画の例コードからの意図的逸脱 — IME 属性保護のため)。
        let bodyLayoutAttributes = theme.bodyLayoutAttributes
        let bodyColorAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: theme.bodyColor]
        let baseParagraphStyle = theme.baseParagraphStyle
        contentStorage.performEditingTransaction {
            for range in invalidated {
                let clipped = clip(range, to: documentLength)
                guard clipped.length > 0 else { continue }
                storage.addAttributes(bodyLayoutAttributes, range: clipped)
                // 段落スタイルは土台(行間)で上書きする。行間 0 のテーマでは addAttributes が
                // 古い行間を消してくれないので明示的に外す(テーマ切替で前の行間が残らないように)。
                // どちらの場合も画像プレビューが予約した paragraphSpacing は消えるが、マーカー属性は
                // 残るので ImagePreviewController は「変化なし」と判断して再適用しない
                // → 予約高さをここで載せ直す。
                if baseParagraphStyle == nil {
                    storage.removeAttribute(.paragraphStyle, range: clipped)
                }
                Self.restoreImageSpacing(in: storage, range: clipped, base: baseParagraphStyle)
                // addAttributes では古い打ち消し線を消せないため、自前で管理する
                // キーだけ明示的に取り除く(setAttributes を避けて IME 属性は保護したまま)。
                storage.removeAttribute(.strikethroughStyle, range: clipped)
                storage.removeAttribute(.strikethroughColor, range: clipped)
                #if canImport(UIKit) && !canImport(AppKit)
                storage.addAttributes(bodyColorAttributes, range: clipped)
                #endif
            }
            for span in spans {
                let clipped = clip(span.range, to: documentLength)
                guard clipped.length > 0 else { continue }
                let attributes = storageAttributes(for: span.kind)
                if !attributes.isEmpty {
                    storage.addAttributes(attributes, range: clipped)
                }
                #if canImport(UIKit) && !canImport(AppKit)
                // 2) 色 — iOS では textStorage 側属性として、フォントと同じ 1 トランザクションで適用する。
                //    UITextView(TextKit2)は renderingAttributes の色を、CJK などフォールバックフォントが
                //    混在する行で誤った文字位置に描画する(シミュレータ検証で確認。属性自体は正しい位置に
                //    設定されている)。storage 属性なら通常のレイアウト経路で正しく描画される。
                //    属性のみの編集なので .editedAttributes しか発火せず、再入しない。
                //    トランザクションを 1 つにまとめるのは processEditing → レイアウト無効化を
                //    フラッシュごとに 2 回走らせないため。
                let colors = renderingAttributes(for: span.kind)
                if !colors.isEmpty {
                    storage.addAttributes(colors, range: clipped)
                }
                #endif
            }
        }

        #if canImport(AppKit)
        // 2) レイアウトに影響しない属性(色)— renderingAttributes へ。再レイアウトなし。
        for range in invalidated {
            let clipped = clip(range, to: documentLength)
            guard clipped.length > 0,
                  let textRange = contentStorage.textRange(for: clipped) else { continue }
            layoutManager.setRenderingAttributes(bodyColorAttributes, for: textRange)
        }
        for span in spans {
            let attributes = renderingAttributes(for: span.kind)
            guard !attributes.isEmpty else { continue }
            let clipped = clip(span.range, to: documentLength)
            guard clipped.length > 0,
                  let textRange = contentStorage.textRange(for: clipped) else { continue }
            for (key, value) in attributes {
                layoutManager.addRenderingAttribute(key, value: value, for: textRange)
            }
        }
        #endif
    }

    /// レンジを文書長にクリップする。パース結果と storage の不整合が起きた場合の防波堤。
    private func clip(_ range: NSRange, to documentLength: Int) -> NSRange {
        let location = min(max(0, range.location), documentLength)
        let length = min(range.length, documentLength - location)
        assert(location == range.location && length == range.length,
               "HighlightPlan range \(range) exceeds document length \(documentLength)")
        return NSRange(location: location, length: length)
    }
}

