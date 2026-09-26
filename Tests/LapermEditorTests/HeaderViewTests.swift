#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import LapermEditor

/// ヘッダ(本文の上に置くサブビュー)は本文を `textContainerInset.height` だけ下げ、テキストコンテナと同じ
/// 左右位置(余白 + lineFragmentPadding)に置かれる。
@MainActor @Test func headerInsetsTheTextAndAlignsWithTheContainer() {
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    textView.margins = .readable
    textView.showsLineNumbers = false
    scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    scrollView.layoutSubtreeIfNeeded()
    #expect(textView.textContainerInset == NSSize(width: 20, height: 0))

    let header = NSView()
    textView.headerHeight = 50
    #expect(textView.textContainerInset.height == 0, "the height alone does nothing without a header view")
    textView.headerView = header
    #expect(header.superview === textView)
    #expect(textView.textContainerInset == NSSize(width: 20, height: 50))
    #expect(textView.textContainerOrigin.y == 50, "the text starts below the header")
    textView.layoutSubtreeIfNeeded()
    let padding = textView.textContainer!.lineFragmentPadding
    #expect(header.frame == NSRect(x: 20 + padding, y: 0, width: 400 - 2 * (20 + padding), height: 50))

    // 幅が変わっても余白に追従する: (1024 − 40 × 17) / 2 = 172(bodyFont 17pt)
    var theme = textView.theme
    theme.bodyFont = .systemFont(ofSize: 17)
    textView.theme = theme
    scrollView.frame = NSRect(x: 0, y: 0, width: 1024, height: 300)
    scrollView.layoutSubtreeIfNeeded()
    #expect(textView.textContainerInset == NSSize(width: 172, height: 50), "the margin update keeps the header inset")
    #expect(header.frame.minX == 172 + padding)
    #expect(header.frame.width == 680 - 2 * padding)

    // 高さの変更と取り外し
    textView.headerHeight = 30
    #expect(textView.textContainerInset.height == 30)
    textView.headerView = nil
    #expect(header.superview == nil)
    #expect(textView.textContainerInset == NSSize(width: 172, height: 0))
}

/// NSTextView は子要素を公開しないので、ヘッダを accessibility の子として返す(XCUITest / 支援技術向け)。
/// NSControl は自身を無視してセルを要素にするので、要素そのものである NSView で確かめる。
@MainActor @Test func headerIsExposedAsAnAccessibilityChild() {
    let textView = MarkdownTextView()
    let header = NSView()
    header.setAccessibilityElement(true)
    header.setAccessibilityRole(.group)
    #expect((textView.accessibilityChildren() ?? []).isEmpty)
    textView.headerView = header
    let children = textView.accessibilityChildren() ?? []
    #expect(children.contains { ($0 as AnyObject) === header })
    textView.headerView = nil
    #expect((textView.accessibilityChildren() ?? []).isEmpty)
}

/// 幅追従を切ったテキストコンテナでは、ヘッダの幅はビュー幅ではなくコンテナの幅(行のパディングを除く)に合わせる。
@MainActor @Test func headerWidthFollowsANonTrackingContainer() {
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    textView.showsLineNumbers = false
    scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    scrollView.layoutSubtreeIfNeeded()
    let container = textView.textContainer!
    container.widthTracksTextView = false
    container.size = NSSize(width: 200, height: container.size.height)
    let header = NSView()
    textView.headerView = header
    textView.headerHeight = 40
    textView.layoutSubtreeIfNeeded()
    let padding = container.lineFragmentPadding
    #expect(header.frame.minX == padding)
    #expect(header.frame.width == 200 - 2 * padding, "\(header.frame)")
}

@MainActor @Test func headerHeightIsSanitized() {
    let textView = MarkdownTextView()
    textView.headerView = NSView()
    textView.headerHeight = -10
    #expect(textView.textContainerInset.height == 0)
    textView.headerHeight = .infinity
    #expect(textView.textContainerInset.height == 0)
    textView.headerHeight = .nan
    #expect(textView.textContainerInset.height == 0)
}

/// `.headerView(height:_:)` は SwiftUI ビューを NSHostingView に載せてテキストビューへ付け、再適用では
/// 同じホストを使い回し、外すと消える。
@MainActor @Test func editorViewInstallsTheHeader() {
    let textView = MarkdownTextView()
    let coordinator = MarkdownEditorView.Coordinator(text: .constant(""))
    MarkdownEditorView(text: .constant("")).headerView(height: 40) { Text("title") }
        .applyHeader(to: textView, coordinator: coordinator)
    let host = try! #require(coordinator.headerHost)
    #expect(textView.headerView === host)
    #expect(textView.headerHeight == 40)
    #expect(textView.textContainerInset.height == 40)
    #expect(host.translatesAutoresizingMaskIntoConstraints, "the text view sets the frame")

    MarkdownEditorView(text: .constant("")).headerView(height: 48) { Text("other") }
        .applyHeader(to: textView, coordinator: coordinator)
    #expect(coordinator.headerHost === host, "re-applying reuses the host")
    #expect(textView.headerHeight == 48)

    MarkdownEditorView(text: .constant("")).applyHeader(to: textView, coordinator: coordinator)
    #expect(coordinator.headerHost == nil)
    #expect(textView.headerView == nil)
    #expect(textView.textContainerInset.height == 0)
}

@MainActor private final class HeaderHeightModel: ObservableObject {
    @Published var height: CGFloat = 40
}

