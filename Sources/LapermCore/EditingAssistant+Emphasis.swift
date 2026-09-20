import Foundation

/// 強調の種類。ボールド(`**`)とイタリック(`*`)。
/// 解除の判定ではアスタリスクとアンダースコアの両方を認識し、挿入は常にアスタリスクを使う。
public enum EmphasisStyle: Sendable, Hashable, CaseIterable {
    /// `**text**`
    case strong
    /// `*text*`
    case emphasis

    /// 挿入するマーカー
    public var marker: String {
        switch self {
        case .strong: "**"
        case .emphasis: "*"
        }
    }

    var markerLength: Int { marker.utf16.count }

    /// 両側にこの本数のマーカー文字が並んでいるとき、このスタイルが「かかっている」とみなすか。
    /// 偶数本はボールド(の入れ子)であってイタリックではないので、イタリックは奇数本だけ
    /// (`***text***` = ボールド + イタリックはどちらにも該当する)。
    func matches(runLength: Int) -> Bool {
        switch self {
        case .strong: runLength >= 2
        case .emphasis: runLength % 2 == 1
        }
    }
}

extension EditingAssistant {
    /// ボールド / イタリックのトグル。
    /// - 選択があればその範囲(前後の空白は除く)、なければカーソル位置の単語を対象にする。
    /// - 対象がすでにマーカーで囲まれていれば(選択にマーカーを含む場合も、外側にある場合も)外す。
    ///   アンダースコアは語内(`foo_bar_baz`)では強調にならないので、両外側が単語文字でないときだけ認識する。
    /// - 対象が空(単語がない)なら空のマーカーを挿入してカーソルを間に置き、
    ///   空マーカーの間でもう一度呼ぶと取り消す。
    /// - 判断できないときは何もしない(nil): 対象の内側に同じスタイルのマーカーが混じる
    ///   (`**a** and **b**` を丸ごと選択)、コードスパンの中、空行をまたぐ選択、文書外の範囲。
    /// 適用後の選択は、選択があったときは内側のテキスト、カーソルだけのときは同じ相対位置のカーソル。
    /// 位置はすべて合成文字境界に丸める。
    public static func toggleEmphasis(
        text: NSString, selection: NSRange, style: EmphasisStyle
    ) -> EditCommand? {
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= text.length, selection.length <= text.length - selection.location
        else { return nil }
        let normalized = composedRange(text: text, range: selection)
        // 空白だけの選択は「選択なし」と同じ扱いにするが、単語は探さず選択開始位置に空マーカーを入れる
        let trimmed = trimmingWhitespace(text: text, range: normalized)
        let hadSelection = trimmed.length > 0
        let target: NSRange
        if hadSelection {
            target = trimmed
        } else if normalized.length > 0 {
            target = NSRange(location: normalized.location, length: 0)
        } else {
            target = TextMotions.wordRange(text: text, at: normalized.location)
        }
        let caret = normalized.location
        let markerLength = style.markerLength
        let content = text.substring(with: target)
        guard !isInsideCodeSpan(text: text, at: target.location), !containsBlankLine(content) else { return nil }

        // 1. 対象の内側にマーカーがある("**hello**" を丸ごと選択)
        if target.length >= 2 * markerLength,
           let inner = innerRange(of: target, in: text, style: style)
        {
            let innerContent = text.substring(with: inner)
            guard !containsAmbiguousMarkers(innerContent, style: style) else { return nil }
            let selected = hadSelection
                ? NSRange(location: target.location, length: inner.length)
                : NSRange(location: target.location + (min(max(caret, inner.location), NSMaxRange(inner)) - inner.location), length: 0)
            return EditCommand(replacementRange: target, replacementString: innerContent, selectedRange: selected)
        }

        // 2. 対象の外側にマーカーがある(単語の上にカーソル、または内側だけ選択)。空マーカーの間も同じ扱い
        if let outer = outerMarkers(around: target, in: text, style: style) {
            guard !containsAmbiguousMarkers(content, style: style) else { return nil }
            let selected = hadSelection
                ? NSRange(location: outer.location, length: target.length)
                : NSRange(location: max(outer.location, caret - markerLength), length: 0)
            return EditCommand(replacementRange: outer, replacementString: content, selectedRange: selected)
        }

        // 3. 囲む(内側に同じスタイルのマーカーが混じるときは、囲んでも解除しても壊れるので何もしない)
        guard !containsAmbiguousMarkers(content, style: style) else { return nil }
        let selected = hadSelection
            ? NSRange(location: target.location + markerLength, length: target.length)
            : NSRange(location: caret + markerLength, length: 0)
        return EditCommand(
            replacementRange: target,
            replacementString: style.marker + content + style.marker,
            selectedRange: selected)
    }

    // MARK: - 範囲の正規化

