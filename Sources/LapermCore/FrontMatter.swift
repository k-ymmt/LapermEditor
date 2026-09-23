import Foundation

/// Note の先頭にある YAML の領域(Laperm CONTEXT.md: Front Matter)と、その中の Property。
///
/// 認識規則は Obsidian に合わせる: 文書の 1 行目がちょうど `---`(先頭の BOM は許す。末尾の空白は無視)で、
/// 閉じも `---` だけの行。閉じが無ければ Front Matter ではない。YAML の `...` と先頭の空行は非対応。
/// 中身は Markdown として解釈されない(`MarkdownParser` がこの領域を空白に置き換えてから swift-markdown
/// に渡す)。
public struct FrontMatter: Hashable, Sendable {
    /// Front Matter に書かれたキー 1 つとその値。解釈できない行は `key == nil` で `.raw` の値になる。
    public struct Property: Hashable, Sendable {
        public enum Value: Hashable, Sendable {
            /// `key: 値`(引用符と行末コメントは外した文字列。値が無ければ空文字列)
            case text(String)
            /// `key: [a, b]`、または `key:` の次行以降の `- 項目`
            case list([String])
            /// 解釈できない行の原文(ネストしたマップ、複数行スカラーなど)。捨てずに表に載せる。
            case raw(String)
        }

        /// キー名。解釈できない行は nil。
        public var key: String?
        public var value: Value
        /// この Property を成す行(複数行のリストは末尾の項目行まで)の UTF-16 レンジ。末尾の改行を含まない。
        public var lineRange: NSRange

        public init(key: String?, value: Value, lineRange: NSRange) {
            self.key = key
            self.value = value
            self.lineRange = lineRange
        }
    }

    /// 開きの `---` の行頭(文書先頭。BOM があればそれを含む)から閉じの `---` の行末(改行を含まない)まで。
    public var range: NSRange
    /// 開きの `---` の行(改行を含まない)。
    public var openingFenceRange: NSRange
    /// 閉じの `---` の行(改行を含まない)。
    public var closingFenceRange: NSRange
    /// 出現順の Property。同じキーが複数回あっても別々に残す(表示専用なので順序と内容を隠さない)。
    public var properties: [Property]

    public init(range: NSRange, openingFenceRange: NSRange, closingFenceRange: NSRange, properties: [Property]) {
        self.range = range
        self.openingFenceRange = openingFenceRange
        self.closingFenceRange = closingFenceRange
        self.properties = properties
    }

    /// 閉じの `---` の行末から次の行頭までを含めた、Front Matter の段落全体の終端(改行込み)。
    /// 文書がここで終わっていれば `NSMaxRange(range)`。
    public func endIncludingNewline(in text: NSString) -> Int {
        guard NSMaxRange(range) <= text.length else { return NSMaxRange(range) }
        return NSMaxRange(text.lineRange(for: NSRange(location: max(0, NSMaxRange(range) - 1), length: 0)))
    }
}

/// Front Matter の認識と、依存を足さない自前の YAML サブセットの読み取り。
///
/// 読めるもの: `key: 値`、`key: [a, b]`、`key:` の次行以降の `- 項目`、引用符付き文字列(`"…"` / `'…'`)、
/// `#` コメント(行全体、または空白に続く行末コメント)。それ以外(ネストしたマップ、`|` / `>` の
/// 複数行スカラー、インデントされた行、コロンの無い行)は「解釈できない行」として原文を残す。
public enum FrontMatterParser {
    private static let bom: unichar = 0xFEFF

    public static func parse(_ text: String) -> FrontMatter? {
        parse(text as NSString)
    }

