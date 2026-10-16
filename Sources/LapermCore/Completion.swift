import Foundation

/// Completion の種類(Laperm ADR 0047)。
public enum CompletionKind: Hashable, Sendable {
    /// `[[` の後ろ: Note のタイトル。
    case noteTitle
    /// `[[Note#` の後ろ: その Note の見出し。`note` は `[[` と `#` の間の文字(前後の空白を除く)で、空なら今の Note(`[[#`)。
    case heading(note: String)
    /// Front Matter の `tags` / `tag` の値: 既存の Tag。
    case tag
}

/// 打ちかけの文字と種類。編集部品が打鍵のたびに検出し(`CompletionTrigger.detect`)、候補プロバイダに渡す。
public struct CompletionQuery: Hashable, Sendable {
    public var kind: CompletionKind
    /// 打ちかけの文字(IME の未確定文字も含む)。`[[` の直後は空。前後の空白は除いていない(照合する側が除く)。
    public var text: String
    /// `text` の文書内の UTF-16 レンジ(確定で置き換える範囲)。
    public var range: NSRange
    /// きっかけの位置(`[[` の先頭、Tag の値の語の先頭)。Esc で閉じた後、同じきっかけでは開き直さない鍵。
    public var anchor: Int

    public init(kind: CompletionKind, text: String, range: NSRange, anchor: Int) {
        self.kind = kind
        self.text = text
        self.range = range
        self.anchor = anchor
    }
}

/// Completion List の 1 行。
public struct CompletionItem: Hashable, Sendable, Identifiable {
    /// 主の文字(Note のタイトル、見出し、Tag)。
    public var title: String
    /// 副文字(Note のフォルダのパス、見出しのレベル `H2`)。無ければ nil。
    public var detail: String?
    /// 確定で打ちかけの文字と置き換わる文字(解決で勝つ Note ならタイトル、負ける Note ならパス)。
    public var insertionText: String

    public init(title: String, detail: String? = nil, insertionText: String) {
        self.title = title
        self.detail = detail
        self.insertionText = insertionText
    }

    public var id: String { "\(insertionText)\u{1F}\(detail ?? "")" }
}

/// きっかけの検出と確定の編集(純粋関数、Laperm ADR 0047)。
///
/// 検出は行の文字の走査で行い、計画(`HighlightPlan`)は出さない場所の判定の補助に使う。計画は編集と交差するスパンを捨てた
/// 状態で届く(再パース前)ので、コードフェンスとインラインコードは文字でも数える。
public enum CompletionTrigger {
    /// Front Matter の Tag のキー(大文字小文字は区別しない)。
    public static let tagKeys: Set<String> = ["tags", "tag"]

    /// キャレット(選択は無い)の位置で Completion が始まるか。始まらなければ nil。
    public static func detect(text: NSString, caret: Int, plan: HighlightPlan) -> CompletionQuery? {
        guard caret >= 0, caret <= text.length else { return nil }
        let line = lineContentRange(containing: caret, in: text)
        if let frontMatter = FrontMatterParser.parse(text) {
            // Front Matter の中は Tag の値の位置だけ(他の Property、フェンスの行では出さない)
            guard line.location > NSMaxRange(frontMatter.openingFenceRange), NSMaxRange(line) < frontMatter.closingFenceRange.location
            else { return wikiLinkQuery(text: text, caret: caret, line: line, plan: plan) }
            return tagQuery(text: text, caret: caret, line: line, frontMatter: frontMatter)
        }
        return wikiLinkQuery(text: text, caret: caret, line: line, plan: plan)
    }

    /// 確定: 打ちかけの文字を候補で置き換える。Wiki Link は `]]` まで整え(既にある `]]` は二重にしない)、キャレットは `]]` の後ろ。
    /// 直後に `|`(Alias)や `#`(見出し)が続く整ったリンクの中なら `]]` は足さず、キャレットは入れた文字の後ろ。
    /// Tag は語だけを置き換える(閉じ括弧やカンマには触れない)。レンジが文書の外なら nil。
    public static func command(for query: CompletionQuery, item: CompletionItem, in text: NSString) -> EditCommand? {
        guard query.range.location != NSNotFound, NSMaxRange(query.range) <= text.length else { return nil }
        var replacement = item.insertionText
        var caret = query.range.location + (replacement as NSString).length
        switch query.kind {
        case .tag:
            break
        case .noteTitle, .heading:
            let line = lineContentRange(containing: NSMaxRange(query.range), in: text)
            let afterRange = NSRange(location: NSMaxRange(query.range), length: max(0, NSMaxRange(line) - NSMaxRange(query.range)))
            let after = text.substring(with: afterRange)
            if after.hasPrefix("]]") {
                caret += 2
            } else if after.hasPrefix("|") || after.hasPrefix("#"), after.contains("]]") {
                // 整ったリンクの中: Alias / 見出しはそのまま
            } else {
                replacement += "]]"
                caret += 2
            }
        }
        return EditCommand(
            replacementRange: query.range, replacementString: replacement,
            selectedRange: NSRange(location: caret, length: 0))
    }

