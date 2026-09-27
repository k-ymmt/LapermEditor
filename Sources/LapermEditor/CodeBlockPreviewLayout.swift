#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import LapermCore

/// Live Preview のコードブロックの箱に描くコードブロック 1 つの中身(Laperm ADR 0020): 言語と、インデントを除いた
/// 本文の行。位置はすべてブロックの先頭(`MarkdownCodeBlock.range.location`)からの相対値(前の編集で箱が動いても
/// 使い回せる)。純粋な値で、レイアウトのキャッシュのキーになる。
struct CodeBlockPreviewModel: Equatable {
    struct Line: Equatable {
        /// 表示する文字列(先頭のインデントを除いた行。改行を含まない)
        var text: String
        /// 表示する部分の先頭(ブロックの先頭からの相対値)。クリックでキャレットを置く位置の基準。
        var displayOffset: Int
        /// 行(改行を含まない)の末尾(ブロックの先頭からの相対値)
        var lineEndOffset: Int
    }

    var language: String?
    var lines: [Line]

    /// コピーする本文(行を改行で繋いだもの。フェンスとインデントを除く)。
    var copyText: String { lines.map(\.text).joined(separator: "\n") }

    static func make(block: MarkdownCodeBlock, text: NSString) -> CodeBlockPreviewModel? {
        guard NSMaxRange(block.range) <= text.length else { return nil }
        let origin = block.range.location
        let lines = block.contentLineRanges(in: text).map { line -> Line in
            let display = block.displayRange(ofContentLine: line, in: text)
            return Line(
                text: text.substring(with: display), displayOffset: display.location - origin,
                lineEndOffset: NSMaxRange(line) - origin)
        }
        return CodeBlockPreviewModel(language: block.language, lines: lines)
    }
}

/// Live Preview でコードブロックを描く箱のレイアウト(Laperm ADR 0020)。箱の左上を原点とする座標を持つ。描画は
/// `CodeBlockPreviewRenderer`、配置はエンジンのビューポートレイアウトパスが行う。
///
/// 箱の幅は本文の幅(Source のコードブロックの箱と同じくテキストコンテナの全幅)。本文は Theme のコードのフォントで
/// 折り返して描き、上下に同じ余白(`Appearance.verticalPadding`)を取る。言語名とコピーボタンは本文の最初の行の高さに
/// 揃えて右上に浮かせ(専用の帯は作らない: 帯のぶん上だけ余白が大きく見える)、最初の行の文字がその下に入らないよう
/// テキストコンテナの exclusion path で避ける(最初の行だけ右端が短く折り返す)。本文のレイアウトとヒットテストは同じ
/// TextKit 1 のスタック(`TextLayout`)で行い、描いた位置とクリックした位置がずれないようにする。
struct CodeBlockPreviewLayout: Equatable {
    /// 本文のレイアウト(TextKit 1)。レイアウトはモデル・幅・見た目が変わったときだけ作り直すので、同一性で比較する。
    final class TextLayout: Equatable {
        let storage: NSTextStorage
        let layoutManager: NSLayoutManager
        let container: NSTextContainer
        /// 各行の、本文の文字列(行を改行で繋いだもの)の中のレンジ。
        let lineRanges: [NSRange]

        /// `exclusion` は本文座標(左上原点)で文字を入れない矩形(右上の言語名とコピーボタンの場所)。
        init(model: CodeBlockPreviewModel, width: CGFloat, appearance: Appearance, exclusion: CGRect? = nil) {
            let joined = NSMutableAttributedString()
            var lineRanges: [NSRange] = []
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            style.lineSpacing = appearance.lineSpacing
            let attributes: [NSAttributedString.Key: Any] = [
                .font: appearance.codeFont, .foregroundColor: appearance.codeColor, .paragraphStyle: style,
            ]
            for (index, line) in model.lines.enumerated() {
                if index > 0 { joined.append(NSAttributedString(string: "\n", attributes: attributes)) }
                lineRanges.append(NSRange(location: joined.length, length: (line.text as NSString).length))
                joined.append(NSAttributedString(string: line.text, attributes: attributes))
            }
            self.lineRanges = lineRanges
            storage = NSTextStorage(attributedString: joined)
            layoutManager = NSLayoutManager()
            layoutManager.usesFontLeading = true
            container = NSTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            if let exclusion, !exclusion.isEmpty {
                #if canImport(AppKit)
                container.exclusionPaths = [NSBezierPath(rect: exclusion)]
                #else
                container.exclusionPaths = [UIBezierPath(rect: exclusion)]
                #endif
            }
            layoutManager.addTextContainer(container)
            storage.addLayoutManager(layoutManager)
            layoutManager.ensureLayout(for: container)
        }

