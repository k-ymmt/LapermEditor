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

    /// モデルのテーブル 1 つ(パース結果 + セルの内容 + レイアウトのキャッシュ)。
    private struct Entry {
        var table: MarkdownTable
        var blockParagraphsRange: NSRange
        var key: ModelKey
        var model: TablePreviewModel
        var layout: TablePreviewLayout?
        var layoutWidth: CGFloat = 0
        var layoutAppearance: TablePreviewLayout.Appearance?
    }

    /// セルの内容が同じかを、位置に依らず判定する鍵(前の編集で位置だけ動いたテーブルのモデルを使い回す)。
    private struct ModelKey: Equatable {
        var text: String
        var relativeTable: MarkdownTable
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

    /// パース確定後の同期。`storage` はハイライト適用済みのテキストストレージ、`text` はその文字列。
    func update(plan: HighlightPlan, storage: NSAttributedString, text: NSString) {
        let old = entries
        documentLength = text.length
        entries = plan.tables.compactMap { table -> Entry? in
            guard table.range.length > 0, NSMaxRange(table.range) <= text.length,
                  text.lineRange(for: NSRange(location: table.range.location, length: 0)).location == table.range.location
            else { return nil }
            let key = ModelKey(
                text: text.substring(with: table.range), relativeTable: table.relativeToStart, themeGeneration: themeGeneration)
            let block = NSRange(location: table.range.location, length: Self.endIncludingNewline(of: table.range, in: text) - table.range.location)
            if let previous = old.first(where: { $0.key == key }) {
                var reused = previous
                reused.table = table
                reused.blockParagraphsRange = block
                return reused
            }
            guard let model = TablePreviewModel.make(table: table, storage: storage, plan: plan, theme: theme) else { return nil }
            return Entry(table: table, blockParagraphsRange: block, key: key, model: model)
        }
        present()
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
        presented = presented.map { table in
            var moved = table
            // 編集より後ろの表示はそのまま平行移動する。編集と交差する表示は(モデルからは外れるので)次の
            // `present` で作り直されるまでの間、位置だけ古いままにし、作り直す範囲は編集と合併して追従させる。
            if table.table.range.location >= NSMaxRange(preEdit) { moved.table = table.table.shifted(by: delta) }
            moved.blockParagraphsRange = Self.shiftMerging(table.blockParagraphsRange, editedRange: editedRange, preEdit: preEdit, delta: delta)
            return moved
        }
        let before = entries.count
        entries = entries.compactMap { entry in
            let touches = preEdit.location <= NSMaxRange(entry.table.range) && NSMaxRange(preEdit) >= entry.table.range.location
            if touches { return nil }
            guard entry.table.range.location >= NSMaxRange(preEdit) else { return entry }
            var moved = entry
            moved.table = entry.table.shifted(by: delta)
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
            guard !(isEditorFocused && selectionTouches(entry.table, blockParagraphsRange: entry.blockParagraphsRange)) else { continue }
            result.append(PresentedTable(table: entry.table, blockParagraphsRange: entry.blockParagraphsRange, layout: cachedLayout(at: index)))
        }
        return result
    }

    private func cachedLayout(at index: Int) -> TablePreviewLayout {
        let entry = entries[index]
        if let layout = entry.layout, entry.layoutWidth == containerWidth, entry.layoutAppearance == appearance {
            return layout
        }
        let layout = TablePreviewLayout.make(model: entry.model, maxWidth: containerWidth, appearance: appearance)
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
        return cell.caretLocation
    }
}