    /// 両端を合成文字境界へ丸める(先頭は文字の頭へ、末尾は文字の終わりへ広げる)。
    private static func composedRange(text: NSString, range: NSRange) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let start = TextMotions.composedStart(text: text, at: range.location)
        // カーソルだけなら文字の頭へ(文字を選択にしない)
        guard range.length > 0 else { return NSRange(location: start, length: 0) }
        var end = NSMaxRange(range)
        if end < text.length {
            let sequence = text.rangeOfComposedCharacterSequence(at: end)
            if sequence.location < end { end = NSMaxRange(sequence) }
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// 前後の空白・改行を除いた範囲。
    private static func trimmingWhitespace(text: NSString, range: NSRange) -> NSRange {
        let content = text.substring(with: range)
        let leading = content.utf16.prefix(while: { isWhitespace($0) }).count
        let trailing = content.utf16.reversed().prefix(while: { isWhitespace($0) }).count
        guard leading + trailing < range.length else { return NSRange(location: range.location, length: 0) }
        return NSRange(location: range.location + leading, length: range.length - leading - trailing)
    }

    private static func isWhitespace(_ unit: UTF16.CodeUnit) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    // MARK: - 対象外の判定

    /// 行頭から offset までのバッククォートが奇数ならコードスパンの中(行単位の近似)。
    private static func isInsideCodeSpan(text: NSString, at offset: Int) -> Bool {
        let lineStart = TextMotions.lineStart(text: text, at: offset)
        var count = 0
        for i in lineStart..<offset where text.character(at: i) == backtick { count += 1 }
        return count % 2 == 1
    }

    /// 空行(段落境界)を含むか。強調は段落をまたげない。
    private static func containsBlankLine(_ content: String) -> Bool {
        // Swift String の range(of:) は "\r\n"(1 Character)の途中で始まる一致を落とすので NSString で探す
        (content as NSString).range(of: "\\r?\\n[ \\t]*\\r?\\n", options: .regularExpression).location != NSNotFound
    }

    /// 内容の(両端を除く)途中に、このスタイルにかかるマーカーの並びがあるか。
    /// あると「囲む」も「外す」も正しい結果にならない(`**a** and **b**` など)。
    private static func containsAmbiguousMarkers(_ content: String, style: EmphasisStyle) -> Bool {
        let units = Array(content.utf16)
        var i = 0
        while i < units.count {
            let unit = units[i]
            guard unit == asterisk || unit == underscore else { i += 1; continue }
            var j = i
            while j < units.count, units[j] == unit { j += 1 }
            let touchesEdge = i == 0 || j == units.count
            if !touchesEdge, style.matches(runLength: j - i) { return true }
            i = j
        }
        return false
    }

    // MARK: - マーカーの検出

    private static let asterisk = UTF16.CodeUnit(UnicodeScalar("*").value)
    private static let underscore = UTF16.CodeUnit(UnicodeScalar("_").value)
    private static let backtick = UTF16.CodeUnit(UnicodeScalar("`").value)

    private struct MarkerRun {
        var character: UTF16.CodeUnit
        var length: Int
    }

    /// offset の直前に続くマーカー文字(`*` か `_`、同じ文字のみ)の並び。
    private static func markerRun(in text: NSString, endingAt offset: Int) -> MarkerRun? {
        guard offset > 0 else { return nil }
        let character = text.character(at: offset - 1)
        guard character == asterisk || character == underscore else { return nil }
        var length = 0
        while offset - length > 0, text.character(at: offset - length - 1) == character { length += 1 }
        return MarkerRun(character: character, length: length)
    }

    /// offset から始まるマーカー文字の並び。
    private static func markerRun(in text: NSString, startingAt offset: Int) -> MarkerRun? {
        guard offset < text.length else { return nil }
        let character = text.character(at: offset)
        guard character == asterisk || character == underscore else { return nil }
        var length = 0
        while offset + length < text.length, text.character(at: offset + length) == character { length += 1 }
        return MarkerRun(character: character, length: length)
    }

    /// アンダースコアの並びが強調の区切りになれるか: 並びの外側が単語文字だと語内(`foo_bar`)なので不可。
    private static func underscoreCanDelimit(text: NSString, openingStart: Int, closingEnd: Int) -> Bool {
        !TextMotions.isWordCharacter(text: text, before: openingStart)
            && !TextMotions.isWordCharacter(text: text, at: closingEnd)
    }

    /// range の先頭と末尾が同じマーカー文字の並びで、style に該当するなら、マーカーを除いた内側の範囲。
    private static func innerRange(of range: NSString.Range, in text: NSString, style: EmphasisStyle) -> NSRange? {
        guard let leading = markerRun(in: text, startingAt: range.location),
              let trailing = markerRun(in: text, endingAt: NSMaxRange(range)),
              leading.character == trailing.character
        else { return nil }
        let leadingLength = min(leading.length, range.length)
        let trailingLength = min(trailing.length, range.length)
        // 並びが範囲の両端で重なる("****" 全体を選択)なら半分ずつに分ける
        let available = min(leadingLength, trailingLength, range.length / 2)
        guard style.matches(runLength: available) else { return nil }
        if leading.character == underscore,
           !underscoreCanDelimit(text: text, openingStart: range.location, closingEnd: NSMaxRange(range))
        {
            return nil
        }
        let markerLength = style.markerLength
        return NSRange(location: range.location + markerLength, length: range.length - 2 * markerLength)
    }

    /// target の外側に style のマーカーが対で並んでいるなら、マーカー込みの範囲(style のマーカー幅ぶん)。
    private static func outerMarkers(around target: NSRange, in text: NSString, style: EmphasisStyle) -> NSRange? {
        guard let before = markerRun(in: text, endingAt: target.location),
              let after = markerRun(in: text, startingAt: NSMaxRange(target)),
              before.character == after.character,
              style.matches(runLength: min(before.length, after.length))
        else { return nil }
        if before.character == underscore,
           !underscoreCanDelimit(
            text: text, openingStart: target.location - before.length, closingEnd: NSMaxRange(target) + after.length)
        {
            return nil
        }
        let markerLength = style.markerLength
        return NSRange(location: target.location - markerLength, length: target.length + 2 * markerLength)
    }
}

extension NSString {
    fileprivate typealias Range = NSRange
}