private struct AutoHeaderHost: View {
    @ObservedObject var model: HeaderHeightModel
    var body: some View {
        MarkdownEditorView(text: .constant("Body"), theme: .default)
            .editorMargins(.readable)
            .headerView { Color.clear.frame(height: model.height) }
    }
}

/// 期限までランループを回しながら条件を待つ(固定の待ち時間はフレークと無駄な待ちの両方を生む)。
@MainActor
private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return true
}

@MainActor
private func makeWindow(_ hosting: NSView, width: CGFloat = 600) -> NSWindow {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hosting
    hosting.frame = CGRect(x: 0, y: 0, width: width, height: 400)
    window.layoutIfNeeded()
    return window
}

@MainActor
private func findTextView(_ view: NSView) -> MarkdownTextView? {
    if let textView = view as? MarkdownTextView { return textView }
    for subview in view.subviews { if let found = findTextView(subview) { return found } }
    return nil
}

/// `.headerView(_:)`(高さ指定なし)は中身の理想の高さをヘッダの高さにし、中身の高さが変わる(タイトルが折り返して
/// 2 行になるなど)と本文の開始位置とホストの frame も追従する。
@MainActor @Test func autoHeightHeaderFollowsItsContent() throws {
    let model = HeaderHeightModel()
    let hosting = NSHostingView(rootView: AutoHeaderHost(model: model))
    let window = makeWindow(hosting)
    let textView = try #require(findTextView(hosting))
    #expect(waitUntil { textView.headerHeight == 40 }, "the first measurement arrives: \(textView.headerHeight)")
    let header = try #require(textView.headerView)
    #expect(textView.textContainerInset.height == 40)
    #expect(header.frame.height == 40)
    #expect(header.frame.minX == textView.textContainerInset.width + textView.textContainer!.lineFragmentPadding)

    model.height = 90
    #expect(waitUntil { textView.headerHeight == 90 }, "the header grows with its content: \(textView.headerHeight)")
    window.layoutIfNeeded()
    #expect(textView.textContainerInset.height == 90)
    #expect(header.frame.height == 90)
    #expect(textView.textContainerOrigin.y == 90, "the text starts below the taller header")
    withExtendedLifetime(window) {}
}

private struct WrappingHeaderHost: View {
    var body: some View {
        MarkdownEditorView(text: .constant("Body"), theme: .default)
            .editorMargins(.readable)
            .headerView {
                Text("A rather long title that does not fit on one line and has to wrap in a narrow window")
                    .font(.system(size: 26, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
    }
}

/// 折り返す中身(Laperm の Note のタイトル)は、ヘッダの幅で計った行数ぶんの高さになり、幅が広がって行数が減れば
/// 低くなる(縦の `fixedSize` が幅に対する理想の高さを取る)。
@MainActor @Test func wrappingHeaderHeightFollowsTheWidth() throws {
    let hosting = NSHostingView(rootView: WrappingHeaderHost())
    let window = makeWindow(hosting, width: 360)
    let textView = try #require(findTextView(hosting))
    #expect(waitUntil { textView.headerHeight > 0 }, "the first measurement arrives")
    let narrow = textView.headerHeight
    #expect(narrow > 60, "the title wraps onto several lines in a 360pt window: \(narrow)")
    #expect(textView.textContainerInset.height == narrow)
    #expect(textView.textContainerOrigin.y == narrow, "the text starts below the wrapped title")

    window.setContentSize(NSSize(width: 1400, height: 400))
    hosting.frame = CGRect(x: 0, y: 0, width: 1400, height: 400)
    window.layoutIfNeeded()
    #expect(waitUntil { textView.headerHeight < narrow }, "a wider header needs fewer lines: \(textView.headerHeight) vs \(narrow)")
    #expect(textView.headerHeight > 0)
    #expect(textView.textContainerInset.height == textView.headerHeight)
    #expect(textView.headerView?.frame.height == textView.headerHeight)
    withExtendedLifetime(window) {}
}

private struct GroupHeaderHost: View {
    var body: some View {
        MarkdownEditorView(text: .constant("Body"), theme: .default)
            .headerView {
                Group {
                    Color.clear.frame(height: 40)
                    Color.clear.frame(height: 90)
                }
            }
    }
}

/// 中身が複数のビュー(Group)なら、要素ごとの高さではなく縦に積んだ全体の高さになる。
@MainActor @Test func autoHeightHeaderStacksMultipleRoots() throws {
    let hosting = NSHostingView(rootView: GroupHeaderHost())
    let window = makeWindow(hosting)
    let textView = try #require(findTextView(hosting))
    #expect(waitUntil { textView.headerHeight == 130 }, "40 + 90, not one of them: \(textView.headerHeight)")
    withExtendedLifetime(window) {}
}

/// 高さ指定なしのヘッダを載せても、計測が届くまでテキストビューの `headerHeight` は触らない(0 のまま)。
@MainActor @Test func editorViewLeavesTheAutoHeightToTheMeasurement() {
    let textView = MarkdownTextView()
    let coordinator = MarkdownEditorView.Coordinator(text: .constant(""))
    textView.headerHeight = 12
    MarkdownEditorView(text: .constant("")).headerView { Text("title") }
        .applyHeader(to: textView, coordinator: coordinator)
    #expect(textView.headerView === coordinator.headerHost)
    #expect(textView.headerHeight == 12, "no fixed height is pushed; the content reports its own")
}
#endif