    // MARK: - Wiki Link(`[[` / `[[Note#`)

    private static func wikiLinkQuery(text: NSString, caret: Int, line: NSRange, plan: HighlightPlan) -> CompletionQuery? {
        // 行の中でキャレットより前の、閉じていない最後の `[[`。間に `[` `]` `|` があれば Wiki Link の打ちかけではない
        var start: Int?
        var i = caret - 1
        while i >= line.location {
            let c = text.character(at: i)
            if c == ASCII.rightBracket || c == ASCII.pipe { return nil }
            if c == ASCII.leftBracket {
                guard i - 1 >= line.location, text.character(at: i - 1) == ASCII.leftBracket else { return nil }
                start = i - 1
                break
            }
            i -= 1
        }
        guard let start else { return nil }
        // エスケープ(`\[[`)と埋め込み(`![[`)は Wiki Link ではない
        if isEscaped(at: start, in: text, lineStart: line.location) { return nil }
        if start > line.location, text.character(at: start - 1) == ASCII.exclamation { return nil }
        guard !isInsideInlineCode(before: start, in: text, lineStart: line.location, plan: plan),
              !isInsideMarkdownLinkDestination(before: start, in: text, lineStart: line.location),
              !isInsideCodeBlock(caret: caret, line: line, in: text, plan: plan)
        else { return nil }
        let innerRange = NSRange(location: start + 2, length: caret - start - 2)
        let inner = text.substring(with: innerRange)
        if let hash = inner.firstIndex(of: "#") {
            let note = inner[..<hash].trimmingCharacters(in: .whitespaces)
            let typed = String(inner[inner.index(after: hash)...])
            let hashOffset = (String(inner[..<hash]) as NSString).length
            return CompletionQuery(
                kind: .heading(note: note), text: typed,
                range: NSRange(location: innerRange.location + hashOffset + 1, length: innerRange.length - hashOffset - 1),
                anchor: start)
        }
        return CompletionQuery(kind: .noteTitle, text: inner, range: innerRange, anchor: start)
    }

    /// `location` の直前のバックスラッシュが奇数個なら CommonMark のエスケープ。
    private static func isEscaped(at location: Int, in text: NSString, lineStart: Int) -> Bool {
        var count = 0
        var i = location
        while i > lineStart, text.character(at: i - 1) == ASCII.backslash {
            count += 1
            i -= 1
        }
        return count % 2 == 1
    }

    /// 行頭から `location` までのエスケープされていないバッククォートが奇数個(開いたまま)なら、インラインコードの中。
    /// 計画の `.inlineCode` のスパン(再パースが済んでいる部分)も見る。
    private static func isInsideInlineCode(before location: Int, in text: NSString, lineStart: Int, plan: HighlightPlan) -> Bool {
        if plan.spans.contains(where: { $0.kind == .inlineCode && NSLocationInRange(location, $0.range) }) { return true }
        var count = 0
        var i = lineStart
        while i < location {
            if text.character(at: i) == ASCII.backtick, !isEscaped(at: i, in: text, lineStart: lineStart) { count += 1 }
            i += 1
        }
        return count % 2 == 1
    }

    /// 行頭から `location` までで最後の `](` の後ろに `)` が無ければ、Markdown Link の URL の中。
    private static func isInsideMarkdownLinkDestination(before location: Int, in text: NSString, lineStart: Int) -> Bool {
        var i = location - 1
        while i > lineStart {
            let c = text.character(at: i)
            if c == ASCII.rightParen { return false }
            if c == ASCII.leftParen, text.character(at: i - 1) == ASCII.rightBracket { return true }
            i -= 1
        }
        return false
    }

    /// コードブロックの中か: 計画のコードブロック(インデント型も)と、文書の先頭から行の前までのフェンスの行(```` ``` ````、`~~~`、
    /// 3 つまでの空白のインデント)の数が奇数(開いたまま)。
    private static func isInsideCodeBlock(caret: Int, line: NSRange, in text: NSString, plan: HighlightPlan) -> Bool {
        if plan.codeBlocks.contains(where: { caret > $0.range.location && caret <= NSMaxRange($0.range) }) { return true }
        var fences = 0
        var location = 0
        while location < line.location {
            var end = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            if isFenceLine(NSRange(location: location, length: contentsEnd - location), in: text) { fences += 1 }
            guard end > location else { break }
            location = end
        }
        return fences % 2 == 1
    }

    private static func isFenceLine(_ line: NSRange, in text: NSString) -> Bool {
        var i = line.location
        let end = NSMaxRange(line)
        var indent = 0
        while i < end, text.character(at: i) == ASCII.space, indent < 3 {
            indent += 1
            i += 1
        }
        guard i + 2 < end else { return false }
        let c = text.character(at: i)
        guard c == ASCII.backtick || c == ASCII.tilde else { return false }
        return text.character(at: i + 1) == c && text.character(at: i + 2) == c
    }

