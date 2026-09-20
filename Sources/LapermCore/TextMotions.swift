import Foundation

/// カーソル移動計算の純粋関数群。offset と戻り値はすべて UTF-16 単位。
/// 戻り値は常に合成文字境界(サロゲートペア・結合文字の途中に落ちない)。
/// Vim ライクなモーダル編集の部品として使える汎用計算で、パーサーには依存しない。
public enum TextMotions {
    /// offset を含む行の行頭
    public static func lineStart(text: NSString, at offset: Int) -> Int {
        var start = 0
        text.getLineStart(
            &start, end: nil, contentsEnd: nil,
            for: NSRange(location: clamp(offset, to: text), length: 0))
        return start
    }

    /// offset を含む行の行末(改行文字の手前)
    public static func lineEnd(text: NSString, at offset: Int) -> Int {
        var contentsEnd = 0
        text.getLineStart(
            nil, end: nil, contentsEnd: &contentsEnd,
            for: NSRange(location: clamp(offset, to: text), length: 0))
        return contentsEnd
    }

    /// 1 行上の preferredColumn 列へ(行が短ければ行末)。先頭行なら現在位置のまま
    public static func lineUp(text: NSString, at offset: Int, preferredColumn: Int) -> Int {
        let start = lineStart(text: text, at: offset)
        guard start > 0 else { return composedStart(text: text, at: offset) }
        return position(inLineContaining: start - 1, column: preferredColumn, text: text)
    }

    /// 1 行下の preferredColumn 列へ(行が短ければ行末)。最終行なら現在位置のまま
    public static func lineDown(text: NSString, at offset: Int, preferredColumn: Int) -> Int {
        var end = 0
        var contentsEnd = 0
        text.getLineStart(
            nil, end: &end, contentsEnd: &contentsEnd,
            for: NSRange(location: clamp(offset, to: text), length: 0))
        guard end > contentsEnd else { return composedStart(text: text, at: offset) }  // 次の行がない
        return position(inLineContaining: end, column: preferredColumn, text: text)
    }

    /// 次の単語頭へ(Vim の w 相当)。文書末ならその場に留まる
    public static func wordForward(text: NSString, at offset: Int) -> Int {
        var i = clamp(offset, to: text)
        guard i < text.length else { return i }
        let startClass = characterClass(text, at: i)
        if startClass != .whitespace {
            while i < text.length, characterClass(text, at: i) == startClass {
                i = NSMaxRange(text.rangeOfComposedCharacterSequence(at: i))
            }
        }
        while i < text.length, characterClass(text, at: i) == .whitespace {
            i = NSMaxRange(text.rangeOfComposedCharacterSequence(at: i))
        }
        return i
    }

    /// 前の単語頭へ(Vim の b 相当)。文書頭ならその場に留まる
    public static func wordBackward(text: NSString, at offset: Int) -> Int {
        var i = clamp(offset, to: text)
        guard i > 0 else { return i }
        i = text.rangeOfComposedCharacterSequence(at: i - 1).location
        while i > 0, characterClass(text, at: i) == .whitespace {
            i = text.rangeOfComposedCharacterSequence(at: i - 1).location
        }
        guard characterClass(text, at: i) != .whitespace else { return i }  // 文書頭まで空白
        let cls = characterClass(text, at: i)
        while i > 0 {
            let prev = text.rangeOfComposedCharacterSequence(at: i - 1).location
            guard characterClass(text, at: prev) == cls else { break }
            i = prev
        }
        return i
    }

    /// offset にある(または隣接する)単語の範囲。単語構成文字(英数字 + アンダースコア、CJK を含む)の
    /// 連続を両側へ広げる。前後どちらも単語文字でなければ offset の空範囲。
    public static func wordRange(text: NSString, at offset: Int) -> NSRange {
        let clamped = clamp(offset, to: text)
        var start = clamped
        while start > 0 {
            let prev = text.rangeOfComposedCharacterSequence(at: start - 1).location
            guard characterClass(text, at: prev) == .word else { break }
            start = prev
        }
        var end = clamped
        while end < text.length, characterClass(text, at: end) == .word {
            end = NSMaxRange(text.rangeOfComposedCharacterSequence(at: end))
        }
        return NSRange(location: start, length: end - start)
    }

    // MARK: - 内部

    private enum CharacterClass { case whitespace, word, symbol }

    /// 単語構成文字は英数字(Unicode 全般。CJK を含む)+ アンダースコア。
    /// それ以外の非空白は記号クラス。改行は空白クラス
    private static func characterClass(_ text: NSString, at offset: Int) -> CharacterClass {
        let range = text.rangeOfComposedCharacterSequence(at: offset)
        guard let scalar = text.substring(with: range).unicodeScalars.first else {
            return .symbol
        }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return .whitespace }
        if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" { return .word }
        return .symbol
    }

    /// lineOffset を含む行の column 列(UTF-16)。行末にクランプし、合成文字境界に丸める
    private static func position(
        inLineContaining lineOffset: Int, column: Int, text: NSString
    ) -> Int {
        var start = 0
        var contentsEnd = 0
        text.getLineStart(
            &start, end: nil, contentsEnd: &contentsEnd,
            for: NSRange(location: lineOffset, length: 0))
        let target = min(start + max(column, 0), contentsEnd)
        guard target < text.length, target > start else { return target }
        return text.rangeOfComposedCharacterSequence(at: target).location
    }

    private static func clamp(_ offset: Int, to text: NSString) -> Int {
        min(max(offset, 0), text.length)
    }

    /// クランプした上で、合成文字の途中にある offset をその文字の先頭へ丸める
    /// (「戻り値は常に合成文字境界」の契約を、移動しない経路でも守る)
    private static func composedStart(text: NSString, at offset: Int) -> Int {
        let clamped = clamp(offset, to: text)
        guard clamped < text.length else { return clamped }
        return text.rangeOfComposedCharacterSequence(at: clamped).location
    }
}
