#if canImport(UIKit)
import Testing
import UIKit
@testable import LapermEditor

/// UITextView(TextKit 2)はフラグメントごとの描画面を renderingSurfaceBounds でクリップするため、
/// コードブロックの全幅背景は iOS でこそ壊れやすい。実際に描画した画素で確認する。
/// フラグメントビューのレイヤーは画面のスケール(iPhone は 3)で描かれる。それより低い
/// スケールで描くとレイヤーの縮小合成で段落の境界行が混色し、実際には無い継ぎ目を検出する
/// ので、同じスケールで描画する。
private let renderScale: CGFloat = 3

@MainActor
private func renderedPixels(of textView: MarkdownTextView) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = renderScale
    return UIGraphicsImageRenderer(bounds: textView.bounds, format: format).image { context in
        textView.layer.render(in: context.cgContext)
    }
}

/// テキストビュー座標(pt)の点の画素色。
private func color(in image: UIImage, at point: CGPoint) -> (r: UInt8, g: UInt8, b: UInt8)? {
    guard let cgImage = image.cgImage else { return nil }
    let width = cgImage.width, height = cgImage.height
    let x = Int(point.x * renderScale), y = Int(point.y * renderScale)
    guard x >= 0, y >= 0, x < width, y < height else { return nil }
    var pixel = [UInt8](repeating: 0, count: 4)
    guard let context = CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(cgImage, in: CGRect(x: -x, y: -(height - 1 - y), width: width, height: height))
    return (pixel[0], pixel[1], pixel[2])
}

private func isRed(_ c: (r: UInt8, g: UInt8, b: UInt8)?) -> Bool {
    guard let c else { return false }
    return c.r > 200 && c.g < 60 && c.b < 60
}

private func isWhite(_ c: (r: UInt8, g: UInt8, b: UInt8)?) -> Bool {
    guard let c else { return false }
    return c.r > 240 && c.g > 240 && c.b > 240
}

@MainActor @Test func codeBlockBackgroundIsDrawnAcrossTheFullWidthOnIOS() throws {
    var theme = MarkdownTheme.default
    theme.backgroundColor = .white
    theme.bodyColor = .black
    theme.codeBlockBackgroundColor = .red
    let textView = MarkdownTextView()
    textView.frame = CGRect(x: 0, y: 0, width: 400, height: 240)
    textView.showsLineNumbers = false
    textView.theme = theme
    textView.text = "x\n\n```\na\nb\n```\n\ny"
    textView.highlightAll()
    textView.layoutIfNeeded()
    let layoutManager = try #require(textView.textLayoutManager)
    layoutManager.ensureLayout(for: layoutManager.documentRange)
    layoutManager.textViewportLayoutController.layoutViewport()
    var fragments: [CodeBlockFragment] = []
    layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: []) {
        if let f = $0 as? CodeBlockFragment { fragments.append(f) }
        return true
    }
    try #require(fragments.count == 4)
    let image = renderedPixels(of: textView)
    let origin = CGPoint(x: textView.textContainerInset.left, y: textView.textContainerInset.top)
    let left = origin.x
    let right = origin.x + textView.textContainer.size.width
    func frame(_ i: Int) -> CGRect { fragments[i].layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y) }
    let lineA = frame(1)
    let lineB = frame(2)
    let box = CGRect(x: left, y: frame(0).minY, width: right - left, height: frame(3).maxY - frame(0).minY)

    // 行の高さで左端・中央・右端が塗られている(renderingSurfaceBounds を広げないと右側が切れる)
    for x in [left + 1, (left + right) / 2, right - 1] {
        #expect(isRed(color(in: image, at: CGPoint(x: x, y: lineA.midY))), "x=\(x)")
    }
    // 継ぎ目と上下余白
    #expect(isRed(color(in: image, at: CGPoint(x: right - 20, y: lineB.minY))))
    #expect(isRed(color(in: image, at: CGPoint(x: right - 20, y: box.minY + 1))))
    #expect(isRed(color(in: image, at: CGPoint(x: right - 20, y: box.maxY - 1))))
    // 角丸とブロック外
    #expect(isWhite(color(in: image, at: CGPoint(x: box.minX + 0.2, y: box.minY + 0.2))))
    #expect(isWhite(color(in: image, at: CGPoint(x: box.maxX - 0.2, y: box.maxY - 0.2))))
    #expect(isWhite(color(in: image, at: CGPoint(x: right - 20, y: box.minY - 2))))
    #expect(isWhite(color(in: image, at: CGPoint(x: right - 20, y: box.maxY + 2))))
}
#endif
