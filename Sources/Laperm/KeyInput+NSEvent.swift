#if os(macOS)
import AppKit
import LapermCore

extension KeyInput {
    /// keyDown イベントから生成する。表現できないイベント(keyDown 以外、
    /// ファンクションキー等)は nil を返し、呼び出し側はデフォルト処理に流す。
    init?(event: NSEvent) {
        guard event.type == .keyDown,
            let chars = event.charactersIgnoringModifiers,
            let scalar = chars.unicodeScalars.first
        else { return nil }
        var modifiers = Modifiers()
        let flags = event.modifierFlags
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }

        let key: Key
        switch scalar.value {
        case 0x1B: key = .escape
        case 0x0D, 0x03: key = .return  // Return / テンキー Enter
        case 0x09: key = .tab
        case 0x19:  // Shift+Tab は back-tab 文字になる
            key = .tab
            modifiers.insert(.shift)
        case 0x7F: key = .backspace
        case 0xF728: key = .forwardDelete
        case 0xF700: key = .up
        case 0xF701: key = .down
        case 0xF702: key = .left
        case 0xF703: key = .right
        case 0xF72C: key = .pageUp
        case 0xF72D: key = .pageDown
        case 0xF729: key = .home
        case 0xF72B: key = .end
        case 0xF704...0xF7FF: return nil  // その他のファンクションキーは対象外
        default:
            // 印字可能文字。Ctrl 押下時も charactersIgnoringModifiers は元の文字を返す
            guard chars.count == 1 else { return nil }
            key = .character(Character(chars))
        }
        self.init(key: key, modifiers: modifiers)
    }
}
#endif