        var usedHeight: CGFloat { ceil(layoutManager.usedRect(for: container).height) }

        static func == (lhs: TextLayout, rhs: TextLayout) -> Bool { lhs === rhs }
    }

    /// テーマから引く見た目。
    struct Appearance: Equatable, BlockPreviewAppearance {
        var background: PlatformColor
        var codeFont: PlatformFont
        var codeColor: PlatformColor
        /// 言語名のフォント(コードのフォントより少し小さい)
        var labelFont: PlatformFont
        /// 言語名とコピーボタンの色(Theme の `syntaxMarker`)
        var labelColor: PlatformColor
        var lineSpacing: CGFloat
        /// 箱の内側の上下の余白(先頭行の上と末尾行の下に同じだけ)。Theme の `codeBlockVerticalPadding`(Source の箱の
        /// 上下余白)を下回らず、少なくとも左右の余白と同じ(浮かせた言語名とコピーボタンが最初の行の高さからはみ出す
        /// ぶんの逃げでもある)。
        var verticalPadding: CGFloat

        init(theme: MarkdownTheme) {
            background = theme.codeBlockBackgroundColor
            codeFont = theme.layoutFont(for: .codeBlock) ?? theme.bodyFont
            codeColor = theme.renderingColor(for: .codeBlock) ?? theme.bodyColor
            labelFont = PlatformFont.systemFont(ofSize: max(9, (codeFont.pointSize * 0.8).rounded()), weight: .medium)
            labelColor = theme.renderingColor(for: .syntaxMarker) ?? .lapermTertiaryLabel
            lineSpacing = theme.lineSpacing
            verticalPadding = max(theme.codeBlockVerticalPadding, CodeBlockPreviewLayout.horizontalPadding)
        }
    }

    var model: CodeBlockPreviewModel
    var text: TextLayout
    var size: CGSize
    /// 本文を描く矩形(箱座標)
    var contentFrame: CGRect
    /// 言語名を描く矩形(箱座標)。言語が無ければ nil。
    var labelFrame: CGRect?
    /// 言語名の表示用の文字列
    var label: NSAttributedString?
    /// コピーボタン(ヒット領域。箱座標)
    var buttonFrame: CGRect

    static let horizontalPadding: CGFloat = 8
    static let cornerRadius: CGFloat = CodeBlockFragment.cornerRadius
    /// ボタンのヒット領域の一辺。言語名と一緒に本文の最初の行の高さの中央に置く(本文が無ければこの高さの行を 1 つ取る)。
    static let buttonSize: CGFloat = 18
    /// ボタンのアイコンの一辺
    static let iconSize: CGFloat = 11
    /// 言語名とボタンの間
    static let labelGap: CGFloat = 6
    /// 隠した先頭の段落と箱の間の余白。予約高さに含める。
    static let topMargin: CGFloat = 0
    /// 箱の下と本文の間に空ける余白。予約高さに含める。
    static let bottomMargin: CGFloat = 0
    /// 幅が決まっていない(0 や非有限)ときに使う幅
    static let fallbackWidth: CGFloat = 320

    /// 先頭の段落に予約する高さ(上余白 + 箱 + 下余白)。
    var reservedHeight: CGFloat { Self.topMargin + size.height + Self.bottomMargin }

