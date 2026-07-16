import SwiftUI
import Testing
@testable import Laperm
@testable import LapermCore

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

@MainActor private final class NullInterceptor: TextInputInterceptor {
    func textView(_ textView: MarkdownTextView, handle input: LapermCore.KeyInput)
        -> LapermCore.KeyInputResult
    { .passthrough }
}

@MainActor @Test func modifiersApplyInterceptorAndCursorStyle() {
    var text = ""
    let binding = Binding(get: { text }, set: { text = $0 })
    let interceptor = NullInterceptor()
    let view = MarkdownEditorView(text: binding)
        .inputInterceptor(interceptor)
        .insertionPointStyle(.block)

    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    view.apply(to: textView)
    #expect(textView.inputInterceptor === interceptor)
    #expect(textView.insertionPointStyle == .block)
}

@MainActor @Test func defaultModifiersLeaveTextViewUntouched() {
    var text = ""
    let binding = Binding(get: { text }, set: { text = $0 })
    let view = MarkdownEditorView(text: binding)

    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    view.apply(to: textView)
    #expect(textView.inputInterceptor == nil)
    #expect(textView.insertionPointStyle == .bar)
}

@Test @MainActor func appliesImagePreviewOptionsAndLoader() {
    let loader = DefaultImageLoader()
    let options = ImagePreviewOptions(
        baseURL: URL(filePath: "/docs/"), maxHeight: 200, allowsRemoteImages: true)
    var text = "hello"
    let view = MarkdownEditorView(text: .init(get: { text }, set: { text = $0 }))
        .imagePreviewOptions(options)
        .imageLoader(loader)
    let textView = MarkdownTextView()
    view.apply(to: textView)
    #expect(textView.imagePreviewOptions == options)
    #expect(textView.imageLoader === loader)
}

@Test @MainActor func changingOptionsResetsLoadStates() {
    let textView = MarkdownTextView()
    textView.string = "![a](a.png)"
    textView.highlightAll()
    // baseURL なし → 相対パスは failed
    let ref = textView.imagePreviewController.references.first
    #expect(ref != nil)
    #expect(textView.imagePreviewController.state(for: ref!) == .failed)
    // baseURL を設定すると再解決されて loading になる(実在パスなのでロード開始)
    let dir = try! writeTempPNG(name: "a.png").deletingLastPathComponent()
    textView.imagePreviewOptions = ImagePreviewOptions(baseURL: dir)
    let newRef = textView.imagePreviewController.references.first
    #expect(newRef != nil)
    #expect(textView.imagePreviewController.state(for: newRef!) != .failed)
}
