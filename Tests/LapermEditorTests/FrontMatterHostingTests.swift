#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import LapermEditor

@MainActor
private func findTextView(_ view: NSView) -> MarkdownTextView? {
    if let textView = view as? MarkdownTextView { return textView }
    for subview in view.subviews { if let found = findTextView(subview) { return found } }
    return nil
}

@MainActor private final class TextModel: ObservableObject {
    @Published var text = ""
}

private struct Host: View {
    @ObservedObject var model: TextModel
    var body: some View {
        MarkdownEditorView(text: $model.text, theme: .default)
            .showsLineNumbers(true)
            .editorMargins(.readable)
            .livePreviewEnabled(true)
    }
}

/// Laperm と同じ構成(SwiftUI ホスト、読みやすい余白、Live Preview、本文は後から届く)で、表が実際のテキスト
/// コンテナ幅で描かれる。以前は幅の変化を `layout()` の中で受け取って再レイアウトを要求しても、その要求が
/// `layout()` の終わりで下ろされ、Note を開いた直後の表が初期の極小幅(値が 1 文字ずつ折り返す)のまま残った。
@MainActor @Test func hostedEditorRelaysOutTheTableAfterTheWidthSettles() throws {
    // Laperm は Note ごとにエディタを作るので、本文はビューがまだ幅を持たない makeNSView の時点で入る
    let model = TextModel()
    model.text = "---\ntitle: Meta\ndescription: A note with front matter\ntags:\n  - alpha\n  - beta\n---\n\n# Meta\n\nBody after the front matter.\n"
    let hosting = NSHostingView(rootView: Host(model: model))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hosting
    // サイドバーにフォーカスがある状態を再現: エディタは first responder ではない
    window.makeFirstResponder(nil)
    hosting.frame = CGRect(x: 0, y: 0, width: 900, height: 450)
    window.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    window.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let textView = try #require(findTextView(hosting))

    let controller = textView.frontMatterController
    #expect(controller.isCollapsed)
    #expect(controller.containerWidth == textView.textContainer!.size.width)
    // 手で layoutViewport() を呼ばずに、直近のビューポートレイアウトが置いた表を見る
    let entry = try #require(textView.debugFrontMatterEntry)
    #expect(entry.frame.width == textView.textContainer!.size.width, "table drawn with the settled width, not the initial one: \(entry.frame)")
    #expect(entry.layout.rows.count == 3)
    #expect(entry.layout.size.height < 200, "values are not wrapped character by character")
    withExtendedLifetime(window) {}
}
#endif
