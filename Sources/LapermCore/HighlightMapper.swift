import Foundation
import Markdown

/// swift-markdown の AST を歩いて HighlightPlan を生成する。
enum HighlightMapper {
    static func plan(for document: Document, in text: String) -> HighlightPlan {
        // 段落の 2 行目以降(特にリスト項目・引用の直後にインデントなしで続く遅延継続行)では
        // インライン要素の桁がずれて報告されるため、cmark のコンテナ照合を再現して
        // 行ごとの補正量を先に求めておく。
        let converter = SourceLocationConverter(text: text).applyingInlineColumnDeltas(for: document)
        var visitor = Visitor(converter: converter, text: text as NSString)
        visitor.visit(document)
        // 適用順: ブロック → インライン → マーカー
        return HighlightPlan(
            spans: visitor.blockSpans + visitor.inlineSpans + visitor.markerSpans,
            images: visitor.imageReferences,
            links: visitor.linkReferences,
            concealableMarkers: visitor.concealableMarkers,
            tables: visitor.tables
        )
    }

    private struct Visitor: MarkupWalker {
        let converter: SourceLocationConverter
        let text: NSString
        var blockSpans: [HighlightSpan] = []
        var inlineSpans: [HighlightSpan] = []
        var markerSpans: [HighlightSpan] = []
        /// Live Preview が隠すマーカー(markerSpans の部分集合)
        var concealableMarkers: [NSRange] = []
        var imageReferences: [ImageReference] = []
        var linkReferences: [LinkReference] = []
        /// テーブルの構造(セルのレンジ)。Live Preview の表が使う。
        var tables: [MarkdownTable] = []
        /// 走査中のテーブル(セル内のインライン要素の位置補正に使う)。
        private var currentTable: MarkdownTable?
        private var tableDepth = 0
        /// リンク・画像の内側を走査中はベア URL 検出を止める(二重検出防止)
        private var inlineLinkDepth = 0

        private func nsRange(of markup: Markup) -> NSRange? {
            guard let sourceRange = markup.range else { return nil }
            // インライン要素だけ遅延継続行の桁補正を受ける(ブロック要素の桁は正しい)
            guard let range = converter.nsRange(of: sourceRange, isInline: markup is InlineMarkup) else { return nil }
            guard markup is InlineMarkup, let table = currentTable else { return range }
            return Self.correctingEscapedPipes(range, in: table, text: text)
        }

        /// cmark-gfm はセルの `\|` を `|` に縮めてからインラインを解釈するので、同じセルの中でその後ろにある
        /// インライン要素の位置は、前にある `\|` の数だけ左にずれて報告される。原文の座標へ戻す。
        static func correctingEscapedPipes(_ range: NSRange, in table: MarkdownTable, text: NSString) -> NSRange {
            let rows = [table.header] + table.rows
            guard let row = rows.first(where: { NSLocationInRange(range.location, $0.lineRange) || range.location == NSMaxRange($0.lineRange) }),
                  let cell = row.cells.last(where: { $0.range.location <= range.location }),
                  cell.range.length > 0
            else { return range }
            // 補正が要るセルか(`\|` が無ければそのまま)
            let cellText = text.substring(with: cell.range)
            guard cellText.contains("\\|") else { return range }
            func actual(reported: Int) -> Int {
                var i = cell.range.location
                var r = cell.range.location
                let end = NSMaxRange(cell.range)
                while r < reported, i < end {
                    if text.character(at: i) == ASCII.backslash, i + 1 < end, text.character(at: i + 1) == ASCII.pipe {
                        i += 2
                    } else {
                        i += 1
                    }
                    r += 1
                }
                return i + (reported - r)
            }
            let start = actual(reported: range.location)
            let end = actual(reported: NSMaxRange(range))
            return NSRange(location: start, length: max(0, end - start))
        }

        // MARK: ブロック要素