    public static func parse(_ text: NSString) -> FrontMatter? {
        guard text.length >= 3 else { return nil }
        // 1 行目: ちょうど "---"(BOM は許す)
        let firstLine = lineContent(at: 0, in: text)
        var fenceStart = firstLine.location
        if text.character(at: fenceStart) == bom { fenceStart += 1 }
        guard isFence(NSRange(location: fenceStart, length: NSMaxRange(firstLine) - fenceStart), in: text)
        else { return nil }

        // 先に閉じの `---` を探す(行の判定だけ)。閉じが無ければ Front Matter ではないので、`---` で始まる
        // だけの巨大な文書で全行を Property として読んでから捨てることはしない。
        guard let closingFence = closingFenceLine(after: firstLine, in: text) else { return nil }

        var state = ParseState()
        var location = nextLineStart(after: firstLine, in: text)
        while location < closingFence.location {
            let line = lineContent(at: location, in: text)
            parseLine(line, in: text, into: &state)
            let next = nextLineStart(after: line, in: text)
            guard next > location else { break }
            location = next
        }
        state.flushPendingList()
        return FrontMatter(
            range: NSRange(location: 0, length: NSMaxRange(closingFence)),
            openingFenceRange: firstLine,
            closingFenceRange: closingFence,
            properties: state.properties)
    }

    /// `firstLine` の次の行以降で最初の `---` だけの行(内容レンジ)。無ければ nil。
    private static func closingFenceLine(after firstLine: NSRange, in text: NSString) -> NSRange? {
        var location = nextLineStart(after: firstLine, in: text)
        while location < text.length {
            let line = lineContent(at: location, in: text)
            if isFence(line, in: text) { return line }
            let next = nextLineStart(after: line, in: text)
            guard next > location else { return nil }
            location = next
        }
        return nil
    }

    // MARK: - 行の解釈

    /// 行を順に読むときの状態。ブロック形式のリスト(`key:` の次行以降の `- 項目`)は、項目を別のバッファに
    /// 溜めて閉じるときに Property へ書く(Property の中の配列へ項目ごとに追記すると、共有ストレージの
    /// コピーで項目数の二乗のコストになる)。
    private struct ParseState {
        var properties: [FrontMatter.Property] = []
        /// 値が空だった直近のキーの添字(次行以降の `- 項目` を受け取る)
        var pendingListIndex: Int?
        var pendingItems: [String] = []
        var pendingLastLineEnd = 0

        /// 開いているリストを閉じて Property に書く(項目が無ければ `.text("")` のまま)。
        mutating func flushPendingList() {
            defer {
                pendingListIndex = nil
                pendingItems = []
            }
            guard let index = pendingListIndex, !pendingItems.isEmpty else { return }
            var property = properties[index]
            property.value = .list(pendingItems)
            property.lineRange = NSRange(
                location: property.lineRange.location, length: pendingLastLineEnd - property.lineRange.location)
            properties[index] = property
        }

        mutating func appendRaw(_ content: String, line: NSRange) {
            properties.append(.init(key: nil, value: .raw(content), lineRange: line))
        }
    }

    private static func parseLine(_ line: NSRange, in text: NSString, into state: inout ParseState) {
        let content = text.substring(with: line)
        let trimmed = content.drop { $0 == " " || $0 == "\t" }
        let indent = content.count - trimmed.count
        if trimmed.isEmpty { return }
        if trimmed.first == "#" {
            // 行頭のコメントは読み飛ばす。インデントされた `#` の行は、開いているリストの中ならコメント、
            // それ以外(複数行スカラーの本文など)は原文のまま残す。
            if indent == 0 || state.pendingListIndex != nil { return }
            state.appendRaw(content, line: line)
            return
        }

        // "- 項目": 開いているリストの項目として受け取る
        if trimmed == "-" || trimmed.hasPrefix("- ") {
            guard state.pendingListIndex != nil else {
                state.appendRaw(content, line: line)
                return
            }
            switch classify(String(trimmed.dropFirst(1))) {
            case .text(let item):
                state.pendingItems.append(item)
                state.pendingLastLineEnd = NSMaxRange(line)
            case .empty:
                state.pendingItems.append("")
                state.pendingLastLineEnd = NSMaxRange(line)
            case .list, .unsupported:
                // 入れ子のリストや読めない項目: その行を原文で残す(リスト自体は続く)
                state.appendRaw(content, line: line)
            }
            return
        }

        // "key: 値"(インデント無し、キーは空でない、コロンの直後は空白か行末)
        if indent == 0, let (key, rest) = splitKey(String(trimmed)) {
            state.flushPendingList()
            switch classify(rest) {
            case .empty:
                state.properties.append(.init(key: key, value: .text(""), lineRange: line))
                state.pendingListIndex = state.properties.count - 1
                state.pendingLastLineEnd = NSMaxRange(line)
            case .text(let value):
                state.properties.append(.init(key: key, value: .text(value), lineRange: line))
            case .list(let items):
                state.properties.append(.init(key: key, value: .list(items), lineRange: line))
            case .unsupported:
                state.appendRaw(content, line: line)
            }
            return
        }

        // それ以外(インデントされた行、コロンの無い行)は解釈できない行
        state.flushPendingList()
        state.appendRaw(content, line: line)
    }

