import AppKit
import LapermCore

/// パース結果(HighlightPlan)を TextKit2 スタックへ差分適用するエンジン。
/// フォント(レイアウト属性)は textStorage へ、色は renderingAttributes へ適用する。
@MainActor
public final class Highlighter {
    public var theme: MarkdownTheme
    public private(set) var currentPlan = HighlightPlan()

    /// 直近のパース所要時間がこれを超えていたら、次回の flush はバックグラウンド経路を使う。
    /// spec: 「パースが 16ms を超える巨大文書ではパースをバックグラウンドキューで行う」
    public var backgroundParseThreshold: Duration = .milliseconds(16)

    /// バックグラウンドパース完了時、今すぐ属性適用してよいかを呼び出し側(view)に問い合わせる。
    /// true を返すと適用を見送る(IME 変換中など)。view 側の highlightNow() が持つ
    /// hasMarkedText() ガードと同じ判断をここでも効かせるためのフック。
    public var shouldDeferApply: (() -> Bool)?
    /// shouldDeferApply が true だった場合に呼ばれる。pendingEditedRanges は
    /// クリアされていないので、view はこれをきっかけに再スケジュールし、
    /// ガード解除後の次の flush で確実に適用させること。
    public var applyDeferred: (() -> Void)?

    private let parser = MarkdownParser()
    private var pendingEditedRanges: [NSRange] = []
    private var lastParseDuration: Duration = .zero
    private var generation = 0
    /// テスト用: 進行中のバックグラウンドパース。世代が一致すれば完了時に適用、
    /// 不一致(その間に編集が入った)なら破棄して再フラッシュする。
    var activeBackgroundParse: Task<Void, Never>?

    public init(theme: MarkdownTheme) {
        self.theme = theme
    }

    /// 全文を再ハイライトする(初期表示・テーマ変更・プログラムによる全文置換時)。
    public func rehighlightAll(
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager
    ) {
        guard let storage = contentStorage.textStorage else { return }
        // 進行中のバックグラウンドパース結果を無効化する。これを怠ると、旧テキストを
        // パースした結果が世代一致のまま新テキストへ適用されてしまう(誤ハイライト)。
        // 無効化されたタスクは破棄経路で flushPendingHighlight を再呼び出しするが、
        // 直下で pendingEditedRanges を空にするため無害な no-op になる。
        generation += 1
        let clock = ContinuousClock()
        var plan = HighlightPlan()
        lastParseDuration = clock.measure { plan = parser.highlightPlan(for: storage.string) }
        let fullRange = NSRange(location: 0, length: storage.length)
        apply(
            spans: plan.spans,
            resetting: [fullRange],
            contentStorage: contentStorage,
            layoutManager: layoutManager
        )
        currentPlan = plan
        pendingEditedRanges = []
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
    public func flushPendingHighlight(
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager
    ) {
        guard !pendingEditedRanges.isEmpty, let storage = contentStorage.textStorage else { return }
        if lastParseDuration > backgroundParseThreshold {
            startBackgroundFlush(
                text: storage.string, contentStorage: contentStorage, layoutManager: layoutManager)
            return
        }
        let clock = ContinuousClock()
        var newPlan = HighlightPlan()
        lastParseDuration = clock.measure { newPlan = parser.highlightPlan(for: storage.string) }
        applyFlush(newPlan: newPlan, contentStorage: contentStorage, layoutManager: layoutManager)
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
    /// 注意: MarkdownTextView.highlightNow() は flushPendingHighlight の直後に
    /// updateBlockDecorations() を呼ぶが、この経路では apply が非同期に完了するため
    /// ブロック装飾の更新は今回のサイクルには間に合わない。装飾は次回の
    /// flush/rehighlightAll で追いつく(巨大文書では 1 サイクル遅延することを許容する v1 の設計)。
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
            } else {
                // 古い結果は破棄。パース中に来た編集の highlightNow は active ガードで
                // 素通りしているため、ここで自分から再フラッシュしないと取りこぼす。
                self.flushPendingHighlight(contentStorage: contentStorage, layoutManager: layoutManager)
            }
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
        contentStorage.performEditingTransaction {
            for range in invalidated {
                let clipped = clip(range, to: documentLength)
                guard clipped.length > 0 else { continue }
                storage.addAttributes(theme.bodyLayoutAttributes, range: clipped)
                // addAttributes では古い打ち消し線を消せないため、自前で管理する
                // キーだけ明示的に取り除く(setAttributes を避けて IME 属性は保護したまま)。
                storage.removeAttribute(.strikethroughStyle, range: clipped)
                storage.removeAttribute(.strikethroughColor, range: clipped)
            }
            for span in spans {
                let attributes = theme.storageAttributes(for: span.kind)
                guard !attributes.isEmpty else { continue }
                let clipped = clip(span.range, to: documentLength)
                guard clipped.length > 0 else { continue }
                storage.addAttributes(attributes, range: clipped)
            }
        }

        // 2) レイアウトに影響しない属性(色)— renderingAttributes へ。再レイアウトなし。
        for range in invalidated {
            let clipped = clip(range, to: documentLength)
            guard clipped.length > 0,
                  let textRange = contentStorage.textRange(for: clipped) else { continue }
            layoutManager.setRenderingAttributes([.foregroundColor: theme.bodyColor], for: textRange)
        }
        for span in spans {
            let attributes = theme.renderingAttributes(for: span.kind)
            guard !attributes.isEmpty else { continue }
            let clipped = clip(span.range, to: documentLength)
            guard clipped.length > 0,
                  let textRange = contentStorage.textRange(for: clipped) else { continue }
            for (key, value) in attributes {
                layoutManager.addRenderingAttribute(key, value: value, for: textRange)
            }
        }
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
