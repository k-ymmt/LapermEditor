#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import LapermCore

/// Live Preview で折りたたむブロックの構造(テーブル / コードブロック)。
protocol PreviewableBlock: Equatable {
    /// ブロックの先頭からブロックの内容の末尾まで(文書座標)
    var range: NSRange { get }
    func shifted(by delta: Int) -> Self
    /// 編集(編集前の座標)がこのブロックの構造を変えうるか
    func isTouched(byEditBefore preEditRange: NSRange) -> Bool
}

extension MarkdownTable: PreviewableBlock {}
extension MarkdownCodeBlock: PreviewableBlock {}

/// オーバーレイに渡す、折りたたんだブロック 1 つの配置(frame はテキストビュー座標)と描画。
@MainActor
protocol BlockPreviewOverlayEntry: Equatable {
    /// ブロックの先頭(文書座標)。オーバーレイがビューを使い回す鍵。
    var location: Int { get }
    var frame: CGRect { get }
    /// 座標は y 下向き、原点は描画の左上。`visibleRect` は描く必要のある矩形。
    func draw(in context: CGContext, visibleRect: CGRect)
}

/// 折りたたんだブロックの場所に描くもののレイアウト。
protocol BlockPreviewLayout: Equatable {
    /// ブロックの先頭の段落に予約する高さ(余白込み)
    var reservedHeight: CGFloat { get }
}

/// テーマから引く見た目。
protocol BlockPreviewAppearance: Equatable {
    init(theme: MarkdownTheme)
}

/// 折りたたむブロック 1 つの材料(パース結果 + 内容のモデルのキャッシュ)。具体の折りたたみ(テーブル / コードブロック)
/// が用意し、`BlockPreviewController` がフォーカス・編集・幅の変化を一手に扱う。
protocol BlockPreviewSource {
    associatedtype Block: PreviewableBlock
    associatedtype Layout: BlockPreviewLayout
    associatedtype Appearance: BlockPreviewAppearance
    associatedtype Key: Hashable

    var block: Block { get set }
    /// 内容が同じかを位置に依らず判定する鍵(前の編集で位置だけ動いたブロックのモデルを使い回す)。
    var key: Key { get }
    /// 文書座標の材料をすべて `delta` だけ平行移動したもの。
    func shifted(by delta: Int) -> Self
    /// 同じ鍵の前回の材料からモデルのキャッシュを引き継ぐ。
    mutating func adoptCache(from previous: Self)
    /// モデル(内容)が作られているか(テスト用)。
    var isModelBuilt: Bool { get }
    /// レイアウトを作る(モデルが無ければここで作る: 折りたたむときに初めて作り、展開中の巨大なブロックで 1 文字打つ
    /// たびに作り直さない)。ブロックがストレージの外を指していれば nil(折りたたまない)。
    @MainActor
    mutating func makeLayout(width: CGFloat, appearance: Appearance, storage: NSTextStorage, theme: MarkdownTheme) -> Layout?
}

/// Live Preview でブロックを折りたたんで別の描画に置き換える状態機械(Laperm ADR 0019 / 0020)。`FrontMatterController` と
/// 同じ仕組みを、文書のどこにでも複数あるブロックへ広げたもの。テーブル(`TablePreviewController`)とコードブロック
/// (`CodeBlockPreviewController`)がこれの具体化。
///
/// 折りたたみ中は、ブロックの先頭の段落だけを残して(文字は極小フォントで幅ゼロ・高さほぼゼロにし、段落の後ろに
/// 描画の高さを予約する)、残りの段落を列挙から外す(セクション折りたたみと同じ仕組み。テキストストレージには
/// 触らない)。描画はオーバーレイが予約領域に行う。
///
/// フォーカスの単位はブロック: エディタが first responder で、選択範囲(キャレット)がそのブロック(内容の末尾まで)に
/// 触れている間は展開され、Source と同じ見た目で編集できる。他のブロックは折りたたまれたまま。
///
/// 入力(有効 / 無効、ブロック、選択、フォーカス、幅、テーマ)から「望む表示」を計算し、TextKit に見せる
/// 「現在の表示」(`presented`)へは `canPresent()` が true のときだけ移す(IME 変換中は見送る)。ブロックに触る
/// 編集はそのブロックをモデルから外し(次のパースまで展開)、描画のクリックも受け付けない。
@MainActor
final class BlockPreviewController<Source: BlockPreviewSource> {
    typealias Block = Source.Block
    typealias Layout = Source.Layout
    typealias Appearance = Source.Appearance

