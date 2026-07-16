import Foundation

/// 見出し 1 件分のアウトライン項目。
public struct OutlineItem: Hashable, Sendable {
    /// 見出しレベル(1...6)
    public var level: Int
    /// マーカー除去済みの見出しテキスト
    public var title: String
    /// 見出し(スパン)の UTF-16 レンジ
    public var headingRange: NSRange
    /// 見出し行頭から、次の同位以上見出しの行頭直前(または文書末尾)まで
    public var sectionRange: NSRange
    /// 折畳時に隠す本体(見出し行の次行頭〜sectionRange 末尾)。本体がなければ length 0
    public var bodyRange: NSRange

    /// 折畳操作のキーとして使う見出し位置
    public var headingLocation: Int { headingRange.location }

    public init(
        level: Int, title: String,
        headingRange: NSRange, sectionRange: NSRange, bodyRange: NSRange
    ) {
        self.level = level
        self.title = title
        self.headingRange = headingRange
        self.sectionRange = sectionRange
        self.bodyRange = bodyRange
    }
}

/// HighlightPlan の heading スパンと原文からアウトラインを構築する純関数。
public enum OutlineBuilder {
    public static func build(from plan: HighlightPlan, text: String) -> [OutlineItem] {
        let ns = text as NSString
        let headings = plan.spans
            .compactMap { span -> (range: NSRange, level: Int)? in
                guard case .heading(let level) = span.kind else { return nil }
                return (span.range, level)
            }
            .sorted { $0.range.location < $1.range.location }
        return headings.enumerated().map { index, heading in
            let headingLine = ns.lineRange(
                for: NSRange(location: heading.range.location, length: 0))
            let sectionStart = headingLine.location
            // 同位以上(数値が同じか小さい)の次見出しの行頭がセクション終端
            let sectionEnd = headings[(index + 1)...]
                .first { $0.level <= heading.level }
                .map { ns.lineRange(for: NSRange(location: $0.range.location, length: 0)).location }
                ?? ns.length
            // Setext 見出しは 2 行(テキスト行 + 下線行)。本体は見出しレンジ末尾を
            // 含む行の次行頭から。
            let headingEndLine = ns.lineRange(
                for: NSRange(
                    location: max(heading.range.location, NSMaxRange(heading.range) - 1),
                    length: 0))
            let bodyStart = min(NSMaxRange(headingEndLine), sectionEnd)
            return OutlineItem(
                level: heading.level,
                title: title(ofHeadingAt: heading.range, in: ns),
                headingRange: heading.range,
                sectionRange: NSRange(location: sectionStart, length: sectionEnd - sectionStart),
                bodyRange: NSRange(location: bodyStart, length: max(0, sectionEnd - bodyStart))
            )
        }
    }

    /// 見出しテキストからマーカーを除去したタイトル。
    /// ATX: 先頭の `#…`、および空白で区切られた末尾の閉じ `#…` を除去。
    /// Setext: 1 行目(テキスト行)をそのまま使う。
    private static func title(ofHeadingAt range: NSRange, in text: NSString) -> String {
        let raw = text.substring(with: range)
        let firstLine = raw.split(
            separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[0]
        var body = firstLine.drop(while: { $0 == "#" })
        let trailingHashes = body.reversed().prefix(while: { $0 == "#" }).count
        if trailingHashes > 0 {
            let cut = body.index(body.endIndex, offsetBy: -trailingHashes)
            if cut > body.startIndex, body[body.index(before: cut)] == " " {
                body = body[..<cut]
            }
        }
        return body.trimmingCharacters(in: .whitespaces)
    }
}
