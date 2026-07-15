import Foundation

/// 編集操作の結果。UI 層がこれを undo 対応の経路で適用する。
/// replacementRange は現在のテキスト座標、selectedRange は適用後座標。
public struct EditCommand: Equatable, Sendable {
    public var replacementRange: NSRange
    public var replacementString: String
    public var selectedRange: NSRange

    public init(replacementRange: NSRange, replacementString: String, selectedRange: NSRange) {
        self.replacementRange = replacementRange
        self.replacementString = replacementString
        self.selectedRange = selectedRange
    }
}

/// 編集支援の判断を行う純粋関数群(状態を持たない)。
/// 全関数は「判断できない・対象外 = nil(→ 呼び出し側はデフォルト動作)」の規約。
/// 判断は行単位のテキスト走査のみで行い、パーサーには依存しない。
public enum EditingAssistant {
    /// Enter: リスト自動継続。空項目ならリストから脱出(行内容全体を削除)
    public static func newline(text: NSString, selection: NSRange) -> EditCommand? {
        guard selection.length == 0, selection.location <= text.length else { return nil }
        let lineRange = text.lineRange(for: NSRange(location: selection.location, length: 0))
        guard let item = ListItemLine.parse(text: text, lineRange: lineRange) else { return nil }
        var contentsEnd = 0
        text.getLineStart(
            nil, end: nil, contentsEnd: &contentsEnd,
            for: NSRange(location: lineRange.location, length: 0))
        // マーカーより前にカーソルがあるときはデフォルト動作(マーカーを分断しない)
        guard selection.location >= item.contentStart else { return nil }
        // 空項目脱出: 本文が空ならインデントごと行内容を削除して空行にする
        if item.contentStart >= contentsEnd {
            return EditCommand(
                replacementRange: NSRange(
                    location: lineRange.location, length: contentsEnd - lineRange.location),
                replacementString: "",
                selectedRange: NSRange(location: lineRange.location, length: 0))
        }
        let inserted = "\n" + item.indent + item.continuationMarker
        return EditCommand(
            replacementRange: NSRange(location: selection.location, length: 0),
            replacementString: inserted,
            selectedRange: NSRange(
                location: selection.location + (inserted as NSString).length, length: 0))
    }

    /// インデント単位(スペース 4。番号付きマーカー幅でもネストが常に成立する値)
    private static let indentUnit = "    "

    /// Tab: 選択範囲(またはカーソル行)内のリスト項目行を 1 段深くする
    public static func indent(text: NSString, selection: NSRange) -> EditCommand? {
        changeIndent(text: text, selection: selection, removing: false)
    }

    /// Shift+Tab: 選択範囲(またはカーソル行)内のリスト項目行を 1 段浅くする
    public static func outdent(text: NSString, selection: NSRange) -> EditCommand? {
        changeIndent(text: text, selection: selection, removing: true)
    }

    private static func changeIndent(
        text: NSString, selection: NSRange, removing: Bool
    ) -> EditCommand? {
        guard NSMaxRange(selection) <= text.length else { return nil }
        let linesRange = text.lineRange(for: selection)
        var rebuilt = ""
        var firstDelta: Int?
        var totalDelta = 0
        var foundListLine = false
        var location = linesRange.location
        while location < NSMaxRange(linesRange) {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            var line = text.substring(with: lineRange)
            var delta = 0
            if ListItemLine.parse(text: text, lineRange: lineRange) != nil {
                foundListLine = true
                if removing {
                    // 行頭から最大 indentUnit 分のスペースを削除
                    let removable = line.prefix(indentUnit.count).prefix(while: { $0 == " " }).count
                    if removable > 0 {
                        line.removeFirst(removable)
                        delta = -removable
                    }
                } else {
                    line = indentUnit + line
                    delta = indentUnit.count
                }
            }
            rebuilt += line
            if firstDelta == nil { firstDelta = delta }
            totalDelta += delta
            location = NSMaxRange(lineRange)
        }
        guard foundListLine, totalDelta != 0 else { return nil }
        // 選択範囲の維持: 先頭行の増減分だけ開始位置をずらし、残りは長さに反映する
        let first = firstDelta ?? 0
        let newLocation = max(linesRange.location, selection.location + first)
        let newLength = max(0, selection.length + totalDelta - first)
        return EditCommand(
            replacementRange: linesRange,
            replacementString: rebuilt,
            selectedRange: NSRange(location: newLocation, length: newLength))
    }