    static func make(model: CodeBlockPreviewModel, maxWidth: CGFloat, appearance: Appearance) -> CodeBlockPreviewLayout {
        let width = maxWidth.isFinite && maxWidth > 0 ? maxWidth : fallbackWidth
        let contentWidth = max(1, width - horizontalPadding * 2)
        let pad = appearance.verticalPadding
        // 言語名とコピーボタンは本文の最初の行(無ければボタンの高さの行)の高さの中央に置く
        let lineHeight = FrontMatterTableLayout.lineHeight(of: appearance.codeFont)
        let headerRowHeight = model.lines.isEmpty ? max(lineHeight, buttonSize) : lineHeight
        let buttonFrame = CGRect(
            x: width - horizontalPadding - buttonSize, y: max(0, pad + (headerRowHeight - buttonSize) / 2),
            width: buttonSize, height: buttonSize)
        var label: NSAttributedString?
        var labelFrame: CGRect?
        if let language = model.language, !language.isEmpty {
            let attributed = NSAttributedString(
                string: language, attributes: [.font: appearance.labelFont, .foregroundColor: appearance.labelColor])
            let labelSize = FrontMatterTableLayout.measure(attributed, width: .greatestFiniteMagnitude)
            let labelWidth = min(labelSize.width, max(0, buttonFrame.minX - labelGap - horizontalPadding))
            label = attributed
            labelFrame = CGRect(
                x: buttonFrame.minX - labelGap - labelWidth, y: pad + (headerRowHeight - labelSize.height) / 2,
                width: labelWidth, height: labelSize.height)
        }
        // 最初の行の文字は言語名とボタンの下に入れない(本文座標)。高さは最初の行の中に収め、2 行目には掛けない。
        let headerLeft = max(0, (labelFrame?.minX ?? buttonFrame.minX) - labelGap - horizontalPadding)
        let exclusion = CGRect(x: headerLeft, y: 0, width: max(0, contentWidth - headerLeft), height: max(1, lineHeight - 1))
        let text = TextLayout(
            model: model, width: contentWidth, appearance: appearance, exclusion: model.lines.isEmpty ? nil : exclusion)
        let contentHeight = model.lines.isEmpty ? 0 : text.usedHeight
        let contentFrame = CGRect(x: horizontalPadding, y: pad, width: contentWidth, height: contentHeight)
        let height = ceil(pad + max(contentHeight, headerRowHeight) + pad)
        return CodeBlockPreviewLayout(
            model: model, text: text, size: CGSize(width: width, height: height), contentFrame: contentFrame,
            labelFrame: labelFrame, label: label, buttonFrame: buttonFrame)
    }

    /// 箱座標の点がコピーボタンの上か(周囲 2pt の遊びを含む)。
    func isOnCopyButton(_ point: CGPoint) -> Bool {
        buttonFrame.insetBy(dx: -2, dy: -2).contains(point)
    }

    /// 箱座標の点に対応するキャレット位置(ブロックの先頭からの相対値): 本文の上ならその点に最も近い文字の間(言語名や
    /// ボタンの脇の空きは最初の行の末尾)、本文より上なら最初の行の先頭、本文より下なら最後の行の末尾。箱の外(上下左右
    /// 4pt の遊びの外)なら nil。
    /// 本文が無ければ 0(ブロックの先頭)。
    func caretOffset(at point: CGPoint) -> Int? {
        guard CGRect(origin: .zero, size: size).insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        guard let first = model.lines.first, let last = model.lines.last else { return 0 }
        if point.y < contentFrame.minY { return first.displayOffset }
        if point.y >= contentFrame.maxY { return last.lineEndOffset }
        let local = CGPoint(
            x: min(max(0, point.x - contentFrame.minX), contentFrame.width), y: point.y - contentFrame.minY)
        var fraction: CGFloat = 0
        let index = text.layoutManager.characterIndex(
            for: local, in: text.container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        let string = text.storage.string as NSString
        var insertion = min(index, string.length)
        // 右半分なら次の挿入位置へ(サロゲートペアや結合文字の内部ではなく、合成文字の後ろ)。行の末尾の改行の後ろへは
        // 丸めない(次の行の先頭ではなくこの行の末尾)。
        if fraction > 0.5, index < string.length, string.character(at: index) != 0x0A {
            insertion = NSMaxRange(string.rangeOfComposedCharacterSequence(at: index))
        }
        guard let lineIndex = text.lineRanges.firstIndex(where: { insertion <= NSMaxRange($0) }) else { return last.lineEndOffset }
        let line = model.lines[lineIndex]
        let column = max(0, insertion - text.lineRanges[lineIndex].location)
        return min(line.displayOffset + column, line.lineEndOffset)
    }
}

/// オーバーレイに渡す箱の配置(frame はテキストビュー座標)。両 OS 共通。
struct CodeBlockPreviewEntry: @MainActor BlockPreviewOverlayEntry {
    /// ブロックの先頭(`MarkdownCodeBlock.range.location`。文書座標)。オーバーレイがビューを使い回す鍵。
    var location: Int
    var layout: CodeBlockPreviewLayout
    var appearance: CodeBlockPreviewLayout.Appearance
    var frame: CGRect
    /// コピー直後(ボタンがチェックマークになる)
    var showsCopied: Bool

