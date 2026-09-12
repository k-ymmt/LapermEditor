import Foundation
import Markdown

/// swift-markdown の SourceLocation(1-based 行、UTF-8 バイト単位 1-based 桁)を
/// UTF-16 ベースの NSRange に変換する。1 文書につき 1 インスタンス生成して使う。
struct SourceLocationConverter {
    private let text: String
    /// 各行の先頭を指す String.Index。cmark と同じく "\n" / "\r\n" / 単独 "\r" を行末とみなす
    private let lineStartIndices: [String.Index]
    /// 行番号(1-based)→ インライン要素の桁に加える補正(UTF-8 バイト)。
    /// cmark はインライン要素の桁を「段落の開始桁 + 段落内容行内のオフセット」で計算する。
    /// 段落の 2 行目以降では内容行がコンテナ接頭辞(`> ` やリストのインデント)と先頭空白を
    /// 除いた位置から始まるため、その位置が段落開始桁と異なる行(遅延継続行・過剰インデント行)
    /// では桁がずれる。ずれは行内で一定なので、cmark のコンテナ照合を再現して行ごとに求める
    /// (applyingInlineColumnDeltas(for:))。
    private var inlineColumnDeltas: [Int: Int] = [:]

    init(text: String) {
        self.text = text
        var starts: [String.Index] = [text.startIndex]
        let utf8 = text.utf8
        var i = utf8.startIndex
        while i < utf8.endIndex {
            let byte = utf8[i]
            let next = utf8.index(after: i)
            if byte == UInt8(ascii: "\n") {
                starts.append(next)
            } else if byte == UInt8(ascii: "\r"),
                      next == utf8.endIndex || utf8[next] != UInt8(ascii: "\n") {
                // 単独の CR も cmark は行末として扱う("\r\n" は "\n" 側で 1 回だけ数える)
                starts.append(next)
            }
            i = next
        }
        self.lineStartIndices = starts
    }

    /// `isInline` が true のとき(インライン要素)だけ継続行の桁補正を適用する。
    /// ブロック要素の桁はブロックパーサーが実際の行から求めるため正しい。
    func nsRange(of sourceRange: SourceRange, isInline: Bool = false) -> NSRange? {
        guard let lower = stringIndex(of: sourceRange.lowerBound, isInline: isInline),
              let upper = stringIndex(of: sourceRange.upperBound, isInline: isInline),
              lower <= upper else { return nil }
        return NSRange(lower..<upper, in: text)
    }

    private func stringIndex(of location: SourceLocation, isInline: Bool) -> String.Index? {
        let lineIndex = location.line - 1
        guard lineIndex >= 0, lineIndex < lineStartIndices.count else { return nil }
        let lineStart = lineStartIndices[lineIndex]
        let utf8 = text.utf8
        let delta = isInline ? (inlineColumnDeltas[location.line] ?? 0) : 0
        let byteOffset = location.column - 1 + delta
        guard byteOffset >= 0,
              let index = utf8.index(lineStart, offsetBy: byteOffset, limitedBy: utf8.endIndex)
        else { return nil }
        // 行内桁が実際には次行へはみ出すケース(不正な column)を拒否する
        if lineIndex + 1 < lineStartIndices.count, index > lineStartIndices[lineIndex + 1] {
            return nil
        }
        return index
    }

    // MARK: - 継続行の桁補正

