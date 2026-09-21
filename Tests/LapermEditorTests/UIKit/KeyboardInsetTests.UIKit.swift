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

    /// 通知 → contentInset。ウィンドウに載せた実ビューで、スクリーン座標のフレームが変換されることまで確かめる。
    @Test func keyboardNotificationsDriveTheContentInset() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let textView = MarkdownTextView()
        textView.frame = CGRect(x: 0, y: 100, width: 402, height: 700)  // 下端は y = 800
        window.addSubview(textView)
        window.layoutIfNeeded()

        post(UIResponder.keyboardWillChangeFrameNotification, frame: CGRect(x: 0, y: 500, width: 402, height: 374))
        let safeArea = textView.safeAreaInsets.bottom
        #expect(textView.keyboardInset == 300 - safeArea)
        #expect(textView.contentInset.bottom == 300 - safeArea)
        #expect(textView.verticalScrollIndicatorInsets.bottom == 300 - safeArea)

        // 高さが変わる(候補バーの出入りなど)
        post(UIResponder.keyboardWillChangeFrameNotification, frame: CGRect(x: 0, y: 600, width: 402, height: 274))
        #expect(textView.keyboardInset == 200 - safeArea)

        // 隠れる
        post(UIResponder.keyboardWillHideNotification, frame: CGRect(x: 0, y: 874, width: 402, height: 274))
        #expect(textView.keyboardInset == 0)
        #expect(textView.contentInset.bottom == 0)
    }

    @Test func layoutRecomputesTheInsetFromTheLastKeyboardFrame() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let textView = MarkdownTextView()
        textView.frame = CGRect(x: 0, y: 100, width: 402, height: 700)
        window.addSubview(textView)
        post(UIResponder.keyboardWillChangeFrameNotification, frame: CGRect(x: 0, y: 500, width: 402, height: 374))
        let safeArea = textView.safeAreaInsets.bottom
        #expect(textView.keyboardInset == 300 - safeArea)

        // ビューが短くなればキーボードとの重なりも減る
        textView.frame = CGRect(x: 0, y: 100, width: 402, height: 500)  // 下端は y = 600
        textView.layoutIfNeeded()
        #expect(textView.keyboardInset == 100 - safeArea)
    }

    @Test func optingOutClearsTheInset() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let textView = MarkdownTextView()
        textView.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.addSubview(textView)
        post(UIResponder.keyboardWillChangeFrameNotification, frame: CGRect(x: 0, y: 500, width: 402, height: 374))
        #expect(textView.keyboardInset > 0)

        textView.adjustsContentInsetForKeyboard = false
        #expect(textView.keyboardInset == 0)
        #expect(textView.contentInset.bottom == 0)

        // 切っている間の通知は無視され、戻すと直近のフレームで再適用される
        post(UIResponder.keyboardWillChangeFrameNotification, frame: CGRect(x: 0, y: 400, width: 402, height: 474))
        #expect(textView.keyboardInset == 0)
        textView.adjustsContentInsetForKeyboard = true
        #expect(textView.keyboardInset == 474 - textView.safeAreaInsets.bottom)
    }

    @Test func viewOutsideAWindowIgnoresTheKeyboard() {
        let textView = MarkdownTextView()
        textView.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        post(UIResponder.keyboardWillChangeFrameNotification, frame: CGRect(x: 0, y: 500, width: 402, height: 374))
        #expect(textView.keyboardInset == 0)
    }

    private func post(_ name: Notification.Name, frame: CGRect) {
        NotificationCenter.default.post(
            name: name, object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame),
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
                UIResponder.keyboardAnimationCurveUserInfoKey: 7,
            ])
    }
}
#endif