    /// 囲い込み対象(開き文字 → 閉じ文字)
    private static let wrapPairs: [Character: Character] = [
        "*": "*", "_": "_", "`": "`", "~": "~", "[": "]", "(": ")",
    ]
    /// 自動閉じ対象(強調記号は日本語の文章中で誤発火しやすいため除外)
    private static let autoClosing: Set<Character> = ["`", "[", "("]
    /// タイプオーバー対象の閉じ文字
    private static let closers: Set<Character> = ["`", "]", ")"]

    /// 文字入力: ペア補完(囲い込み・自動閉じ・タイプオーバー)。
    /// タイプオーバーは「置換なし・選択移動のみ」のコマンドを返す。
    public static func insertion(
        text: NSString, selection: NSRange, typing: String
    ) -> EditCommand? {
        guard NSMaxRange(selection) <= text.length,
            typing.count == 1, let character = typing.first else { return nil }
        // 囲い込み: 選択範囲をペアで囲み、内側のテキストを選択したままにする
        if selection.length > 0 {
            guard let closing = wrapPairs[character] else { return nil }
            let selected = text.substring(with: selection)
            return EditCommand(
                replacementRange: selection,
                replacementString: "\(character)\(selected)\(closing)",
                selectedRange: NSRange(location: selection.location + 1, length: selection.length))
        }
        // タイプオーバー: カーソル直後が同じ閉じ文字ならカーソルだけ進める
        // (closers 通過後なので character は必ず ASCII — asciiValue は非 nil)
        if closers.contains(character), selection.location < text.length,
            text.character(at: selection.location) == unichar(character.asciiValue!) {
            return EditCommand(
                replacementRange: NSRange(location: selection.location, length: 0),
                replacementString: "",
                selectedRange: NSRange(location: selection.location + 1, length: 0))
        }
        // 自動閉じ: 閉じ側を挿入してカーソルを間に置く
        if autoClosing.contains(character), let closing = wrapPairs[character] {
            return EditCommand(
                replacementRange: selection,
                replacementString: "\(character)\(closing)",
                selectedRange: NSRange(location: selection.location + 1, length: 0))
        }
        return nil
    }

    /// クリック: offset がタスク項目のチェックボックス "[ ]" / "[x]" の 3 文字上に
    /// あるときだけ状態文字 1 文字を置換するコマンドを返す。
    /// 置換は同長 1 文字なので、UI 層は適用前の選択範囲をそのまま復元できる。
    public static func toggleCheckbox(text: NSString, at offset: Int) -> EditCommand? {
        guard offset >= 0, offset <= text.length else { return nil }
        let lineRange = text.lineRange(for: NSRange(location: offset, length: 0))
        guard let item = ListItemLine.parse(text: text, lineRange: lineRange),
            let boxLocation = item.checkboxLocation,
            offset >= boxLocation, offset < boxLocation + 3 else { return nil }
        let stateLocation = boxLocation + 1
        let state = text.character(at: stateLocation)
        let isChecked = state == unichar(UnicodeScalar("x").value)
            || state == unichar(UnicodeScalar("X").value)
        return EditCommand(
            replacementRange: NSRange(location: stateLocation, length: 1),
            replacementString: isChecked ? " " : "x",
            selectedRange: NSRange(location: stateLocation, length: 1))
    }
}