        mutating func visitHeading(_ heading: Heading) {
            if var range = nsRange(of: heading), range.length > 0 {
                // ATX 見出しの行頭 "#…"(+スペース 1 個)をマーカーに。Setext はマーカーなし。
                // cmark の ATX 見出しレンジは閉じ側の "#" 列を含まず、空見出し "# #" では "#" だけに
                // なることもあるので、開き側・閉じ側とも見出し行の内容末尾までを見る。
                let headingLine = lineContentRange(from: range.location)
                let markerLength = leadingHashMarkerLength(in: headingLine)
                if markerLength == 0 {
                    // cmark が Setext 見出しの終端を次ブロックまで過大報告するため
                    // (例: "Title\n=====\nbody" で見出しレンジが後続の Paragraph
                    // "body" まで飲み込む)、下線行末尾にクランプする。
                    range = clampedSetextRange(range, heading: heading)
                }
                blockSpans.append(HighlightSpan(range: range, kind: .heading(level: heading.level)))
                if markerLength > 0 {
                    appendConcealableMarker(NSRange(location: range.location, length: markerLength))
                    // 閉じ側の "#" 列(CommonMark の optional closing sequence)。cmark の見出しレンジは
                    // 閉じ側を含むので、行末から逆に走査する。
                    if let closing = closingHashMarkerRange(in: headingLine, afterOpening: markerLength) {
                        appendConcealableMarker(closing)
                    }
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
                appendQuoteMarkers(in: range, nestedQuoteRanges: nestedBlockQuoteRanges(in: blockQuote))
            }
            descendInto(blockQuote)
        }

        mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
            if let range = nsRange(of: thematicBreak), range.length > 0 {
                blockSpans.append(HighlightSpan(range: range, kind: .thematicBreak))
            }
        }

        mutating func visitTable(_ table: Markdown.Table) {
            if var range = nsRange(of: table), range.length > 0 {
                var headRange = nsRange(of: table.head)
                // cmark-gfm は段落の直後(空行なし)にテーブルが続くとき、段落の最終行を
                // ヘッダー行として奪う一方で Table の sourcepos を段落の先頭にし、Head や
                // 段落内インライン要素の位置も壊す。区切り行の位置からヘッダー行を特定し、
                // テーブルレンジ(と Head)をそこへクランプして、飲み込まれた段落行を
                // テーブル/マーカー扱いしないようにする(段落側のインライン装飾は失われる)。
                if let delimiterLine = tableDelimiterLine(in: range),
                   delimiterLine.lineIndex > 1 {
                    let headerLine = text.lineRange(
                        for: NSRange(location: delimiterLine.range.location - 1, length: 0))
                    // ヘッダー行の内容の先頭から(行頭の空白は含めない: リスト項目の中のテーブルが行頭から始まる
                    // テーブルに見えないように。cmark 自身のレンジも空白を含まない)
                    var start = headerLine.location
                    while start < NSMaxRange(headerLine),
                          text.character(at: start) == ASCII.space || text.character(at: start) == ASCII.tab {
                        start += 1
                    }
                    range = NSRange(location: start, length: NSMaxRange(range) - start)
                    headRange = clippedLineRange(at: start, within: range)
                }
                blockSpans.append(HighlightSpan(range: range, kind: .table))
                if let headRange, headRange.length > 0 {
                    blockSpans.append(HighlightSpan(range: headRange, kind: .tableHeader))
                }
                appendTableMarkers(in: range)
                if let table = MarkdownTableParser.parse(range: range, in: text) {
                    tables.append(table)
                    currentTable = table
                }
            }
            tableDepth += 1
            descendInto(table)
            tableDepth -= 1
            currentTable = nil
        }