    /// 段落(および複数行 Setext 見出し)の 2 行目以降について桁補正量を計算して保持した
    /// 新しいコンバータを返す。
    ///
    /// cmark(blocks.c)は各行でまず開いているコンテナの接頭辞を順に照合し、
    /// - すべて一致すれば先頭空白を読み飛ばした位置から(通常の継続行)、
    /// - 途中で一致しなければ最後に一致した接頭辞の直後から(遅延継続行)、
    /// 行の残りを段落内容に追加する。インラインの桁は「段落開始桁 − 1 + 内容行内オフセット」で
    /// 報告されるため、補正量 = (内容の実バイト位置) − (段落開始桁 − 1) と決定的に求まる。
    /// 求めた補正量は、原文と一字一句同じ Text ノード(エスケープ・実体参照・行末空白の
    /// 切り詰めを含まないもの)で検証し、矛盾する行は補正しない(再現の取りこぼしに対する安全網)。
    ///
    /// コストは継続行あたり接頭辞の長さ + 検証する Text ノードの長さに比例し、
    /// 行の長さの二乗にはならない。
    func applyingInlineColumnDeltas(for document: Document) -> SourceLocationConverter {
        var deltas: [Int: Int] = [:]
        var rejected = Set<Int>()
        var containers: [Container] = []

        func visit(_ markup: Markup) {
            switch markup {
            case let node as Markdown.Text:
                validate(node)
                return
            case let node as BlockQuote:
                containers.append(.blockQuote(startLine: node.range?.lowerBound.line ?? 0))
                defer { containers.removeLast() }
                for child in node.children { visit(child) }
                return
            case let node as ListItem:
                containers.append(.listItem(
                    startLine: node.range?.lowerBound.line ?? 0,
                    contentIndent: listItemContentIndent(of: node, outer: containers)))
                defer { containers.removeLast() }
                for child in node.children { visit(child) }
                return
            case is Paragraph, is Heading:
                recordDeltas(forLeaf: markup)
            default:
                break
            }
            for child in markup.children { visit(child) }
        }

        func recordDeltas(forLeaf leaf: Markup) {
            guard let range = leaf.range, range.upperBound.line > range.lowerBound.line else { return }
            let blockOffset = range.lowerBound.column - 1
            for line in (range.lowerBound.line + 1)...range.upperBound.line {
                guard let contentOffset = contentOffset(ofContinuationLine: line, containers: containers),
                      contentOffset - blockOffset != 0
                else { continue }
                deltas[line] = contentOffset - blockOffset
            }
        }

        func validate(_ node: Markdown.Text) {
            guard let range = node.range,
                  range.lowerBound.line == range.upperBound.line,
                  let delta = deltas[range.lowerBound.line],
                  // 原文と同じバイト列を持つノードだけ検証に使う(エスケープ・実体参照・
                  // 行末空白の切り詰めがあるノードは文字列長がソース上の長さと一致しない)
                  range.upperBound.column - range.lowerBound.column == node.string.utf8.count
            else { return }
            let line = range.lowerBound.line
            if !matches(node.string, atByteOffset: range.lowerBound.column - 1 + delta, ofLine: line) {
                rejected.insert(line)
            }
        }

        visit(document)
        for line in rejected { deltas[line] = nil }
        var copy = self
        copy.inlineColumnDeltas = deltas
        return copy
    }

    /// 行(1-based)の byteOffset 位置から needle の UTF-8 列がそのまま並んでいるか(配列確保なし)。
    private func matches(_ needle: String, atByteOffset byteOffset: Int, ofLine line: Int) -> Bool {
        let lineIndex = line - 1
        guard lineIndex >= 0, lineIndex < lineStartIndices.count, byteOffset >= 0 else { return false }
        let utf8 = text.utf8
        let lineEnd = lineIndex + 1 < lineStartIndices.count ? lineStartIndices[lineIndex + 1] : utf8.endIndex
        guard let start = utf8.index(lineStartIndices[lineIndex], offsetBy: byteOffset, limitedBy: lineEnd)
        else { return false }
        return utf8[start..<lineEnd].starts(with: needle.utf8)
    }

    // MARK: cmark のコンテナ接頭辞照合の再現

    /// 段落を囲む開いたコンテナ。
    private enum Container {
        case blockQuote(startLine: Int)
        /// contentIndent = marker_offset + padding(桁)。nil はマーカー行を解釈できず
        /// 再現不能なことを示す(配下の段落は補正しない)。
        case listItem(startLine: Int, contentIndent: Int?)
    }

