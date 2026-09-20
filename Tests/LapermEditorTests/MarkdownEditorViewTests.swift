#if os(macOS)
import SwiftUI
import Testing
@testable import LapermEditor
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

@MainActor @Test func appliesOutlineAndFoldingModifiers() {
    let textView = MarkdownTextView()
    var received: [[OutlineItem]] = []
    let proxy = MarkdownEditorProxy()
    let view = MarkdownEditorView(text: .constant("# A\nbody"))
        .onOutlineChange { received.append($0) }
        .foldingEnabled(false)
        .editorProxy(proxy)
    view.apply(to: textView)
    #expect(textView.isFoldingEnabled == false)
    #expect(textView.onOutlineChange != nil)
    #expect(proxy.textView === textView)
}

@MainActor @Test func outlineChangeIsDeliveredAsynchronously() async {
    let textView = MarkdownTextView()
    var received: [[OutlineItem]] = []
    let view = MarkdownEditorView(text: .constant("# A\nbody"))
        .onOutlineChange { received.append($0) }
    view.apply(to: textView)
    textView.string = "# A\nbody"
    textView.highlightAll()
    // 同期時点では未配信(ビュー更新中の @State 破棄を避けるための遅延)
    #expect(received.isEmpty)
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(received.map { $0.map(\.title) } == [["A"]])
}

@MainActor @Test func foldingChangeIsDeliveredAsynchronously() async {
    let textView = MarkdownTextView()
    var received: [[Int]] = []
    let view = MarkdownEditorView(text: .constant("# A\nbody"))
        .onFoldingChange { received.append($0) }
    view.apply(to: textView)
    #expect(textView.onFoldingChange != nil)
    textView.string = "# A\nbody"
    textView.highlightAll()
    textView.fold(at: 0)
    // 同期時点では未配信(ビュー更新中の @State 破棄を避けるための遅延)
    #expect(received.isEmpty)
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(received == [[0]])
    #expect(textView.foldedHeadingLocations == [0])
}

@MainActor @Test func proxyForwardsToTextView() {
    let proxy = MarkdownEditorProxy()
    let textView = MarkdownTextView()
    textView.string = "# A\nbody"
    textView.highlightAll()
    proxy.textView = textView
    proxy.fold(at: 0)
    #expect(textView.isFolded(at: 0))
    proxy.unfoldAll()
    #expect(!textView.isFolded(at: 0))
}

@MainActor @Test func linkModifiersApplyToTextView() {
    let base = URL(filePath: "/docs/", directoryHint: .isDirectory)
    var openedURLs: [URL] = []
    let view = MarkdownEditorView(text: .constant("[a](b.md)"))
        .linkOptions(LinkOptions(opensOnCommandClick: true, baseURL: base))
        .onOpenLink { openedURLs.append($0); return true }
    let textView = MarkdownTextView()
    view.apply(to: textView)
    #expect(textView.linkOptions == LinkOptions(opensOnCommandClick: true, baseURL: base))
    #expect(textView.onOpenLink?(URL(string: "https://example.com")!) == true)
    #expect(openedURLs == [URL(string: "https://example.com")!])
}
#endif

#if os(macOS)
@MainActor @Test func editingOptionsModifierIsAppliedToTextView() {
    var text = ""
    let binding = Binding(get: { text }, set: { text = $0 })
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    #expect(textView.editingOptions == EditingOptions())

    let options = EditingOptions(continuesLists: false, completesPairs: false)
    MarkdownEditorView(text: binding).editingOptions(options).apply(to: textView)
    #expect(textView.editingOptions == options)

    MarkdownEditorView(text: binding).apply(to: textView)
    #expect(textView.editingOptions == EditingOptions())
}
#endif
