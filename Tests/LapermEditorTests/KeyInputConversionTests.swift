#if os(macOS)
import AppKit
import Testing
@testable import LapermEditor
@testable import LapermCore

@MainActor @Test func convertsPlainCharacter() {
    let input = KeyInput(event: keyEvent("a"))
    #expect(input == KeyInput(key: .character("a")))
}

@MainActor @Test func convertsShiftedCharacterWithModifier() {
    let input = KeyInput(event: keyEvent("A", ignoringModifiers: "A", modifiers: .shift))
    #expect(input == KeyInput(key: .character("A"), modifiers: .shift))
}

@MainActor @Test func convertsControlCharacterFromIgnoringModifiers() {
    // Ctrl+A: characters は制御文字だが charactersIgnoringModifiers は "a"
    let input = KeyInput(event: keyEvent("\u{01}", ignoringModifiers: "a", modifiers: .control))
    #expect(input == KeyInput(key: .character("a"), modifiers: .control))
}

@MainActor @Test func convertsEscape() {
    let input = KeyInput(event: keyEvent("\u{1B}", keyCode: 53))
    #expect(input == KeyInput(key: .escape))
}

@MainActor @Test func convertsArrowKeys() {
    #expect(KeyInput(event: keyEvent("\u{F700}", keyCode: 126)) == KeyInput(key: .up))
    #expect(KeyInput(event: keyEvent("\u{F701}", keyCode: 125)) == KeyInput(key: .down))
    #expect(KeyInput(event: keyEvent("\u{F702}", keyCode: 123)) == KeyInput(key: .left))
    #expect(KeyInput(event: keyEvent("\u{F703}", keyCode: 124)) == KeyInput(key: .right))
}

@MainActor @Test func convertsBackTabToShiftTab() {
    // Shift+Tab は charactersIgnoringModifiers が back-tab 文字(0x19)になる
    let input = KeyInput(event: keyEvent("\u{19}", modifiers: .shift, keyCode: 48))
    #expect(input == KeyInput(key: .tab, modifiers: .shift))
}

@MainActor @Test func convertsReturnBackspaceForwardDelete() {
    #expect(KeyInput(event: keyEvent("\r", keyCode: 36)) == KeyInput(key: .return))
    #expect(KeyInput(event: keyEvent("\u{7F}", keyCode: 51)) == KeyInput(key: .backspace))
    #expect(KeyInput(event: keyEvent("\u{F728}", keyCode: 117)) == KeyInput(key: .forwardDelete))
}

@MainActor @Test func rejectsKeyUpAndFunctionKeys() {
    #expect(KeyInput(event: keyEvent("a", type: .keyUp)) == nil)
    // F1(0xF704)は対象外
    #expect(KeyInput(event: keyEvent("\u{F704}", keyCode: 122)) == nil)
}
#endif