        /// テーブルレンジ内で最初に現れる区切り行("|---|:--:|" 等)。
        /// lineIndex はレンジ先頭行を 0 とする行番号。正常なテーブルでは 1 になる。
        private func tableDelimiterLine(in range: NSRange) -> (range: NSRange, lineIndex: Int)? {
            var location = range.location
            let end = NSMaxRange(range)
            var lineIndex = 0
            while location < end {
                let line = clippedLineRange(at: location, within: range)
                if lineIndex > 0, isTableDelimiterLine(line) {
                    return (line, lineIndex)
                }
                let fullLine = text.lineRange(for: NSRange(location: location, length: 0))
                if NSMaxRange(fullLine) <= location { break }
                location = NSMaxRange(fullLine)
                lineIndex += 1
            }
            return nil
        }

        /// GFM の区切り行か(判定は `MarkdownTableParser` と共有)。
        private func isTableDelimiterLine(_ line: NSRange) -> Bool {
            MarkdownTableParser.delimiterAlignments(line: line, in: text) != nil
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
            let delimiter = symmetricDelimiterLength(in: range, character: ASCII.backtick)
            if delimiter > 0 {
                appendSymmetricMarkers(in: range, length: delimiter)
            }
        }

        mutating func visitLink(_ link: Link) {
            if let range = nsRange(of: link), range.length > 0 {
                inlineSpans.append(HighlightSpan(range: range, kind: .link))
                appendLinkMarkers(in: range, link: link)
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
                let delimiter = symmetricDelimiterLength(in: range, character: ASCII.tilde)
                if delimiter > 0 {
                    appendSymmetricMarkers(in: range, length: delimiter)
                }
            }
            descendInto(strikethrough)
        }

        // MARK: ヘルパー

        private mutating func appendDelimited(_ markup: Markup, kind: SyntaxKind, delimiterLength: Int) {
            guard let range = nsRange(of: markup), range.length >= delimiterLength * 2 else { return }
            inlineSpans.append(HighlightSpan(range: range, kind: kind))
            appendSymmetricMarkers(in: range, length: delimiterLength)
        }

        /// range の先頭と末尾 length 文字ずつを構文マーカーにする(強調・コード・打ち消し線で共用)。
        private mutating func appendSymmetricMarkers(in range: NSRange, length: Int) {
            appendConcealableMarker(NSRange(location: range.location, length: length))
            appendConcealableMarker(NSRange(location: NSMaxRange(range) - length, length: length))
        }

        /// Live Preview で隠せる構文マーカー(`.syntaxMarker` スパンにも載せる)。
        private mutating func appendConcealableMarker(_ range: NSRange) {
            markerSpans.append(HighlightSpan(range: range, kind: .syntaxMarker))
            concealableMarkers.append(range)
        }

