import Foundation
import Markdown

/// swift-markdown の AST を歩いて HighlightPlan を生成する。
enum HighlightMapper {
    static func plan(for document: Document, in text: String) -> HighlightPlan {
        var visitor = Visitor(converter: SourceLocationConverter(text: text), text: text as NSString)
        visitor.visit(document)
        // 適用順: ブロック → インライン → マーカー
        return HighlightPlan(
            spans: visitor.blockSpans + visitor.inlineSpans + visitor.markerSpans,
            images: visitor.imageReferences,
            links: visitor.linkReferences
        )
    }

    private struct Visitor: MarkupWalker {
        let converter: SourceLocationConverter
        let text: NSString
        var blockSpans: [HighlightSpan] = []
        var inlineSpans: [HighlightSpan] = []
        var markerSpans: [HighlightSpan] = []
        var imageReferences: [ImageReference] = []
        var linkReferences: [LinkReference] = []
        private var tableDepth = 0
        /// リンク・画像の内側を走査中はベア URL 検出を止める(二重検出防止)
        private var inlineLinkDepth = 0

        private func nsRange(of markup: Markup) -> NSRange? {
            guard let sourceRange = markup.range else { return nil }
            return converter.nsRange(of: sourceRange)
        }

        // MARK: ブロック要素

        mutating func visitHeading(_ heading: Heading) {
            if var range = nsRange(of: heading), range.length > 0 {
                // ATX 見出しの行頭 "#…"(+スペース 1 個)をマーカーに。Setext はマーカーなし。
                let markerLength = leadingHashMarkerLength(in: range)
                if markerLength == 0 {
                    // cmark が Setext 見出しの終端を次ブロックまで過大報告するため
                    // (例: "Title\n=====\nbody" で見出しレンジが後続の Paragraph
                    // "body" まで飲み込む)、下線行末尾にクランプする。
                    range = clampedSetextRange(range, heading: heading)
                }
                blockSpans.append(HighlightSpan(range: range, kind: .heading(level: heading.level)))
                if markerLength > 0 {
                    markerSpans.append(HighlightSpan(
                        range: NSRange(location: range.location, length: markerLength),
                        kind: .syntaxMarker
                    ))
                }
            }
            descendInto(heading)
        }

