import Foundation

/// GFM のテーブル 1 つ(ヘッダー行 + 区切り行 + ボディ行)の構造。UI 層が Live Preview の表として描くために使う
/// (Laperm ADR 0019)。レンジはすべて原文の UTF-16 オフセット。
public struct MarkdownTable: Hashable, Sendable {
    /// 区切り行のコロンで決まる列の揃え(`---` は無指定、`:--` 左、`:-:` 中央、`--:` 右)。
    public enum Alignment: Hashable, Sendable {
        case none
        case left
        case center
        case right
    }

    /// セル 1 つ。内容は両端の空白を除いた部分(空セルは長さ 0)。
    public struct Cell: Hashable, Sendable {
        public var range: NSRange

        public init(range: NSRange) {
            self.range = range
        }
    }

    /// ヘッダー行またはボディの 1 行。セルは列数に合わせてある(足りない分は行末の空セル、余った分は捨てる。
    /// GFM の規則)。
    public struct Row: Hashable, Sendable {
        /// 行(改行を含まない)
        public var lineRange: NSRange
        public var cells: [Cell]

        public init(lineRange: NSRange, cells: [Cell]) {
            self.lineRange = lineRange
            self.cells = cells
        }
    }

    /// ヘッダー行の行頭から最後の行の行末(改行を含まない)まで。`HighlightSpan` の `.table` と同じ。
    public var range: NSRange
    /// 列ごとの揃え。列数 = `alignments.count`(区切り行のセル数)。
    public var alignments: [Alignment]
    public var header: Row
    /// 区切り行(改行を含まない)
    public var delimiterLineRange: NSRange
    /// ボディの行(無ければ空)
    public var rows: [Row]

    public init(range: NSRange, alignments: [Alignment], header: Row, delimiterLineRange: NSRange, rows: [Row]) {
        self.range = range
        self.alignments = alignments
        self.header = header
        self.delimiterLineRange = delimiterLineRange
        self.rows = rows
    }

    public var columnCount: Int { alignments.count }

    /// すべてのレンジを `delta` だけ平行移動したもの。
    public func shifted(by delta: Int) -> MarkdownTable {
        func move(_ range: NSRange) -> NSRange { NSRange(location: range.location + delta, length: range.length) }
        func move(_ row: Row) -> Row {
            Row(lineRange: move(row.lineRange), cells: row.cells.map { Cell(range: move($0.range)) })
        }
        return MarkdownTable(
            range: move(range), alignments: alignments, header: move(header),
            delimiterLineRange: move(delimiterLineRange), rows: rows.map(move))
    }

    /// テーブルの先頭を 0 にしたもの(内容の比較用: 前の編集で位置だけ動いたテーブルを同じと見なす)。
    public var relativeToStart: MarkdownTable { shifted(by: -range.location) }
}

