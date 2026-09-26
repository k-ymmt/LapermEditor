#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import LapermCore

/// Live Preview でテーブルを格子の表に折りたたむ状態機械(Laperm ADR 0019)。`FrontMatterController` と同じ
/// 仕組みを、文書のどこにでも複数あるブロックへ広げたもの。
///
/// 折りたたみ中は、ヘッダー行の段落だけを残して(文字は極小フォントで幅ゼロ・高さほぼゼロにし、段落の後ろに
/// 表の高さを予約する)、区切り行とボディの段落を列挙から外す(セクション折りたたみと同じ仕組み。テキスト
/// ストレージには触らない)。表はオーバーレイが予約領域に描く。
///
/// フォーカスの単位はブロック: エディタが first responder で、選択範囲(キャレット)がそのテーブル(最後の行の
/// 行末まで)に触れている間は展開され、Source と同じ見た目で編集できる。他のテーブルは折りたたまれたまま。
/// 行頭から始まらないテーブル(リスト項目や引用の中)は折りたたまない(段落の先頭がテーブルの先頭ではないので、
/// ヘッダー行の段落を隠せない)。
///
/// 入力(有効 / 無効、テーブル、選択、フォーカス、幅、テーマ)から「望む表示」を計算し、TextKit に見せる
/// 「現在の表示」(`presented`)へは `canPresent()` が true のときだけ移す(IME 変換中は見送る)。テーブルに触る
/// 編集はそのテーブルをモデルから外し(次のパースまで展開)、表のクリックも受け付けない。
@MainActor
final class TablePreviewController {
    /// TextKit に見せている表示のテーブル 1 つ。
    struct PresentedTable: Equatable {
        var table: MarkdownTable
        /// ブロックの段落全体(最後の行の改行まで)。切替時に作り直す範囲。編集で追従させる。
        var blockParagraphsRange: NSRange
        var layout: TablePreviewLayout
    }

    /// モデルのテーブル 1 つ(パース結果 + セルの内容 + レイアウトのキャッシュ)。セルの内容(`model`)は折りたたむ
    /// ときに初めて作る: キャレットが中にある(展開中の)巨大なテーブルで、1 文字打つたびに全セルを作り直さない。
    private struct Entry {
        var table: MarkdownTable
        var blockParagraphsRange: NSRange
        var key: ModelKey
        /// テーブルと交差するスパン(Syntax Marker を除く)と隠すマーカー(文書座標)。セルの内容の材料。
        var spans: [HighlightSpan]
        var markers: [NSRange]
        var model: TablePreviewModel?
        var layout: TablePreviewLayout?
        var layoutWidth: CGFloat = 0
        var layoutAppearance: TablePreviewLayout.Appearance?
    }

    /// セルの内容が同じかを、位置に依らず判定する鍵(前の編集で位置だけ動いたテーブルのモデルを使い回す)。テーブルの
    /// 外の変化でセルの見た目が変わるもの(参照リンクの定義の増減でリンクになる / ならなくなる)はスパンとマーカーで拾う。
    private struct ModelKey: Equatable {
        var text: String
        var relativeTable: MarkdownTable
        var relativeSpans: [HighlightSpan]
        var relativeMarkers: [NSRange]
        var themeGeneration: Int
    }

    // MARK: 入力

    private(set) var isEnabled = false
    private var entries: [Entry] = []
    /// 直近の `update` 時の文書の長さ(文末の空行がブロックの段落に属するかの判定に使う)。編集で追従させる。
    private(set) var documentLength = 0
    private(set) var isEditorFocused = true
    private(set) var selectedRanges: [NSRange] = []
    private(set) var containerWidth: CGFloat = 0
    private(set) var appearance: TablePreviewLayout.Appearance
    private var theme: MarkdownTheme
    private var themeGeneration = 0
    /// 直近の `update` のテキストストレージ(セルの内容を遅延して作るために持つ)。エンジン(テキストビュー)が
    /// 持ち主なので弱参照。
    private weak var storage: NSTextStorage?
    /// 展開中(モデルにあるが折りたたまれていない)のテーブルのブロック。行単位の Syntax Marker 隠しから除外し、
    /// ブロック全体を Source と同じ見た目にする(ADR 0019: フォーカスの単位はブロック)。編集で追従させる。
    private(set) var exemptRanges: [NSRange] = []
    /// 今 TextKit の表示を変えてよいか(IME 変換中は false)。既定は常に true。
    var canPresent: () -> Bool = { true }

