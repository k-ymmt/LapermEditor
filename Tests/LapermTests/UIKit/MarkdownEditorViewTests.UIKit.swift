#if canImport(UIKit)
import SwiftUI
import Testing
@testable import Laperm
@testable import LapermCore

@MainActor @Test func textViewDidChangeUpdatesBinding() {
    var text = "a"
    let binding = Binding(get: { text }, set: { text = $0 })
    let coordinator = MarkdownEditorView(text: binding).makeCoordinator()
    let textView = MarkdownTextView()
    textView.text = "changed"
    coordinator.textViewDidChange(textView)
    #expect(text == "changed")
}

@MainActor @Test func swiftUIUpdateGuardSuppressesFeedback() {
    var text = "a"
    let binding = Binding(get: { text }, set: { text = $0 })
    let coordinator = MarkdownEditorView(text: binding).makeCoordinator()
    let textView = MarkdownTextView()
    textView.text = "changed"
    coordinator.isUpdatingFromSwiftUI = true
    coordinator.textViewDidChange(textView)
    #expect(text == "a")
}

@MainActor @Test func typingUpdatesBindingThroughCoordinator() {
    // insertText 経由の入力で Coordinator に textViewDidChange が届き Binding が更新されること
    var text = ""
    let binding = Binding(get: { text }, set: { text = $0 })
    let view = MarkdownEditorView(text: binding)
    let coordinator = view.makeCoordinator()
    let textView = MarkdownTextView()
    textView.delegate = coordinator
    textView.insertText("x")
    #expect(text == "x")
}

@Test @MainActor func appliesOptionsModifiers() {
    let loader = DefaultImageLoader()
    let options = ImagePreviewOptions(
        baseURL: URL(filePath: "/docs/"), maxHeight: 200, allowsRemoteImages: true)
    let base = URL(filePath: "/docs/", directoryHint: .isDirectory)
    var openedURLs: [URL] = []
    let proxy = MarkdownEditorProxy()
    let view = MarkdownEditorView(text: .constant("hello"))
        .imagePreviewOptions(options)
        .imageLoader(loader)
        .linkOptions(LinkOptions(opensOnCommandClick: true, baseURL: base))
        .onOpenLink { openedURLs.append($0); return true }
        .foldingEnabled(false)
        .editorProxy(proxy)
    let textView = MarkdownTextView()
    view.apply(to: textView)
    #expect(textView.imagePreviewOptions == options)
    #expect(textView.imageLoader === loader)
    #expect(textView.linkOptions == LinkOptions(opensOnCommandClick: true, baseURL: base))
    #expect(textView.onOpenLink?(URL(string: "https://example.com")!) == true)
    #expect(openedURLs == [URL(string: "https://example.com")!])
    #expect(textView.isFoldingEnabled == false)
    #expect(proxy.textView === textView)
}

@MainActor @Test func outlineChangeIsDeliveredAsynchronously() async {
    let textView = MarkdownTextView()
    var received: [[OutlineItem]] = []
    let view = MarkdownEditorView(text: .constant("# A\nbody"))
        .onOutlineChange { received.append($0) }
    view.apply(to: textView)
    textView.text = "# A\nbody"
    textView.highlightAll()
    #expect(received.isEmpty)
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(received.map { $0.map(\.title) } == [["A"]])
}
#endif