    // MARK: - Tag(Front Matter の `tags` の値)

    private static func tagQuery(text: NSString, caret: Int, line: NSRange, frontMatter: FrontMatter) -> CompletionQuery? {
        let lineText = text.substring(with: line) as NSString
        let caretInLine = caret - line.location
        let segmentStart: Int
        if let valueStart = tagKeyValueStart(in: lineText) {
            // `tags: a, b` / `tags: [a, b]`: キャレットより前の最後の区切り(`,` か `[`)の後ろ。`]` を越えていたら値の外
            guard caretInLine >= valueStart else { return nil }
            var start = valueStart
            var i = valueStart
            var sawOpening = false
            while i < caretInLine {
                let c = lineText.character(at: i)
                if c == ASCII.leftBracket, !sawOpening {
                    sawOpening = true
                    start = i + 1
                } else if c == ASCII.rightBracket {
                    return nil
                } else if c == 0x2C {  // `,`
                    start = i + 1
                }
                i += 1
            }
            segmentStart = start
        } else if let itemStart = listItemContentStart(in: lineText), isItemOfTagList(line: line, in: text, frontMatter: frontMatter) {
            guard caretInLine >= itemStart else { return nil }
            segmentStart = itemStart
        } else {
            return nil
        }
        // 語: 先頭の空白、引用符 1 つ、`#` 1 つを除いた残り。Tag の文字だけから成り、空でないときだけ
        var wordStart = segmentStart
        while wordStart < caretInLine, lineText.character(at: wordStart) == ASCII.space || lineText.character(at: wordStart) == ASCII.tab {
            wordStart += 1
        }
        if wordStart < caretInLine {
            let c = lineText.character(at: wordStart)
            if c == 0x22 || c == 0x27 { wordStart += 1 }  // `"` / `'`
        }
        if wordStart < caretInLine, lineText.character(at: wordStart) == ASCII.hash { wordStart += 1 }
        guard wordStart < caretInLine else { return nil }
        let word = lineText.substring(with: NSRange(location: wordStart, length: caretInLine - wordStart))
        guard word.unicodeScalars.allSatisfy(isTagScalar) else { return nil }
        let range = NSRange(location: line.location + wordStart, length: caretInLine - wordStart)
        return CompletionQuery(kind: .tag, text: word, range: range, anchor: range.location)
    }

    /// `tags:` / `tag:`(インデント無し、大文字小文字は区別しない)の行なら、コロンの直後の位置。
    private static func tagKeyValueStart(in line: NSString) -> Int? {
        let colon = line.range(of: ":")
        guard colon.location != NSNotFound, colon.location > 0 else { return nil }
        let key = line.substring(to: colon.location)
        guard !key.hasPrefix(" "), !key.hasPrefix("\t"), tagKeys.contains(key.trimmingCharacters(in: .whitespaces).lowercased()) else { return nil }
        let after = colon.location + 1
        if after < line.length {
            let c = line.character(at: after)
            guard c == ASCII.space || c == ASCII.tab else { return nil }
        }
        return after
    }

    /// `- 項目` の行なら `-` の直後の位置。
    private static func listItemContentStart(in line: NSString) -> Int? {
        var i = 0
        while i < line.length, line.character(at: i) == ASCII.space || line.character(at: i) == ASCII.tab { i += 1 }
        guard i < line.length, line.character(at: i) == ASCII.dash else { return nil }
        let after = i + 1
        if after < line.length {
            let c = line.character(at: after)
            guard c == ASCII.space || c == ASCII.tab else { return nil }
        }
        return after
    }

    /// `line`(`- 項目` の行)の上をたどり、他の項目・コメント・空行を飛ばして最初に着く行が値の無い `tags:` なら、その Tag のリストの項目。
    private static func isItemOfTagList(line: NSRange, in text: NSString, frontMatter: FrontMatter) -> Bool {
        var location = line.location
        while location > NSMaxRange(frontMatter.openingFenceRange) {
            let previous = lineContentRange(containing: location - 1, in: text)
            let content = text.substring(with: previous) as NSString
            let trimmed = (content as String).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || listItemContentStart(in: content) != nil {
                location = previous.location
                continue
            }
            guard let valueStart = tagKeyValueStart(in: content) else { return false }
            let rest = content.substring(from: valueStart).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty || rest.hasPrefix("#")
        }
        return false
    }

    /// Obsidian が Tag に許す文字: 字(どの言語でも)、結合記号、数字、`_`、`-`、`/`(Laperm の `TagName.isTagScalar` と同じ)。
    static func isTagScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" || scalar == "-" || scalar == "/" { return true }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    // MARK: - 行

    /// `location` を含む行の内容のレンジ(改行を含まない)。
    static func lineContentRange(containing location: Int, in text: NSString) -> NSRange {
        var start = 0
        var contentsEnd = 0
        text.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: min(location, text.length), length: 0))
        return NSRange(location: start, length: max(0, contentsEnd - start))
    }
}