    // MARK: 表示

    /// 位置順。
    private(set) var presented: [PresentedTable] = []
    private var pendingDirtyRanges: [NSRange] = []
    private var needsRedraw = false

    init(theme: MarkdownTheme) {
        self.theme = theme
        appearance = .init(theme: theme)
    }

    /// モデルにあるテーブル(折りたたみ候補。テスト用)。
    var tables: [MarkdownTable] { entries.map(\.table) }

    /// 折りたたまれているテーブルのブロックの先頭位置(昇順)。
    var collapsedLocations: [Int] { presented.map(\.table.range.location) }

    func isCollapsed(tableAt location: Int) -> Bool {
        presented.contains { $0.table.range.location == location }
    }

    // MARK: - 入力の更新

    /// テスト用: そのテーブルのセルの内容が作られているか。
    func isModelBuilt(forTableAt location: Int) -> Bool {
        entries.first { $0.table.range.location == location }?.model != nil
    }

    /// パース確定後の同期。`storage` はハイライト適用済みのテキストストレージ、`text` はその文字列。
    func update(plan: HighlightPlan, storage: NSTextStorage, text: NSString) {
        let old = entries
        self.storage = storage
        documentLength = text.length
        let tables = plan.tables.filter { table in
            table.range.length > 0 && NSMaxRange(table.range) <= text.length
                && text.lineRange(for: NSRange(location: table.range.location, length: 0)).location == table.range.location
        }
        let (spansByTable, markersByTable) = Self.bucket(plan: plan, tables: tables)
        entries = tables.enumerated().map { index, table -> Entry in
            let origin = table.range.location
            let key = ModelKey(
                text: text.substring(with: table.range), relativeTable: table.relativeToStart,
                relativeSpans: spansByTable[index].map { HighlightSpan(range: NSRange(location: $0.range.location - origin, length: $0.range.length), kind: $0.kind) },
                relativeMarkers: markersByTable[index].map { NSRange(location: $0.location - origin, length: $0.length) },
                themeGeneration: themeGeneration)
            let block = NSRange(location: origin, length: Self.endIncludingNewline(of: table.range, in: text) - origin)
            if let previous = old.first(where: { $0.key == key }) {
                var reused = previous
                reused.table = table
                reused.blockParagraphsRange = block
                reused.spans = spansByTable[index]
                reused.markers = markersByTable[index]
                return reused
            }
            return Entry(table: table, blockParagraphsRange: block, key: key, spans: spansByTable[index], markers: markersByTable[index], model: nil)
        }
        present()
        refreshExemptRanges()
    }

    /// 計画のスパン(Syntax Marker を除く)と隠すマーカーを、交差するテーブルごとに分ける。テーブルは位置順で互いに
    /// 重ならないので、開始位置の二分探索で 1 回の走査に収める(テーブル数 × スパン数にしない)。
    private static func bucket(plan: HighlightPlan, tables: [MarkdownTable]) -> ([[HighlightSpan]], [[NSRange]]) {
        var spans = [[HighlightSpan]](repeating: [], count: tables.count)
        var markers = [[NSRange]](repeating: [], count: tables.count)
        guard !tables.isEmpty else { return (spans, markers) }
        func tableIndex(containing range: NSRange) -> Int? {
            var low = 0
            var high = tables.count
            while low < high {
                let mid = (low + high) / 2
                if tables[mid].range.location <= range.location { low = mid + 1 } else { high = mid }
            }
            // 開始位置が range.location 以下の最後のテーブルか、range の中で始まる次のテーブル(ブロックスパンなど)
            for candidate in [low - 1, low] where candidate >= 0 && candidate < tables.count
                && NSIntersectionRange(tables[candidate].range, range).length > 0 {
                return candidate
            }
            return nil
        }
        for span in plan.spans where span.kind != .syntaxMarker {
            if let index = tableIndex(containing: span.range) { spans[index].append(span) }
        }
        for marker in plan.concealableMarkers {
            if let index = tableIndex(containing: marker) { markers[index].append(marker) }
        }
        return (spans, markers)
    }

