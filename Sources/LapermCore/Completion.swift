import Foundation

/// Completion の種類(Laperm ADR 0047)。
public enum CompletionKind: Hashable, Sendable {
    /// `[[` の後ろ: Note のタイトル。
    case noteTitle
    /// `[[Note#` の後ろ: その Note の見出し。`note` は `[[` と `#` の間の文字(前後の空白を除く)で、空なら今の Note(`[[#`)。
    case heading(note: String)
    /// Front Matter の `tags` / `tag` の値: 既存の Tag。
    case tag
    /// `![[` の後ろ: Attachment の名前(Laperm ADR 0054)。確定の編集は `.noteTitle` と同じ(`]]` まで整える)。
    case attachment
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
    /// 行の先頭に出す SF Symbol の名前(Attachment の候補の `paperclip` / `photo`、Laperm ADR 0054)。nil なら記号なし。
    public var symbol: String?

    public init(title: String, detail: String? = nil, insertionText: String, symbol: String? = nil) {
        self.title = title
        self.detail = detail
        self.insertionText = insertionText
        self.symbol = symbol
    }

    public var id: String { "\(insertionText)\u{1F}\(detail ?? "")" }
}

/// きっかけの検出と確定の編集(純粋関数、Laperm ADR 0047)。
///
/// 検出は行の文字の走査で行う。計画(`HighlightPlan`)は出さない場所の判定に使うが、打鍵の直後の計画は編集と交差するスパン
/// (打っている最中のコードブロック・インラインコード・Front Matter)を捨てた状態なので、`planIsCurrent` が false のときは
/// コードフェンス・バッククォート・Front Matter を文字でも読む(true なら計画を信じて文字の走査を省く)。
public enum CompletionTrigger {
    /// Front Matter の Tag のキー(大文字小文字は区別しない)。
    public static let tagKeys: Set<String> = ["tags", "tag"]

    /// キャレット(選択は無い。IME の変換中は未確定文字の末尾)の位置で Completion が始まるか。始まらなければ nil。
    /// `range` は打ちかけの語の全体(キャレットの後ろに語の続きがあればそれも: `[[Wki]]` の `W` の後ろで確定すれば `ki` ごと置き換わる)、
    /// `text` はキャレットまでの部分(絞り込みに使う)。
    public static func detect(text: NSString, caret: Int, plan: HighlightPlan, planIsCurrent: Bool = false) -> CompletionQuery? {
        guard caret >= 0, caret <= text.length else { return nil }
        let line = lineContentRange(containing: caret, in: text)
        if let frontMatter = planIsCurrent ? plan.frontMatter : FrontMatterParser.parse(text) {
            // Front Matter の中は Tag の値の位置だけ(他の Property、フェンスの行では出さない)
            guard line.location > NSMaxRange(frontMatter.openingFenceRange), NSMaxRange(line) < frontMatter.closingFenceRange.location
            else { return wikiLinkQuery(text: text, caret: caret, line: line, plan: plan, planIsCurrent: planIsCurrent) }
            return tagQuery(text: text, caret: caret, line: line, frontMatter: frontMatter)
        }
        return wikiLinkQuery(text: text, caret: caret, line: line, plan: plan, planIsCurrent: planIsCurrent)
    }