    func draw(in context: CGContext, visibleRect: CGRect) {
        CodeBlockPreviewRenderer.draw(layout, appearance: appearance, showsCopied: showsCopied, in: context, visibleRect: visibleRect)
    }
}

/// 箱の描画。両 OS のオーバーレイが `draw(_:)` から呼ぶ(座標は y 下向き、原点は箱の左上)。`visibleRect`(描く必要の
/// ある矩形)を渡すと、それに掛からない本文の行は描かない。
enum CodeBlockPreviewRenderer {
    static func draw(
        _ layout: CodeBlockPreviewLayout, appearance: CodeBlockPreviewLayout.Appearance, showsCopied: Bool,
        in context: CGContext, visibleRect: CGRect? = nil
    ) {
        let bounds = CGRect(origin: .zero, size: layout.size)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let visible = visibleRect ?? bounds
        context.saveGState()
        let radius = CodeBlockPreviewLayout.cornerRadius
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(appearance.background.cgColor)
        context.fillPath()

        if let label = layout.label, let labelFrame = layout.labelFrame, labelFrame.intersects(visible) {
            label.draw(with: labelFrame, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
        if layout.buttonFrame.intersects(visible) {
            drawButton(in: layout.buttonFrame, showsCopied: showsCopied, color: appearance.labelColor, background: appearance.background, in: context)
        }
        if !layout.model.lines.isEmpty, layout.contentFrame.intersects(visible) {
            let text = layout.text
            let localVisible = visible.offsetBy(dx: -layout.contentFrame.minX, dy: -layout.contentFrame.minY)
            let glyphs = text.layoutManager.glyphRange(forBoundingRect: localVisible, in: text.container)
            if glyphs.length > 0 {
                text.layoutManager.drawGlyphs(forGlyphRange: glyphs, at: layout.contentFrame.origin)
            }
        }
        context.restoreGState()
    }

    /// コピーボタン: 重なった 2 枚の角丸の四角(コピー)、またはチェックマーク(コピー直後)。
    static func drawButton(in frame: CGRect, showsCopied: Bool, color: PlatformColor, background: PlatformColor, in context: CGContext) {
        let icon = CodeBlockPreviewLayout.iconSize
        let origin = CGPoint(x: frame.midX - icon / 2, y: frame.midY - icon / 2)
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if showsCopied {
            context.setLineWidth(1.6)
            context.move(to: CGPoint(x: origin.x + icon * 0.15, y: origin.y + icon * 0.55))
            context.addLine(to: CGPoint(x: origin.x + icon * 0.42, y: origin.y + icon * 0.82))
            context.addLine(to: CGPoint(x: origin.x + icon * 0.9, y: origin.y + icon * 0.2))
            context.strokePath()
        } else {
            context.setLineWidth(1.2)
            let square = icon * 0.7
            let back = CGRect(x: origin.x + icon - square, y: origin.y, width: square, height: square).insetBy(dx: 0.6, dy: 0.6)
            let front = CGRect(x: origin.x, y: origin.y + icon - square, width: square, height: square).insetBy(dx: 0.6, dy: 0.6)
            context.addPath(CGPath(roundedRect: back, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            context.strokePath()
            // 前の四角は背景で塗って後ろの四角の線を隠す
            let frontPath = CGPath(roundedRect: front, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
            context.addPath(frontPath)
            context.setFillColor(background.cgColor)
            context.fillPath()
            context.addPath(frontPath)
            context.strokePath()
        }
        context.restoreGState()
    }
}
