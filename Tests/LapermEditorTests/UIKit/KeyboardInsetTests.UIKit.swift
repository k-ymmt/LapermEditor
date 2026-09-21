#if canImport(UIKit)
import Testing
import UIKit
@testable import LapermEditor

/// キーボード回避(iOS のみ)。SwiftUI に縮めさせない代わりに、テキストビューが
/// キーボード(アクセサリ込み)に隠れる分だけ contentInset.bottom を自分で持つ。
@MainActor
struct KeyboardInsetTests {
    private let bounds = CGRect(x: 0, y: 0, width: 402, height: 600)

    @Test func insetIsTheOverlapMinusTheSafeArea() {
        let keyboard = CGRect(x: 0, y: 500, width: 402, height: 336)
        #expect(MarkdownTextView.keyboardBottomInset(bounds: bounds, keyboardFrame: keyboard, safeAreaBottom: 0) == 100)
        #expect(MarkdownTextView.keyboardBottomInset(bounds: bounds, keyboardFrame: keyboard, safeAreaBottom: 34) == 66)
    }

    @Test func insetDoesNotDependOnScrollOffset() {
        // bounds.origin = contentOffset。キーボードフレームも同じ座標系に変換されて届く。
        let scrolled = bounds.offsetBy(dx: 0, dy: 1000)
        let keyboard = CGRect(x: 0, y: 1500, width: 402, height: 336)
        #expect(MarkdownTextView.keyboardBottomInset(bounds: scrolled, keyboardFrame: keyboard, safeAreaBottom: 0) == 100)
    }

    @Test func dockedKeyboardWiderThanTheViewStillInsets() {
        // iPad Split View: ビューは画面の左半分、キーボードは全幅
        let keyboard = CGRect(x: -100, y: 500, width: 1024, height: 400)
        #expect(MarkdownTextView.keyboardBottomInset(bounds: bounds, keyboardFrame: keyboard, safeAreaBottom: 0) == 100)
    }

    @Test func noInsetWhenTheKeyboardIsBelowOrBesideTheView() {
        let below = CGRect(x: 0, y: 600, width: 402, height: 336)
        #expect(MarkdownTextView.keyboardBottomInset(bounds: bounds, keyboardFrame: below, safeAreaBottom: 0) == 0)
        let offscreen = CGRect(x: 0, y: 874, width: 402, height: 336)
        #expect(MarkdownTextView.keyboardBottomInset(bounds: bounds, keyboardFrame: offscreen, safeAreaBottom: 0) == 0)
        // iPad の浮動キーボードがビューの横にある
        let beside = CGRect(x: 500, y: 400, width: 320, height: 250)
        #expect(MarkdownTextView.keyboardBottomInset(bounds: bounds, keyboardFrame: beside, safeAreaBottom: 0) == 0)
        // safe area の方が重なりより大きい
        let shallow = CGRect(x: 0, y: 590, width: 402, height: 336)
        #expect(MarkdownTextView.keyboardBottomInset(bounds: bounds, keyboardFrame: shallow, safeAreaBottom: 34) == 0)
    }

    /// 浮動・分割キーボード(ビューの下端を覆わない)には余白を付けない: その下の空き領域まで
    /// 余白にすると本文が不要に押し上げられる。
    @Test func floatingKeyboardInsideTheViewDoesNotInset() {
        let wide = CGRect(x: 0, y: 0, width: 800, height: 600)
        let floating = CGRect(x: 80, y: 100, width: 320, height: 250)
        #expect(MarkdownTextView.keyboardBottomInset(bounds: wide, keyboardFrame: floating, safeAreaBottom: 0) == 0)
        // 下端に接した瞬間からは対象になる
        let touching = CGRect(x: 80, y: 350, width: 320, height: 250)
        #expect(MarkdownTextView.keyboardBottomInset(bounds: wide, keyboardFrame: touching, safeAreaBottom: 0) == 250)
    }

