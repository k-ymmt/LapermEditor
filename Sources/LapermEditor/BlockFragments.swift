#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// 予約領域(reservedBottomHeight)を layoutFragmentFrame に確実に含める共通基底クラス。
/// TextKit2 は文書末尾の段落について trailing paragraphSpacing を
/// layoutFragmentFrame / usageBoundsForTextContainer に算入しないため、
/// 画像プレビューの予約がその段落の末尾に確保されないことがある
/// (装飾付き段落 = コードブロック/引用/水平線/テーブルであっても同様)。
/// テキスト行の下に reservedBottomHeight ぶんの高さを補うことで、
/// 文書末尾でも通常段落と同じ予約高さになるようにする。
/// `BlockFragmentProvider` が返すすべてのフラグメントの共通基底とすることで、
/// 「装飾の有無」と「画像予約の有無」を独立に組み合わせられるようにしている。
class ReservingTextLayoutFragment: NSTextLayoutFragment {
    /// この段落の末尾に確保すべき追加の高さ(画像プレビューの予約高さなど)。
    /// nil の場合は通常の `NSTextLayoutFragment` と同じ挙動になる。
    var reservedBottomHeight: CGFloat?

    /// テーマの行間(`MarkdownTheme.lineSpacing`)。TextKit 2 は行間を「文書の最初の行を除く
    /// 各行の上」に置くので、段落の先頭行もフラグメント上端から行間ぶん下に始まる。
    var lineSpacing: CGFloat = 0

    /// この段落が装飾ブロック(コードブロック / 引用 / テーブル)の先頭段落か。
    /// 先頭段落だけ行間を装飾の外に出す(途中の段落で下げると隣の段落の装飾との間に隙間が開く)。
    var isBlockStart = false

    /// ブロック装飾を上端から何 pt 下げて描き始めるか。ブロック先頭段落で、先頭行の上に入った
    /// 行間ぶんだけ(最大でも `lineSpacing`)下げて、行間を装飾の外に出す。文書の最初の行には
    /// 行間が付かないので 0 になる。paragraphSpacingBefore(コードブロックの上余白)は含めない。
    var decorationTopInset: CGFloat {
        guard isBlockStart else { return 0 }
        let firstLineTop = textLineFragments.first?.typographicBounds.minY ?? 0
        return max(0, min(lineSpacing, firstLineTop))
    }

    /// ブロック装飾の下端(フラグメント原点基準)。通常はフレーム下端(paragraphSpacing の予約込み)。
    /// 文書末尾の追加行(改行で終わる文書の最後の空行)があるときはその手前で止めるが、追加行の
    /// 上にも行間が入っている(minY = 末尾行下端 + paragraphSpacing + 行間)ので、その行間は除く。
    var decorationBottom: CGFloat {
        guard let extra = trailingExtraLineFragment else { return layoutFragmentFrame.height }
        return max(textLinesBottom, extra.typographicBounds.minY - lineSpacing)
    }

    /// 装飾を描く矩形(フラグメント原点基準)。`renderingSurfaceBounds` は描画に必要な領域で
    /// あって文字領域ではないので、上下は `decorationTopInset` / `decorationBottom` で決める。
    var decorationRect: CGRect {
        let top = decorationTopInset
        let bounds = renderingSurfaceBounds
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, decorationBottom - top))
    }

    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        guard let reservedBottomHeight, reservationApplies else { return frame }
        let needed = textLinesBottom + reservedBottomHeight
        if frame.height < needed { frame.size.height = needed }
        return frame
    }

    /// サブクラスが予約を見送りたい状況(既に高さが確保されている等)で false を返す。
    var reservationApplies: Bool { true }

    /// テキスト行群(文書末尾の追加行を除く)の下端(フラグメント原点からの相対値)。
    var textLinesBottom: CGFloat {
        let extra = trailingExtraLineFragment
        return textLineFragments.reduce(0) { $1 === extra ? $0 : max($0, $1.typographicBounds.maxY) }
    }

    /// 文書が改行で終わるとき、最後の段落のフラグメントに付く文字数ゼロの「追加行」
    /// (次に入力する行のためのキャレット位置)。それ以外は nil。
    var trailingExtraLineFragment: NSTextLineFragment? {
        guard textLineFragments.count > 1, let last = textLineFragments.last,
              last.characterRange.length == 0 else { return nil }
        return last
    }
}

/// コードブロック: テキストコンテナの全幅を段落の高さぶん塗る。
///
/// 1 つのコードブロックは段落(= 行)ごとのフラグメントに分かれるが、隣り合う段落の
/// 矩形を隙間なく連ね、ブロック先頭の段落だけ上の角、末尾の段落だけ下の角を丸めることで
/// 全体が 1 つの角丸の箱に見えるようにする。上下の内側余白はフラグメント側では作らず、
/// `BlockFragmentProvider` が先頭 / 末尾段落の段落スタイル(paragraphSpacingBefore /
/// paragraphSpacing)で確保した高さを、ここではそのまま塗るだけにする
/// (行の位置をずらすとキャレットやヒットテストとずれるため)。
final class CodeBlockFragment: ReservingTextLayoutFragment {
    static let cornerRadius: CGFloat = 4

