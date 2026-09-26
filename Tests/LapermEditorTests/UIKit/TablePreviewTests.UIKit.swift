#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import LapermEditor

// テキスト: "# T\n"(0-3) "\n"(4) "| a | b |\n"(5-14) "|---|:-:|\n"(15-24) "| 1 | 2 |\n"(25-34) "\n"(35) "after"(36-40)
private let sample = "# T\n\n| a | b |\n|---|:-:|\n| 1 | 2 |\n\nafter"

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

/// Live Preview のテーブルは、キーボードが無い(first responder でない)間とキャレットが外にある間は表に折りたたまれ、
/// 表の上のタップは標準のタップより先に受け取ってセルにキャレットを置く(ADR 0019)。
@MainActor @Test func tableCollapsesAndTheGridInterceptsTaps() throws {
    let textView = makeLaidOutTextView(sample)
    let window = hostInWindow(textView)
    defer { withExtendedLifetime(window) {} }
    textView.isLivePreviewEnabled = true
    textView.selectedRange = NSRange(location: 38, length: 0)  // after
    textView.layoutIfNeeded()
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    let controller = textView.tablePreviewController
    #expect(controller.collapsedLocations == [5])
    #expect(!enumeratedOffsets(textView).contains(15))
    let entry = try #require(textView.debugTableEntries.first)
    #expect(entry.layout.rows.count == 2)
    #expect(entry.frame.minX == textView.editorTextContainerOrigin.x + textView.textContainer.lineFragmentPadding)
    #expect(entry.frame.width <= textView.imageContainerWidth)

    // ボディ行の 2 列目の上のタッチは自分のタップが受け取り、そのセルの末尾(32)にキャレットを置いて展開する
    let cell = entry.layout.rows[1].cells[1]
    let point = CGPoint(x: entry.frame.minX + cell.frame.midX, y: entry.frame.minY + cell.frame.midY)
    #expect(textView.shouldInterceptTap(atPoint: point, modifiers: []))
    #expect(textView.expandTable(atPoint: point))
    #expect(textView.selectedRange == NSRange(location: 32, length: 0))
    #expect(controller.collapsedLocations.isEmpty)
    #expect(enumeratedOffsets(textView).contains(15))
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    #expect(textView.debugTableEntries.isEmpty)
    #expect(!textView.shouldInterceptTap(atPoint: point, modifiers: []))

    // キーボードを閉じる(first responder を失う)と、キャレットがテーブル内でも表に戻る
    textView.resignFirstResponder()
    #expect(controller.collapsedLocations == [5])
    textView.becomeFirstResponder()
    #expect(controller.collapsedLocations.isEmpty)
    #expect(textView.text == sample)
}
#endif