    /// 通知 → contentInset。ウィンドウに載せた実ビューで、スクリーン座標のフレームが変換されることまで確かめる。
    @Test func keyboardNotificationsDriveTheContentInset() {
        let window = makeWindow()
        let textView = MarkdownTextView()
        textView.frame = CGRect(x: 0, y: 100, width: 402, height: 700)  // 下端は y = 800
        window.addSubview(textView)
        window.layoutIfNeeded()

        post(.change, frame: CGRect(x: 0, y: 500, width: 402, height: 374), screen: window.screen)
        let safeArea = textView.safeAreaInsets.bottom
        #expect(textView.keyboardInset == 300 - safeArea)
        #expect(textView.contentInset.bottom == 300 - safeArea)
        #expect(textView.verticalScrollIndicatorInsets.bottom == 300 - safeArea)

        // 高さが変わる(候補バーの出入りなど)
        post(.change, frame: CGRect(x: 0, y: 600, width: 402, height: 274), screen: window.screen)
        #expect(textView.keyboardInset == 200 - safeArea)

        // 隠れる
        post(.hide, frame: CGRect(x: 0, y: 874, width: 402, height: 274), screen: window.screen)
        #expect(textView.keyboardInset == 0)
        #expect(textView.contentInset.bottom == 0)
    }

    /// 利用側が設定した下余白(独自の下部 UI など)は上書きせず、キーボード分を足し引きするだけ。
    @Test func hostContentInsetSurvivesTheKeyboard() {
        let window = makeWindow()
        let textView = MarkdownTextView()
        textView.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        textView.contentInset.bottom = 64
        textView.verticalScrollIndicatorInsets.bottom = 64
        window.addSubview(textView)

        post(.change, frame: CGRect(x: 0, y: 574, width: 402, height: 300), screen: window.screen)
        let safeArea = textView.safeAreaInsets.bottom
        #expect(textView.contentInset.bottom == 64 + 300 - safeArea)
        #expect(textView.verticalScrollIndicatorInsets.bottom == 64 + 300 - safeArea)

        post(.hide, frame: CGRect(x: 0, y: 874, width: 402, height: 300), screen: window.screen)
        #expect(textView.contentInset.bottom == 64)
        #expect(textView.verticalScrollIndicatorInsets.bottom == 64)

        // 無効化でもキーボード分だけ外れる
        post(.change, frame: CGRect(x: 0, y: 574, width: 402, height: 300), screen: window.screen)
        textView.adjustsContentInsetForKeyboard = false
        #expect(textView.contentInset.bottom == 64)
    }

    @Test func layoutRecomputesTheInsetFromTheLastKeyboardFrame() {
        let window = makeWindow()
        let textView = MarkdownTextView()
        textView.frame = CGRect(x: 0, y: 100, width: 402, height: 700)
        window.addSubview(textView)
        post(.change, frame: CGRect(x: 0, y: 500, width: 402, height: 374), screen: window.screen)
        let safeArea = textView.safeAreaInsets.bottom
        #expect(textView.keyboardInset == 300 - safeArea)

        // ビューが短くなればキーボードとの重なりも減る
        textView.frame = CGRect(x: 0, y: 100, width: 402, height: 500)  // 下端は y = 600
        textView.layoutIfNeeded()
        #expect(textView.keyboardInset == 100 - safeArea)
    }

    /// キーボードが出たまま作られたビュー(Note の切り替えなど)は、ウィンドウに付いた時点で
    /// 画面のキャッシュから追いつく。隠れた後に作られたビューには何も付かない。
    @Test func viewAddedWhileTheKeyboardIsUpCatchesUp() {
        let window = makeWindow()
        let first = MarkdownTextView()
        first.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.addSubview(first)
        post(.change, frame: CGRect(x: 0, y: 574, width: 402, height: 300), screen: window.screen)

        let second = MarkdownTextView()
        second.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.addSubview(second)
        second.layoutIfNeeded()
        #expect(second.keyboardInset == 300 - second.safeAreaInsets.bottom)

        post(.hide, frame: CGRect(x: 0, y: 874, width: 402, height: 300), screen: window.screen)
        let third = MarkdownTextView()
        third.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.addSubview(third)
        third.layoutIfNeeded()
        #expect(third.keyboardInset == 0)
        #expect(second.keyboardInset == 0)
    }

