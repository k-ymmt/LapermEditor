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

        var properties: [FrontMatter.Property] = []
        /// 値が空だった直近のキーの添字(次行以降の `- 項目` を受け取る)
        var pendingListIndex: Int?
        var location = nextLineStart(after: firstLine, in: text)
        while location < text.length {
            let line = lineContent(at: location, in: text)
            if isFence(line, in: text) {
                return FrontMatter(
                    range: NSRange(location: 0, length: NSMaxRange(line)),
                    openingFenceRange: firstLine,
                    closingFenceRange: line,
                    properties: properties)
            }
            parseLine(line, in: text, into: &properties, pendingListIndex: &pendingListIndex)
            let next = nextLineStart(after: line, in: text)
            guard next > location else { break }
            location = next
        }
        // 閉じが無い
        return nil
    }

    // MARK: - 行の解釈

    private static func parseLine(
        _ line: NSRange, in text: NSString,
        into properties: inout [FrontMatter.Property], pendingListIndex: inout Int?
    ) {
        let content = text.substring(with: line)
        let trimmed = content.drop { $0 == " " || $0 == "\t" }
        let indent = content.count - trimmed.count
        // 空行・コメント行
        if trimmed.isEmpty || trimmed.first == "#" { return }

        // "- 項目": 直前が値の無いキー(またはその続きのリスト)なら項目として受け取る
        if trimmed == "-" || trimmed.hasPrefix("- ") {
            if let index = pendingListIndex {
                let item = scalar(from: String(trimmed.dropFirst(1)))
                var property = properties[index]
                var items: [String]
                switch property.value {
                case .list(let existing): items = existing
                default: items = []
                }
                items.append(item)
                property.value = .list(items)
                property.lineRange = NSRange(
                    location: property.lineRange.location, length: NSMaxRange(line) - property.lineRange.location)
                properties[index] = property
                return
            }
            properties.append(.init(key: nil, value: .raw(content), lineRange: line))
            return
        }

        // "key: 値"(インデント無し、キーは空でない、コロンの直後は空白か行末)
        if indent == 0, let (key, rest) = splitKey(String(trimmed)) {
            pendingListIndex = nil
            if rest.isEmpty {
                properties.append(.init(key: key, value: .text(""), lineRange: line))
                pendingListIndex = properties.count - 1
            } else if rest.hasPrefix("["), rest.hasSuffix("]") {
                properties.append(.init(key: key, value: .list(flowItems(rest)), lineRange: line))
            } else if isBlockScalarIndicator(rest) {
                // "key: |" / "key: >" の複数行スカラーは読まない(続く行はインデントされた行として raw になる)
                properties.append(.init(key: nil, value: .raw(content), lineRange: line))
            } else {
                properties.append(.init(key: key, value: .text(scalar(from: rest)), lineRange: line))
            }
            return
        }

        // それ以外(インデントされた行、コロンの無い行)は解釈できない行
        pendingListIndex = nil
        properties.append(.init(key: nil, value: .raw(content), lineRange: line))
    }

    /// "key: rest" を分ける。コロンの直後が空白か行末である最初のコロンで切る。
    /// `{` / `[` で始まる行(フローのマップ / リスト)はキーにしない。
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

    /// スカラー値: 引用符付きなら中身(エスケープを戻す)、そうでなければ行末コメントを外して前後の空白を落とす。
    static func scalar(from raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard let quote = value.first, quote == "\"" || quote == "'" else {
            return stripComment(value)
        }
        var result = ""
        var index = value.index(after: value.startIndex)
        while index < value.endIndex {
            let c = value[index]
            if quote == "\"", c == "\\", value.index(after: index) < value.endIndex {
                let escaped = value[value.index(after: index)]
                switch escaped {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(escaped)
                }
                index = value.index(index, offsetBy: 2)
                continue
            }
            if c == quote {
                let after = value.index(after: index)
                if quote == "'", after < value.endIndex, value[after] == "'" {
                    result.append("'")
                    index = value.index(after: after)
                    continue
                }
                return result  // 閉じ引用符の後(コメントなど)は無視
            }
            result.append(c)
            index = value.index(after: index)
        }
        // 閉じ引用符が無い: 引用符も含めて原文のまま
        return stripComment(value)
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

    /// "[a, "b, c", d]" → ["a", "b, c", "d"]。引用符の外のカンマで分け、空の項目は落とす。
    static func flowItems(_ flow: String) -> [String] {
        let inner = flow.dropFirst().dropLast()
        var items: [String] = []
        var current = ""
        var quote: Character?
        for c in inner {
            if let open = quote {
                current.append(c)
                if c == open { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
                current.append(c)
            } else if c == "," {
                items.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        items.append(current)
        return items.map { scalar(from: $0) }.filter { !$0.isEmpty }
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
