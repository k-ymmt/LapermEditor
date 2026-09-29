#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import LapermEditor

// Live Preview で描かれたリンクのタップと長押しのメニュー(Laperm ADR 0031 / issue #2)。

/// 文字範囲の最初の行の矩形の中央(ビュー座標)。
@MainActor
private func center(of range: NSRange, in textView: MarkdownTextView) throws -> CGPoint {
    let frame = try #require(textView.engine.segmentFrames(for: range)?.first)
    return CGPoint(x: frame.midX, y: frame.midY)
}

/// キーボードの無い(first responder でない)エディタでは全段落が描かれた状態: リンクの上のタップは標準のタップ
/// (キャレット移動)より先に受け取って開く。リンクの外は従来どおり標準処理へ。長押しのメニューは開く / コピー / 編集。
@MainActor @Test func renderedLinksInterceptTapsAndOfferTheLinkMenuOnIOS() throws {
    let textView = makeLaidOutTextView("Go [site](https://s.example) now\n\nplain\n")
    let window = hostInWindow(textView)
    defer { withExtendedLifetime(window) {} }
    textView.isLivePreviewEnabled = true
    textView.layoutIfNeeded()
    var opened: [URL] = []
    textView.onOpenLink = { opened.append($0); return true }
    let onSite = try center(of: NSRange(location: 4, length: 4), in: textView)
    let hit = try #require(textView.linkHit(atPoint: onSite))
    #expect(hit.isRendered)
    #expect(textView.shouldInterceptTap(atPoint: onSite, modifiers: []))
    #expect(textView.openRenderedLink(atPoint: onSite))
    #expect(opened == [URL(string: "https://s.example")!])
    #expect(!textView.shouldInterceptTap(atPoint: try center(of: NSRange(location: 29, length: 3), in: textView), modifiers: []))

    let menu = textView.linkMenu(for: hit)
    #expect(menu.children.compactMap { ($0 as? UIAction)?.title } == ["Open Link", "Copy Link", "Edit"])

    // 「編集」: キャレットを置いて編集を始めると、その段落のリンクは描かれた状態ではなくなる(タップはキャレット移動)
    textView.beginEditing(at: hit.editCaret)
    #expect(textView.selectedRange == hit.editCaret)
    textView.layoutIfNeeded()
    let editing = try center(of: NSRange(location: 4, length: 4), in: textView)
    #expect(textView.linkHit(atPoint: editing)?.isRendered == false)
    #expect(!textView.shouldInterceptTap(atPoint: editing, modifiers: []))
}
#endif
