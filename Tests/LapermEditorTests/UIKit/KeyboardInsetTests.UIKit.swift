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

    /// 追従先の contentOffset: キャレットの下に 1 行分の余裕を取って可視領域の下端に収める。
    @Test func revealOffsetPutsTheCaretOneLineAboveTheKeyboard() {
        // 可視領域は 600 - 300 = 300pt。キャレット(高さ 20)の下端は 500 → 520 まで見せたいので 220 進める。
        let caret = CGRect(x: 0, y: 480, width: 2, height: 20)
        let y = MarkdownTextView.contentOffsetY(
            revealing: caret, bounds: bounds, bottomInset: 300, contentHeight: 2000, adjustedInsets: (top: 0, bottom: 300))
        #expect(y == 220)
        // スクロール済みでも同じ量だけ進む(bounds.origin = contentOffset)
        let scrolled = bounds.offsetBy(dx: 0, dy: 1000)
        let scrolledY = MarkdownTextView.contentOffsetY(
            revealing: caret.offsetBy(dx: 0, dy: 1000), bounds: scrolled, bottomInset: 300, contentHeight: 3000,
            adjustedInsets: (top: 0, bottom: 300))
        #expect(scrolledY == 1220)
    }

    @Test func revealOffsetNeverScrollsUpwards() {
        let caret = CGRect(x: 0, y: 100, width: 2, height: 20)
        let y = MarkdownTextView.contentOffsetY(
            revealing: caret, bounds: bounds, bottomInset: 300, contentHeight: 2000, adjustedInsets: (top: 0, bottom: 300))
        #expect(y == bounds.minY)
    }

    /// 短い本文では、余白込みのコンテンツ下端を越えて空白を見せない(UIScrollView が跳ね返す位置)。
    @Test func revealOffsetStopsAtTheContentEnd() {
        let caret = CGRect(x: 0, y: 480, width: 2, height: 20)
        // コンテンツ 520 + 下余白 300 - 高さ 600 = 220 が下限。余裕込みだと 220 なのでちょうど。
        #expect(
            MarkdownTextView.contentOffsetY(
                revealing: caret, bounds: bounds, bottomInset: 300, contentHeight: 520, adjustedInsets: (top: 0, bottom: 300))
                == 220)
        // コンテンツ 500 なら下限 200 で止まる
        #expect(
            MarkdownTextView.contentOffsetY(
                revealing: caret, bounds: bounds, bottomInset: 300, contentHeight: 500, adjustedInsets: (top: 0, bottom: 300))
                == 200)
        // 余白を入れてもビューより短いコンテンツは上端(-top)から動かない
        #expect(
            MarkdownTextView.contentOffsetY(
                revealing: caret, bounds: bounds, bottomInset: 300, contentHeight: 200, adjustedInsets: (top: 50, bottom: 50))
                == -50)
    }

    /// 通知一発で(scrollRangeToVisible の別アニメーションを待たずに)キャレットが余白の上に来る。
    /// 見えているキャレットのときは読んでいる位置を動かさない。
    @Test func keyboardNotificationScrollsTheHiddenCaretIntoView() {
        let window = makeWindow()
        let textView = makeLaidOutTextView(
            (1...80).map { "line \($0)" }.joined(separator: "\n"), width: 402, height: 874)
        window.addSubview(textView)
        window.makeKeyAndVisible()
        defer { tearDown(textView, in: window) }
        #expect(textView.becomeFirstResponder())
        let restingOffsetY = textView.contentOffset.y  // -adjustedContentInset.top(上の safe area)

        // 見えているキャレット(先頭)は動かない
        textView.selectedRange = NSRange(location: 0, length: 0)
        post(.change, frame: CGRect(x: 0, y: 500, width: 402, height: 374), screen: window.screen)
        #expect(textView.contentOffset.y == restingOffsetY)
        post(.hide, frame: CGRect(x: 0, y: 874, width: 402, height: 374), screen: window.screen)

        // キーボードに隠れる行(y ≈ 700)をタップした状態
        let inset = 374 - textView.safeAreaInsets.bottom
        let hiddenLine = textView.closestPosition(to: CGPoint(x: 60, y: 700))!
        textView.selectedTextRange = textView.textRange(from: hiddenLine, to: hiddenLine)
        let caretBefore = textView.caretRect(for: hiddenLine)
        #expect(textView.caretIsHidden(byBottomInset: inset))
        post(.change, frame: CGRect(x: 0, y: 500, width: 402, height: 374), screen: window.screen)
        #expect(textView.keyboardInset == inset)
        // 通知の同期処理だけで(別のアニメーションを待たずに)キャレットが 1 行分の余裕込みで余白の上にある
        let visibleBottom = textView.bounds.maxY - textView.adjustedContentInset.bottom
        #expect(abs(caretBefore.maxY + caretBefore.height - visibleBottom) < 0.01)
        // キャレット矩形はコンテンツ座標なのでスクロールしても変わらない。動いたのは contentOffset だけ。
        #expect(textView.caretRect(for: hiddenLine) == caretBefore)
        #expect(abs(textView.contentOffset.y - (caretBefore.maxY + caretBefore.height - (874 - 374))) < 0.01)
    }

    /// アニメーション中はビューポートに通過範囲(開始時の bounds)を足して、出発側の描画を保つ。
    /// duration 0 の通知(テストの既定)ではアニメーションしないので何も足さない。
    @Test func animatedRevealKeepsTheTraversedRangeInTheViewport() {
        let window = makeWindow()
        let textView = makeLaidOutTextView(
            (1...80).map { "line \($0)" }.joined(separator: "\n"), width: 402, height: 874)
        window.addSubview(textView)
        window.makeKeyAndVisible()
        defer { tearDown(textView, in: window) }
        #expect(textView.becomeFirstResponder())
        let hiddenLine = textView.closestPosition(to: CGPoint(x: 60, y: 700))!
        textView.selectedTextRange = textView.textRange(from: hiddenLine, to: hiddenLine)
        let controller = textView.textLayoutManager!.textViewportLayoutController
        let startBounds = textView.bounds

        post(.change, frame: CGRect(x: 0, y: 500, width: 402, height: 374), screen: window.screen, duration: 0.25)
        #expect(textView.keyboardScrollTraversedBounds == startBounds)
        #expect(textView.contentOffset.y > startBounds.minY)
        // 親クラスのビューポートは次のレイアウトで更新されるので、ここでは出発範囲が含まれることだけ見る
        #expect(textView.viewportBounds(for: controller).contains(startBounds))

        // ガターも通過範囲まで広がり、コンテンツ座標で出発側の行番号を持つ
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        let gutter = textView.gutterView
        #expect(abs(gutter.frame.minY - startBounds.minY) < 0.01)
        #expect(gutter.frame.maxY >= textView.bounds.maxY - 0.01)
        #expect(gutter.contentOffsetY == startBounds.minY)
        #expect(gutter.lines.contains { $0.yInTextView < startBounds.minY + 100 })
        #expect(gutter.lines.contains { $0.yInTextView > textView.bounds.minY })

        // アニメーションが終わると外れる(描画されないテストのウィンドウでは完了ハンドラが来ないので期限で)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
        #expect(textView.keyboardScrollTraversedBounds == nil)
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        #expect(abs(gutter.frame.minY - textView.bounds.minY) < 0.01)
        #expect(gutter.frame.height == textView.bounds.height)

        // 見えているキャレットでは(スクロールしないので)足さない
        post(.hide, frame: CGRect(x: 0, y: 874, width: 402, height: 374), screen: window.screen)
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.contentOffset.y = startBounds.minY
        post(.change, frame: CGRect(x: 0, y: 500, width: 402, height: 374), screen: window.screen, duration: 0.25)
        #expect(textView.keyboardScrollTraversedBounds == nil)
    }

    /// ホストが自分の下部 UI のために持つ contentInset.bottom も可視領域から除く(旧 scrollRangeToVisible
    /// と同じ)。余白の判定と移動先の両方。
    @Test func hostBottomInsetCountsAsHiddenArea() {
        let window = makeWindow()
        let textView = makeLaidOutTextView(
            (1...80).map { "line \($0)" }.joined(separator: "\n"), width: 402, height: 874)
        textView.contentInset.bottom = 64
        window.addSubview(textView)
        window.makeKeyAndVisible()
        defer { tearDown(textView, in: window) }
        #expect(textView.becomeFirstResponder())
        let safeArea = textView.safeAreaInsets.bottom
        let inset = 374 - safeArea

        // キーボードの上端より上だがホスト余白(64pt)の中にあるキャレットは「隠れている」
        let boundary = textView.bounds.maxY - 374 - 64
        let inHostArea = textView.closestPosition(to: CGPoint(x: 60, y: boundary + 30))!
        textView.selectedTextRange = textView.textRange(from: inHostArea, to: inHostArea)
        let caret = textView.caretRect(for: inHostArea)
        #expect(caret.maxY > boundary && caret.maxY < textView.bounds.maxY - 374)
        #expect(textView.caretIsHidden(byBottomInset: inset))

        post(.change, frame: CGRect(x: 0, y: 500, width: 402, height: 374), screen: window.screen)
        #expect(abs(textView.adjustedContentInset.bottom - (64 + 374)) < 0.01)
        let visibleBottom = textView.bounds.maxY - textView.adjustedContentInset.bottom
        #expect(abs(caret.maxY + caret.height - visibleBottom) < 0.01)
    }

    /// 一画面より遠いキャレットへはアニメーションせずに移る(通過範囲を全部レイアウトしない)。
    @Test func farCaretJumpsWithoutAnimation() {
        let window = makeWindow()
        let textView = makeLaidOutTextView(
            (1...400).map { "line \($0)" }.joined(separator: "\n"), width: 402, height: 874)
        window.addSubview(textView)
        window.makeKeyAndVisible()
        defer { tearDown(textView, in: window) }
        #expect(textView.becomeFirstResponder())
        textView.selectedRange = NSRange(location: textView.text.utf16.count, length: 0)
        let startBounds = textView.bounds

        post(.change, frame: CGRect(x: 0, y: 500, width: 402, height: 374), screen: window.screen, duration: 0.25)
        #expect(textView.keyboardScrollTraversedBounds == nil)
        #expect(textView.contentOffset.y - startBounds.minY > startBounds.height)
        let caret = textView.caretRect(for: textView.selectedTextRange!.end)
        #expect(caret.maxY <= textView.bounds.maxY - textView.adjustedContentInset.bottom)
    }

    /// 実ビューのテストの後始末: キーボードを閉じた状態(共有キャッシュも空)に戻す。
    private func tearDown(_ textView: MarkdownTextView, in window: UIWindow) {
        textView.resignFirstResponder()
        post(.hide, frame: CGRect(x: 0, y: 874, width: 402, height: 374), screen: window.screen)
        window.isHidden = true
    }

    /// 402×874(iPhone 17 Pro)のウィンドウ。`init(frame:)` は iOS 26 で非推奨なので既定の init から作る。
    private func makeWindow() -> UIWindow {
        let window = UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        return window
    }

    private enum Kind { case change, hide }

    private func post(_ kind: Kind, frame: CGRect, screen: UIScreen?, duration: Double = 0) {
        let name: Notification.Name =
            kind == .change ? UIResponder.keyboardWillChangeFrameNotification : UIResponder.keyboardWillHideNotification
        NotificationCenter.default.post(
            name: name, object: screen,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame),
                UIResponder.keyboardAnimationDurationUserInfoKey: duration,
                UIResponder.keyboardAnimationCurveUserInfoKey: 7,
            ])
    }
}
#endif
