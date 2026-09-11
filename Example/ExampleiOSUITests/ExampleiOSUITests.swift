import XCTest

/// ExampleiOS をシミュレータ上で実際に操作して確認する GUI 検証。
/// 環境変数 LAPERM_SCREENSHOT_DIR が指定されていれば各段階のスクリーンショットを PNG で保存する
/// (ホスト側から目視確認するため)。
final class ExampleiOSUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        if let dir = ProcessInfo.processInfo.environment["LAPERM_SCREENSHOT_DIR"] {
            app.launchEnvironment["LAPERM_CRASH_LOG"] = dir + "/crash.txt"
        }
    }

    private func launch(uiTestDocument: Bool) {
        app.launchArguments = uiTestDocument ? ["-uiTestDocument"] : []
        app.launch()
    }

    private func saveScreenshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let dir = ProcessInfo.processInfo.environment["LAPERM_SCREENSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: url)
    }

    private var textView: XCUIElement { app.textViews.firstMatch }

    private var documentText: String { (textView.value as? String) ?? "" }

    /// テキストビュー左上からのオフセット(pt)でタップする
    private func tap(dx: CGFloat, dy: CGFloat) {
        textView.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dx, dy: dy)).tap()
    }

    /// 見出し(H1, 約 31pt)の下、n 番目(0-based)の本文行(約 17pt)の中央 y。
    /// textContainerInset.top = 8。
    private func bodyLineY(_ n: CGFloat) -> CGFloat { 8 + 31 + 17 * n + 8 }
    /// ガター(44) + lineFragmentPadding(5) + 等幅 14pt(約 8.4pt/字)で n 文字目付近の x
    private func columnX(_ n: CGFloat) -> CGFloat { 44 + 5 + 8.4 * n }

    func testEditorRendersAndSupportsCoreInteractions() {
        launch(uiTestDocument: true)
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        saveScreenshot("01-initial")
        XCTAssertTrue(documentText.contains("- [ ] タスク"))

        // 1) チェックボックスのタップでトグル(本文 0 行目 "- [ ] タスク" の "[ ]" 付近)
        tap(dx: columnX(3), dy: bodyLineY(0))
        XCTAssertTrue(documentText.contains("- [x] タスク"), documentText)
        saveScreenshot("02-checkbox-toggled")

        // 2) 行末にキャレットを置いて Return → リスト項目が自動継続する
        tap(dx: 300, dy: bodyLineY(0))
        textView.typeText("\nabc")
        XCTAssertTrue(documentText.contains("- [x] タスク\n- [ ] abc"), documentText)
        saveScreenshot("03-list-continued")

        // 3) 折畳: ガター左端のシェブロン(1 行目の見出し)をタップ → 本文が隠れる
        tap(dx: 8, dy: 8 + 10)
        saveScreenshot("04-folded")
        // 折り畳んでも文書は変わらない
        XCTAssertTrue(documentText.contains("- [x] タスク"))
        tap(dx: 8, dy: 8 + 10)
        saveScreenshot("05-unfolded")

        // 4) 編集メニュー「リンクを開く」: 本文 4 行目(タスク, abc, 空行, 本文, リンク)のリンク内に
        //    長押しでキャレットを置き、同じ位置をタップすると iOS 標準の編集メニューが出る
        let linkPoint = textView.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: columnX(3), dy: bodyLineY(4)))
        linkPoint.press(forDuration: 1.0)
        linkPoint.tap()
        // 項目名はシミュレータの言語に依存する(en: "Open Link" / ja: "リンクを開く")
        let openLink = app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@ OR title IN %@",
                        ["Open Link", "リンクを開く"], ["Open Link", "リンクを開く"])).firstMatch
        var appeared = openLink.waitForExistence(timeout: 5)
        if !appeared {
            saveScreenshot("06a-after-caret-tap")
            // 予備: ダブルタップで単語選択してメニューを出す
            linkPoint.doubleTap()
            appeared = openLink.waitForExistence(timeout: 5)
        }
        saveScreenshot("06-edit-menu")
        XCTAssertTrue(appeared, app.debugDescription)
        openLink.tap()
        let status = app.staticTexts["openedLinkStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue((status.label).contains("https://example.com/inline"), status.label)
        saveScreenshot("07-link-opened")

        // 5) 行番号トグル OFF / テーマ切替
        app.buttons["lineNumbersToggle"].firstMatch.tap()
        saveScreenshot("08-line-numbers-off")
        app.buttons["themeToggle"].firstMatch.tap()
        saveScreenshot("09-alternate-theme")
    }

    /// サンプル文書全体(コードブロック・引用・テーブル・画像プレビュー)をスクロールしながら撮影する。
    /// 画像プレビュー(ローカル画像は表示、missing/リモートはエラー枠)はスクリーンショットで目視確認する。
    func testFullSampleDocumentRendersWhileScrolling() {
        launch(uiTestDocument: false)
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        XCTAssertTrue(documentText.contains("![サンプル](sample.png)"))
        saveScreenshot("10-sample-top")
        // テキストビューが画面に収まっている(= 内部でスクロールできる)こと。
        // UIViewRepresentable が sizeThatFits で全文の高さを返すと画面外に伸びてスクロール不能になる。
        let windowFrame = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(textView.frame.maxY, windowFrame.maxY + 1,
                                 "textView \(textView.frame) exceeds window \(windowFrame)")
        // 画像プレビュー(文書末尾)まで数回スワイプして撮影する
        for i in 1...4 {
            textView.swipeUp(velocity: .slow)
            saveScreenshot("1\(i)-sample-scrolled")
        }
    }
}