    /// TextKit に見せている表示のブロック 1 つ。
    struct PresentedBlock: Equatable {
        var block: Block
        /// ブロックの段落全体(最後の行の改行まで)。切替時に作り直す範囲。編集で追従させる。
        var blockParagraphsRange: NSRange
        var layout: Layout
    }

    /// モデルのブロック 1 つ(材料 + レイアウトのキャッシュ)。
    private struct Entry {
        var source: Source
        var blockParagraphsRange: NSRange
        var layout: Layout?
        var layoutWidth: CGFloat = 0
        var layoutAppearance: Appearance?
        var block: Block { source.block }
    }

    // MARK: 入力

    private(set) var isEnabled = false
    private var entries: [Entry] = []
    /// 直近の `update` 時の文書の長さ(文末の空行がブロックの段落に属するかの判定に使う)。編集で追従させる。
    private(set) var documentLength = 0
    private(set) var isEditorFocused = true
    private(set) var selectedRanges: [NSRange] = []
    private(set) var containerWidth: CGFloat = 0
    private(set) var appearance: Appearance
    private(set) var theme: MarkdownTheme
    private(set) var themeGeneration = 0
    /// 直近の `update` のテキストストレージ(内容を遅延して作るために持つ)。エンジン(テキストビュー)が持ち主なので弱参照。
    private weak var storage: NSTextStorage?
    /// 展開中(モデルにあるが折りたたまれていない)のブロック。行単位の Syntax Marker 隠しから除外し、
    /// ブロック全体を Source と同じ見た目にする(ADR 0019: フォーカスの単位はブロック)。編集で追従させる。
    private(set) var exemptRanges: [NSRange] = []
    /// 今 TextKit の表示を変えてよいか(IME 変換中は false)。既定は常に true。
    var canPresent: () -> Bool = { true }

    // MARK: 表示

    /// 位置順。
    private(set) var presented: [PresentedBlock] = []
    private var pendingDirtyRanges: [NSRange] = []
    private var needsRedraw = false

    init(theme: MarkdownTheme) {
        self.theme = theme
        appearance = Appearance(theme: theme)
    }

    /// モデルにあるブロック(折りたたみ候補。テスト用)。
    var blocks: [Block] { entries.map(\.block) }

    /// 折りたたまれているブロックの先頭位置(昇順)。
    var collapsedLocations: [Int] { presented.map(\.block.range.location) }

    func isCollapsed(blockAt location: Int) -> Bool {
        presented.contains { $0.block.range.location == location }
    }

    /// テスト用: そのブロックの内容が作られているか。
    func isModelBuilt(forBlockAt location: Int) -> Bool {
        entries.first { $0.block.range.location == location }?.source.isModelBuilt ?? false
    }

    /// `location` から始まるブロックがモデルにあるか(触る編集の後、次のパースまでは無い)。
    func hasBlock(at location: Int) -> Bool {
        entries.contains { $0.block.range.location == location }
    }

    // MARK: - 入力の更新

    /// パース確定後の同期。`sources` は折りたたみ候補(位置順、互いに重ならない)、`storage` はハイライト適用済みの
    /// テキストストレージ、`text` はその文字列。同じ鍵の前回の材料からモデルを引き継ぐ。
    func update(sources: [Source], storage: NSTextStorage, text: NSString) {
        // 前回の材料を鍵で引く(同じ内容のブロックが複数あれば位置順に対応させる)。ブロック数 × ブロック数にしない。
        var old: [Source.Key: [Entry]] = [:]
        for entry in entries.reversed() { old[entry.source.key, default: []].append(entry) }
        self.storage = storage
        documentLength = text.length
        entries = sources.map { source -> Entry in
            // ブロックの段落: 先頭の行の行頭(インデント型コードブロックはブロックの先頭がインデントの後にある)から
            // 最後の行の改行まで
            let origin = text.lineRange(for: NSRange(location: source.block.range.location, length: 0)).location
            let block = NSRange(location: origin, length: Self.endIncludingNewline(of: source.block.range, in: text) - origin)
            var entry = Entry(source: source, blockParagraphsRange: block)
            // 同じ鍵の前回の材料からモデルとレイアウトを引き継ぐ(パースのたびに全ブロックを作り直さない)
            if let previous = old[source.key]?.popLast() {
                entry.source.adoptCache(from: previous.source)
                entry.layout = previous.layout
                entry.layoutWidth = previous.layoutWidth
                entry.layoutAppearance = previous.layoutAppearance
            }
            return entry
        }
        present()
        refreshExemptRanges()
    }

