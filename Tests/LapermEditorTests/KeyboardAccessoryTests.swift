#if canImport(UIKit)
import SwiftUI
import Testing
import UIKit
@testable import LapermEditor

/// キーボードアクセサリ(iOS のみ)。`swift test` は macOS で走るので、このファイルは xcodebuild test で確かめる。
@MainActor @Test func keyboardAccessoryIsInstalledAsInputAccessoryView() {
    @State var text = ""
    let textView = MarkdownTextView()
    let coordinator = MarkdownEditorView.Coordinator(text: $text)
    let view = MarkdownEditorView(text: $text).keyboardAccessory { Text("bar") }
    view.applyKeyboardAccessory(to: textView, coordinator: coordinator)
    #expect(textView.inputAccessoryView != nil)
    #expect(textView.inputAccessoryView === coordinator.accessoryHost?.view)
    #expect(textView.inputAccessoryView?.backgroundColor == .clear)

    // 再適用では同じホストを使い回す
    let again = MarkdownEditorView(text: $text).keyboardAccessory { Text("baz") }
    let host = coordinator.accessoryHost
    again.applyKeyboardAccessory(to: textView, coordinator: coordinator)
    #expect(coordinator.accessoryHost === host)

    // 外すと inputAccessoryView も消える
    MarkdownEditorView(text: $text).applyKeyboardAccessory(to: textView, coordinator: coordinator)
    #expect(textView.inputAccessoryView == nil)
    #expect(coordinator.accessoryHost == nil)
}

@MainActor @Test func keyboardAccessoryHasIntrinsicHeight() {
    @State var text = ""
    let textView = MarkdownTextView()
    let coordinator = MarkdownEditorView.Coordinator(text: $text)
    MarkdownEditorView(text: $text).keyboardAccessory { Color.clear.frame(height: 56) }
        .applyKeyboardAccessory(to: textView, coordinator: coordinator)
    let accessory = try! #require(textView.inputAccessoryView)
    #expect(!accessory.translatesAutoresizingMaskIntoConstraints)
    #expect(accessory.intrinsicContentSize.height == 56)
}
#endif