/// テーブルの行をセルに分ける(GFM の規則)。swift-markdown の Table ノードは cmark-gfm の位置情報が
/// セル単位で信用できないため(段落直後のテーブルで壊れる: `HighlightMapper.visitTable` 参照)、
/// `HighlightMapper` が求めたテーブルのレンジの中を自前で走査する。
public enum MarkdownTableParser {
    /// `range`(ヘッダー行の行頭から最後の行の行末まで)をテーブルとして読む。2 行目が区切り行でなければ nil。
    public static func parse(range: NSRange, in text: NSString) -> MarkdownTable? {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return nil }
        var lines: [NSRange] = []
        var location = range.location
        let end = NSMaxRange(range)
        while location < end {
            let line = clippedLineRange(at: location, within: range, in: text)
            lines.append(line)
            let fullLine = text.lineRange(for: NSRange(location: location, length: 0))
            guard NSMaxRange(fullLine) > location else { break }
            location = NSMaxRange(fullLine)
        }
        guard lines.count >= 2, let alignments = delimiterAlignments(line: lines[1], in: text) else { return nil }
        let columns = alignments.count
        func row(_ line: NSRange) -> MarkdownTable.Row {
            var cells = splitCells(line: line, in: text).map { MarkdownTable.Cell(range: $0) }
            if cells.count > columns {
                cells.removeLast(cells.count - columns)
            }
            while cells.count < columns {
                cells.append(MarkdownTable.Cell(range: NSRange(location: NSMaxRange(line), length: 0)))
            }
            return MarkdownTable.Row(lineRange: line, cells: cells)
        }
        return MarkdownTable(
            range: range, alignments: alignments, header: row(lines[0]),
            delimiterLineRange: lines[1], rows: lines.dropFirst(2).map(row))
    }

    /// GFM の区切り行なら列ごとの揃え、そうでなければ nil。パイプで分けた各セルが `:?-+:?`(空白は許容)で、
    /// 行頭 / 行末のパイプの外側だけ空でよい。
    public static func delimiterAlignments(line: NSRange, in text: NSString) -> [MarkdownTable.Alignment]? {
        let pieces = splitCells(line: line, in: text, trimming: false)
        guard !pieces.isEmpty else { return nil }
        var alignments: [MarkdownTable.Alignment] = []
        for piece in pieces {
            var i = piece.location
            var end = NSMaxRange(piece)
            while i < end, isSpaceOrTab(text.character(at: i)) { i += 1 }
            while end > i, isSpaceOrTab(text.character(at: end - 1)) { end -= 1 }
            guard i < end else { return nil }
            let leadingColon = text.character(at: i) == ASCII.colon
            let trailingColon = text.character(at: end - 1) == ASCII.colon
            if leadingColon { i += 1 }
            if trailingColon, end > i { end -= 1 }
            guard i < end else { return nil }
            for k in i..<end where text.character(at: k) != ASCII.dash { return nil }
            switch (leadingColon, trailingColon) {
            case (true, true): alignments.append(.center)
            case (true, false): alignments.append(.left)
            case (false, true): alignments.append(.right)
            case (false, false): alignments.append(.none)
            }
        }
        return alignments
    }

    /// 行をエスケープされていない `|` で分け、行頭 / 行末のパイプ(とその外側の空白)を除いたセルのレンジ。
    /// `trimming` なら各セルの両端の空白も除く(空セルは長さ 0 で、その位置はセルの空白の中)。
    static func splitCells(line: NSRange, in text: NSString, trimming: Bool = true) -> [NSRange] {
        var start = line.location
        var end = NSMaxRange(line)
        while start < end, isSpaceOrTab(text.character(at: start)) { start += 1 }
        while end > start, isSpaceOrTab(text.character(at: end - 1)) { end -= 1 }
        guard start < end else { return [] }
        if text.character(at: start) == ASCII.pipe { start += 1 }
        if end > start, text.character(at: end - 1) == ASCII.pipe, !isEscaped(at: end - 1, from: start, in: text) {
            end -= 1
        }
        var cells: [NSRange] = []
        var cellStart = start
        var i = start
        while i <= end {
            if i == end || (text.character(at: i) == ASCII.pipe && !isEscaped(at: i, from: start, in: text)) {
                var cell = NSRange(location: cellStart, length: i - cellStart)
                if trimming { cell = trimmed(cell, in: text) }
                cells.append(cell)
                cellStart = i + 1
            }
            i += 1
        }
        return cells
    }

    /// `index` の `|` が直前のバックスラッシュでエスケープされているか(バックスラッシュ自体は数えない)。
    private static func isEscaped(at index: Int, from start: Int, in text: NSString) -> Bool {
        index > start && text.character(at: index - 1) == ASCII.backslash
    }

    private static func trimmed(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, isSpaceOrTab(text.character(at: start)) { start += 1 }
        while end > start, isSpaceOrTab(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func isSpaceOrTab(_ c: unichar) -> Bool {
        c == ASCII.space || c == ASCII.tab
    }

    /// location を含む行のレンジを range 内にクリップし、末尾の改行を除いて返す。
    private static func clippedLineRange(at location: Int, within range: NSRange, in text: NSString) -> NSRange {
        var lineStart = 0
        var contentsEnd = 0
        text.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        return NSIntersectionRange(NSRange(location: lineStart, length: contentsEnd - lineStart), range)
    }
}