    var fillColor: PlatformColor = .quaternarySystemFill
    /// ブロックの先頭段落(上の角を丸める)
    var roundsTop = false
    /// ブロックの末尾段落(下の角を丸める)
    var roundsBottom = false

    /// これ以上のコンテナ幅は「折り返しなし(実質無制限)」とみなし、全幅塗りをやめる。
    static let unboundedContainerWidth: CGFloat = 1_000_000

    /// 背景矩形(フラグメント原点基準)。`layoutFragmentFrame` はテキストの使用幅しか持たず、
    /// 原点 x は lineFragmentPadding ぶんずれているので、コンテナ左端(x = -frame.minX)から
    /// コンテナ幅ぶんを塗る。高さは段落スタイルの上下余白・予約領域込みのフレーム高。
    /// ただし文書末尾の追加行(改行で終わる文書の最後の空行)はブロックの外なので、
    /// その手前(= 末尾段落の paragraphSpacing の直後)で止める。
    var backgroundRect: CGRect {
        let frame = layoutFragmentFrame
        let width = Self.backgroundWidth(
            containerWidth: textLayoutManager?.textContainer?.size.width,
            textRightEdge: frame.maxX)
        let top = decorationTopInset
        return CGRect(x: -frame.minX, y: top, width: width, height: max(0, decorationBottom - top))
    }

    /// 背景の幅。コンテナ幅が 0(NSTextContainer では「無制限」)・非有限・無制限相当の
    /// 巨大値のときは全幅の意味がないので、コンテナ左端からテキスト右端までに落とす。
    static func backgroundWidth(containerWidth: CGFloat?, textRightEdge: CGFloat) -> CGFloat {
        guard let containerWidth, containerWidth > 0, containerWidth.isFinite,
              containerWidth < unboundedContainerWidth else { return max(0, textRightEdge) }
        return containerWidth
    }

    /// 追加行があるときは末尾段落の paragraphSpacing が追加行の手前に既に算入されている
    /// (文書末尾で落ちるのは改行なしで終わる場合だけ)ので、予約で二重に足さない。
    override var reservationApplies: Bool { trailingExtraLineFragment == nil }

    /// 描画面を背景矩形まで広げる。UITextView はフラグメントごとの描画面をこの境界で
    /// クリップするため、これを広げないと文字の周囲しか塗れない。
    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(backgroundRect)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        // 段落ごとの矩形が隣接するので、辺をデバイスピクセルに揃えてアンチエイリアスの
        // 継ぎ目(薄い線)が出ないようにする。point は呼び出し側が指定する描画原点
        // (NSTextView / UITextView は CTM を原点へ移した上で .zero を渡してくる)。
        let rect = Self.pixelAligned(backgroundRect.offsetBy(dx: point.x, dy: point.y), in: context)
        let path = CGPath.blockBackground(
            in: rect, cornerRadius: Self.cornerRadius,
            roundsTop: roundsTop, roundsBottom: roundsBottom)
        context.setFillColor(fillColor.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }

    /// rect の各辺をデバイスピクセル境界に丸めたもの(ユーザー座標で返す)。
    static func pixelAligned(_ rect: CGRect, in context: CGContext) -> CGRect {
        let device = context.convertToDeviceSpace(rect).standardized
        let snapped = CGRect(
            x: device.minX.rounded(), y: device.minY.rounded(),
            width: device.maxX.rounded() - device.minX.rounded(),
            height: device.maxY.rounded() - device.minY.rounded())
        return context.convertToUserSpace(snapped).standardized
    }
}

extension CGPath {
    /// 上下の角を個別に丸められる矩形パス(y 下向きのフラグメント座標を前提に、
    /// minY 側を「上」として扱う)。
    static func blockBackground(
        in rect: CGRect, cornerRadius: CGFloat, roundsTop: Bool, roundsBottom: Bool
    ) -> CGPath {
        let radius = max(0, min(cornerRadius, rect.width / 2, rect.height / 2))
        let top = roundsTop ? radius : 0
        let bottom = roundsBottom ? radius : 0
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        if top > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                tangent2End: CGPoint(x: rect.maxX, y: rect.minY + top), radius: top)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        if bottom > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.maxX - bottom, y: rect.maxY), radius: bottom)
        }
        path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        if bottom > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottom), radius: bottom)
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top))
        if top > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                tangent2End: CGPoint(x: rect.minX + top, y: rect.minY), radius: top)
        }
        path.closeSubpath()
        return path
    }
}