        /// リンク記法のマーカー: 先頭の "["(自動リンクなら "<")と、リンクテキスト末尾から記法末尾まで
        /// (インライン形式 "](url)"、参照形式 "][ref]"、自動リンクの ">")。裸の URL(テキストと
        /// レンジが一致する)や、子ノードの位置が取れないリンクにはマーカーを付けない。
        private mutating func appendLinkMarkers(in range: NSRange, link: Link) {
            let first = text.character(at: range.location)
            guard first == ASCII.leftBracket || first == ASCII.lessThan else { return }
            let childRanges = link.children.compactMap { nsRange(of: $0) }
            let textEnd: Int
            if let childEnd = childRanges.map(NSMaxRange).max() {
                textEnd = childEnd
            } else if first == ASCII.leftBracket, range.length > 2,
                      text.character(at: range.location + 1) == ASCII.rightBracket {
                // 空ラベルのリンク "[](url)": 子ノードが無いので "]" の位置から閉じ側にする
                textEnd = range.location + 1
            } else {
                return
            }
            guard textEnd > range.location, textEnd < NSMaxRange(range) else { return }
            appendConcealableMarker(NSRange(location: range.location, length: 1))
            appendConcealableMarker(NSRange(location: textEnd, length: NSMaxRange(range) - textEnd))
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
        /// CommonMark の ATX 見出しは "#" 列の直後が空白か行末でなければならない
        /// ("#hashtag\n===" は "#" で始まる Setext 見出し)。
        private func leadingHashMarkerLength(in range: NSRange) -> Int {
            let end = NSMaxRange(range)
            var i = range.location
            var count = 0
            while i < end, count < 6, text.character(at: i) == ASCII.hash {
                count += 1
                i += 1
            }
            guard count > 0 else { return 0 }
            guard i < end else { return count }
            switch text.character(at: i) {
            case ASCII.space, ASCII.tab:
                return count + 1
            case ASCII.newline, ASCII.carriageReturn:
                return count
            default:
                return 0
            }
        }

        /// ATX 見出しの閉じ側 "#" 列(+ 直前のスペース 1 個以上)のレンジ。行末の空白を除いた位置から
        /// 逆に "#" を数え、その直前が空白でなければ(本文の "#"、"\#" エスケープ)閉じ側ではない。
        /// 開き側のマーカーの直後から始まる列("# #" のような空見出し)は開き側のスペースの後から数える。
        private func closingHashMarkerRange(in range: NSRange, afterOpening openingLength: Int) -> NSRange? {
            let contentStart = range.location + openingLength
            var end = NSMaxRange(range)
            while end > contentStart, isSpaceOrTab(text.character(at: end - 1)) { end -= 1 }
            var i = end
            while i > contentStart, text.character(at: i - 1) == ASCII.hash { i -= 1 }
            guard i < end else { return nil }
            var start = i
            if start > contentStart {
                guard isSpaceOrTab(text.character(at: start - 1)) else { return nil }
                while start > contentStart, isSpaceOrTab(text.character(at: start - 1)) { start -= 1 }
            }
            return NSRange(location: start, length: end - start)
        }

        /// location からその行の内容末尾(改行を含まない)までのレンジ。
        private func lineContentRange(from location: Int) -> NSRange {
            var contentsEnd = 0
            text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            return NSRange(location: location, length: max(0, contentsEnd - location))
        }

        private func isSpaceOrTab(_ character: unichar) -> Bool {
            character == ASCII.space || character == ASCII.tab
        }

        /// location を含む行のレンジを range 内にクリップし、末尾の改行(LF / CR / CRLF 等)を除いて返す。
        private func clippedLineRange(at location: Int, within range: NSRange) -> NSRange {
            var lineStart = 0
            var contentsEnd = 0
            text.getLineStart(
                &lineStart, end: nil, contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0))
            return NSIntersectionRange(NSRange(location: lineStart, length: contentsEnd - lineStart), range)
        }

