import CoreGraphics

/// 本文の左右余白。テキストは最小余白を確保しつつ、最大幅(本文フォントサイズの倍数 = em)を超えない
/// 範囲でビューの中央に置く。行番号ガターが本文と同じビューに重なる iOS では、左余白はガター幅を
/// 下回らない(ガターが余白に収まる広さなら本文の位置は行番号の表示・非表示で動かない)。
/// macOS のガターはスクロールビューのルーラー(テキストビューの外)なので、余白は左右対称になる。
public struct EditorMargins: Equatable, Sendable {
    /// 左右それぞれの最小余白(pt)。`NSTextContainer.lineFragmentPadding` はこれに加わる。
    public var minimumHorizontal: CGFloat
    /// 本文の最大幅(本文フォントサイズの倍数)。nil で制限なし。
    public var maximumWidthInEms: CGFloat?

    public init(minimumHorizontal: CGFloat = 0, maximumWidthInEms: CGFloat? = nil) {
        self.minimumHorizontal = minimumHorizontal
        self.maximumWidthInEms = maximumWidthInEms
    }

    /// 余白なし(ビューの端まで本文が広がる。行番号ガターの幅だけは避ける)。
    public static let none = EditorMargins()

    /// 読みやすい余白: 左右 20pt 以上、本文は 40em(17pt なら 680pt、全角 40 字 / 半角約 80 字)まで。
    public static let readable = EditorMargins(minimumHorizontal: 20, maximumWidthInEms: 40)

    /// 左右の余白(テキストコンテナの inset)を決める。値は整数 pt に切り上げる(最小余白を下回らず、
    /// 本文が最大幅を超えない向き)。有限でない値(無限大・NaN)は 0 / 制限なしとして扱う。
    /// 余白がビューより広い設定でも右余白を削って本文幅を負にしない(ガター以上に狭いビューでは 0 になる)。
    /// - Parameters:
    ///   - viewWidth: 本文を置くビューの幅。
    ///   - gutterWidth: 本文と同じビューに重なるガターの幅(ガターがビューの外にあるなら 0)。
    ///   - fontSize: 本文フォントのサイズ(最大幅の基準)。
    func horizontalInsets(viewWidth: CGFloat, gutterWidth: CGFloat, fontSize: CGFloat)
        -> (leading: CGFloat, trailing: CGFloat)
    {
        let width = viewWidth.isFinite ? max(0, viewWidth) : 0
        let gutter = gutterWidth.isFinite ? max(0, gutterWidth) : 0
        let symmetric = symmetricMargin(viewWidth: width, fontSize: fontSize)
        // ガターの分は幅に関わらず確保する(レイアウト前の幅 0 でも本文がガターに重ならない)。
        let leading = max(symmetric, gutter)
        let trailing = min(symmetric, max(0, width - leading))
        return (leading, trailing)
    }

    /// 左右同値の余白(`NSTextView.textContainerInset` 用)。`horizontalInsets` の小さい側と同じで、
    /// 余白がビューの半分を超える設定でも本文幅を負にしない。
    func symmetricHorizontalInset(viewWidth: CGFloat, fontSize: CGFloat) -> CGFloat {
        let insets = horizontalInsets(viewWidth: viewWidth, gutterWidth: 0, fontSize: fontSize)
        return min(insets.leading, insets.trailing)
    }

    /// 最小余白と最大幅から決まる片側の余白(ガターを考慮しない)。
    private func symmetricMargin(viewWidth: CGFloat, fontSize: CGFloat) -> CGFloat {
        var symmetric = minimumHorizontal.isFinite ? max(0, minimumHorizontal) : 0
        if let ems = maximumWidthInEms, ems.isFinite, ems > 0, fontSize.isFinite, fontSize > 0 {
            symmetric = max(symmetric, (viewWidth - ems * fontSize) / 2)
        }
        return symmetric.rounded(.up)
    }
}
