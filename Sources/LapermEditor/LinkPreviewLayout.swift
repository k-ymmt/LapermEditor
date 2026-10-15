#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import LapermCore

/// Live Preview で Link Preview のカードを描くレイアウト(Laperm ADR 0046)。カードの左上を原点とする座標を持つ。描画は
/// `LinkPreviewRenderer`、配置はエンジンのビューポートレイアウトパスが行う。
///
/// 左にタイトル 1 行・説明 2 行・ホスト名(サイト名)1 行、右に `imageSide` の正方形の画像(aspect fill、読めたときだけ)。
/// 幅はコンテナ幅まで、上限 `maxWidth`、左寄せ。高さは中身で決まる(画像が無ければ低い)。色は Theme の既存の項目を
/// 流用する(背景 `codeBlockBackground`、タイトル `link`、説明とホスト名は本文色を薄めたもの)。
struct LinkPreviewLayout: Equatable, BlockPreviewLayout {
    /// テーマから引く見た目。
    struct Appearance: Equatable, BlockPreviewAppearance {
        var background: PlatformColor
        var titleFont: PlatformFont
        var titleColor: PlatformColor
        /// 説明とホスト名のフォント(本文より少し小さい)
        var detailFont: PlatformFont
        var descriptionColor: PlatformColor
        var hostColor: PlatformColor

        init(theme: MarkdownTheme) {
            background = theme.codeBlockBackgroundColor
            titleFont = Self.titleFont(forBodyFont: theme.bodyFont)
            titleColor = theme.renderingColor(for: .link) ?? .lapermLink
            detailFont = Self.detailFont(forBodyFont: theme.bodyFont)
            descriptionColor = theme.bodyColor.withAlphaComponent(0.7)
            hostColor = theme.bodyColor.withAlphaComponent(0.5)
        }

        /// タイトル: 本文のフォントの太字(太字の無いフォントはそのまま)。
        static func titleFont(forBodyFont bodyFont: PlatformFont) -> PlatformFont {
            #if canImport(AppKit)
            return NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
            #else
            guard let descriptor = bodyFont.fontDescriptor.withSymbolicTraits(.traitBold) else { return bodyFont }
            return UIFont(descriptor: descriptor, size: bodyFont.pointSize)
            #endif
        }

        /// 説明とホスト名: 本文のフォントの 0.85 倍(9pt 以上)。
        static func detailFont(forBodyFont bodyFont: PlatformFont) -> PlatformFont {
            bodyFont.withSize(max(9, (bodyFont.pointSize * 0.85).rounded()))
        }
    }

    var preview: LinkPreview
    var size: CGSize
    var titleText: NSAttributedString
    var titleFrame: CGRect
    var descriptionText: NSAttributedString?
    var descriptionFrame: CGRect?
    var hostText: NSAttributedString?
    var hostFrame: CGRect?
    /// 画像(読めたときだけ)と置く正方形(カード座標)
    var image: PlatformImage?
    var imageFrame: CGRect?

    /// カードの幅の上限
    static let maxWidth: CGFloat = 560
    /// 画像の正方形の一辺
    static let imageSide: CGFloat = 88
    /// カードの内側の余白
    static let padding: CGFloat = 10
    /// 文字と画像の間
    static let imageGap: CGFloat = 10
    /// 行の間
    static let lineGap: CGFloat = 2
    static let cornerRadius: CGFloat = CodeBlockFragment.cornerRadius
    static let imageCornerRadius: CGFloat = 6
    /// 隠した段落とカードの間の余白。予約高さに含める。
    static let topMargin: CGFloat = 0
    /// カードの下と本文の間に空ける余白。予約高さに含める。
    static let bottomMargin: CGFloat = 0
    /// 幅が決まっていない(0 や非有限)ときに使う幅
    static let fallbackWidth: CGFloat = 320

    var reservedHeight: CGFloat { Self.topMargin + size.height + Self.bottomMargin }

