#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import CoreText
import LapermCore

/// クリック / タップ / 長押し / 右クリックの点にあるリンク(Laperm ADR 0031)。本文のリンク、折りたたまれたテーブルの
/// 格子のセルの中のリンク、折りたたまれた Front Matter の表の値の URL のどれか。
struct LinkHit: Equatable {
    enum Target: Equatable {
        /// Markdown Link / 裸の URL / Front Matter の URL(書かれたままの文字列。開くときに `LinkURLResolver` で解決する)
        case url(destination: String)
        case wiki(WikiLinkReference)
    }

    var target: Target
    /// メニューの「編集」でキャレットを置く位置(文書座標)
    var editCaret: NSRange
    /// リンクとして描かれているか(Live Preview でキャレットの無い段落、表の格子、Front Matter の表)。
    /// true なら修飾キー無しのクリック / タップで開く。
    var isRendered: Bool
}

/// リンクのメニューの項目名(両 OS 共通。テストもここから引くので実行環境の言語に依らない)。
enum LinkMenuTitle {
    static var open: String { String(localized: "Open Link", bundle: .module) }
    static var copy: String { String(localized: "Copy Link", bundle: .module) }
    static var edit: String { String(localized: "Edit", bundle: .module) }
}

/// 折りたたまれた表(格子 / Front Matter)の表示用文字列に付ける、リンクの印。
enum PreviewLinkAttribute {
    /// Front Matter の表: 値の中の URL(値は `String`)
    static let url = NSAttributedString.Key("LapermPreviewLinkURL")
    /// テーブルの格子: そのリンクのテーブルの先頭からの相対位置(値は `Int`)。文書座標に戻して計画のリンクを引く。
    static let sourceOffset = NSAttributedString.Key("LapermPreviewLinkSourceOffset")
}

enum PreviewLinks {
    /// 文字列の中の `http://` / `https://` の URL のレンジ(空白・山括弧・引用符で終わり、末尾の句読点は含めない。
    /// 閉じ括弧は URL の中に対応する開き括弧が無いときだけ除く: 本文の裸の URL(`HighlightMapper`)と同じ規則)。
    static func urlRanges(in string: String) -> [NSRange] {
        let text = string as NSString
        var result: [NSRange] = []
        for match in urlPattern.matches(in: string, range: NSRange(location: 0, length: text.length)) {
            var range = match.range
            while range.length > 0 {
                let last = text.character(at: NSMaxRange(range) - 1)
                if trailingPunctuation.contains(last) {
                    range.length -= 1
                } else if closingBrackets.contains(last) {
                    let url = text.substring(with: range)
                    let open = Character(UnicodeScalar(openingBracket[last]!)!)
                    let close = Character(UnicodeScalar(last)!)
                    guard url.filter({ $0 == close }).count > url.filter({ $0 == open }).count else { break }
                    range.length -= 1
                } else {
                    break
                }
            }
            // スキームだけ(ホストが無い)は URL として扱わない
            let scheme = text.substring(with: match.range).lowercased().hasPrefix("https") ? 8 : 7
            if range.length > scheme { result.append(range) }
        }
        return result
    }

    private static let urlPattern = try! NSRegularExpression(pattern: "https?://[^\\s<>\"']+", options: [.caseInsensitive])
    private static let closingBrackets: Set<unichar> = Set(")]}".utf16)
    private static let openingBracket: [unichar: unichar] = [0x29: 0x28, 0x5D: 0x5B, 0x7D: 0x7B]
    private static let trailingPunctuation: Set<unichar> = Set(".,;:!?".utf16)

    /// `text` の URL にリンクの色と `PreviewLinkAttribute.url` を付けたもの(Front Matter の表の値 / チップ)。
    static func linkifyingURLs(in text: NSAttributedString, color: PlatformColor) -> NSAttributedString {
        let ranges = urlRanges(in: text.string)
        guard !ranges.isEmpty else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        let string = text.string as NSString
        for range in ranges {
            result.addAttributes([.foregroundColor: color, PreviewLinkAttribute.url: string.substring(with: range)], range: range)
        }
        return result
    }

    /// 幅 `width` で折り返して描いた `text`(左上原点、y 下向き)の点 `point` に重なっている文字の添字。文字の上でなければ nil。
    /// 表の文字は `NSAttributedString.draw(with:options:)` で描かれ、同じ Core Text の行分割になる。グリフの位置と送り幅で
    /// 判定するので、右から左の文字が混ざる行でも見た目の位置の文字を返す。高さは文字列に必要なぶん(打ち切らない)。
    static func characterIndex(in text: NSAttributedString, width: CGFloat, at point: CGPoint) -> Int? {
        guard text.length > 0, width > 0, point.x >= -2, point.y >= -2 else { return nil }
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let constraints = CGSize(width: width, height: .greatestFiniteMagnitude)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, constraints, nil)
        let height = ceil(suggested.height) + 1
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return nil }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (line, origin) in zip(lines, origins) {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            // Core Text の y は下から。描画(y 下向き)の行の上端と下端に直す
            let top = height - origin.y - ascent
            let bottom = height - origin.y + descent + leading
            guard point.y >= top - 1, point.y < bottom + 1 else { continue }
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return nil }
            for run in runs {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                var positions = [CGPoint](repeating: .zero, count: count)
                var advances = [CGSize](repeating: .zero, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                for glyph in 0..<count where advances[glyph].width > 0 {
                    let start = origin.x + positions[glyph].x
                    if start - 1 <= point.x, point.x < start + advances[glyph].width + 1 {
                        return indices[glyph]
                    }
                }
            }
            return nil
        }
        return nil
    }
}
