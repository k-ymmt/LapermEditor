#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import LapermEditor

// テキスト: "# T\n"(0-3) "\n"(4) "Before\n"(5-11) "\n"(12) "```swift\n"(13-21) "let x = 1\n"(22-31) "print(x)\n"(32-40)
// "```"(41-43) "\n"(44) "\n"(45) "after"(46-50)
private let sample = "# T\n\nBefore\n\n```swift\nlet x = 1\nprint(x)\n```\n\nafter"

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

/// Live Preview のコードブロックは、キーボードが無い(first responder でない)間とキャレットが外にある間は箱に
/// 折りたたまれ、箱の上のタップは標準のタップより先に受け取ってタップした文字の間にキャレットを置く。コピーボタンの
/// タップは本文をペーストボードへコピーして展開しない(ADR 0020)。
@MainActor @Test func codeBlockCollapsesAndTheBoxInterceptsTaps() throws {
    let textView = makeLaidOutTextView(sample)
    let window = hostInWindow(textView)
    defer { withExtendedLifetime(window) {} }
    textView.isLivePreviewEnabled = true
    textView.selectedRange = NSRange(location: 48, length: 0)  // after
    textView.layoutIfNeeded()
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    let controller = textView.codeBlockPreviewController
    #expect(controller.collapsedLocations == [13])
    #expect(!enumeratedOffsets(textView).contains(22))
    let entry = try #require(textView.debugCodeBlockEntries.first)
    #expect(entry.layout.label?.string == "swift")
    #expect(entry.frame.minX == textView.editorTextContainerOrigin.x)
    #expect(entry.frame.width == textView.textContainer.size.width)

    // コピーボタンの上のタッチは自分のタップが受け取り、本文をコピーして展開しない
    let button = entry.layout.buttonFrame
    let buttonPoint = CGPoint(x: entry.frame.minX + button.midX, y: entry.frame.minY + button.midY)
    #expect(textView.shouldInterceptTap(atPoint: buttonPoint, modifiers: []))
    // シミュレータのテストバンドルからは UIPasteboard.general が読み戻せない(nil)ので、コピーの成立はエンジンの
    // 通知(チェックマーク)と、ブロックが展開されないことで確かめる。中身はコントローラのテストが持つ。
    #expect(textView.copyCodeBlock(atPoint: buttonPoint))
    #expect(controller.collapsedLocations == [13])
    #expect(textView.engine.copiedCodeBlockLocation == 13)
    #expect(textView.codeBlockPreviewController.copyText(forCodeBlockAt: 13) == "let x = 1\nprint(x)")

    // 本文の 1 行目の左端のタッチは、その文字の間(22)にキャレットを置いて展開する
    let content = entry.layout.contentFrame
    let point = CGPoint(x: entry.frame.minX + content.minX, y: entry.frame.minY + content.minY + 2)
    #expect(textView.shouldInterceptTap(atPoint: point, modifiers: []))
    #expect(!textView.copyCodeBlock(atPoint: point))
    #expect(textView.expandCodeBlock(atPoint: point))
    #expect(textView.selectedRange == NSRange(location: 22, length: 0))
    #expect(controller.collapsedLocations.isEmpty)
    #expect(enumeratedOffsets(textView).contains(22))
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    #expect(textView.debugCodeBlockEntries.isEmpty)
    #expect(!textView.shouldInterceptTap(atPoint: point, modifiers: []))

    // キーボードを閉じる(first responder を失う)と、キャレットがブロック内でも箱に戻る
    textView.resignFirstResponder()
    #expect(controller.collapsedLocations == [13])
    textView.becomeFirstResponder()
    #expect(controller.collapsedLocations.isEmpty)
    #expect(textView.text == sample)
}
#endif