    /// 値の解釈結果。
    enum Scalar: Equatable {
        /// 値が無い(または行末コメントだけ)
        case empty
        case text(String)
        case list([String])
        /// 対応しない構文(複数行スカラー、入れ子、閉じていない引用符、未知のエスケープ)。行を原文で残す。
        case unsupported
    }

    /// `key:` の後ろ(または `- ` の後ろ)の文字列を解釈する。コメントは引用符を考慮して先に外し、その後で
    /// 空値・フローリスト・複数行スカラーを判定する(`tags: [a, b] # comment` はリスト、`tags: # comment` は空値)。
    static func classify(_ raw: String) -> Scalar {
        let body = raw.trimmingCharacters(in: .whitespaces)
        guard let first = body.first, first != "#" else { return .empty }
        if first == "\"" || first == "'" {
            guard let (value, remainder) = parseQuoted(body) else { return .unsupported }
            let rest = remainder.trimmingCharacters(in: .whitespaces)
            guard rest.isEmpty || rest.first == "#" else { return .unsupported }
            return .text(value)
        }
        let unquoted = stripComment(body)
        if unquoted.first == "[" {
            guard unquoted.hasSuffix("]"), let items = flowItems(unquoted) else { return .unsupported }
            return .list(items)
        }
        if unquoted.first == "{" || isBlockScalarIndicator(unquoted) { return .unsupported }
        return .text(unquoted)
    }