/// 引用: 行頭側に縦のアクセントバー。
///
/// バーは `BlockFragmentProvider` が表示用の段落スタイル(headIndent / firstLineHeadIndent)で
/// 空けた `indent` の余白の中に描く。x はテキストコンテナの端(段落によらず一定)から決め、
/// 字形のインク境界(`renderingSurfaceBounds`)や段落ごとに変わるフラグメント原点には依存させない:
/// インク境界は先頭の字形(Live Preview で ">" が隠れた行は本文の 1 文字目)で 1〜3pt 変わるので、
/// それを基準にすると複数行の引用でバーが行ごとにずれて見える。辺はデバイスピクセルに揃え、
/// 隣り合う段落のバーが継ぎ目なく 1 本に見えるようにする。
/// 右から左へ書く段落(右寄せで、余白も右側に付く)ではバーも右端に置く。
final class BlockquoteFragment: ReservingTextLayoutFragment {
    /// バーの幅(pt)。
    static let barWidth: CGFloat = 3
    /// 余白の端からバーまでの距離(pt)。余白が狭ければ `barInset(indent:)` で詰める。
    static let barInset: CGFloat = 1

    var barColor: PlatformColor = .systemGray
    /// 本文を行頭から下げた幅(`MarkdownTheme.blockquoteIndent`)。バーはこの中に置く。
    var indent: CGFloat = 0

    /// 余白の端からバーまでの実際の距離。余白がバーより狭ければ余白の中に収まる範囲で端に寄せ、
    /// 余白が無ければ 0(バーは行頭に重なる)。
    static func barInset(indent: CGFloat) -> CGFloat {
        min(barInset, max(0, indent - barWidth))
    }

    /// バーの矩形(フラグメント原点基準)。
    /// 上下は `decorationRect` と同じだが、`decorationRect` は `renderingSurfaceBounds` を参照する
    /// (ここではそれをバーまで広げている)ので、再帰しないよう上下端の値から直接組み立てる。
    var barRect: CGRect {
        let top = decorationTopInset
        return CGRect(x: barX, y: top, width: Self.barWidth, height: max(0, decorationBottom - top))
    }

    /// バーの x(フラグメント原点基準)。コンテナ座標で決めてフラグメント座標へ変換する:
    /// LTR はコンテナ左端 + lineFragmentPadding + inset、RTL はコンテナ右端 - lineFragmentPadding
    /// - inset - 幅。フラグメント原点はコンテナ左端から `layoutFragmentFrame.minX` にある。
    private var barX: CGFloat {
        let frame = layoutFragmentFrame
        let container = textLayoutManager?.textContainer
        let padding = container?.lineFragmentPadding ?? 0
        let inset = Self.barInset(indent: indent)
        let containerLeft = -frame.minX
        if isRightToLeft, let width = container?.size.width, width > 0, width.isFinite,
           width < CodeBlockFragment.unboundedContainerWidth {
            return containerLeft + width - padding - inset - Self.barWidth
        }
        return containerLeft + padding + inset
    }

    /// 段落が右寄せ(右から左へ書く段落)か。LTR の段落は先頭行がコンテナ座標で必ず
    /// lineFragmentPadding + indent から始まり、RTL の段落はテキストの幅ぶん右にずれる。
    /// フラグメント原点ではなく先頭行で見るのは、文書末尾の段落のフレームがインデントの無い
    /// 追加行(改行の後のキャレット行)まで含んで左に広がるため。
    private var isRightToLeft: Bool {
        let padding = textLayoutManager?.textContainer?.lineFragmentPadding ?? 0
        let firstLineX = layoutFragmentFrame.minX + (textLineFragments.first?.typographicBounds.minX ?? 0)
        return firstLineX - padding - max(0, indent) > 0.5
    }

    /// 描画面をバーの矩形まで広げる(UITextView はこの境界でクリップする)。
    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(barRect)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        let rect = CodeBlockFragment.pixelAligned(barRect.offsetBy(dx: point.x, dy: point.y), in: context)
        context.setFillColor(barColor.cgColor)
        context.fill(rect)
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

/// 水平線: "---" テキストに重ねて罫線を描画
final class ThematicBreakFragment: ReservingTextLayoutFragment {
    var lineColor: PlatformColor = .lapermSeparator

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        let bounds = renderingSurfaceBounds.offsetBy(dx: point.x, dy: point.y)
        // 罫線は "---" のテキスト行の中央に引く(行間ぶん上に入った余白で中心がずれないように)。
        let midY = textLineFragments.first.map { point.y + $0.typographicBounds.midY } ?? bounds.midY
        context.setStrokeColor(lineColor.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: bounds.minX, y: midY))
        context.addLine(to: CGPoint(x: bounds.maxX, y: midY))
        context.strokePath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

/// テーブル: テキスト背面に角丸背景
final class TableBackgroundFragment: ReservingTextLayoutFragment {
    var fillColor: PlatformColor = .quaternarySystemFill

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        let rect = decorationRect.offsetBy(dx: point.x, dy: point.y).insetBy(dx: 2, dy: 0)
        let path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.setFillColor(fillColor.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}
