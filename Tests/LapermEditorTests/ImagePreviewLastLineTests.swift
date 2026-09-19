#if os(macOS)
import AppKit
import Foundation
import Testing
import LapermCore
@testable import LapermEditor

/// 画像記法が文書の最終行(末尾に改行なし)にあるとき、プレビューがテキスト行の
/// 上ではなく下に描かれ、かつ予約領域が usageBounds に含まれてクリップされないことを検証する。
///
/// 回帰の背景: TextKit2 は文書末尾の段落について trailing paragraphSpacing を
/// layoutFragmentFrame / usageBoundsForTextContainer に算入しない。そのため
/// (a) 予約領域が確保されず(クリップ)、(b) `maxY - totalHeight` 起点の配置が
/// テキストの上に食い込む、という二つの症状が出ていた。
@MainActor
private func layoutTextView(string: String, imageHeight: CGFloat = 50) throws
    -> (textView: MarkdownTextView, imageLocation: Int) {
    let url = try writeTempPNG(name: "sample.png", width: 100, height: Int(imageHeight))
    let textView = MarkdownTextView()
    textView.setFrameSize(NSSize(width: 500, height: 600))
    textView.imagePreviewController.options =
        ImagePreviewOptions(baseURL: url.deletingLastPathComponent())
    textView.string = string
    textView.highlightAll()
    // ロードを実行せず状態を確定させる(ヘッドレスの決定性のため)
    textView.imagePreviewController.setStateForTesting(
        .loaded(NSImage(size: NSSize(width: 100, height: imageHeight))), destination: "sample.png")
    textView.highlightAll()
    textView.textLayoutManager?.ensureLayout(for: textView.textLayoutManager!.documentRange)
    textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    let location = (string as NSString).range(of: "![").location
    return (textView, location)
}

/// 画像段落フラグメントのテキスト行下端(textView 座標)を求める。
@MainActor
private func textLineBottom(of textView: MarkdownTextView, at location: Int) -> CGFloat? {
    guard let lm = textView.textLayoutManager,
          let cm = lm.textContentManager,
          let start = cm.location(cm.documentRange.location, offsetBy: location),
          let fragment = lm.textLayoutFragment(for: start) else { return nil }
    let bottom = fragment.textLineFragments.reduce(0) { max($0, $1.typographicBounds.maxY) }
    return fragment.layoutFragmentFrame.minY + bottom + textView.textContainerOrigin.y
}

@Test @MainActor func lastLineImagePreviewIsBelowTextNotAbove() throws {
    let (textView, loc) = try layoutTextView(string: "hello\n\n![sample](sample.png)")
    guard let entry = textView.debugImageEntries.first(where: { $0.reference.range.location == loc }) else {
        Issue.record("no overlay entry collected for last-line image")
        return
    }
    guard let lineBottom = textLineBottom(of: textView, at: loc) else {
        Issue.record("could not resolve text line bottom")
        return
    }
    // プレビューはテキスト行の下端以降に置かれる(バグ時は上にずれて minY < lineBottom だった)
    #expect(entry.frame.minY >= lineBottom)
}

@Test @MainActor func lastLineImageReservesSpaceInUsageBounds() throws {
    // 予約領域が usageBounds に含まれること(含まれないと末尾でクリップされる)
    let (textView, _) = try layoutTextView(string: "hello\n\n![sample](sample.png)")
    guard let lm = textView.textLayoutManager else {
        Issue.record("no layout manager")
        return
    }
    // テキスト 3 行(17*3=51)+ 予約(50+8=58)= 109 相当。少なくともテキストのみより高い。
    let height = lm.usageBoundsForTextContainer.height
    #expect(height >= 51 + 50 + ImagePreviewController.padding)
}

@Test @MainActor func midDocumentImagePreviewStillBelowText() throws {
    // 回帰防止: 中間の画像は従来どおりテキストの下に置かれる
    let (textView, loc) = try layoutTextView(string: "hello\n\n![sample](sample.png)\n\nafter")
    guard let entry = textView.debugImageEntries.first(where: { $0.reference.range.location == loc }),
          let lineBottom = textLineBottom(of: textView, at: loc) else {
        Issue.record("no entry / line bottom for mid-doc image")
        return
    }
    #expect(entry.frame.minY >= lineBottom)
}

@Test @MainActor func lastLineImageInsideBlockquoteReservesSpaceInUsageBounds() throws {
    // 回帰防止: 装飾(引用)フラグメントが返されるパスでも、末尾行の画像予約が
    // usageBounds に含まれること(装飾が優先されて予約が消えるとクリップされる)。
    let (textView, _) = try layoutTextView(string: "hello\n\n> ![sample](sample.png)")
    guard let lm = textView.textLayoutManager else {
        Issue.record("no layout manager")
        return
    }
    // テキスト 3 行(17*3=51)+ 予約(50+8=58)= 109 相当。少なくともテキストのみより高い。
    let height = lm.usageBoundsForTextContainer.height
    #expect(height >= 51 + 50 + ImagePreviewController.padding)
}
#endif
