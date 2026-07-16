import AppKit
import Foundation
import Testing
import LapermCore
@testable import Laperm

private func ref(location: Int, destination: String) -> ImageReference {
    ImageReference(
        altText: "alt", destination: destination,
        range: NSRange(location: location, length: 10),
        paragraphRange: NSRange(location: 0, length: 30))
}

@Test func stacksImagesBottomUpInSourceOrder() {
    // テキスト行下端 104 から予約領域 = (50+8) + (30+8) = 96 を下に積む
    let items = ImagePreviewLayout.itemFrames(
        references: [ref(location: 0, destination: "a.png"), ref(location: 12, destination: "b.png")],
        sizes: [CGSize(width: 100, height: 50), CGSize(width: 60, height: 30)],
        fragmentFrame: CGRect(x: 0, y: 0, width: 500, height: 200),
        textLinesBottom: 104,
        leadingInset: 5,
        padding: 8)
    #expect(items.count == 2)
    // 1 枚目: テキスト行下端(y = 104)+ padding/2
    #expect(items[0].frame == CGRect(x: 5, y: 108, width: 100, height: 50))
    // 2 枚目: 1 枚目のスロット(58)ぶん下
    #expect(items[1].frame == CGRect(x: 5, y: 166, width: 60, height: 30))
}

@Test func stacksBelowTextLineRegardlessOfFragmentHeight() {
    // 末尾段落: layoutFragmentFrame に spacing が含まれず height=17 でも、
    // テキスト行下端(17)を起点にプレビューはテキストの下へ積まれる(上に食い込まない)。
    let items = ImagePreviewLayout.itemFrames(
        references: [ref(location: 0, destination: "a.png")],
        sizes: [CGSize(width: 100, height: 50)],
        fragmentFrame: CGRect(x: 0, y: 34, width: 500, height: 17),
        textLinesBottom: 17,
        leadingInset: 5,
        padding: 8)
    #expect(items.count == 1)
    // フラグメント原点(34)+ テキスト行下端(17)= 51 が予約領域先頭、+ padding/2
    #expect(items[0].frame == CGRect(x: 5, y: 55, width: 100, height: 50))
    #expect(items[0].frame.minY > 34 + 17)  // テキスト行下端より下
}

@Test func emptyReferencesYieldNoItems() {
    let items = ImagePreviewLayout.itemFrames(
        references: [], sizes: [],
        fragmentFrame: CGRect(x: 0, y: 0, width: 500, height: 20),
        textLinesBottom: 17,
        leadingInset: 5, padding: 8)
    #expect(items.isEmpty)
}

@Test @MainActor func overlayReusesAndRemovesItemViews() {
    let overlay = ImagePreviewOverlayView()
    let reference = ref(location: 0, destination: "a.png")
    overlay.update(entries: [ImagePreviewOverlayEntry(
        reference: reference,
        frame: NSRect(x: 0, y: 0, width: 100, height: 50),
        state: .loading)])
    #expect(overlay.subviews.count == 1)
    let first = overlay.subviews[0]

    // 同じ参照の更新はビューを使い回す
    overlay.update(entries: [ImagePreviewOverlayEntry(
        reference: reference,
        frame: NSRect(x: 0, y: 10, width: 100, height: 50),
        state: .failed)])
    #expect(overlay.subviews.count == 1)
    #expect(overlay.subviews[0] === first)
    #expect(overlay.subviews[0].frame.origin.y == 10)

    // ビューポート外に出たら取り外す
    overlay.update(entries: [])
    #expect(overlay.subviews.isEmpty)
}

@Test @MainActor func overlayIsNotHitTestable() {
    let overlay = ImagePreviewOverlayView()
    #expect(overlay.hitTest(NSPoint(x: 1, y: 1)) == nil)
}
