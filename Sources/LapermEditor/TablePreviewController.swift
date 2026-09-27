#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import LapermCore

/// Live Preview でテーブルを格子の表に折りたたむ(Laperm ADR 0019)。折りたたみの状態機械は `BlockPreviewController`、
/// ここはテーブル固有の部分: 折りたたみ候補(行頭から始まるテーブル。リスト項目や引用の中のものは段落の先頭が
/// テーブルの先頭ではないのでヘッダー行の段落を隠せない)、セルの内容(`TablePreviewModel`)とレイアウト
/// (`TablePreviewLayout`)、表のクリック先。
typealias TablePreviewController = BlockPreviewController<TablePreviewSource>

/// テーブル 1 つの材料: パース結果 + セルの内容の材料(交差するスパンと隠すマーカー)+ セルの内容のキャッシュ。
/// セルの内容(`model`)は折りたたむときに初めて作る: キャレットが中にある(展開中の)巨大なテーブルで、1 文字打つ
/// たびに全セルを作り直さない。
struct TablePreviewSource: BlockPreviewSource {
    /// セルの内容が同じかを、位置に依らず判定する鍵(前の編集で位置だけ動いたテーブルのモデルを使い回す)。テーブルの
    /// 外の変化でセルの見た目が変わるもの(参照リンクの定義の増減でリンクになる / ならなくなる)はスパンとマーカーで拾う。
    struct Key: Hashable {
        var text: String
        var relativeTable: MarkdownTable
        var relativeSpans: [HighlightSpan]
        var relativeMarkers: [NSRange]
        /// Unresolved と解決された Wiki Link(テーブル相対)。解決結果が変わればモデルを作り直す。
        var relativeUnresolved: [NSRange]
        var themeGeneration: Int
    }

    var block: MarkdownTable
    var key: Key
    /// テーブルと交差するスパン(Syntax Marker を除く)と隠すマーカー(文書座標)。セルの内容の材料。
    var spans: [HighlightSpan]
    var markers: [NSRange]
    /// Unresolved な Wiki Link のレンジ(文書座標、テーブルと交差するもの)
    var unresolvedWikiLinks: [NSRange] = []
    var model: TablePreviewModel?

    var isModelBuilt: Bool { model != nil }

    func shifted(by delta: Int) -> TablePreviewSource {
        var moved = self
        moved.block = block.shifted(by: delta)
        moved.spans = spans.map { HighlightSpan(range: NSRange(location: $0.range.location + delta, length: $0.range.length), kind: $0.kind) }
        moved.markers = markers.map { NSRange(location: $0.location + delta, length: $0.length) }
        moved.unresolvedWikiLinks = unresolvedWikiLinks.map { NSRange(location: $0.location + delta, length: $0.length) }
        return moved
    }

    mutating func adoptCache(from previous: TablePreviewSource) {
        model = previous.model
    }

    @MainActor
    mutating func makeLayout(
        width: CGFloat, appearance: TablePreviewLayout.Appearance, storage: NSTextStorage, theme: MarkdownTheme
    ) -> TablePreviewLayout? {
        if model == nil {
            model = TablePreviewModel.make(table: block, storage: storage, spans: spans, markers: markers, unresolvedWikiLinks: unresolvedWikiLinks, theme: theme)
        }
        guard let model else { return nil }
        return TablePreviewLayout.make(model: model, maxWidth: width, appearance: appearance)
    }
}

extension TablePreviewLayout: BlockPreviewLayout {}
extension TablePreviewLayout.Appearance: BlockPreviewAppearance {}

extension BlockPreviewController where Source == TablePreviewSource {
    typealias PresentedTable = PresentedBlock

    /// モデルにあるテーブル(折りたたみ候補。テスト用)。
    var tables: [MarkdownTable] { blocks }

    func isCollapsed(tableAt location: Int) -> Bool { isCollapsed(blockAt: location) }

    /// テスト用: そのテーブルのセルの内容が作られているか。
    func isModelBuilt(forTableAt location: Int) -> Bool { isModelBuilt(forBlockAt: location) }

    /// パース確定後の同期。`storage` はハイライト適用済みのテキストストレージ、`text` はその文字列。
    func update(plan: HighlightPlan, storage: NSTextStorage, text: NSString, unresolvedWikiLinkRanges: [NSRange] = []) {
        let tables = plan.tables.filter { table in
            table.range.length > 0 && NSMaxRange(table.range) <= text.length
                && text.lineRange(for: NSRange(location: table.range.location, length: 0)).location == table.range.location
        }
        let (spansByTable, markersByTable) = Self.bucket(plan: plan, tables: tables)
        let sources = tables.enumerated().map { index, table -> TablePreviewSource in
            let origin = table.range.location
            let unresolved = unresolvedWikiLinkRanges.filter { NSIntersectionRange($0, table.range).length > 0 }
            let key = TablePreviewSource.Key(
                text: text.substring(with: table.range), relativeTable: table.relativeToStart,
                relativeSpans: spansByTable[index].map { HighlightSpan(range: NSRange(location: $0.range.location - origin, length: $0.range.length), kind: $0.kind) },
                relativeMarkers: markersByTable[index].map { NSRange(location: $0.location - origin, length: $0.length) },
                relativeUnresolved: unresolved.map { NSRange(location: $0.location - origin, length: $0.length) },
                themeGeneration: themeGeneration)
            return TablePreviewSource(
                block: table, key: key, spans: spansByTable[index], markers: markersByTable[index], unresolvedWikiLinks: unresolved, model: nil)
        }
        update(sources: sources, storage: storage, text: text)
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

    /// `location` から始まる折りたたまれたテーブルの表示(ビューポートレイアウトパスが表を置くために使う)。
    func presentedTable(at location: Int) -> PresentedTable? { presentedBlock(at: location) }

    /// `location` から始まる折りたたまれたテーブルの表座標の点に対応するキャレット位置(文書座標: セルの内容の
    /// 末尾)。表の外、またはそのテーブルに触る編集の後(次のパース待ち)なら nil。
    func caretLocation(inTableAt location: Int, tablePoint point: CGPoint) -> Int? {
        guard let table = presentedBlock(at: location), hasBlock(at: location),
              let cell = table.layout.cell(at: point) else { return nil }
        return table.block.range.location + cell.caretOffset
    }
}

extension BlockPreviewController.PresentedBlock where Source == TablePreviewSource {
    var table: MarkdownTable { block }
}