        /// Setext 見出し(下線型)の終端を、下線行の内容末尾(改行を含まない)に
        /// クランプする。見出しテキストの終端がどの行にあるかを子ノードのレンジ
        /// から求め、その次行(下線行)の contentsEnd を新しい終端とする。
        /// クランプの結果レンジが縮まらない場合は元のレンジをそのまま返す。
        private func clampedSetextRange(_ range: NSRange, heading: Heading) -> NSRange {
            let childRanges = heading.children.compactMap { nsRange(of: $0) }
            guard let textEnd = childRanges.map(NSMaxRange).max() else { return range }
            let textLine = text.lineRange(for: NSRange(location: textEnd, length: 0))
            let underlineStart = NSMaxRange(textLine)
            guard underlineStart <= NSMaxRange(range), underlineStart <= text.length else {
                return range
            }
            let underlineLine = text.lineRange(for: NSRange(location: underlineStart, length: 0))
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: underlineLine)
            let newLength = min(NSMaxRange(range), contentsEnd) - range.location
            guard newLength < range.length else { return range }
            return NSRange(location: range.location, length: newLength)
        }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            guard let range = nsRange(of: codeBlock), range.length > 0 else { return }
            blockSpans.append(HighlightSpan(range: range, kind: .codeBlock))
            // フェンス行をマーカーに(インデント型コードブロックはフェンスなし)
            let firstLine = clippedLineRange(at: range.location, within: range)
            if isFenceLine(firstLine) {
                markerSpans.append(HighlightSpan(range: firstLine, kind: .syntaxMarker))
                let lastLine = clippedLineRange(at: max(range.location, NSMaxRange(range) - 1), within: range)
                if lastLine != firstLine, isFenceLine(lastLine) {
                    markerSpans.append(HighlightSpan(range: lastLine, kind: .syntaxMarker))
                }
            }
            // コードブロック内部は descend しない(強調等を解釈しない)
        }

        mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
            // 最外の BlockQuote のみブロックスパンと行頭マーカーを生成
            if !(blockQuote.parent is BlockQuote), let range = nsRange(of: blockQuote), range.length > 0 {
                blockSpans.append(HighlightSpan(range: range, kind: .blockquote))
                appendQuoteMarkers(in: range)
            }
            descendInto(blockQuote)
        }

        mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
            if let range = nsRange(of: thematicBreak), range.length > 0 {
                blockSpans.append(HighlightSpan(range: range, kind: .thematicBreak))
            }
        }

        mutating func visitTable(_ table: Markdown.Table) {
            if let range = nsRange(of: table), range.length > 0 {
                blockSpans.append(HighlightSpan(range: range, kind: .table))
                if let headRange = nsRange(of: table.head), headRange.length > 0 {
                    blockSpans.append(HighlightSpan(range: headRange, kind: .tableHeader))
                }
                appendTableMarkers(in: range)
            }
            tableDepth += 1
            descendInto(table)
            tableDepth -= 1
        }

        mutating func visitListItem(_ listItem: ListItem) {
            if let range = nsRange(of: listItem), range.length > 0,
               let marker = listMarkerRange(in: range) {
                inlineSpans.append(HighlightSpan(range: marker, kind: .listMarker))
                if let checkbox = listItem.checkbox,
                   let box = checkboxRange(after: marker, within: range) {
                    markerSpans.append(HighlightSpan(range: box, kind: .syntaxMarker))
                    if checkbox == .checked {
                        // チェック済み: 項目直下の Paragraph のみ淡色化。
                        // Paragraph レンジはチェックボックスの後から始まり、
                        // ネストした子リストを含まないため子項目を汚染しない。
                        for child in listItem.children where child is Paragraph {
                            if let paragraphRange = nsRange(of: child), paragraphRange.length > 0 {
                                inlineSpans.append(
                                    HighlightSpan(range: paragraphRange, kind: .taskChecked))
                            }
                        }
                    }
                }
            }
            descendInto(listItem)
        }

        // MARK: インライン要素

        mutating func visitStrong(_ strong: Strong) {
            appendDelimited(strong, kind: .strong, delimiterLength: 2)
            descendInto(strong)
        }

        mutating func visitEmphasis(_ emphasis: Emphasis) {
            appendDelimited(emphasis, kind: .emphasis, delimiterLength: 1)
            descendInto(emphasis)
        }

        mutating func visitInlineCode(_ inlineCode: InlineCode) {
            guard let range = nsRange(of: inlineCode), range.length > 0 else { return }
            inlineSpans.append(HighlightSpan(range: range, kind: .inlineCode))
            // デリミタは実際のバッククォート列を走査して求める。
            // CommonMark はパディングスペースを code から剥がすため、
            // (range.length - code.length) / 2 のような算術では
            // スペースまでマーカーに含めてしまう。
            let delimiter = symmetricDelimiterLength(
                in: range, character: unichar(UnicodeScalar("`").value))
            if delimiter > 0 {
                markerSpans.append(HighlightSpan(
                    range: NSRange(location: range.location, length: delimiter),
                    kind: .syntaxMarker
                ))
                markerSpans.append(HighlightSpan(
                    range: NSRange(location: NSMaxRange(range) - delimiter, length: delimiter),
                    kind: .syntaxMarker
                ))
            }
        }

        mutating func visitLink(_ link: Link) {
            if let range = nsRange(of: link), range.length > 0 {
                inlineSpans.append(HighlightSpan(range: range, kind: .link))
                linkReferences.append(LinkReference(
                    text: plainText(of: link),
                    destination: link.destination ?? "",
                    range: range))
            }
            inlineLinkDepth += 1
            descendInto(link)
            inlineLinkDepth -= 1
        }

        mutating func visitImage(_ image: Markdown.Image) {
            if let range = nsRange(of: image), range.length >= 2 {
                inlineSpans.append(HighlightSpan(range: range, kind: .image))
                appendImageMarkers(in: range, image: image)
                imageReferences.append(ImageReference(
                    altText: plainText(of: image),
                    destination: image.source ?? "",
                    range: range,
                    paragraphRange: text.paragraphRange(for: range),
                    isInsideTable: tableDepth > 0
                ))
            }
            inlineLinkDepth += 1
            descendInto(image)
            inlineLinkDepth -= 1
        }

        mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
            if let range = nsRange(of: strikethrough), range.length > 0 {
                inlineSpans.append(HighlightSpan(range: range, kind: .strikethrough))
                // cmark-gfm はチルダ 1 個も打ち消し線にするため、デリミタ長は
                // 実テキストのチルダ列を走査して求める(インラインコードと同方式)。
                let delimiter = symmetricDelimiterLength(
                    in: range, character: unichar(UnicodeScalar("~").value))
                if delimiter > 0 {
                    markerSpans.append(HighlightSpan(
                        range: NSRange(location: range.location, length: delimiter),
                        kind: .syntaxMarker
                    ))
                    markerSpans.append(HighlightSpan(
                        range: NSRange(location: NSMaxRange(range) - delimiter, length: delimiter),
                        kind: .syntaxMarker
                    ))
                }
            }
            descendInto(strikethrough)
        }

        // MARK: ヘルパー

        private mutating func appendDelimited(_ markup: Markup, kind: SyntaxKind, delimiterLength: Int) {
            guard let range = nsRange(of: markup), range.length >= delimiterLength * 2 else { return }
            inlineSpans.append(HighlightSpan(range: range, kind: kind))
            markerSpans.append(HighlightSpan(
                range: NSRange(location: range.location, length: delimiterLength),
                kind: .syntaxMarker
            ))
            markerSpans.append(HighlightSpan(
                range: NSRange(location: NSMaxRange(range) - delimiterLength, length: delimiterLength),
                kind: .syntaxMarker
            ))
        }

        /// range の先頭にある character の連続長を求め、閉じ側にも同じ長さの列が
        /// ある場合のみその長さを返す(なければ 0)。インラインコードのバッククォートと
        /// 打ち消し線のチルダで共用する。
        private func symmetricDelimiterLength(in range: NSRange, character: unichar) -> Int {
            let end = NSMaxRange(range)
            var delimiter = 0
            while range.location + delimiter < end,
                  text.character(at: range.location + delimiter) == character {
                delimiter += 1
            }
            guard delimiter > 0, range.length >= delimiter * 2 else { return 0 }
            for i in (end - delimiter)..<end where text.character(at: i) != character {
                return 0
            }
            return delimiter
        }

        /// 行頭の "#…"(最大 6 個)+ 直後のスペース 1 個の長さ。ATX 見出しでなければ 0。
        private func leadingHashMarkerLength(in range: NSRange) -> Int {
            let end = NSMaxRange(range)
            var i = range.location
            var count = 0
            while i < end, count < 6, text.character(at: i) == UInt16(UnicodeScalar("#").value) {
                count += 1
                i += 1
            }
            guard count > 0 else { return 0 }
            if i < end, text.character(at: i) == UInt16(UnicodeScalar(" ").value) {
                count += 1
            }
            return count
        }

        /// location を含む行のレンジを range 内にクリップし、末尾の改行を除いて返す。
        private func clippedLineRange(at location: Int, within range: NSRange) -> NSRange {
            var line = text.lineRange(for: NSRange(location: location, length: 0))
            // 末尾の改行を除く
            while line.length > 0, text.character(at: NSMaxRange(line) - 1) == UInt16(UnicodeScalar("\n").value) {
                line.length -= 1
            }
            return NSIntersectionRange(line, range)
        }

        /// テーブルレンジ内のパイプ("\|" エスケープを除く)と区切り行をマーカー化する。
        /// GFM テーブルはヘッダー 1 行 + 区切り行 1 行 + ボディという固定構造のため、
        /// レンジ内の 2 行目を区切り行("---|---" 等)として行全体をマーカーにする
        /// (区切り行は AST の Head にも Body にも含まれない)。
        private mutating func appendTableMarkers(in range: NSRange) {
            let pipe = unichar(UnicodeScalar("|").value)
            let backslash = unichar(UnicodeScalar("\\").value)
            var location = range.location
            let end = NSMaxRange(range)
            var lineIndex = 0
            while location < end {
                let line = clippedLineRange(at: location, within: range)
                if lineIndex == 1 {
                    if line.length > 0 {
                        markerSpans.append(HighlightSpan(range: line, kind: .syntaxMarker))
                    }
                } else {
                    var i = line.location
                    while i < NSMaxRange(line) {
                        if text.character(at: i) == pipe,
                           i == line.location || text.character(at: i - 1) != backslash {
                            markerSpans.append(HighlightSpan(
                                range: NSRange(location: i, length: 1), kind: .syntaxMarker))
                        }
                        i += 1
                    }
                }
                let fullLine = text.lineRange(for: NSRange(location: location, length: 0))
                if NSMaxRange(fullLine) <= location { break }
                location = NSMaxRange(fullLine)
                lineIndex += 1
            }
        }

        private func isFenceLine(_ line: NSRange) -> Bool {
            guard line.length >= 3 else { return false }
            let first = text.character(at: line.location)
            let backtick = UInt16(UnicodeScalar("`").value)
            let tilde = UInt16(UnicodeScalar("~").value)
            guard first == backtick || first == tilde else { return false }
            return text.character(at: line.location + 1) == first
                && text.character(at: line.location + 2) == first
        }

        /// range 内の各行頭にある ">" を 1 文字ずつマーカーとして追加(ネスト分も拾う)。
        private mutating func appendQuoteMarkers(in range: NSRange) {
            let space = UInt16(UnicodeScalar(" ").value)
            let gt = UInt16(UnicodeScalar(">").value)
            var location = range.location
            let end = NSMaxRange(range)
            while location < end {
                let line = text.lineRange(for: NSRange(location: location, length: 0))
                let lineEnd = min(NSMaxRange(line), end)
                var i = line.location
                var leadingSpaces = 0
                while i < lineEnd, text.character(at: i) == space, leadingSpaces < 3 {
                    i += 1
                    leadingSpaces += 1
                }
                while i < lineEnd, text.character(at: i) == gt {
                    markerSpans.append(HighlightSpan(range: NSRange(location: i, length: 1), kind: .syntaxMarker))
                    i += 1
                    if i < lineEnd, text.character(at: i) == space { i += 1 }
                }
                if NSMaxRange(line) <= location { break }
                location = NSMaxRange(line)
            }
        }

        /// リストアイテム先頭のマーカー("-" "*" "+" または "1." "1)")のレンジ。
        private func listMarkerRange(in range: NSRange) -> NSRange? {
            let end = NSMaxRange(range)
            var i = range.location
            let space = UInt16(UnicodeScalar(" ").value)
            while i < end, text.character(at: i) == space { i += 1 }
            guard i < end else { return nil }
            let start = i
            let c = text.character(at: i)
            let bullets: [UInt16] = ["-", "*", "+"].map { UInt16(UnicodeScalar($0)!.value) }
            if bullets.contains(c) {
                i += 1
            } else {
                let zero = UInt16(UnicodeScalar("0").value)
                let nine = UInt16(UnicodeScalar("9").value)
                while i < end, (zero...nine).contains(text.character(at: i)) { i += 1 }
                guard i > start, i < end else { return nil }
                let dot = UInt16(UnicodeScalar(".").value)
                let paren = UInt16(UnicodeScalar(")").value)
                guard text.character(at: i) == dot || text.character(at: i) == paren else { return nil }
                i += 1
            }
            return NSRange(location: start, length: i - start)
        }

        /// リストマーカー直後の "[ ]" / "[x]" / "[X]"(3 文字)のレンジ。なければ nil。
        /// 呼び出し側で listItem.checkbox の存在を確認してから使うこと
        /// (checkbox 非 nil ならパーサーが認めた実チェックボックスが必ず存在する)。
        private func checkboxRange(after marker: NSRange, within range: NSRange) -> NSRange? {
            let end = NSMaxRange(range)
            let space = unichar(UnicodeScalar(" ").value)
            var i = NSMaxRange(marker)
            while i < end, text.character(at: i) == space { i += 1 }
            guard i + 3 <= end,
                  text.character(at: i) == unichar(UnicodeScalar("[").value),
                  text.character(at: i + 2) == unichar(UnicodeScalar("]").value) else { return nil }
            return NSRange(location: i, length: 3)
        }

        /// 画像記法のマーカー: 先頭の "![" と、alt 末尾から記法末尾まで
        /// (インライン形式 "](url)" と参照形式 "][ref]" の両方をカバーする)。
        private mutating func appendImageMarkers(in range: NSRange, image: Markdown.Image) {
            markerSpans.append(HighlightSpan(
                range: NSRange(location: range.location, length: 2),
                kind: .syntaxMarker
            ))
            var altEnd = range.location + 2
            for child in image.children {
                if let childRange = nsRange(of: child) {
                    altEnd = max(altEnd, NSMaxRange(childRange))
                }
            }
            if altEnd < NSMaxRange(range) {
                markerSpans.append(HighlightSpan(
                    range: NSRange(location: altEnd, length: NSMaxRange(range) - altEnd),
                    kind: .syntaxMarker
                ))
            }
        }

        /// 子孫の Text ノードを連結したプレーンテキスト(強調などの装飾を剥がす)。
        private func plainText(of markup: Markup) -> String {
            var result = ""
            func collect(_ markup: Markup) {
                if let textNode = markup as? Markdown.Text { result += textNode.string }
                for child in markup.children { collect(child) }
            }
            collect(markup)
            return result
        }

        // MARK: ベア URL 検出

        /// swift-markdown は GFM autolink 拡張を有効化していないため、
        /// 裸の http(s) URL は Text ノードのまま届く。ここで自前検出する。
        mutating func visitText(_ node: Markdown.Text) {
            guard inlineLinkDepth == 0, let range = nsRange(of: node), range.length > 0
            else { return }
            appendBareURLs(in: range)
        }

        private mutating func appendBareURLs(in range: NSRange) {
            let end = NSMaxRange(range)
            var i = range.location
            while i < end {
                guard let schemeLength = urlSchemeLength(at: i, end: end) else {
                    i += 1
                    continue
                }
                // 直前が ASCII 英数字なら単語の一部("xhttps://…")なのでスキップ
                if i > 0, isASCIIAlphanumeric(text.character(at: i - 1)) {
                    i += schemeLength
                    continue
                }
                var j = i + schemeLength
                while j < end, !isURLTerminator(text.character(at: j)) { j += 1 }
                let urlEnd = trimTrailingPunctuation(from: i, to: j)
                if urlEnd > i + schemeLength {
                    let urlRange = NSRange(location: i, length: urlEnd - i)
                    let destination = text.substring(with: urlRange)
                    inlineSpans.append(HighlightSpan(range: urlRange, kind: .link))
                    linkReferences.append(LinkReference(
                        text: destination, destination: destination, range: urlRange))
                }
                i = j
            }
        }

        /// location から "https://" / "http://" が始まっていればその長さ(UTF-16)。
        private func urlSchemeLength(at location: Int, end: Int) -> Int? {
            for scheme in ["https://", "http://"] {
                let length = (scheme as NSString).length
                guard location + length <= end else { continue }
                let candidate = text.substring(
                    with: NSRange(location: location, length: length))
                if candidate.lowercased() == scheme { return length }
            }
            return nil
        }

        /// URL の終端文字: 空白・制御文字・"<"・非 ASCII(全角文字等)。
        private func isURLTerminator(_ c: unichar) -> Bool {
            c <= 0x20 || c == unichar(UnicodeScalar("<").value) || c >= 0x7F
        }

        private func isASCIIAlphanumeric(_ c: unichar) -> Bool {
            let zero = unichar(UnicodeScalar("0").value), nine = unichar(UnicodeScalar("9").value)
            let a = unichar(UnicodeScalar("a").value), z = unichar(UnicodeScalar("z").value)
            let A = unichar(UnicodeScalar("A").value), Z = unichar(UnicodeScalar("Z").value)
            return (zero...nine).contains(c) || (a...z).contains(c) || (A...Z).contains(c)
        }

        /// 末尾の約物をトリムする。")" は URL 内の括弧バランスを見て閉じ超過分のみ落とす。
        private func trimTrailingPunctuation(from start: Int, to end: Int) -> Int {
            let trailing: Set<unichar> = Set(".,;:!?'\"".utf16)
            let open = unichar(UnicodeScalar("(").value)
            let close = unichar(UnicodeScalar(")").value)
            var end = end
            while end > start {
                let c = text.character(at: end - 1)
                if trailing.contains(c) {
                    end -= 1
                    continue
                }
                if c == close {
                    var opens = 0, closes = 0
                    for k in start..<end {
                        let ch = text.character(at: k)
                        if ch == open { opens += 1 }
                        if ch == close { closes += 1 }
                    }
                    if closes > opens {
                        end -= 1
                        continue
                    }
                }
                break
            }
            return end
        }
    }
}