    static func make(preview: LinkPreview, image: PlatformImage?, host: String?, maxWidth: CGFloat, appearance: Appearance) -> LinkPreviewLayout {
        let available = maxWidth.isFinite && maxWidth > 0 ? maxWidth : fallbackWidth
        let width = min(available, self.maxWidth)
        let imageWidth = image == nil ? 0 : imageSide + imageGap
        let textWidth = max(1, width - padding * 2 - imageWidth)

        let titleText = NSAttributedString(
            string: preview.title, attributes: attributes(font: appearance.titleFont, color: appearance.titleColor, lineBreakMode: .byTruncatingTail))
        let titleHeight = FrontMatterTableLayout.lineHeight(of: appearance.titleFont)
        var y = titleHeight
        var descriptionText: NSAttributedString?
        var descriptionHeight: CGFloat = 0
        if let description = preview.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            let text = NSAttributedString(
                string: description, attributes: attributes(font: appearance.detailFont, color: appearance.descriptionColor, lineBreakMode: .byWordWrapping))
            let lineHeight = FrontMatterTableLayout.lineHeight(of: appearance.detailFont)
            let measured = FrontMatterTableLayout.measure(text, width: textWidth).height
            descriptionHeight = min(ceil(measured), lineHeight * 2)
            descriptionText = text
            y += lineGap + descriptionHeight
        }
        var hostText: NSAttributedString?
        var hostHeight: CGFloat = 0
        if let host = (preview.siteName ?? host)?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            hostText = NSAttributedString(
                string: host, attributes: attributes(font: appearance.detailFont, color: appearance.hostColor, lineBreakMode: .byTruncatingTail))
            hostHeight = FrontMatterTableLayout.lineHeight(of: appearance.detailFont)
            y += lineGap + hostHeight
        }
        let textBlockHeight = y
        let height = ceil(max(textBlockHeight, image == nil ? 0 : imageSide) + padding * 2)
        // 文字の列と画像は縦方向の中央に揃える
        var top = (height - textBlockHeight) / 2
        let titleFrame = CGRect(x: padding, y: top, width: textWidth, height: titleHeight)
        top += titleHeight
        var descriptionFrame: CGRect?
        if descriptionText != nil {
            top += lineGap
            descriptionFrame = CGRect(x: padding, y: top, width: textWidth, height: descriptionHeight)
            top += descriptionHeight
        }
        var hostFrame: CGRect?
        if hostText != nil {
            top += lineGap
            hostFrame = CGRect(x: padding, y: top, width: textWidth, height: hostHeight)
        }
        let imageFrame = image == nil ? nil : CGRect(x: width - padding - imageSide, y: (height - imageSide) / 2, width: imageSide, height: imageSide)
        return LinkPreviewLayout(
            preview: preview, size: CGSize(width: width, height: height), titleText: titleText, titleFrame: titleFrame,
            descriptionText: descriptionText, descriptionFrame: descriptionFrame, hostText: hostText, hostFrame: hostFrame,
            image: image, imageFrame: imageFrame)
    }

    private static func attributes(font: PlatformFont, color: PlatformColor, lineBreakMode: NSLineBreakMode) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = lineBreakMode
        return [.font: font, .foregroundColor: color, .paragraphStyle: style]
    }
}

/// オーバーレイに渡すカードの配置(frame はテキストビュー座標)。両 OS 共通。
struct LinkPreviewEntry: @MainActor BlockPreviewOverlayEntry {
    /// 段落の先頭(`LinkPreviewCandidate.range.location`。文書座標)。オーバーレイがビューを使い回す鍵。
    var location: Int
    var layout: LinkPreviewLayout
    var appearance: LinkPreviewLayout.Appearance
    var frame: CGRect

    func draw(in context: CGContext, visibleRect: CGRect) {
        LinkPreviewRenderer.draw(layout, appearance: appearance, in: context)
    }
}

/// カードの描画。両 OS のオーバーレイが `draw(_:)` から呼ぶ(座標は y 下向き、原点はカードの左上)。
enum LinkPreviewRenderer {
    static func draw(_ layout: LinkPreviewLayout, appearance: LinkPreviewLayout.Appearance, in context: CGContext) {
        let bounds = CGRect(origin: .zero, size: layout.size)
        guard bounds.width > 0, bounds.height > 0 else { return }
        context.saveGState()
        let radius = LinkPreviewLayout.cornerRadius
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(appearance.background.cgColor)
        context.fillPath()
        // 行数は矩形の高さで決まり、最後に見える行は省略記号で切る(`.truncatesLastVisibleLine`)
        layout.titleText.draw(with: layout.titleFrame, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
        if let text = layout.descriptionText, let frame = layout.descriptionFrame {
            text.draw(with: frame, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
        }
        if let text = layout.hostText, let frame = layout.hostFrame {
            text.draw(with: frame, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
        }
        if let image = layout.image, let frame = layout.imageFrame {
            drawImage(image, fillingSquare: frame, in: context)
        }
        context.restoreGState()
    }

    /// 画像を正方形に aspect fill で描く(角丸で切り抜く)。
    static func drawImage(_ image: PlatformImage, fillingSquare square: CGRect, in context: CGContext) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(square.width / size.width, square.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let rect = CGRect(
            x: square.midX - drawn.width / 2, y: square.midY - drawn.height / 2, width: drawn.width, height: drawn.height)
        context.saveGState()
        let radius = LinkPreviewLayout.imageCornerRadius
        context.addPath(CGPath(roundedRect: square, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        #if canImport(AppKit)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        #else
        image.draw(in: rect)
        #endif
        context.restoreGState()
    }
}
