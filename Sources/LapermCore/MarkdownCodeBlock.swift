import Foundation

/// コードブロック 1 つ(フェンス付き、またはインデント型)の構造。UI 層が Live Preview のコードブロックの箱として
/// 描くために使う(Laperm ADR 0020)。レンジはすべて原文の UTF-16 オフセット。
public struct MarkdownCodeBlock: Hashable, Sendable {
    /// ブロック全体。フェンス付きは開始フェンス(インデントの後)から終了フェンス行の行末まで(閉じていなければ文書末
    /// まで)、インデント型は最初の行のインデントの後から最後の行の行末まで(`.codeBlock` スパンと違い、cmark が
    /// 報告する最後の行の改行は含めない)。
    public var range: NSRange
    /// ブロックの最初の行の行頭(`range.location` の前のインデントを含む物理的な行頭)。ブロックの段落はここから始まる。
    public var lineStart: Int
    /// フェンス付きか(インデント型は false)。
    public var isFenced: Bool
    /// 終了フェンスがあるか。インデント型は常に true。
    public var isClosed: Bool
    /// リスト項目や引用の中(文書直下ではない)か。Live Preview は中のものを折りたたまない。
    public var isNested: Bool
    /// 言語(開始フェンスの info string の最初の語)。無ければ nil。
    public var language: String?
    /// コード本文(フェンス付きはフェンスの間の行、インデント型は全行)の、最初の行の行頭(インデントを含む。
    /// インデント型では `range.location` より前)から最後の行の行末(改行を含まない)まで。本文の行が 1 行も無ければ nil。
    public var contentRange: NSRange?
    /// 本文の各行の先頭から取り除くインデントの幅(桁数。フェンス付きは開始フェンスのインデント、インデント型は 4)。
    public var contentIndent: Int

    public init(
        range: NSRange, lineStart: Int, isFenced: Bool, isClosed: Bool, isNested: Bool, language: String?,
        contentRange: NSRange?, contentIndent: Int
    ) {
        self.range = range
        self.lineStart = lineStart
        self.isFenced = isFenced
        self.isClosed = isClosed
        self.isNested = isNested
        self.language = language
        self.contentRange = contentRange
        self.contentIndent = contentIndent
    }

    /// すべてのレンジを `delta` だけ平行移動したもの。
    public func shifted(by delta: Int) -> MarkdownCodeBlock {
        var moved = self
        moved.range = NSRange(location: range.location + delta, length: range.length)
        moved.lineStart = lineStart + delta
        moved.contentRange = contentRange.map { NSRange(location: $0.location + delta, length: $0.length) }
        return moved
    }

    /// ブロックの先頭を 0 にしたもの(内容の比較用)。
    public var relativeToStart: MarkdownCodeBlock { shifted(by: -range.location) }

    /// 編集(編集前の座標のレンジ)がこのブロックの構造を変えうるか。テーブルと同じ規則(`MarkdownTable.isTouched`)を
    /// 行頭(`lineStart`)から適用する: 中はもちろん、行頭への挿入(インデント型の先頭のインデントの中も)、末尾への挿入、
    /// 直前の改行の削除も含む。直後の行への挿入は含まない。`HighlightPlan.shifted` と Live Preview の箱が同じ規則を使う。
    public func isTouched(byEditBefore preEditRange: NSRange) -> Bool {
        preEditRange.location <= NSMaxRange(range) && NSMaxRange(preEditRange) >= lineStart
    }

    /// 本文の行(改行を含まない。`contentRange` を行に分けたもの)。
    public func contentLineRanges(in text: NSString) -> [NSRange] {
        guard let contentRange, NSMaxRange(contentRange) <= text.length else { return [] }
        var lines: [NSRange] = []
        var location = contentRange.location
        let end = NSMaxRange(contentRange)
        repeat {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            lines.append(NSRange(location: location, length: max(0, min(contentsEnd, end) - location)))
            // 改行で終わった行の次の行が本文の終端で始まる(最後の行が空行)ときは、終端に長さ 0 の行がある
            guard lineEnd > contentsEnd, lineEnd <= end else { break }
            location = lineEnd
        } while true
        return lines
    }

    /// `line`(本文の 1 行)の先頭から `contentIndent` ぶんのインデントを除いた、表示する部分。空白は 1 つ 1 桁、
    /// タブは次の 4 の倍数の桁まで(CommonMark)。タブがインデントの幅をまたぐときはそのタブまで取り除く(CommonMark
    /// では残りの桁が空白として残るが、原文に無い文字は表示に足さない)。
    public func displayRange(ofContentLine line: NSRange, in text: NSString) -> NSRange {
        let start = Self.indentEnd(of: line, columns: contentIndent, in: text)
        return NSRange(location: start, length: NSMaxRange(line) - start)
    }

    /// `line` の先頭から `columns` 桁のインデントを読み飛ばした位置(空白 1 桁、タブは次の 4 の倍数の桁まで)。
    public static func indentEnd(of line: NSRange, columns: Int, in text: NSString) -> Int {
        var column = 0
        var i = line.location
        let end = NSMaxRange(line)
        while i < end, column < columns {
            switch text.character(at: i) {
            case ASCII.space: column += 1
            case ASCII.tab: column += 4 - column % 4
            default: return i
            }
            i += 1
        }
        return i
    }

    /// 行頭 `lineStart` から `location` までの桁数(空白 1 桁、タブは次の 4 の倍数の桁まで、他の文字は 1 桁)。
    public static func indentColumns(from lineStart: Int, to location: Int, in text: NSString) -> Int {
        var column = 0
        var i = lineStart
        while i < location {
            column += text.character(at: i) == ASCII.tab ? 4 - column % 4 : 1
            i += 1
        }
        return column
    }
}
