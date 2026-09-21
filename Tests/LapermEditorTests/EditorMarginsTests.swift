import CoreGraphics
import Testing
@testable import LapermEditor

// EditorMargins.horizontalInsets は純粋な計算なので、両プラットフォームで同じテストを走らせる。

@Test func noMarginsKeepOnlyTheGutter() {
    let none = EditorMargins.none
    #expect(none.horizontalInsets(viewWidth: 390, gutterWidth: 44, fontSize: 17) == (44, 0))
    #expect(none.horizontalInsets(viewWidth: 390, gutterWidth: 0, fontSize: 17) == (0, 0))
}

@Test func readableMarginsOnANarrowViewUseTheMinimum() {
    // iPhone 幅: 最大幅(680pt)に届かないので最小余白。ガター表示時は左がガター幅になる。
    let readable = EditorMargins.readable
    #expect(readable.horizontalInsets(viewWidth: 390, gutterWidth: 0, fontSize: 17) == (20, 20))
    #expect(readable.horizontalInsets(viewWidth: 390, gutterWidth: 44, fontSize: 17) == (44, 20))
}

@Test func readableMarginsOnAWideViewCenterTheText() {
    // 1024pt 幅: 本文 680pt を中央に置く → 左右 172pt。ガター(44pt)は余白に収まるので本文は動かない。
    let readable = EditorMargins.readable
    #expect(readable.horizontalInsets(viewWidth: 1024, gutterWidth: 0, fontSize: 17) == (172, 172))
    #expect(readable.horizontalInsets(viewWidth: 1024, gutterWidth: 44, fontSize: 17) == (172, 172))
}

@Test func maximumWidthFollowsTheFontSize() {
    let readable = EditorMargins.readable
    // 14pt → 560pt 幅: 1024 − 560 = 464 → 232 ずつ
    #expect(readable.horizontalInsets(viewWidth: 1024, gutterWidth: 0, fontSize: 14) == (232, 232))
    // 最大幅なしなら幅に依らず最小余白
    let unlimited = EditorMargins(minimumHorizontal: 12, maximumWidthInEms: nil)
    #expect(unlimited.horizontalInsets(viewWidth: 4000, gutterWidth: 0, fontSize: 17) == (12, 12))
}

@Test func insetsAreRoundedUpToWholePoints() {
    // 1001 − 680 = 321 → 160.5 → 161(本文は最大幅 680 を超えない)
    #expect(EditorMargins.readable.horizontalInsets(viewWidth: 1001, gutterWidth: 0, fontSize: 17) == (161, 161))
    // 最小余白も下回らない
    let fractional = EditorMargins(minimumHorizontal: 20.9, maximumWidthInEms: nil)
    #expect(fractional.horizontalInsets(viewWidth: 390, gutterWidth: 0, fontSize: 17) == (21, 21))
}

@Test func textWidthNeverExceedsTheMaximumAsTheViewGrows() {
    let readable = EditorMargins.readable
    for width in stride(from: CGFloat(700), through: 1100, by: 1) {
        let insets = readable.horizontalInsets(viewWidth: width, gutterWidth: 0, fontSize: 17)
        let textWidth = width - insets.leading - insets.trailing
        // 最大幅は超えない。最大幅に届くビュー(720pt 以上)では切り上げの 1pt しか損なわない。
        #expect(textWidth <= 680, "width \(width) → \(textWidth)")
        #expect(textWidth >= min(678, width - 40), "width \(width) → \(textWidth)")
        #expect(insets.leading >= 20 && insets.trailing >= 20)
    }
}

@Test func symmetricInsetKeepsThePositiveWidthWhenMarginsExceedHalfTheView() {
    // 左右 200pt を 390pt 幅に求めると非対称には (200, 190)。対称適用(AppKit)は小さい側を取り、本文幅を負にしない。
    let wide = EditorMargins(minimumHorizontal: 200, maximumWidthInEms: nil)
    #expect(wide.horizontalInsets(viewWidth: 390, gutterWidth: 0, fontSize: 17) == (200, 190))
    #expect(wide.symmetricHorizontalInset(viewWidth: 390, fontSize: 17) == 190)
    #expect(wide.symmetricHorizontalInset(viewWidth: 1024, fontSize: 17) == 200)
    #expect(wide.symmetricHorizontalInset(viewWidth: 100, fontSize: 17) == 0)
    #expect(EditorMargins.readable.symmetricHorizontalInset(viewWidth: 1024, fontSize: 17) == 172)
}

@Test func nonFiniteValuesAreTreatedAsNoMargin() {
    let infinite = EditorMargins(minimumHorizontal: .infinity, maximumWidthInEms: .nan)
    #expect(infinite.horizontalInsets(viewWidth: 390, gutterWidth: 44, fontSize: 17) == (44, 0))
    #expect(EditorMargins.readable.horizontalInsets(viewWidth: .infinity, gutterWidth: 44, fontSize: .nan) == (44, 0))
    #expect(EditorMargins.readable.horizontalInsets(viewWidth: 390, gutterWidth: .nan, fontSize: 17) == (20, 20))
}

@Test func insetsNeverExceedTheView() {
    let readable = EditorMargins.readable
    // 幅 0(レイアウト前)や極端に狭いビューでも、ガターの分は確保しつつ右余白で負の幅にしない
    #expect(readable.horizontalInsets(viewWidth: 0, gutterWidth: 44, fontSize: 17) == (44, 0))
    #expect(EditorMargins.none.horizontalInsets(viewWidth: 0, gutterWidth: 44, fontSize: 17) == (44, 0))
    #expect(readable.horizontalInsets(viewWidth: 50, gutterWidth: 44, fontSize: 17) == (44, 6))
    #expect(readable.horizontalInsets(viewWidth: 30, gutterWidth: 0, fontSize: 17) == (20, 10))
    // 不正な値(負の余白・0 のフォント)は余白なし扱い
    let odd = EditorMargins(minimumHorizontal: -5, maximumWidthInEms: 40)
    #expect(odd.horizontalInsets(viewWidth: 390, gutterWidth: 0, fontSize: 0) == (0, 0))
}
