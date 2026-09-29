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

/// 閉じていないフェンス(Laperm issue #4): "```" の後で改行したキャレット行(文書末の追加行)も箱の中。
/// iOS でも追加行の背景が renderingSurfaceBounds で切られず、キャレット矩形が箱の中に収まる。
@MainActor @Test func unclosedFenceCaretLineIsPaintedOnIOS() throws {
    var theme = MarkdownTheme.default
    theme.backgroundColor = .white
    theme.bodyColor = .black
    theme.codeBlockBackgroundColor = .red
    let textView = MarkdownTextView()
    textView.frame = CGRect(x: 0, y: 0, width: 400, height: 240)
    textView.showsLineNumbers = false
    textView.theme = theme
    // 再パースを必ず同期にする(負荷でパースが閾値を超えるとバックグラウンドへ回り、highlightNow が同期を待たない)
    textView.markdownHighlighter.backgroundParseThreshold = .seconds(60)
    textView.text = "```\n"
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
    let only = try #require(fragments.first)
    #expect(fragments.count == 1)
    #expect(only.includesTrailingExtraLine && only.roundsBottom)
    let extra = try #require(only.trailingExtraLineFragment)
    let origin = CGPoint(x: textView.textContainerInset.left, y: textView.textContainerInset.top)
    let frame = only.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
    let left = origin.x
    let right = origin.x + textView.textContainer.size.width
    let image = renderedPixels(of: textView)
    // キャレット行の高さで左端・中央・右端が塗られている
    let caretLineY = frame.minY + extra.typographicBounds.midY
    for x in [left + 1, (left + right) / 2, right - 1] {
        #expect(isRed(color(in: image, at: CGPoint(x: x, y: caretLineY))), "x=\(x)")
    }
    // 箱の下(予約した下余白の下)は塗られていない
    #expect(isWhite(color(in: image, at: CGPoint(x: (left + right) / 2, y: frame.maxY + 3))))
    // 実際のキャレット矩形(文書末)は箱の中
    let caret = textView.caretRect(for: textView.endOfDocument)
    #expect(caret.minY >= frame.minY - 0.5 && caret.maxY <= frame.maxY + 0.5, "caret \(caret) in \(frame)")
    // 追加行に入力すると(再パース前でも)新しい段落が箱の中に入る
    func codeBlockFragments() -> [CodeBlockFragment] {
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var found: [CodeBlockFragment] = []
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: []) {
            if let f = $0 as? CodeBlockFragment { found.append(f) }
            return true
        }
        return found
    }
    textView.selectedRange = NSRange(location: 4, length: 0)
    textView.insertText("a\n")
    #expect(codeBlockFragments().count == 2)
    // 再パースで追加行の扱いと末尾の角丸が新しい末尾段落へ移る(UITextView は変わらない段落のフラグメントを
    // 使い回すので、装飾レンジの変化による無効化が要る)
    textView.engine.highlightNow()
    let after = codeBlockFragments()
    let described = after.map { "extra=\($0.includesTrailingExtraLine) bottom=\($0.roundsBottom) range=\($0.rangeInElement)" }
    #expect(after.map(\.includesTrailingExtraLine) == [false, true], "\(described)")
    #expect(after.map(\.roundsBottom) == [false, true], "\(described)")
    let caretAfter = textView.caretRect(for: textView.endOfDocument)
    let lastFrame = try #require(after.last).layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
    #expect(caretAfter.minY >= lastFrame.minY - 0.5 && caretAfter.maxY <= lastFrame.maxY + 0.5, "caret \(caretAfter) in \(lastFrame)")
}
/// テーブルの箱(Laperm issue #3)も iOS で全幅に塗られ、末尾に行を足す / 消すと旧末尾・新末尾の段落の下余白と角丸が
/// 付け替わる(UITextView は変わらない段落のフラグメントを使い回すので、再生成されることを確かめる)。
@MainActor @Test func tableBoxIsFullWidthAndItsPaddingMovesWithTheLastRowOnIOS() throws {
    var theme = MarkdownTheme.default
    theme.backgroundColor = .white
    theme.bodyColor = .black
    theme.tableBackgroundColor = .red
    let textView = MarkdownTextView()
    textView.frame = CGRect(x: 0, y: 0, width: 400, height: 240)
    textView.showsLineNumbers = false
    textView.theme = theme
    // 再パースを必ず同期にする(負荷でパースが閾値を超えるとバックグラウンドへ回り、highlightNow が同期を待たない)
    textView.markdownHighlighter.backgroundParseThreshold = .seconds(60)
    textView.text = "| a |\n|---|\n| 1 |\n\nafter\n"
    textView.highlightAll()
    textView.layoutIfNeeded()
    let layoutManager = try #require(textView.textLayoutManager)
    let contentManager = try #require(layoutManager.textContentManager)
    func fragment(at location: Int) -> NSTextLayoutFragment? {
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        layoutManager.textViewportLayoutController.layoutViewport()
        return contentManager.location(contentManager.documentRange.location, offsetBy: location).flatMap { layoutManager.textLayoutFragment(for: $0) }
    }
    func spacingAfter(at location: Int) -> CGFloat {
        let paragraph = fragment(at: location)?.textElement as? NSTextParagraph
        let style = paragraph?.attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        return style?.paragraphSpacing ?? 0
    }
    let padding = theme.codeBlockVerticalPadding
    #expect(spacingAfter(at: 12) == padding)
    #expect((fragment(at: 12) as? CodeBlockFragment)?.roundsBottom == true)

    // 行の中央の高さで、文字より右(右端の手前)も塗られている
    let row = try #require(fragment(at: 12))
    let image = renderedPixels(of: textView)
    let origin = CGPoint(x: textView.textContainerInset.left, y: textView.textContainerInset.top)
    let right = origin.x + textView.textContainer.size.width
    let rowMidY = origin.y + row.layoutFragmentFrame.minY + (row.textLineFragments.first?.typographicBounds.midY ?? 0)
    #expect(isRed(color(in: image, at: CGPoint(x: right - 20, y: rowMidY))), "right of the text at y \(rowMidY)")

    // 末尾に行を足す("| 1 |" の段落は編集しない)
    textView.textStorage.replaceCharacters(in: NSRange(location: 18, length: 0), with: "| 2 |\n")
    textView.highlightNow()
    #expect(spacingAfter(at: 12) == 0, "the old last row loses its bottom padding")
    #expect((fragment(at: 12) as? CodeBlockFragment)?.roundsBottom == false)
    #expect(spacingAfter(at: 18) == padding)
    #expect((fragment(at: 18) as? CodeBlockFragment)?.roundsBottom == true)

    // 消すと元に戻る
    textView.textStorage.replaceCharacters(in: NSRange(location: 18, length: 6), with: "")
    textView.highlightNow()
    #expect(spacingAfter(at: 12) == padding)
    #expect((fragment(at: 12) as? CodeBlockFragment)?.roundsBottom == true)
}
#endif
