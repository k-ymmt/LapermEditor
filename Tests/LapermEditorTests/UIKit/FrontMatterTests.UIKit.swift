#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import LapermEditor

// テキスト: "---\n"(0-3) "title: Foo\n"(4-14) "tags:\n"(15-20) "  - a\n"(21-26) "---\n"(27-30) "# H\n"(31-34) "body"(35-38)
private let sample = "---\ntitle: Foo\ntags:\n  - a\n---\n# H\nbody"

@MainActor
private func enumeratedOffsets(_ textView: MarkdownTextView) -> [Int] {
    let contentManager = textView.textLayoutManager!.textContentManager!
    var offsets: [Int] = []
    contentManager.enumerateTextElements(from: contentManager.documentRange.location) { element in
        if let location = element.elementRange?.location {
            offsets.append(contentManager.offset(from: contentManager.documentRange.location, to: location))
        }
        return true
    }
    return offsets
}

/// Live Preview の Front Matter は、キーボードが無い(first responder でない)間とキャレットが本文にある間は表に
/// 折りたたまれ、表の上のタップは標準のタップより先に受け取って Property の行にキャレットを置く(ADR 0016)。
@MainActor @Test func frontMatterCollapsesAndTheTableInterceptsTaps() throws {
    let textView = makeLaidOutTextView(sample)
    let window = hostInWindow(textView)
    defer { withExtendedLifetime(window) {} }
    textView.isLivePreviewEnabled = true
    textView.selectedRange = NSRange(location: 36, length: 0)  // body
    textView.layoutIfNeeded()
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    #expect(textView.frontMatterController.isCollapsed)
    #expect(!enumeratedOffsets(textView).contains(4))
    let entry = try #require(textView.debugFrontMatterEntry)
    #expect(entry.layout.rows.count == 2)
    #expect(entry.frame.width == textView.textContainer.size.width, "the table spans the text container like a code block box")

    // 表の 2 行目(tags)の上のタッチは自分のタップが受け取り、その行末(20)にキャレットを置いて展開する
    let point = CGPoint(x: entry.frame.minX + 20, y: entry.frame.minY + entry.layout.rows[1].frame.midY)
    #expect(textView.shouldInterceptTap(atPoint: point, modifiers: []))
    #expect(textView.expandFrontMatter(atPoint: point))
    #expect(textView.selectedRange == NSRange(location: 20, length: 0))
    #expect(!textView.frontMatterController.isCollapsed)
    #expect(enumeratedOffsets(textView).contains(4))
    // 展開中は表が無いのでタップは標準処理へ
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    #expect(textView.debugFrontMatterEntry == nil)
    #expect(!textView.shouldInterceptTap(atPoint: point, modifiers: []))

    // キーボードを閉じる(first responder を失う)と、キャレットがブロック内でも表に戻る
    textView.resignFirstResponder()
    #expect(textView.frontMatterController.isCollapsed)
    textView.becomeFirstResponder()
    #expect(!textView.frontMatterController.isCollapsed)
    #expect(textView.text == sample)
}
#endif
