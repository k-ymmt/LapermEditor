import Foundation

/// コードブロック 1 つ(フェンス付き、またはインデント型)の構造。UI 層が Live Preview のコードブロックの箱として
/// 描くために使う(Laperm ADR 0020)。レンジはすべて原文の UTF-16 オフセット。
public struct MarkdownCodeBlock: Hashable, Sendable {
    /// ブロック全体(`.codeBlock` スパンと同じ)。フェンス付きは開始フェンス(インデントの後)から終了フェンス行の
    /// 行末まで(閉じていなければ文書末まで)、インデント型は最初の行のインデントの後から最後の行の改行まで
    /// (cmark の報告どおり。最後の行の改行を含むことがある)。
    public var range: NSRange
    /// フェンス付きか(インデント型は false)。
    public var isFenced: Bool
    /// 終了フェンスがあるか。インデント型は常に true。
    public var isClosed: Bool
    /// 言語(開始フェンスの info string の最初の語)。無ければ nil。
    public var language: String?
    /// コード本文(フェンス付きはフェンスの間の行、インデント型は全行)の、最初の行の先頭(インデントを含む)から
    /// 最後の行の行末(改行を含まない)まで。本文の行が 1 行も無ければ nil。
    public var contentRange: NSRange?
    /// 本文の各行の先頭から取り除くインデントの幅(空白の数。フェンス付きは開始フェンスのインデント、インデント型は 4)。
    public var contentIndent: Int

    public init(
        range: NSRange, isFenced: Bool, isClosed: Bool, language: String?, contentRange: NSRange?, contentIndent: Int
    ) {
        self.range = range
        self.isFenced = isFenced
        self.isClosed = isClosed
        self.language = language
        self.contentRange = contentRange
        self.contentIndent = contentIndent
    }

    /// すべてのレンジを `delta` だけ平行移動したもの。
    public func shifted(by delta: Int) -> MarkdownCodeBlock {
        var moved = self
        moved.range = NSRange(location: range.location + delta, length: range.length)
        moved.contentRange = contentRange.map { NSRange(location: $0.location + delta, length: $0.length) }
        return moved
    }

    /// ブロックの先頭を 0 にしたもの(内容の比較用)。
    public var relativeToStart: MarkdownCodeBlock { shifted(by: -range.location) }

    /// 編集(編集前の座標のレンジ)がこのブロックの構造を変えうるか。テーブルと同じ規則(`MarkdownTable.isTouched`):
    /// 中はもちろん、先頭への挿入、末尾への挿入、直前の改行の削除も含む。直後の行への挿入は含まない。
    public func isTouched(byEditBefore preEditRange: NSRange) -> Bool {
        preEditRange.location <= NSMaxRange(range) && NSMaxRange(preEditRange) >= range.location
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
            guard lineEnd > location, lineEnd < end else { break }
            location = lineEnd
        } while true
        return lines
    }

    /// `line`(本文の 1 行)の先頭から `contentIndent` ぶんのインデントを除いた、表示する部分。空白は 1 つ 1 桁、
    /// タブは次の 4 の倍数の桁まで(CommonMark)。タブがインデントの幅をまたぐときはそのタブまで取り除く。
    public func displayRange(ofContentLine line: NSRange, in text: NSString) -> NSRange {
        var column = 0
        var i = line.location
        let end = NSMaxRange(line)
        while i < end, column < contentIndent {
            switch text.character(at: i) {
            case ASCII.space: column += 1
            case ASCII.tab: column += 4 - column % 4
            default: return NSRange(location: i, length: end - i)
            }
            i += 1
        }
        return NSRange(location: i, length: end - i)
    }
}