    /// 確定: 打ちかけの語を候補で置き換える。Wiki Link は `]]` まで整え(既にある `]]` は二重にしない)、キャレットは `]]` の後ろ
    /// (整ったリンクの中で `|alias` / `#heading` が続いていても、その `]]` の後ろ)。Tag は語だけを置き換える(閉じ括弧やカンマには
    /// 触れない)。レンジが文書の外なら nil。
    public static func command(for query: CompletionQuery, item: CompletionItem, in text: NSString) -> EditCommand? {
        guard query.range.location != NSNotFound, NSMaxRange(query.range) <= text.length else { return nil }
        var replacement = item.insertionText
        var caret = query.range.location + (replacement as NSString).length
        switch query.kind {
        case .tag:
            break
        case .noteTitle, .heading, .attachment:
            let line = lineContentRange(containing: NSMaxRange(query.range), in: text)
            let afterRange = NSRange(location: NSMaxRange(query.range), length: max(0, NSMaxRange(line) - NSMaxRange(query.range)))
            let after = text.substring(with: afterRange) as NSString
            if after.hasPrefix("]]") {
                caret += 2
            } else if after.hasPrefix("|") || after.hasPrefix("#"), case let closing = after.range(of: "]]"), closing.location != NSNotFound {
                // 整ったリンクの中: Alias / 見出しはそのまま、キャレットはその `]]` の後ろ
                caret += NSMaxRange(closing)
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

    private static func wikiLinkQuery(text: NSString, caret: Int, line: NSRange, plan: HighlightPlan, planIsCurrent: Bool) -> CompletionQuery? {
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
        // エスケープ(`\[[`)は Wiki Link ではない。埋め込み(`![[`)は Attachment の候補(ADR 0054)。
        if isEscaped(at: start, in: text, lineStart: line.location) { return nil }
        let isEmbed = start > line.location && text.character(at: start - 1) == ASCII.exclamation
            && !isEscaped(at: start - 1, in: text, lineStart: line.location)
        guard !isInsideInlineCode(before: start, in: text, lineStart: line.location, plan: plan, planIsCurrent: planIsCurrent),
              !isInsideMarkdownLinkDestination(before: start, in: text, lineStart: line.location),
              !isInsideCodeBlock(caret: caret, line: line, in: text, plan: plan, planIsCurrent: planIsCurrent)
        else { return nil }
        let typedRange = NSRange(location: start + 2, length: caret - start - 2)
        let typed = text.substring(with: typedRange)
        if isEmbed {
            // 埋め込みは名前だけ(`#` も `|` も候補を閉じる)。きっかけは `!` の位置。
            if typed.contains("#") { return nil }
            let end = tokenEnd(from: caret, line: line, in: text, stopping: [ASCII.rightBracket, ASCII.pipe, ASCII.hash])
            return CompletionQuery(
                kind: .attachment, text: typed, range: NSRange(location: typedRange.location, length: end - typedRange.location),
                anchor: start - 1)
        }
        if let hash = typed.firstIndex(of: "#") {
            let note = typed[..<hash].trimmingCharacters(in: .whitespaces)
            let afterHash = String(typed[typed.index(after: hash)...])
            let headingStart = typedRange.location + (String(typed[..<hash]) as NSString).length + 1
            // 語の続き: `]` か `|` まで
            let end = tokenEnd(from: caret, line: line, in: text, stopping: [ASCII.rightBracket, ASCII.pipe])
            return CompletionQuery(
                kind: .heading(note: note), text: afterHash,
                range: NSRange(location: headingStart, length: end - headingStart), anchor: start)
        }
        // 語の続き: `]`、`|`、`#` まで
        let end = tokenEnd(from: caret, line: line, in: text, stopping: [ASCII.rightBracket, ASCII.pipe, ASCII.hash])
        return CompletionQuery(kind: .noteTitle, text: typed, range: NSRange(location: typedRange.location, length: end - typedRange.location), anchor: start)
    }

    /// キャレットから行末へ、`stopping` のどれかの直前まで。
    private static func tokenEnd(from caret: Int, line: NSRange, in text: NSString, stopping: Set<unichar>) -> Int {
        var end = caret
        while end < NSMaxRange(line), !stopping.contains(text.character(at: end)) { end += 1 }
        return end
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

    /// インラインコードの中か。計画の `.inlineCode` のスパン(確定した計画)と、計画が古いときは行頭から `location` までの
    /// バッククォートの連続を対応付けて(CommonMark: 同じ長さの連続で閉じる)開いたままなら中。改行をまたぐコードスパンは見ない。
    private static func isInsideInlineCode(before location: Int, in text: NSString, lineStart: Int, plan: HighlightPlan, planIsCurrent: Bool) -> Bool {
        if plan.spans.contains(where: { $0.kind == .inlineCode && NSLocationInRange(location, $0.range) }) { return true }
        if planIsCurrent { return false }
        var open: Int?
        var i = lineStart
        while i < location {
            guard text.character(at: i) == ASCII.backtick else {
                i += 1
                continue
            }
            var run = 0
            while i < location, text.character(at: i) == ASCII.backtick {
                run += 1
                i += 1
            }
            if isEscaped(at: i - run, in: text, lineStart: lineStart), run == 1 { continue }
            if let opened = open {
                if opened == run { open = nil }
            } else {
                open = run
            }
        }
        return open != nil
    }

    /// 行頭から `location` までで最後の `](` の後ろの括弧が閉じていなければ、Markdown Link の URL の中(URL の中の対応した括弧は
    /// CommonMark で有効なので深さを数える。エスケープされた括弧は数えない)。
    private static func isInsideMarkdownLinkDestination(before location: Int, in text: NSString, lineStart: Int) -> Bool {
        var depth = 0
        var i = location - 1
        while i > lineStart {
            let c = text.character(at: i)
            if (c == ASCII.rightParen || c == ASCII.leftParen), isEscaped(at: i, in: text, lineStart: lineStart) {
                i -= 1
                continue
            }
            if c == ASCII.rightParen { depth += 1 }
            if c == ASCII.leftParen {
                if depth == 0 { return text.character(at: i - 1) == ASCII.rightBracket }
                depth -= 1
            }
            i -= 1
        }
        return false
    }

    /// コードブロックの中か: 計画のコードブロック(インデント型も、引用の中も)。計画が古いときは文書の先頭から行の前までの
    /// フェンスを追う(開きは 3 つ以上の同じ記号、閉じは同じ記号で開き以上の長さ、どちらも 3 つまでの空白と引用の `>` の後ろ。
    /// 打っている最中のインデント型のコードブロックは計画が捨てているので見つからない: 再パースが済めば出なくなる)。
    private static func isInsideCodeBlock(caret: Int, line: NSRange, in text: NSString, plan: HighlightPlan, planIsCurrent: Bool) -> Bool {
        if plan.codeBlocks.contains(where: { caret > $0.range.location && caret <= NSMaxRange($0.range) }) { return true }
        if planIsCurrent { return false }
        var open: (character: unichar, length: Int)?
        var location = 0
        while location < line.location {
            var end = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            if let fence = fence(in: NSRange(location: location, length: contentsEnd - location), in: text) {
                if let opened = open {
                    if fence.character == opened.character, fence.length >= opened.length, fence.isClosing { open = nil }
                } else {
                    open = (fence.character, fence.length)
                }
            }
            guard end > location else { break }
            location = end
        }
        return open != nil
    }

    /// 行がフェンス(```` ``` ```` / `~~~` 以上、3 つまでの空白と引用の `>` の後ろ)なら記号と長さ。`isClosing` は記号の後ろが空白だけ。
    private static func fence(in line: NSRange, in text: NSString) -> (character: unichar, length: Int, isClosing: Bool)? {
        var i = line.location
        let end = NSMaxRange(line)
        // 引用の `>`(とその後ろの 1 つの空白)を剥がす
        while true {
            var j = i
            var indent = 0
            while j < end, text.character(at: j) == ASCII.space, indent < 3 {
                indent += 1
                j += 1
            }
            guard j < end, text.character(at: j) == ASCII.greaterThan else {
                i = j
                break
            }
            i = j + 1
            if i < end, text.character(at: i) == ASCII.space { i += 1 }
        }
        guard i < end else { return nil }
        let c = text.character(at: i)
        guard c == ASCII.backtick || c == ASCII.tilde else { return nil }
        var length = 0
        while i < end, text.character(at: i) == c {
            length += 1
            i += 1
        }
        guard length >= 3 else { return nil }
        var isClosing = true
        while i < end {
            let rest = text.character(at: i)
            if rest != ASCII.space && rest != ASCII.tab {
                isClosing = false
                break
            }
            i += 1
        }
        return (c, length, isClosing)
    }

    // MARK: - Tag(Front Matter の `tags` の値)

    private static func tagQuery(text: NSString, caret: Int, line: NSRange, frontMatter: FrontMatter) -> CompletionQuery? {
        let lineText = text.substring(with: line) as NSString
        let caretInLine = caret - line.location
        let segmentStart: Int
        if let valueStart = tagKeyValueStart(in: lineText) {
            // `tags: a, b` / `tags: [a, b]`: キャレットより前の最後の区切り(引用符の外の `,` か `[`)の後ろ。`]` を越えていたら値の外、
            // 入れ子の `[` は Tag のリストではない
            guard caretInLine >= valueStart else { return nil }
            var start = valueStart
            var i = valueStart
            var sawOpening = false
            var quote: unichar?
            while i < caretInLine {
                let c = lineText.character(at: i)
                if let open = quote {
                    if c == open { quote = nil }
                } else if c == 0x22 || c == 0x27 {  // `"` / `'`
                    quote = c
                } else if c == ASCII.leftBracket {
                    if sawOpening { return nil }
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
        // 語: 先頭の空白、引用符 1 つ、`#` 1 つを除いた残り。空白の後ろの `#` は YAML のコメント(`tags: #sw`、`- #sw`)で値ではない。
        // Tag の文字だけから成り、空でないときだけ
        var wordStart = segmentStart
        var skippedSpace = false
        while wordStart < caretInLine, lineText.character(at: wordStart) == ASCII.space || lineText.character(at: wordStart) == ASCII.tab {
            wordStart += 1
            skippedSpace = true
        }
        if wordStart < caretInLine {
            let c = lineText.character(at: wordStart)
            if c == 0x22 || c == 0x27 {
                wordStart += 1
                skippedSpace = false
            }
        }
        if wordStart < caretInLine, lineText.character(at: wordStart) == ASCII.hash {
            if skippedSpace { return nil }
            wordStart += 1
        }
        guard wordStart < caretInLine else { return nil }
        let typed = lineText.substring(with: NSRange(location: wordStart, length: caretInLine - wordStart))
        guard typed.unicodeScalars.allSatisfy(isTagScalar) else { return nil }
        // 語の続き(キャレットの後ろの Tag の文字)も置き換える
        var wordEnd = caretInLine
        while wordEnd < lineText.length {
            let c = lineText.character(at: wordEnd)
            guard !UTF16.isSurrogate(c), let scalar = Unicode.Scalar(c), isTagScalar(scalar) else { break }
            wordEnd += 1
        }
        let range = NSRange(location: line.location + wordStart, length: wordEnd - wordStart)
        return CompletionQuery(kind: .tag, text: typed, range: range, anchor: range.location)
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