/// リスト項目行の解析結果。行頭のインデント・マーカー・チェックボックスを走査で検出する。
struct ListItemLine {
    /// 行頭の空白(スペース/タブ)
    var indent: String
    /// 継続時に次行へ挿入するマーカー("- " / "4. " / "- [ ] " など、末尾スペース込み)
    var continuationMarker: String
    /// チェックボックス "[ ]" / "[x]" / "[X]" の文書内オフセット(タスク項目のみ)
    var checkboxLocation: Int?
    /// 本文開始オフセット(マーカーと後続スペースの直後、文書座標)
    var contentStart: Int

    static func parse(text: NSString, lineRange: NSRange) -> ListItemLine? {
        var contentsEnd = 0
        text.getLineStart(
            nil, end: nil, contentsEnd: &contentsEnd,
            for: NSRange(location: lineRange.location, length: 0))
        let space = unichar(UnicodeScalar(" ").value)
        let tab = unichar(UnicodeScalar("\t").value)
        var i = lineRange.location
        while i < contentsEnd, text.character(at: i) == space || text.character(at: i) == tab {
            i += 1
        }
        let indent = text.substring(
            with: NSRange(location: lineRange.location, length: i - lineRange.location))
        guard i < contentsEnd else { return nil }

        // マーカー: "-" / "*" / "+" または "数字列." / "数字列)"
        let markerText: String
        let bullets: Set<unichar> = [
            unichar(UnicodeScalar("-").value),
            unichar(UnicodeScalar("*").value),
            unichar(UnicodeScalar("+").value),
        ]
        if bullets.contains(text.character(at: i)) {
            markerText = String(UnicodeScalar(text.character(at: i))!)
            i += 1
        } else if isDigit(text.character(at: i)) {
            var j = i
            var number = 0
            while j < contentsEnd, isDigit(text.character(at: j)) {
                number = number * 10 + Int(text.character(at: j) - 48)
                j += 1
            }
            // 桁数の異常な数字列はリストとして扱わない(オーバーフロー防止)
            guard j - i <= 9, j < contentsEnd else { return nil }
            let delimiter = text.character(at: j)
            guard delimiter == unichar(UnicodeScalar(".").value)
                || delimiter == unichar(UnicodeScalar(")").value) else { return nil }
            // 継続マーカーは番号 +1(区切り文字は元の行に合わせる)
            markerText = "\(number + 1)\(String(UnicodeScalar(delimiter)!))"
            i = j + 1
        } else {
            return nil
        }

        // マーカー直後に少なくとも 1 個のスペースが必要
        guard i < contentsEnd, text.character(at: i) == space else { return nil }
        while i < contentsEnd, text.character(at: i) == space { i += 1 }

        // チェックボックス "[ ]" / "[x]" / "[X]"(直後がスペースまたは行末のときのみ)
        var checkboxLocation: Int?
        var continuation = markerText + " "
        if i + 3 <= contentsEnd,
            text.character(at: i) == unichar(UnicodeScalar("[").value),
            text.character(at: i + 2) == unichar(UnicodeScalar("]").value) {
            let state = text.character(at: i + 1)
            let isState = state == space
                || state == unichar(UnicodeScalar("x").value)
                || state == unichar(UnicodeScalar("X").value)
            let followedBySpaceOrEnd = i + 3 == contentsEnd || text.character(at: i + 3) == space
            if isState && followedBySpaceOrEnd {
                checkboxLocation = i
                // タスクはチェック状態に関わらず未チェックで継続する
                continuation += "[ ] "
                i += 3
                while i < contentsEnd, text.character(at: i) == space { i += 1 }
            }
        }
        return ListItemLine(
            indent: indent,
            continuationMarker: continuation,
            checkboxLocation: checkboxLocation,
            contentStart: i)
    }

    private static func isDigit(_ character: unichar) -> Bool {
        character >= 48 && character <= 57
    }
}
