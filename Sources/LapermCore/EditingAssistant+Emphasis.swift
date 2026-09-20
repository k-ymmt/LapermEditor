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
    /// `**` はボールドであってイタリックではないので、イタリックは 2 本ちょうどを除外する
    /// (`***text***` = ボールド + イタリックはどちらにも該当する)。
    func matches(runLength: Int) -> Bool {
        switch self {
        case .strong: runLength >= 2
        case .emphasis: runLength >= 1 && runLength != 2
        }
    }
}

extension EditingAssistant {
    /// ボールド / イタリックのトグル。
    /// - 選択があればその範囲(前後の空白は除く)、なければカーソル位置の単語を対象にする。
    /// - 対象がすでにマーカーで囲まれていれば(選択にマーカーを含む場合も、外側にある場合も)外す。
    /// - 対象が空(単語がない)なら空のマーカーを挿入してカーソルを間に置き、
    ///   空マーカーの間でもう一度呼ぶと取り消す。
    /// 適用後の選択は、選択があったときは内側のテキスト、カーソルだけのときは同じ相対位置のカーソル。
    /// 選択が文書外なら nil。
    public static func toggleEmphasis(
        text: NSString, selection: NSRange, style: EmphasisStyle
    ) -> EditCommand? {
        guard selection.location != NSNotFound, NSMaxRange(selection) <= text.length else { return nil }
        // 空白だけの選択は「選択なし」と同じ扱いにするが、単語は探さず選択開始位置に空マーカーを入れる
        let trimmed = trimmingWhitespace(text: text, range: selection)
        let hadSelection = trimmed.length > 0
        let target: NSRange
        if hadSelection {
            target = trimmed
        } else if selection.length > 0 {
            target = NSRange(location: selection.location, length: 0)
        } else {
            target = TextMotions.wordRange(text: text, at: selection.location)
        }
        let caret = selection.location
        let markerLength = style.markerLength

        // 1. 対象の内側にマーカーがある("**hello**" を丸ごと選択)
        if target.length >= 2 * markerLength,
           let inner = innerRange(of: target, in: text, style: style)
        {
            let content = text.substring(with: inner)
            let selected = hadSelection
                ? NSRange(location: target.location, length: inner.length)
                : NSRange(location: target.location + (min(max(caret, inner.location), NSMaxRange(inner)) - inner.location), length: 0)
            return EditCommand(replacementRange: target, replacementString: content, selectedRange: selected)
        }

        // 2. 対象の外側にマーカーがある(単語の上にカーソル、または内側だけ選択)。空マーカーの間も同じ扱い
        let before = markerRun(in: text, endingAt: target.location)
        let after = markerRun(in: text, startingAt: NSMaxRange(target))
        if let before, let after, before.character == after.character,
           style.matches(runLength: min(before.length, after.length))
        {
            let outer = NSRange(location: target.location - markerLength, length: target.length + 2 * markerLength)
            let content = text.substring(with: target)
            let selected = hadSelection
                ? NSRange(location: outer.location, length: target.length)
                : NSRange(location: max(outer.location, caret - markerLength), length: 0)
            return EditCommand(replacementRange: outer, replacementString: content, selectedRange: selected)
        }

        // 3. 囲む
        let content = text.substring(with: target)
        let selected = hadSelection
            ? NSRange(location: target.location + markerLength, length: target.length)
            : NSRange(location: caret + markerLength, length: 0)
        return EditCommand(
            replacementRange: target,
            replacementString: style.marker + content + style.marker,
            selectedRange: selected)
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

    private static let asterisk = UTF16.CodeUnit(UnicodeScalar("*").value)
    private static let underscore = UTF16.CodeUnit(UnicodeScalar("_").value)

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

    /// range の先頭と末尾が同じマーカー文字の並びで、style に該当するなら、マーカーを除いた内側の範囲。
    private static func innerRange(of range: NSRange, in text: NSString, style: EmphasisStyle) -> NSRange? {
        guard let leading = markerRun(in: text, startingAt: range.location),
              let trailing = markerRun(in: text, endingAt: NSMaxRange(range)),
              leading.character == trailing.character
        else { return nil }
        let leadingLength = min(leading.length, range.length)
        let trailingLength = min(trailing.length, range.length)
        // 並びが範囲の両端で重なる("****" 全体を選択)なら半分ずつに分ける
        let available = min(leadingLength, trailingLength, range.length / 2)
        guard style.matches(runLength: available) else { return nil }
        let markerLength = style.markerLength
        return NSRange(location: range.location + markerLength, length: range.length - 2 * markerLength)
    }
}
