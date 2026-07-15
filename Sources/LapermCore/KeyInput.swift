import Foundation

/// AppKit 非依存のキー入力表現。
/// character は Shift 適用済み("A" は character("A") + shift)。
public struct KeyInput: Equatable, Sendable {
    public enum Key: Equatable, Sendable {
        case character(Character)
        case escape
        case `return`
        case tab
        case backspace
        case forwardDelete
        case up, down, left, right
        case pageUp, pageDown, home, end
    }

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public let key: Key
    public let modifiers: Modifiers

    public init(key: Key, modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// インターセプタの応答。
public enum KeyInputResult: Equatable, Sendable {
    /// イベントを消費する。テキストビューには渡さない
    case handled
    /// 通常の処理(IME・挿入・キーバインディング)へ流す
    case passthrough
}