        /// テーブルレンジ内のパイプ("\|" エスケープを除く)と区切り行をマーカー化する。
        /// GFM テーブルはヘッダー 1 行 + 区切り行 1 行 + ボディという固定構造のため、
        /// レンジ内の 2 行目を区切り行("---|---" 等)として行全体をマーカーにする
        /// (区切り行は AST の Head にも Body にも含まれない)。
        private mutating func appendTableMarkers(in range: NSRange) {
            let pipe = ASCII.pipe
            let backslash = ASCII.backslash
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

        /// フェンス行か: 先頭の空白(CommonMark はフェンスの前に最大 3 個のスペースを許す)を
        /// 読み飛ばした位置から "```" / "~~~" が始まる。line はコードブロックレンジで
        /// クリップ済みなので、開始フェンスは range.location(インデント後)から始まる。
        private func isFenceLine(_ line: NSRange) -> Bool {
            var i = line.location
            let end = NSMaxRange(line)
            var leadingSpaces = 0
            while i < end, text.character(at: i) == ASCII.space, leadingSpaces < 3 {
                i += 1
                leadingSpaces += 1
            }
            guard i + 3 <= end else { return false }
            let first = text.character(at: i)
            guard first == ASCII.backtick || first == ASCII.tilde else { return false }
            return text.character(at: i + 1) == first && text.character(at: i + 2) == first
        }

        /// blockQuote の子孫にある BlockQuote のレンジ(ネストの深さの判定用)。
        private func nestedBlockQuoteRanges(in blockQuote: BlockQuote) -> [NSRange] {
            var ranges: [NSRange] = []
            func collect(_ markup: Markup) {
                for child in markup.children {
                    if child is BlockQuote, let range = nsRange(of: child), range.length > 0 { ranges.append(range) }
                    collect(child)
                }
            }
            collect(blockQuote)
            return ranges
        }

        /// range 内の各行頭にある ">"(+ 直後のスペース 1 個)をマーカーとして追加(ネスト分も拾う)。
        /// 先頭行はレンジ先頭(外側コンテナの接頭辞の直後)から走査し、以降の行では
        /// 外側コンテナぶんのインデント + 3 個までのスペースを読み飛ばす。
        /// 1 行あたりのマーカー数は、その行を含む引用(最外 + ネスト)の数まで: 引用内のコードブロックの
        /// "> ```\n> > literal" では 2 個目の ">" はコード本文なので隠さない。
        private mutating func appendQuoteMarkers(in range: NSRange, nestedQuoteRanges: [NSRange]) {
            let space = ASCII.space
            let gt = ASCII.greaterThan
            var location = range.location
            let end = NSMaxRange(range)
            let firstLine = text.lineRange(for: NSRange(location: range.location, length: 0))
            let containerIndent = range.location - firstLine.location
            var isFirstLine = true
            while location < end {
                let line = text.lineRange(for: NSRange(location: location, length: 0))
                let lineEnd = min(NSMaxRange(line), end)
                var i = isFirstLine ? range.location : line.location
                let allowedSpaces = isFirstLine ? 3 : containerIndent + 3
                var leadingSpaces = 0
                while i < lineEnd, text.character(at: i) == space, leadingSpaces < allowedSpaces {
                    i += 1
                    leadingSpaces += 1
                }
                let lineContent = NSRange(location: line.location, length: lineEnd - line.location)
                var remaining = 1 + nestedQuoteRanges.count(where: { NSIntersectionRange($0, lineContent).length > 0 })
                while i < lineEnd, remaining > 0, text.character(at: i) == gt {
                    // CommonMark の引用マーカーは ">" と直後のスペース 1 個(あれば)
                    let start = i
                    i += 1
                    if i < lineEnd, text.character(at: i) == space { i += 1 }
                    appendConcealableMarker(NSRange(location: start, length: i - start))
                    remaining -= 1
                }
                if NSMaxRange(line) <= location { break }
                location = NSMaxRange(line)
                isFirstLine = false
            }
        }

        /// リストアイテム先頭のマーカー("-" "*" "+" または "1." "1)")のレンジ。
        private func listMarkerRange(in range: NSRange) -> NSRange? {
            let end = NSMaxRange(range)
            var i = range.location
            while i < end, text.character(at: i) == ASCII.space { i += 1 }
            guard i < end else { return nil }
            let start = i
            let c = text.character(at: i)
            if c == ASCII.dash || c == ASCII.asterisk || c == ASCII.plus {
                i += 1
            } else {
                while i < end, ASCII.isDigit(text.character(at: i)) { i += 1 }
                guard i > start, i < end else { return nil }
                guard text.character(at: i) == ASCII.period || text.character(at: i) == ASCII.rightParen
                else { return nil }
                i += 1
            }
            return NSRange(location: start, length: i - start)
        }

        /// リストマーカー直後の "[ ]" / "[x]" / "[X]"(3 文字)のレンジ。なければ nil。
        /// 呼び出し側で listItem.checkbox の存在を確認してから使うこと
        /// (checkbox 非 nil ならパーサーが認めた実チェックボックスが必ず存在する)。
        private func checkboxRange(after marker: NSRange, within range: NSRange) -> NSRange? {
            let end = NSMaxRange(range)
            var i = NSMaxRange(marker)
            while i < end, text.character(at: i) == ASCII.space { i += 1 }
            guard i + 3 <= end,
                  text.character(at: i) == ASCII.leftBracket,
                  text.character(at: i + 2) == ASCII.rightBracket else { return nil }
            return NSRange(location: i, length: 3)
        }

        /// 画像記法のマーカー: 先頭の "![" と、alt 末尾から記法末尾まで
        /// (インライン形式 "](url)" と参照形式 "][ref]" の両方をカバーする)。
        private mutating func appendImageMarkers(in range: NSRange, image: Markdown.Image) {
            appendConcealableMarker(NSRange(location: range.location, length: 2))
            var altEnd = range.location + 2
            for child in image.children {
                if let childRange = nsRange(of: child) {
                    altEnd = max(altEnd, NSMaxRange(childRange))
                }
            }
            if altEnd < NSMaxRange(range) {
                appendConcealableMarker(NSRange(location: altEnd, length: NSMaxRange(range) - altEnd))
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
        ///
        /// Text ノードの全文字位置から呼ばれる(10k 行文書で約 20 万回)ため、
        /// 文字列生成・小文字化・配列確保を一切行わず UTF-16 コード単位を直接比較する。
        /// 旧実装(`substring` + `lowercased()`)は URL を含まない文書でも 1 パースあたり
        /// 約 150ms(debug)を消費していた。
        ///
        /// 検出対象は仕様どおり http(s) 固定。スキーム名は大文字小文字を区別しない
        /// (RFC 3986 §3.1)ので ASCII 大文字だけを小文字に畳む。非 ASCII の見かけ上の
        /// 同形文字(U+017F ſ 等)は Unicode 小文字化でも `s` にならないため、旧実装と
        /// 一致結果は同じ。
        private func urlSchemeLength(at location: Int, end: Int) -> Int? {
            // "http://" の 7 単位に満たなければスキームではない。ほぼ全位置は次の
            // 先頭文字判定で抜ける。
            guard location + 7 <= end else { return nil }
            guard lowerASCII(text.character(at: location)) == 0x68 /* h */,
                  lowerASCII(text.character(at: location + 1)) == 0x74 /* t */,
                  lowerASCII(text.character(at: location + 2)) == 0x74 /* t */,
                  lowerASCII(text.character(at: location + 3)) == 0x70 /* p */
            else { return nil }
            let colon: unichar = 0x3A, slash: unichar = 0x2F
            // "http://"
            if text.character(at: location + 4) == colon,
               text.character(at: location + 5) == slash,
               text.character(at: location + 6) == slash {
                return 7
            }
            // "https://"
            if location + 8 <= end,
               lowerASCII(text.character(at: location + 4)) == 0x73 /* s */,
               text.character(at: location + 5) == colon,
               text.character(at: location + 6) == slash,
               text.character(at: location + 7) == slash {
                return 8
            }
            return nil
        }

        /// ASCII 大文字(A–Z)だけを小文字に畳む。それ以外はそのまま返す。
        private func lowerASCII(_ c: unichar) -> unichar {
            (c >= 0x41 && c <= 0x5A) ? c + 0x20 : c
        }

        /// URL の終端文字: 空白・制御文字・"<"・非 ASCII(全角文字等)。
        private func isURLTerminator(_ c: unichar) -> Bool {
            c <= 0x20 || c == unichar(UnicodeScalar("<").value) || c >= 0x7F
        }

        private func isASCIIAlphanumeric(_ c: unichar) -> Bool {
            ASCII.isAlphanumeric(c)
        }

        /// ベア URL 末尾から落とす約物
        private static let trailingURLPunctuation: Set<unichar> = Set(".,;:!?'\"".utf16)

        /// 末尾の約物をトリムする。")" は URL 内の括弧バランスを見て閉じ超過分のみ落とす。
        private func trimTrailingPunctuation(from start: Int, to end: Int) -> Int {
            let trailing = Self.trailingURLPunctuation
            let open = ASCII.leftParen
            let close = ASCII.rightParen
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
