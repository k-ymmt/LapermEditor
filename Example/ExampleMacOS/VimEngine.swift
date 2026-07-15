import Foundation
import LapermCore

/// 最小限の Vim ステートマシン(入力インターセプト API のリファレンス実装)。
/// KeyInput と文書状態から実行すべきアクションを純粋に計算する。AppKit 非依存。
struct VimEngine {
    enum Mode: Equatable {
        case normal
        case insert
    }

    enum Action: Equatable {
        case move(to: Int)      // カーソル移動(UTF-16 offset)
        case edit(EditCommand)  // undo 対応の編集
        case none               // 消費するが何もしない(モード切替・d 待ちなど)
        case passthrough        // 通常のテキスト入力処理へ
    }

    private(set) var mode: Mode = .normal
    private var pendingDelete = false  // "d" の 1 打目を受けた状態
    private var preferredColumn: Int?  // j / k の列記憶

    mutating func handle(_ input: KeyInput, text: NSString, selection: NSRange) -> Action {
        switch mode {
        case .insert:
            if input.key == .escape {
                mode = .normal
                return .none
            }
            return .passthrough
        case .normal:
            return handleNormal(input, text: text, selection: selection)
        }
    }

    private mutating func handleNormal(
        _ input: KeyInput, text: NSString, selection: NSRange
    ) -> Action {
        let caret = min(selection.location, text.length)
        // Cmd / Ctrl 付きはアプリ・システムのショートカットに任せる
        guard input.modifiers.isDisjoint(with: [.command, .control]) else {
            pendingDelete = false
            return .passthrough
        }
        guard case .character(let char) = input.key else {
            pendingDelete = false
            // 編集系の特殊キー(Return / Tab / Backspace 等)は NORMAL では消費して
            // 文書を変更させない。移動系(矢印・Page/Home/End)は無害なので通過させる
            switch input.key {
            case .escape, .return, .tab, .backspace, .forwardDelete:
                return .none
            case .up, .down, .left, .right, .pageUp, .pageDown, .home, .end:
                // 通過した移動キーで列記憶が古くなるためリセット
                preferredColumn = nil
                return .passthrough
            case .character:
                return .passthrough  // guard で除外済み(到達しない)
            }
        }
        if pendingDelete {
            pendingDelete = false
            return char == "d" ? deleteLine(text: text, caret: caret) : .none
        }
        if char != "j" && char != "k" { preferredColumn = nil }
        switch char {
        case "h":
            let lineStart = TextMotions.lineStart(text: text, at: caret)
            guard caret > lineStart else { return .none }
            return .move(to: text.rangeOfComposedCharacterSequence(at: caret - 1).location)
        case "l":
            guard caret < TextMotions.lineEnd(text: text, at: caret) else { return .none }
            return .move(to: NSMaxRange(text.rangeOfComposedCharacterSequence(at: caret)))
        case "j", "k":
            let column = preferredColumn
                ?? (caret - TextMotions.lineStart(text: text, at: caret))
            preferredColumn = column
            let target = char == "j"
                ? TextMotions.lineDown(text: text, at: caret, preferredColumn: column)
                : TextMotions.lineUp(text: text, at: caret, preferredColumn: column)
            return .move(to: target)
        case "0":
            return .move(to: TextMotions.lineStart(text: text, at: caret))
        case "$":
            return .move(to: TextMotions.lineEnd(text: text, at: caret))
        case "w":
            return .move(to: TextMotions.wordForward(text: text, at: caret))
        case "b":
            return .move(to: TextMotions.wordBackward(text: text, at: caret))
        case "x":
            guard caret < TextMotions.lineEnd(text: text, at: caret) else { return .none }
            let range = text.rangeOfComposedCharacterSequence(at: caret)
            return .edit(EditCommand(
                replacementRange: range, replacementString: "",
                selectedRange: NSRange(location: range.location, length: 0)))
        case "d":
            pendingDelete = true
            return .none
        case "i":
            mode = .insert
            return .none
        case "a":
            mode = .insert
            guard caret < TextMotions.lineEnd(text: text, at: caret) else { return .none }
            return .move(to: NSMaxRange(text.rangeOfComposedCharacterSequence(at: caret)))
        case "o":
            mode = .insert
            let lineEnd = TextMotions.lineEnd(text: text, at: caret)
            return .edit(EditCommand(
                replacementRange: NSRange(location: lineEnd, length: 0),
                replacementString: "\n",
                selectedRange: NSRange(location: lineEnd + 1, length: 0)))
        case "O":
            mode = .insert
            let lineStart = TextMotions.lineStart(text: text, at: caret)
            return .edit(EditCommand(
                replacementRange: NSRange(location: lineStart, length: 0),
                replacementString: "\n",
                selectedRange: NSRange(location: lineStart, length: 0)))
        default:
            return .none  // normal モードでは未対応キーも文字挿入させない
        }
    }

    private func deleteLine(text: NSString, caret: Int) -> Action {
        let lineRange = text.lineRange(for: NSRange(location: caret, length: 0))
        let newCaret = min(lineRange.location, text.length - lineRange.length)
        return .edit(EditCommand(
            replacementRange: lineRange, replacementString: "",
            selectedRange: NSRange(location: max(newCaret, 0), length: 0)))
    }
}