    /// "key: rest" を分ける。コロンの直後が空白か行末である最初のコロンで切る。
    /// `{` / `[` / 引用符で始まる行(フローのマップ / リスト、引用符付きキー)はキーにしない。
    private static func splitKey(_ line: String) -> (key: String, rest: String)? {
        guard let first = line.first, first != "{", first != "[", first != "\"", first != "'" else { return nil }
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == ":" {
                let after = line.index(after: index)
                if after == line.endIndex || line[after] == " " || line[after] == "\t" {
                    let key = line[..<index].trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { return nil }
                    return (key, line[after...].trimmingCharacters(in: .whitespaces))
                }
            }
            index = line.index(after: index)
        }
        return nil
    }

    private static func isBlockScalarIndicator(_ rest: String) -> Bool {
        guard let first = rest.first, first == "|" || first == ">" else { return false }
        return rest.dropFirst().allSatisfy { $0 == "-" || $0 == "+" || $0.isNumber }
    }

    /// 引用符で始まる文字列を読み、中身と閉じ引用符の後ろの残りを返す。閉じていない、または対応しない
    /// エスケープなら nil。`"…"` は YAML の主なエスケープ(`\n` `\t` `\"` `\\` `\/` `\0` `\r` `\uXXXX` `\xXX`
    /// `\UXXXXXXXX`)、`'…'` は `''` だけを解釈する。
    static func parseQuoted(_ text: String) -> (value: String, remainder: Substring)? {
        guard let quote = text.first, quote == "\"" || quote == "'" else { return nil }
        var result = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let c = text[index]
            if quote == "\"", c == "\\" {
                let escapeStart = text.index(after: index)
                guard escapeStart < text.endIndex else { return nil }
                let escaped = text[escapeStart]
                var next = text.index(after: escapeStart)
                switch escaped {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "0": result.append("\0")
                case "\"", "\\", "/", " ": result.append(escaped)
                case "x", "u", "U":
                    let digits = escaped == "x" ? 2 : escaped == "u" ? 4 : 8
                    guard let end = text.index(next, offsetBy: digits, limitedBy: text.endIndex),
                          let code = UInt32(text[next..<end], radix: 16),
                          let scalar = Unicode.Scalar(code)
                    else { return nil }
                    result.unicodeScalars.append(scalar)
                    next = end
                default:
                    return nil
                }
                index = next
                continue
            }
            if c == quote {
                let after = text.index(after: index)
                if quote == "'", after < text.endIndex, text[after] == "'" {
                    result.append("'")
                    index = text.index(after: after)
                    continue
                }
                return (result, text[after...])
            }
            result.append(c)
            index = text.index(after: index)
        }
        return nil
    }

    /// 空白に続く `#` 以降を落とす(引用符無しの値の行末コメント)。
    private static func stripComment(_ value: String) -> String {
        var previousIsSpace = false
        var index = value.startIndex
        while index < value.endIndex {
            let c = value[index]
            if c == "#", previousIsSpace {
                return value[..<index].trimmingCharacters(in: .whitespaces)
            }
            previousIsSpace = c == " " || c == "\t"
            index = value.index(after: index)
        }
        return value
    }

    /// "[a, "b, c", d]" → ["a", "b, c", "d"]。引用符の外のカンマで分け、引用符無しの空の項目(末尾のカンマなど)は
    /// 落とし、`""` は空文字列として残す。入れ子の `[` / `{`、閉じていない引用符、未知のエスケープは nil。
    static func flowItems(_ flow: String) -> [String]? {
        guard flow.hasPrefix("["), flow.hasSuffix("]"), flow.count >= 2 else { return nil }
        let inner = String(flow.dropFirst().dropLast())
        var items: [String] = []
        var index = inner.startIndex
        var current = ""
        var currentQuoted: String?
        func finishItem() -> Bool {
            defer {
                current = ""
                currentQuoted = nil
            }
            if let quoted = currentQuoted {
                guard current.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
                items.append(quoted)
                return true
            }
            let plain = current.trimmingCharacters(in: .whitespaces)
            if !plain.isEmpty { items.append(plain) }
            return true
        }
        while index < inner.endIndex {
            let c = inner[index]
            switch c {
            case "\"", "'":
                guard currentQuoted == nil, current.trimmingCharacters(in: .whitespaces).isEmpty,
                      let (value, remainder) = parseQuoted(String(inner[index...]))
                else { return nil }
                currentQuoted = value
                current = ""
                index = inner.index(inner.endIndex, offsetBy: -remainder.count)
                continue
            case "[", "{", "]", "}":
                return nil
            case ",":
                guard finishItem() else { return nil }
            default:
                current.append(c)
            }
            index = inner.index(after: index)
        }
        guard finishItem() else { return nil }
        return items
    }

    // MARK: - 行の走査

    /// `line`(改行を含まない)が "---" だけの行か(末尾の空白は無視)。
    private static func isFence(_ line: NSRange, in text: NSString) -> Bool {
        guard line.length >= 3 else { return false }
        for offset in 0..<3 where text.character(at: line.location + offset) != ASCII.dash { return false }
        var i = line.location + 3
        while i < NSMaxRange(line) {
            let c = text.character(at: i)
            guard c == ASCII.space || c == ASCII.tab else { return false }
            i += 1
        }
        return true
    }

    /// location を含む行の内容レンジ(改行を含まない)。
    private static func lineContent(at location: Int, in text: NSString) -> NSRange {
        var start = 0
        var contentsEnd = 0
        text.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        return NSRange(location: start, length: max(0, contentsEnd - start))
    }

    /// `line` の次の行頭。文書末尾なら text.length。
    private static func nextLineStart(after line: NSRange, in text: NSString) -> Int {
        var end = 0
        text.getLineStart(nil, end: &end, contentsEnd: nil, for: NSRange(location: line.location, length: 0))
        return end
    }
}
