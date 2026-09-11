#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import Laperm

/// レイアウト済みの MarkdownTextView を作る(ヘッドレスでも TextKit2 のレイアウトは動く)
@MainActor
func makeLaidOutTextView(_ markdown: String, width: CGFloat = 400, height: CGFloat = 300)
    -> MarkdownTextView {
    let textView = MarkdownTextView()
    textView.frame = CGRect(x: 0, y: 0, width: width, height: height)
    textView.text = markdown
    textView.highlightAll()
    textView.layoutIfNeeded()
    return textView
}

/// characterRange の表示フレーム中心点(textView 座標)を求める
@MainActor
func midpoint(of characterRange: NSRange, in textView: MarkdownTextView) -> CGPoint {
    let layoutManager = textView.textLayoutManager!
    let contentManager = layoutManager.textContentManager!
    layoutManager.ensureLayout(for: layoutManager.documentRange)
    let start = contentManager.location(
        contentManager.documentRange.location, offsetBy: characterRange.location)!
    let end = contentManager.location(start, offsetBy: characterRange.length)!
    let textRange = NSTextRange(location: start, end: end)!
    var frame = CGRect.zero
    layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) {
        _, segmentFrame, _, _ in
        frame = segmentFrame
        return false
    }
    let origin = textView.editorTextContainerOrigin
    return CGPoint(x: frame.midX + origin.x, y: frame.midY + origin.y)
}

/// テスト用の PNG データ(width×height の単色画像)
func makePNGData(width: Int, height: Int) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(
        size: CGSize(width: width, height: height), format: format
    ).image { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    return image.pngData()!
}

/// 一時ディレクトリに PNG を書き出して URL を返す
func writeTempPNG(name: String, width: Int = 100, height: Int = 50) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("LapermTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try makePNGData(width: width, height: height).write(to: url)
    return url
}

/// UITextView の undoManager はレスポンダチェーン(ウィンドウ)から供給されるため、
/// undo を検証するテストではウィンドウに載せて first responder にする。
@MainActor
func hostInWindow(_ textView: MarkdownTextView) -> UIWindow {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
    let controller = UIViewController()
    controller.view.addSubview(textView)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    textView.becomeFirstResponder()
    return window
}
#endif