    /// 展開中のブロックを取り直し、変わった分(展開された / 折りたたまれた / 範囲が変わった)を作り直す
    /// (表示用段落の Syntax Marker 隠しが変わる)。
    private func refreshExemptRanges() {
        // 表示を移せない間(IME 変換中)は除外も動かさない(移せたときに `present` がまとめて取り直す)
        guard canPresent() else { return }
        let new: [NSRange] = isEnabled
            ? entries.filter { entry in !presented.contains { $0.blockParagraphsRange.location == entry.blockParagraphsRange.location } }
                .map(\.blockParagraphsRange)
            : []
        guard new != exemptRanges else { return }
        for range in exemptRanges where !new.contains(range) { appendDirty(range) }
        for range in new where !exemptRanges.contains(range) { appendDirty(range) }
        exemptRanges = new
    }

    /// `paragraph` が展開中のブロックにあるか(行単位の Syntax Marker 隠しから除外する)。
    func isExempt(paragraph: NSRange) -> Bool {
        exemptRanges.contains { NSLocationInRange(paragraph.location, $0) }
    }

    /// `range` の行末から次の行頭までを含めた終端(改行込み)。文書がそこで終わっていれば `NSMaxRange(range)`。
    static func endIncludingNewline(of range: NSRange, in text: NSString) -> Int {
        guard NSMaxRange(range) <= text.length, range.length > 0 else { return NSMaxRange(range) }
        return NSMaxRange(text.lineRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0)))
    }

    func selectionDidChange(_ ranges: [NSRange]) {
        guard ranges != selectedRanges else { return }
        selectedRanges = ranges
        present()
    }

    func editorFocusDidChange(_ focused: Bool) {
        guard isEditorFocused != focused else { return }
        isEditorFocused = focused
        present()
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        present()
        refreshExemptRanges()
    }

    func containerWidthDidChange(_ width: CGFloat) {
        guard width != containerWidth else { return }
        containerWidth = width
        present()
    }

    /// テーマの変更。内容(色・フォント)は次の `update` で作り直す(エンジンはテーマ変更のあと再同期する)。
    func themeDidChange(_ newTheme: MarkdownTheme) {
        guard newTheme != theme else { return }
        theme = newTheme
        themeGeneration += 1
        let newAppearance = Appearance(theme: newTheme)
        guard newAppearance != appearance else { return }
        appearance = newAppearance
        present()
    }

    /// 編集(didProcessEditing)からの座標追従。ブロック(前後を含む: 直前の改行の削除や先頭への挿入も構造を変える)に
    /// 触る編集はそのブロックをモデルから外し、次の `update` まで展開する。後ろのブロックは平行移動する。現在の表示の
    /// ブロック範囲と保留中の作り直し範囲は編集レンジと合併して追従する。
    func noteEdit(editedRange: NSRange, changeInLength delta: Int) {
        let preEdit = NSRange(location: editedRange.location, length: max(0, editedRange.length - delta))
        documentLength = max(0, documentLength + delta)
        pendingDirtyRanges = pendingDirtyRanges.map { Self.shiftMerging($0, editedRange: editedRange, preEdit: preEdit, delta: delta) }
        exemptRanges = exemptRanges.map { Self.shiftMerging($0, editedRange: editedRange, preEdit: preEdit, delta: delta) }
        presented = presented.compactMap { item -> PresentedBlock? in
            var moved = item
            let merged = Self.shiftMerging(item.blockParagraphsRange, editedRange: editedRange, preEdit: preEdit, delta: delta)
            let start = item.blockParagraphsRange.location
            if preEdit.location <= start, NSMaxRange(preEdit) >= start {
                // 編集が先頭の段落の先頭に触れる(先頭への挿入、直前の改行の削除、先頭の削除・置換): 先頭の段落がどこから
                // 始まるか分からなくなる(挿入した文字はこの段落に入り、改行を消せば前の段落と繋がる)ので、`canPresent` に
                // 関わらず表示から外す(古い先頭位置のままだと、本当の先頭の段落まで列挙から外れてブロックが丸ごと
                // 消える)。旧ブロック(編集と合併した範囲)は作り直す。
                let dirtyStart = min(start, editedRange.location)
                appendDirty(NSRange(location: dirtyStart, length: max(NSMaxRange(editedRange), NSMaxRange(item.blockParagraphsRange) + delta) - dirtyStart))
                return nil
            } else if start >= NSMaxRange(preEdit) {
                // 編集より前(触れない): そのまま平行移動
                moved.block = item.block.shifted(by: delta)
            }
            // 編集が先頭より後ろでブロックに触る: 先頭の段落の先頭は変わらないので位置は保ち、
            // 作り直す範囲だけ編集と合併して追従させる(モデルからは外れるので次の `present` で解除される)
            moved.blockParagraphsRange = merged
            return moved
        }
        let before = entries.count
        entries = entries.compactMap { entry in
            // 触る編集の判定はブロックの規則(`isTouched`: 行頭から内容の末尾まで。`HighlightPlan.shifted` と同じ)
            if entry.block.isTouched(byEditBefore: preEdit) { return nil }
            guard entry.blockParagraphsRange.location >= NSMaxRange(preEdit) else { return entry }
            var moved = entry
            moved.source = entry.source.shifted(by: delta)
            moved.blockParagraphsRange = NSRange(location: entry.blockParagraphsRange.location + delta, length: entry.blockParagraphsRange.length)
            return moved
        }
        if entries.count != before { present() }
    }

    private static func shiftMerging(_ range: NSRange, editedRange: NSRange, preEdit: NSRange, delta: Int) -> NSRange {
        if NSMaxRange(range) <= preEdit.location { return range }
        if range.location >= NSMaxRange(preEdit) {
            return NSRange(location: range.location + delta, length: range.length)
        }
        let start = min(range.location, editedRange.location)
        let end = max(NSMaxRange(editedRange), NSMaxRange(range) + delta)
        return NSRange(location: start, length: max(0, end - start))
    }

    // MARK: - 望む表示

    /// 選択範囲がブロック(内容の末尾まで)に触れているか。キャレットは先頭から末尾まで(両端を含む)、
    /// 選択範囲は交差(ブロックの直前で終わる選択は触れない)。文書がブロックの改行で終わるとき、その後ろ
    /// (文末の空行)のキャレットは最後の段落のフラグメントに描かれるので、触れているものとして扱う。
    func selectionTouches(_ block: Block, blockParagraphsRange: NSRange) -> Bool {
        // 先頭はブロックの段落の行頭(インデント型コードブロックの先頭のインデントの中も含む: そこは隠れる段落なので、
        // 触れていないと扱うとキャレットが隠れた行に居座る)
        let start = blockParagraphsRange.location
        let contentEnd = NSMaxRange(block.range)
        let trailingEmptyLine = NSMaxRange(blockParagraphsRange) > contentEnd && NSMaxRange(blockParagraphsRange) == documentLength
            ? documentLength : nil
        return selectedRanges.contains { selection in
            guard selection.location != NSNotFound else { return false }
            if selection.length == 0 {
                return (selection.location >= start && selection.location <= contentEnd) || selection.location == trailingEmptyLine
            }
            return selection.location <= contentEnd && NSMaxRange(selection) > start
        }
    }

    private func desiredPresentation() -> [PresentedBlock] {
        guard isEnabled else { return [] }
        var result: [PresentedBlock] = []
        for index in entries.indices {
            let entry = entries[index]
            guard !(isEditorFocused && selectionTouches(entry.block, blockParagraphsRange: entry.blockParagraphsRange)),
                  let layout = cachedLayout(at: index) else { continue }
            result.append(PresentedBlock(block: entry.block, blockParagraphsRange: entry.blockParagraphsRange, layout: layout))
        }
        return result
    }

    /// レイアウト(幅・見た目が同じなら使い回す。内容が無ければ材料が作る)。ストレージが無い、またはブロックが
    /// ストレージの外を指していれば nil(そのブロックは折りたたまない)。
    private func cachedLayout(at index: Int) -> Layout? {
        let entry = entries[index]
        if let layout = entry.layout, entry.layoutWidth == containerWidth, entry.layoutAppearance == appearance {
            return layout
        }
        guard let storage,
              let layout = entries[index].source.makeLayout(width: containerWidth, appearance: appearance, storage: storage, theme: theme)
        else { return nil }
        entries[index].layout = layout
        entries[index].layoutWidth = containerWidth
        entries[index].layoutAppearance = appearance
        return layout
    }

    /// 望む表示と現在の表示がずれているか(`canPresent` が false で移せていない)。
    var hasPendingPresentation: Bool { desiredPresentation() != presented }

    /// 望む表示を TextKit に見せる表示へ移す(`canPresent()` が true のとき)。変わった分の作り直し範囲を溜める。
    @discardableResult
    func present() -> Bool {
        let desired = desiredPresentation()
        guard desired != presented, canPresent() else { return false }
        let old = presented
        presented = desired
        var matchedOld = Set<Int>()
        for item in desired {
            if let index = old.firstIndex(where: { $0.blockParagraphsRange.location == item.blockParagraphsRange.location }) {
                matchedOld.insert(index)
                let previous = old[index]
                if previous.blockParagraphsRange != item.blockParagraphsRange
                    || previous.block.range != item.block.range
                    || previous.layout.reservedHeight != item.layout.reservedHeight {
                    appendDirty(previous.blockParagraphsRange)
                    appendDirty(item.blockParagraphsRange)
                } else if previous.layout != item.layout {
                    needsRedraw = true
                }
            } else {
                appendDirty(item.blockParagraphsRange)
            }
        }
        for (index, previous) in old.enumerated() where !matchedOld.contains(index) {
            appendDirty(previous.blockParagraphsRange)
        }
        refreshExemptRanges()
        return true
    }

    private func appendDirty(_ range: NSRange) {
        guard range.length > 0, !pendingDirtyRanges.contains(range) else { return }
        pendingDirtyRanges.append(range)
    }

    var hasPendingDirtyRanges: Bool { !pendingDirtyRanges.isEmpty }

    func takePendingDirtyRanges() -> [NSRange] {
        defer { pendingDirtyRanges = [] }
        return pendingDirtyRanges
    }

    /// 描き直しだけが要る(高さは変わらないがレイアウトが変わった)か。
    func takeNeedsRedraw() -> Bool {
        defer { needsRedraw = false }
        return needsRedraw
    }

    /// 描き直しを求める(コピーの通知など、レイアウトの外の見た目が変わったとき)。
    func setNeedsRedraw() {
        needsRedraw = true
    }

    // MARK: - TextKit への供給(現在の表示に従う)

    /// `offset` から始まる段落を含む、折りたたまれたブロック(先頭の段落も含む)。
    private func presentedBlock(containingParagraphAt offset: Int) -> PresentedBlock? {
        // 位置順なので、先頭が offset 以下の最後のブロックだけが候補
        var low = 0
        var high = presented.count
        while low < high {
            let mid = (low + high) / 2
            if presented[mid].blockParagraphsRange.location <= offset { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let candidate = presented[low - 1]
        return offset < NSMaxRange(candidate.blockParagraphsRange) ? candidate : nil
    }

    /// 折りたたみ中、先頭の段落以外のブロックの段落は列挙から外す(= レイアウトされず見えない)。
    func shouldEnumerate(paragraphStartingAt offset: Int) -> Bool {
        guard let item = presentedBlock(containingParagraphAt: offset) else { return true }
        return offset == item.blockParagraphsRange.location
    }

    /// 折りたたみ中の先頭の段落に予約する描画の高さ。該当しなければ nil。
    func reservedHeight(forParagraph paragraph: NSRange) -> CGFloat? {
        guard let item = presentedBlock(containingParagraphAt: paragraph.location),
              paragraph.location == item.blockParagraphsRange.location else { return nil }
        return item.layout.reservedHeight
    }

    /// 折りたたみ中の先頭の段落の表示用段落: 全文字を極小フォントで隠し(行の高さもほぼ 0)、
    /// 段落の後ろに描画の高さを予約する。それ以外の段落は nil(他の仕組みに任せる)。
    func textParagraph(with range: NSRange, in contentStorage: NSTextContentStorage) -> NSTextParagraph? {
        guard let height = reservedHeight(forParagraph: range), range.length > 0,
              let storage = contentStorage.textStorage, NSMaxRange(range) <= storage.length else { return nil }
        let text = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        let full = NSRange(location: 0, length: text.length)
        text.addAttribute(.font, value: LivePreviewConcealer.hiddenFont, range: full)
        let style = (text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.paragraphSpacing = height
        style.paragraphSpacingBefore = 0
        style.lineSpacing = 0
        style.maximumLineHeight = LivePreviewConcealer.hiddenFontSize
        text.addAttribute(.paragraphStyle, value: style, range: full)
        return NSTextParagraph(attributedString: text)
    }

    /// `location` から始まる折りたたまれたブロックの表示(ビューポートレイアウトパスが描画を置くために使う)。
    func presentedBlock(at location: Int) -> PresentedBlock? {
        presented.first { $0.block.range.location == location }
    }
}
