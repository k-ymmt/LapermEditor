import SwiftUI
import Testing
@testable import Laperm

// NSViewRepresentable.Context は外部から構築できないため、makeNSView 経路は
// ExampleMacOS(Task 13-14)で検証し、ここでは Coordinator の同期ロジックを検証する。

@MainActor @Test func textDidChangeUpdatesBinding() {
    var text = "a"
    let binding = Binding(get: { text }, set: { text = $0 })
    let coordinator = MarkdownEditorView(text: binding).makeCoordinator()

    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    textView.string = "changed"
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    #expect(text == "changed")
}

@MainActor @Test func swiftUIUpdateGuardSuppressesFeedback() {
    var text = "a"
    let binding = Binding(get: { text }, set: { text = $0 })
    let coordinator = MarkdownEditorView(text: binding).makeCoordinator()

    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    textView.string = "changed"
    coordinator.isUpdatingFromSwiftUI = true
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    #expect(text == "a")  // ガード中は Binding を更新しない
}