    /// 継続行 line(1-based)で段落内容が始まる実バイト位置(行頭からのオフセット)。
    /// 再現できない場合は nil。
    private func contentOffset(ofContinuationLine line: Int, containers: [Container]) -> Int? {
        guard var cursor = makeCursor(line: line) else { return nil }
        for container in containers {
            switch matchPrefix(container, line: line, cursor: &cursor) {
            case .matched:
                continue
            case .unmatched:
                // 遅延継続行: 最後に一致した接頭辞の直後から内容が始まる(先頭空白は内容の一部)。
                // 部分消費されたタブは add_line がタブを飛ばして残り桁ぶんの空白を内容に補うため、
                // 内容オフセットとソースのバイト位置がその分ずれる。
                if cursor.partiallyConsumedTab {
                    return cursor.offset + 1 - (LinePrefixCursor.tabStop - cursor.column % LinePrefixCursor.tabStop)
                }
                return cursor.offset
            case .unknown:
                return nil
            }
        }
        // すべて一致: 先頭空白を読み飛ばした位置から内容が始まる
        return cursor.firstNonspace().offset
    }

    private enum PrefixMatch { case matched, unmatched, unknown }

    private func matchPrefix(_ container: Container, line: Int, cursor: inout LinePrefixCursor) -> PrefixMatch {
        switch container {
        case .blockQuote:
            // parse_block_quote_prefix: インデント 3 以下の ">" とその直後の空白 1 桁
            let fns = cursor.firstNonspace()
            let indent = fns.column - cursor.column
            guard indent <= 3, fns.byte == UInt8(ascii: ">") else { return .unmatched }
            cursor.advance(columns: indent + 1)
            if let b = cursor.peek(), b == UInt8(ascii: " ") || b == UInt8(ascii: "\t") {
                cursor.advance(columns: 1)
            }
            return .matched
        case .listItem(let startLine, let contentIndent):
            guard let contentIndent else { return .unknown }
            if startLine == line {
                // マーカー行では open_new_blocks がマーカーとパディングを消費する
                // (= marker_offset + padding 桁を進めるのと等価)
                cursor.advance(columns: contentIndent)
                return .matched
            }
            // parse_node_item_prefix: 内容インデント以上なら、その桁数だけ進める
            let fns = cursor.firstNonspace()
            guard fns.column - cursor.column >= contentIndent else { return .unmatched }
            cursor.advance(columns: contentIndent)
            return .matched
        }
    }

    /// リスト項目の内容インデント(marker_offset + padding、桁)をマーカー行から求める。
    private func listItemContentIndent(of item: ListItem, outer: [Container]) -> Int? {
        guard let range = item.range else { return nil }
        let line = range.lowerBound.line
        guard var cursor = makeCursor(line: line) else { return nil }
        for container in outer {
            guard matchPrefix(container, line: line, cursor: &cursor) == .matched else { return nil }
        }
        let fns = cursor.firstNonspace()
        guard fns.offset == range.lowerBound.column - 1,
              let markerLength = listMarkerLength(from: fns.index)
        else { return nil }
        let markerOffset = fns.column - cursor.column
        // parse_list_marker のパディング計算: マーカー直後の空白を最大 5 桁まで数え、
        // 1〜4 桁ならその桁数、それ以外(5 桁以上・空白なし・行末)は 1 桁をパディングとする
        cursor.advance(bytes: fns.offset + markerLength - cursor.offset)
        let columnAfterMarker = cursor.column
        while cursor.column - columnAfterMarker <= 5,
              let b = cursor.peek(), b == UInt8(ascii: " ") || b == UInt8(ascii: "\t") {
            cursor.advance(columns: 1)
        }
        let spaces = cursor.column - columnAfterMarker
        let padding = (spaces >= 5 || spaces < 1 || LinePrefixCursor.isLineEnd(cursor.peek()))
            ? markerLength + 1 : markerLength + spaces
        return markerOffset + padding
    }