    /// 展開中のテーブルのブロックを取り直し、変わった分(展開された / 折りたたまれた / 範囲が変わった)を作り直す
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

    /// `paragraph` が展開中のテーブルのブロックにあるか(行単位の Syntax Marker 隠しから除外する)。
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

    /// テーマの変更。セルの文字列(色)は次の `update` で作り直す(エンジンはテーマ変更のあと再同期する)。
    func themeDidChange(_ newTheme: MarkdownTheme) {
        guard newTheme != theme else { return }
        theme = newTheme
        themeGeneration += 1
        let newAppearance = TablePreviewLayout.Appearance(theme: newTheme)
        guard newAppearance != appearance else { return }
        appearance = newAppearance
        present()
    }

    /// 編集(didProcessEditing)からの座標追従。テーブル(ブロックの前後を含む: 直前の改行の削除やヘッダー行への
    /// 挿入も構造を変える)に触る編集はそのテーブルをモデルから外し、次の `update` まで展開する。後ろのテーブルは
    /// 平行移動する。現在の表示のブロック範囲と保留中の作り直し範囲は編集レンジと合併して追従する。
    func noteEdit(editedRange: NSRange, changeInLength delta: Int) {
        let preEdit = NSRange(location: editedRange.location, length: max(0, editedRange.length - delta))
        documentLength = max(0, documentLength + delta)
        pendingDirtyRanges = pendingDirtyRanges.map { Self.shiftMerging($0, editedRange: editedRange, preEdit: preEdit, delta: delta) }
        exemptRanges = exemptRanges.map { Self.shiftMerging($0, editedRange: editedRange, preEdit: preEdit, delta: delta) }
        presented = presented.compactMap { table -> PresentedTable? in
            var moved = table
            let merged = Self.shiftMerging(table.blockParagraphsRange, editedRange: editedRange, preEdit: preEdit, delta: delta)
            if table.table.range.location >= NSMaxRange(preEdit) {
                // 編集より後ろ: そのまま平行移動
                moved.table = table.table.shifted(by: delta)
            } else if preEdit.location <= table.table.range.location, NSMaxRange(preEdit) >= table.table.range.location {
                // 編集がヘッダー行の先頭を含む(先頭の削除・置換): ヘッダー行の段落がどこから始まるか分からなくなるので、
                // `canPresent` に関わらず表示から外す(古い先頭位置のままだと、本当のヘッダー行まで列挙から外れて
                // テーブルが丸ごと消える)。旧ブロックは作り直す。
                appendDirty(merged)
                return nil
            }
            // 編集がヘッダー行の先頭より後ろでブロックに触る: ヘッダー行の段落の先頭は変わらないので位置は保ち、
            // 作り直す範囲だけ編集と合併して追従させる(モデルからは外れるので次の `present` で解除される)
            moved.blockParagraphsRange = merged
            return moved
        }
        let before = entries.count
        entries = entries.compactMap { entry in
            if entry.table.isTouched(byEditBefore: preEdit) { return nil }
            guard entry.table.range.location >= NSMaxRange(preEdit) else { return entry }
            var moved = entry
            moved.table = entry.table.shifted(by: delta)
            moved.blockParagraphsRange = NSRange(location: entry.blockParagraphsRange.location + delta, length: entry.blockParagraphsRange.length)
            moved.spans = entry.spans.map { HighlightSpan(range: NSRange(location: $0.range.location + delta, length: $0.range.length), kind: $0.kind) }
            moved.markers = entry.markers.map { NSRange(location: $0.location + delta, length: $0.length) }
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

    /// 選択範囲がテーブル(最後の行の行末まで)に触れているか。キャレットは先頭から行末まで(両端を含む)、
    /// 選択範囲は交差(テーブルの直前で終わる選択は触れない)。文書がテーブルの改行で終わるとき、その後ろ
    /// (文末の空行)のキャレットは最後の段落のフラグメントに描かれるので、触れているものとして扱う。
    func selectionTouches(_ table: MarkdownTable, blockParagraphsRange: NSRange) -> Bool {
        let start = table.range.location
        let contentEnd = NSMaxRange(table.range)
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

    private func desiredPresentation() -> [PresentedTable] {
        guard isEnabled else { return [] }
        var result: [PresentedTable] = []
        for index in entries.indices {
            let entry = entries[index]
            guard !(isEditorFocused && selectionTouches(entry.table, blockParagraphsRange: entry.blockParagraphsRange)),
                  let layout = cachedLayout(at: index) else { continue }
            result.append(PresentedTable(table: entry.table, blockParagraphsRange: entry.blockParagraphsRange, layout: layout))
        }
        return result
    }

    /// セルの内容(無ければここで作る)とレイアウト(幅・見た目が同じなら使い回す)。ストレージが無い、またはテーブルが
    /// ストレージの外を指していれば nil(そのテーブルは折りたたまない)。
    private func cachedLayout(at index: Int) -> TablePreviewLayout? {
        let entry = entries[index]
        if let layout = entry.layout, entry.layoutWidth == containerWidth, entry.layoutAppearance == appearance {
            return layout
        }
        let model: TablePreviewModel
        if let built = entry.model {
            model = built
        } else {
            guard let storage,
                  let built = TablePreviewModel.make(
                    table: entry.table, storage: storage, spans: entry.spans, markers: entry.markers, theme: theme)
            else { return nil }
            entries[index].model = built
            model = built
        }
        let layout = TablePreviewLayout.make(model: model, maxWidth: containerWidth, appearance: appearance)
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
        for table in desired {
            if let index = old.firstIndex(where: { $0.blockParagraphsRange.location == table.blockParagraphsRange.location }) {
                matchedOld.insert(index)
                let previous = old[index]
                if previous.blockParagraphsRange != table.blockParagraphsRange
                    || previous.table.range != table.table.range
                    || previous.layout.reservedHeight != table.layout.reservedHeight {
                    appendDirty(previous.blockParagraphsRange)
                    appendDirty(table.blockParagraphsRange)
                } else if previous.layout != table.layout {
                    needsRedraw = true
                }
            } else {
                appendDirty(table.blockParagraphsRange)
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

    func takeNeedsRedraw() -> Bool {
        defer { needsRedraw = false }
        return needsRedraw
    }

    // MARK: - TextKit への供給(現在の表示に従う)

    /// `offset` から始まる段落を含む、折りたたまれたテーブル(ヘッダー行の段落も含む)。
    private func presentedTable(containingParagraphAt offset: Int) -> PresentedTable? {
        // 位置順なので、先頭が offset 以下の最後のテーブルだけが候補
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

    /// 折りたたみ中、ヘッダー行の段落以外のブロックの段落は列挙から外す(= レイアウトされず見えない)。
    func shouldEnumerate(paragraphStartingAt offset: Int) -> Bool {
        guard let table = presentedTable(containingParagraphAt: offset) else { return true }
        return offset == table.table.range.location
    }

    /// 折りたたみ中のヘッダー行の段落に予約する表の高さ。該当しなければ nil。
    func reservedHeight(forParagraph paragraph: NSRange) -> CGFloat? {
        guard let table = presentedTable(containingParagraphAt: paragraph.location),
              paragraph.location == table.table.range.location else { return nil }
        return table.layout.reservedHeight
    }

    /// 折りたたみ中のヘッダー行の段落の表示用段落: 全文字を極小フォントで隠し(行の高さもほぼ 0)、
    /// 段落の後ろに表の高さを予約する。それ以外の段落は nil(他の仕組みに任せる)。
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

    /// `location` から始まる折りたたまれたテーブルの表示(ビューポートレイアウトパスが表を置くために使う)。
    func presentedTable(at location: Int) -> PresentedTable? {
        presented.first { $0.table.range.location == location }
    }

    /// `location` から始まる折りたたまれたテーブルの表座標の点に対応するキャレット位置(文書座標: セルの内容の
    /// 末尾)。表の外、またはそのテーブルに触る編集の後(次のパース待ち)なら nil。
    func caretLocation(inTableAt location: Int, tablePoint point: CGPoint) -> Int? {
        guard let table = presentedTable(at: location),
              entries.contains(where: { $0.table.range.location == location }),
              let cell = table.layout.cell(at: point) else { return nil }
        return table.table.range.location + cell.caretOffset
    }
}
