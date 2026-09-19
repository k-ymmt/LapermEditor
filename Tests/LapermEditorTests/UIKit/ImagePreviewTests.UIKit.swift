#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import LapermCore
@testable import LapermEditor

@MainActor
private func layoutTextView(string: String, imageHeight: CGFloat = 50) throws
    -> (textView: MarkdownTextView, imageLocation: Int) {
    let url = try writeTempPNG(name: "sample.png", width: 100, height: Int(imageHeight))
    let textView = MarkdownTextView()
    textView.frame = CGRect(x: 0, y: 0, width: 500, height: 600)
    textView.imagePreviewController.options =
        ImagePreviewOptions(baseURL: url.deletingLastPathComponent())
    textView.text = string
    textView.highlightAll()
    // ロードを実行せず状態を確定させる(ヘッドレスの決定性のため)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: imageHeight)).image { _ in }
    textView.imagePreviewController.setStateForTesting(.loaded(image), destination: "sample.png")
    textView.highlightAll()
    textView.layoutIfNeeded()
    textView.textLayoutManager?.ensureLayout(for: textView.textLayoutManager!.documentRange)
    textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    let location = (string as NSString).range(of: "![").location
    return (textView, location)
}

@MainActor
private func textLineBottom(of textView: MarkdownTextView, at location: Int) -> CGFloat? {
    guard let lm = textView.textLayoutManager,
          let cm = lm.textContentManager,
          let start = cm.location(cm.documentRange.location, offsetBy: location),
          let fragment = lm.textLayoutFragment(for: start) else { return nil }
    let bottom = fragment.textLineFragments.reduce(0) { max($0, $1.typographicBounds.maxY) }
    return fragment.layoutFragmentFrame.minY + bottom + textView.editorTextContainerOrigin.y
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
    #expect(entry.frame.minY >= lineBottom)
    // ガターのインセットぶん右にずれる
    #expect(entry.frame.minX >= textView.textContainerInset.left)
}

@Test @MainActor func lastLineImageReservesSpaceInUsageBounds() throws {
    let (textView, _) = try layoutTextView(string: "hello\n\n![sample](sample.png)")
    guard let lm = textView.textLayoutManager else {
        Issue.record("no layout manager")
        return
    }
    // テキスト 3 行 + 予約(画像 50 + padding)。行高は iOS のフォントメトリクス由来なので実測値で組む
    let lineHeight = textView.theme.bodyFont.lineHeight
    let height = lm.usageBoundsForTextContainer.height
    #expect(height >= 3 * lineHeight + 50 + ImagePreviewController.padding - 0.5)
}

@Test @MainActor func defaultLoaderLoadsLocalPNG() async throws {
    let url = try writeTempPNG(name: "a.png", width: 100, height: 50)
    let image = try await DefaultImageLoader().loadImage(for: url)
    #expect(image.size.width == 100)
    #expect(image.size.height == 50)
}

@Test @MainActor func changingOptionsResetsLoadStates() {
    let textView = MarkdownTextView()
    textView.text = "![a](a.png)"
    textView.highlightAll()
    let ref = textView.imagePreviewController.references.first
    #expect(ref != nil)
    #expect(textView.imagePreviewController.state(for: ref!) == .failed)
    let dir = try! writeTempPNG(name: "a.png").deletingLastPathComponent()
    textView.imagePreviewOptions = ImagePreviewOptions(baseURL: dir)
    let newRef = textView.imagePreviewController.references.first
    #expect(newRef != nil)
    #expect(textView.imagePreviewController.state(for: newRef!) != .failed)
}
#endif
