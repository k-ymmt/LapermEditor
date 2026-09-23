#if canImport(UIKit)
import SwiftUI
import Testing
import UIKit
@testable import LapermEditor

/// ヘッダ(iOS)。`swift test` は macOS で走るので、このファイルは xcodebuild test で確かめる。
/// 本文は `textContainerInset.top` だけ下がり、ヘッダはテキストコンテナと同じ左右位置に置かれる。
@MainActor @Test func headerInsetsTheTextAndAlignsWithTheContainer() {
    let textView = MarkdownTextView()
    textView.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    textView.margins = .readable
    textView.showsLineNumbers = false
    textView.layoutIfNeeded()
    let defaultTop = textView.textContainerInset.top
    #expect(textView.textContainerInset.left == 20)

    let header = UIView()
    textView.headerHeight = 50
    #expect(textView.textContainerInset.top == defaultTop, "the height alone does nothing without a header view")
    textView.headerView = header
    #expect(header.superview === textView)
    #expect(textView.textContainerInset.top == 50)
    textView.layoutIfNeeded()
    let padding = textView.textContainer.lineFragmentPadding
    #expect(header.frame == CGRect(x: 20 + padding, y: 0, width: 400 - 2 * (20 + padding), height: 50))

    // ガター(左余白に含まれる)があれば、その右から始まる
    textView.showsLineNumbers = true
    textView.layoutIfNeeded()
    #expect(header.frame.minX == textView.textContainerInset.left + padding)
    #expect(header.frame.minX >= LineNumberGutterView.width)

    textView.headerHeight = 30
    #expect(textView.textContainerInset.top == 30)
    textView.headerView = nil
    #expect(header.superview == nil)
    #expect(textView.textContainerInset.top == defaultTop, "removing the header restores the default top inset")
}

/// ヘッダを使わない利用側が設定した上余白はレイアウトで保たれ、ヘッダを付けて外すとその値に戻る。
@MainActor @Test func customTopInsetSurvivesLayoutAndHeaderRemoval() {
    let textView = MarkdownTextView()
    textView.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    textView.textContainerInset.top = 24
    textView.margins = .readable
    textView.layoutIfNeeded()
    #expect(textView.textContainerInset.top == 24, "layout must not touch the top inset without a header")
    textView.showsLineNumbers = false
    textView.layoutIfNeeded()
    #expect(textView.textContainerInset.top == 24)

    textView.headerView = UIView()
    textView.headerHeight = 50
    #expect(textView.textContainerInset.top == 50)
    textView.headerView = nil
    #expect(textView.textContainerInset.top == 24, "removal restores the caller's inset, not the UITextView default")
}

/// `headerView` を直接差し替えると、そのビューを持っていたコントローラは親からも外れ、`headerViewController` も消える。
@MainActor @Test func replacingTheHeaderViewDirectlyDetachesTheController() {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
    let parent = UIViewController()
    window.rootViewController = parent
    window.isHidden = false
    let textView = MarkdownTextView()
    parent.view.addSubview(textView)
    let controller = UIViewController()
    textView.headerViewController = controller
    #expect(controller.parent === parent)

    let plain = UIView()
    textView.headerView = plain
    #expect(controller.parent == nil, "the controller must not linger in the parent's children")
    #expect(textView.headerViewController == nil)
    #expect(controller.view.superview == nil)
    #expect(plain.superview === textView)

    textView.headerViewController = controller
    #expect(controller.parent === parent, "the same controller can be installed again")
    #expect(textView.headerView === controller.view)
    textView.headerView = nil
    #expect(controller.parent == nil)
    #expect(textView.headerViewController == nil)
    window.isHidden = true
}