    /// index から始まるリストマーカー("-" / "+" / "*" または 1〜9 桁の数字 + "." / ")")のバイト長
    private func listMarkerLength(from index: String.Index) -> Int? {
        let utf8 = text.utf8
        guard index < utf8.endIndex else { return nil }
        switch utf8[index] {
        case UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: "*"):
            return 1
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            var i = index
            var digits = 0
            while i < utf8.endIndex, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(utf8[i]), digits < 9 {
                digits += 1
                i = utf8.index(after: i)
            }
            guard i < utf8.endIndex, utf8[i] == UInt8(ascii: ".") || utf8[i] == UInt8(ascii: ")") else { return nil }
            return digits + 1
        default:
            return nil
        }
    }

    private func makeCursor(line: Int) -> LinePrefixCursor? {
        let lineIndex = line - 1
        guard lineIndex >= 0, lineIndex < lineStartIndices.count else { return nil }
        let utf8 = text.utf8
        let end = lineIndex + 1 < lineStartIndices.count ? lineStartIndices[lineIndex + 1] : utf8.endIndex
        return LinePrefixCursor(utf8: utf8, lineStart: lineStartIndices[lineIndex], lineEnd: end)
    }
}

/// cmark_parser の offset / column / partially_consumed_tab を 1 行ぶん再現するカーソル。
/// 接頭辞部分(行頭の数バイト)しか触らないため逐次的に進める。
private struct LinePrefixCursor {
    static let tabStop = 4

    private let utf8: String.UTF8View
    private let lineEnd: String.Index
    private(set) var index: String.Index
    /// 行頭からのバイトオフセット(parser->offset)
    private(set) var offset = 0
    /// タブを 4 桁止まりで展開した桁(parser->column)
    private(set) var column = 0
    /// タブを桁単位で途中まで消費した状態(parser->partially_consumed_tab)。index はそのタブを指す
    private(set) var partiallyConsumedTab = false

    init(utf8: String.UTF8View, lineStart: String.Index, lineEnd: String.Index) {
        self.utf8 = utf8
        self.index = lineStart
        self.lineEnd = lineEnd
    }

    static func isLineEnd(_ byte: UInt8?) -> Bool {
        guard let byte else { return true }
        return byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
    }

    func peek() -> UInt8? {
        index < lineEnd ? utf8[index] : nil
    }

    /// S_find_first_nonspace: 現在位置から空白・タブを読み飛ばした位置(状態は変えない)
    func firstNonspace() -> (index: String.Index, offset: Int, column: Int, byte: UInt8?) {
        var i = index, off = offset, col = column
        while i < lineEnd {
            switch utf8[i] {
            case UInt8(ascii: " "): col += 1
            case UInt8(ascii: "\t"): col += Self.tabStop - col % Self.tabStop
            default: return (i, off, col, utf8[i])
            }
            i = utf8.index(after: i)
            off += 1
        }
        return (i, off, col, nil)
    }

    /// S_advance_offset(columns = true): 桁単位で進める。タブは途中まで消費されることがある
    mutating func advance(columns count: Int) {
        var remaining = count
        while remaining > 0, let b = peek() {
            if b == UInt8(ascii: "\t") {
                let charsToTab = Self.tabStop - column % Self.tabStop
                partiallyConsumedTab = charsToTab > remaining
                let advanced = min(remaining, charsToTab)
                column += advanced
                if !partiallyConsumedTab { step() }
                remaining -= advanced
            } else {
                partiallyConsumedTab = false
                step()
                column += 1
                remaining -= 1
            }
        }
    }

    /// S_advance_offset(columns = false): バイト単位で進める。タブは丸ごと消費する
    mutating func advance(bytes count: Int) {
        var remaining = count
        while remaining > 0, let b = peek() {
            if b == UInt8(ascii: "\t") {
                column += Self.tabStop - column % Self.tabStop
            } else {
                column += 1
            }
            partiallyConsumedTab = false
            step()
            remaining -= 1
        }
    }

    private mutating func step() {
        index = utf8.index(after: index)
        offset += 1
    }
}
