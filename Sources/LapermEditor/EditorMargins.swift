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

    /// 左右の余白(テキストコンテナの inset)を決める。値は整数 pt に切り下げる。
    /// - Parameters:
    ///   - viewWidth: 本文を置くビューの幅。
    ///   - gutterWidth: 本文と同じビューに重なるガターの幅(ガターがビューの外にあるなら 0)。
    ///   - fontSize: 本文フォントのサイズ(最大幅の基準)。
    func horizontalInsets(viewWidth: CGFloat, gutterWidth: CGFloat, fontSize: CGFloat)
        -> (leading: CGFloat, trailing: CGFloat)
    {
        var symmetric = max(0, minimumHorizontal)
        if let ems = maximumWidthInEms, ems > 0, fontSize > 0 {
            symmetric = max(symmetric, (viewWidth - ems * fontSize) / 2)
        }
        symmetric = symmetric.rounded(.down)
        // ガターの分は幅に関わらず確保する(レイアウト前の幅 0 でも本文がガターに重ならない)。
        let leading = max(symmetric, max(0, gutterWidth))
        let trailing = min(symmetric, max(0, viewWidth - leading))
        return (leading, trailing)
    }
}