/// 設置・撤去は UIKit のコンテナの契約の順(addChild → view を足す → didMove、willMove(nil) → view を外す → removeFromParent)。
@MainActor @Test func childControllerCallbacksFollowTheContainerContract() {
    final class Recording: UIViewController {
        var events: [String] = []
        override func willMove(toParent parent: UIViewController?) {
            super.willMove(toParent: parent)
            events.append("willMove(\(parent == nil ? "nil" : "parent")) superview=\(view.superview == nil ? "nil" : "set") parent=\(self.parent == nil ? "nil" : "set")")
        }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            events.append("didMove(\(parent == nil ? "nil" : "parent")) superview=\(view.superview == nil ? "nil" : "set") parent=\(self.parent == nil ? "nil" : "set")")
        }
    }
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
    let parent = UIViewController()
    window.rootViewController = parent
    window.isHidden = false
    let textView = MarkdownTextView()
    parent.view.addSubview(textView)
    let controller = Recording()

    textView.headerViewController = controller
    // addChild が willMove(parent) を呼び(親は設定済み、view はまだ無い)、view を足してから didMove(parent)
    #expect(controller.events == ["willMove(parent) superview=nil parent=set", "didMove(parent) superview=set parent=set"], "\(controller.events)")

    controller.events.removeAll()
    textView.headerViewController = nil
    // willMove(nil) の時点では view も親も残り、view を外してから removeFromParent(didMove(nil) は removeFromParent が呼ぶ)
    #expect(controller.events == ["willMove(nil) superview=set parent=set", "didMove(nil) superview=nil parent=nil"], "\(controller.events)")
    window.isHidden = true
}

/// ヘッダの上ではテキストビュー自身のタップは始まらず、スクロールのパンだけ通る。
@MainActor @Test func gesturesOverTheHeaderAreLeftToTheHeader() {
    let textView = MarkdownTextView()
    textView.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    let header = UIView()
    textView.headerView = header
    textView.headerHeight = 50
    textView.layoutIfNeeded()
    final class Probe: UITapGestureRecognizer {
        var point = CGPoint.zero
        override func location(in view: UIView?) -> CGPoint { point }
    }
    let tap = Probe()
    textView.addGestureRecognizer(tap)
    tap.point = CGPoint(x: 100, y: 10)
    #expect(!textView.gestureRecognizerShouldBegin(tap))
    tap.point = CGPoint(x: 100, y: 120)
    #expect(textView.gestureRecognizerShouldBegin(tap))
    #expect(textView.gestureRecognizerShouldBegin(textView.panGestureRecognizer), "scrolling still works from the header")
}

@MainActor @Test func editorViewInstallsTheHeader() {
    let textView = MarkdownTextView()
    let coordinator = MarkdownEditorView.Coordinator(text: .constant(""))
    MarkdownEditorView(text: .constant("")).headerView(height: 40) { Text("title") }
        .applyHeader(to: textView, coordinator: coordinator)
    let host = try! #require(coordinator.headerHost)
    #expect(textView.headerView === host.view)
    #expect(textView.headerHeight == 40)
    #expect(textView.textContainerInset.top == 40)
    #expect(host.view.backgroundColor == .clear)
    #expect(host.safeAreaRegions.isEmpty, "the header sits in the scrolled content; no keyboard / safe area layout")

    MarkdownEditorView(text: .constant("")).headerView(height: 48) { Text("other") }
        .applyHeader(to: textView, coordinator: coordinator)
    #expect(coordinator.headerHost === host, "re-applying reuses the host")
    #expect(textView.headerHeight == 48)

    MarkdownEditorView(text: .constant("")).applyHeader(to: textView, coordinator: coordinator)
    #expect(coordinator.headerHost == nil)
    #expect(textView.headerView == nil)
    #expect(textView.headerViewController == nil)
}

/// ヘッダのビューコントローラは、テキストビューがウィンドウに付いている間だけ最寄りのビューコントローラの子になる
/// (SwiftUI の `@FocusState` がビューコントローラ階層を要する)。ウィンドウから外れる・外すと親からも外れる。
@MainActor @Test func headerViewControllerBecomesAChildOfTheNearestViewController() {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
    let parent = UIViewController()
    window.rootViewController = parent
    window.isHidden = false
    let textView = MarkdownTextView()
    let header = UIViewController()

    textView.headerViewController = header
    #expect(textView.headerView === header.view)
    #expect(header.parent == nil, "not in a window yet")

    parent.view.addSubview(textView)
    #expect(header.parent === parent, "moving into the window attaches the child")

    textView.removeFromSuperview()
    #expect(header.parent == nil, "leaving the window detaches the child (no leak through the parent's children)")
    parent.view.addSubview(textView)
    #expect(header.parent === parent, "coming back re-attaches it")

    textView.headerViewController = nil
    #expect(header.parent == nil)
    #expect(textView.headerView == nil)
    #expect(textView.textContainerInset.top == 8)
    window.isHidden = true
}
#endif