    @Test func optingOutClearsTheInset() {
        let window = makeWindow()
        let textView = MarkdownTextView()
        textView.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.addSubview(textView)
        post(.change, frame: CGRect(x: 0, y: 500, width: 402, height: 374), screen: window.screen)
        #expect(textView.keyboardInset > 0)

        textView.adjustsContentInsetForKeyboard = false
        #expect(textView.keyboardInset == 0)
        #expect(textView.contentInset.bottom == 0)

        // 切っている間の通知は無視され、戻すと直近のフレームで再適用される
        post(.change, frame: CGRect(x: 0, y: 400, width: 402, height: 474), screen: window.screen)
        #expect(textView.keyboardInset == 0)
        textView.adjustsContentInsetForKeyboard = true
        #expect(textView.keyboardInset == 474 - textView.safeAreaInsets.bottom)
    }

    @Test func viewOutsideAWindowIgnoresTheKeyboard() {
        let textView = MarkdownTextView()
        textView.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        post(.change, frame: CGRect(x: 0, y: 500, width: 402, height: 374), screen: nil)
        #expect(textView.keyboardInset == 0)
    }

    /// 画面情報のない通知(古い OS の形)も受け入れる。
    @Test func notificationWithoutAScreenStillApplies() {
        let window = makeWindow()
        let textView = MarkdownTextView()
        textView.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.addSubview(textView)
        post(.change, frame: CGRect(x: 0, y: 574, width: 402, height: 300), screen: nil)
        #expect(textView.keyboardInset == 300 - textView.safeAreaInsets.bottom)
        post(.hide, frame: CGRect(x: 0, y: 874, width: 402, height: 300), screen: nil)
        #expect(textView.keyboardInset == 0)
    }

    /// 追従は「新しい余白でキャレットが隠れる」ときだけ: 見えているキャレットでは読んでいる位置を動かさない。
    @Test func caretVisibilityDecidesWhetherToScroll() {
        let textView = makeLaidOutTextView(
            (1...60).map { "line \($0)" }.joined(separator: "\n"), width: 402, height: 400)
        textView.selectedRange = NSRange(location: 0, length: 0)
        #expect(!textView.caretIsHidden(byBottomInset: 300))
        textView.selectedRange = NSRange(location: textView.text.utf16.count, length: 0)
        // 文末のキャレットは可視領域(400pt)の外にあるので、余白に関係なく隠れている
        #expect(textView.caretIsHidden(byBottomInset: 0))

        // 可視領域の下の方にあるキャレットは、余白が増えると隠れる
        textView.selectedRange = NSRange(location: 0, length: 0)
        let caret = textView.caretRect(for: textView.selectedTextRange!.end)
        #expect(!textView.caretIsHidden(byBottomInset: 400 - caret.maxY))
        #expect(textView.caretIsHidden(byBottomInset: 400 - caret.maxY + 1))
    }

    /// 402×874(iPhone 17 Pro)のウィンドウ。`init(frame:)` は iOS 26 で非推奨なので既定の init から作る。
    private func makeWindow() -> UIWindow {
        let window = UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        return window
    }

    private enum Kind { case change, hide }

    private func post(_ kind: Kind, frame: CGRect, screen: UIScreen?) {
        let name: Notification.Name =
            kind == .change ? UIResponder.keyboardWillChangeFrameNotification : UIResponder.keyboardWillHideNotification
        NotificationCenter.default.post(
            name: name, object: screen,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame),
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
                UIResponder.keyboardAnimationCurveUserInfoKey: 7,
            ])
    }
}
#endif
