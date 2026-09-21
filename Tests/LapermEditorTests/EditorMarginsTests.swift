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

@Test func insetsAreRoundedDownToWholePoints() {
    // 1001 − 680 = 321 → 160.5 → 160
    #expect(EditorMargins.readable.horizontalInsets(viewWidth: 1001, gutterWidth: 0, fontSize: 17) == (160, 160))
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
