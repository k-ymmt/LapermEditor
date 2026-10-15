#if os(macOS)
import AppKit
import Testing
@testable import LapermEditor
@testable import LapermCore

// Link Preview(Laperm ADR 0046): 裸の URL だけの段落が、Provider の答えが届いたらカードに折りたたまれる。

// "# T\n"(0-3) "\n"(4) "https://a.example/post"(5-26) "\n"(27) "\n"(28) "after"(29-33)
private let sample = "# T\n\nhttps://a.example/post\n\nafter"
private let sampleURL = URL(string: "https://a.example/post")!
private let samplePreview = LinkPreview(title: "A post", description: "What the post says", siteName: "A Example")

/// 答えを辞書で持ち、`holds` の間は答えを保留する Provider。
@MainActor
final class StubLinkPreviewProvider: LinkPreviewProvider {
    var previews: [String: LinkPreview] = [:]
    private(set) var requested: [URL] = []
    var holds = false
    private var pending: [URL: CheckedContinuation<LinkPreview?, Never>] = [:]
    private(set) var cancelled: [URL] = []

    init(previews: [String: LinkPreview] = [:]) {
        self.previews = previews
    }

    @MainActor func linkPreview(for url: URL) async -> LinkPreview? {
        requested.append(url)
        guard holds else { return previews[url.absoluteString] }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in pending[url] = continuation }
        } onCancel: {
            Task { @MainActor in
                self.cancelled.append(url)
                self.pending.removeValue(forKey: url)?.resume(returning: nil)
            }
        }
    }

    /// 保留中の答えを返す。
    func answer(_ url: URL, with preview: LinkPreview?) {
        pending.removeValue(forKey: url)?.resume(returning: preview)
    }

    var pendingURLs: [URL] { Array(pending.keys) }
}

/// 条件が成り立つまでメインアクターの Task を進める(取得は Task で届く)。
@MainActor
func settle(_ condition: () -> Bool) async {
    for _ in 0..<200 {
        if condition() { return }
        await Task.yield()
    }
}

@MainActor
private func makeController(_ text: String, provider: (any LinkPreviewProvider)?, width: CGFloat = 400, isActive: Bool? = nil)
    -> (LinkPreviewController, LinkPreviewStore) {
    let controller = LinkPreviewController(theme: .default)
    let store = LinkPreviewStore()
    store.provider = provider
    store.onChange = { [weak controller] in controller?.invalidateLayouts() }
    controller.setEnabled(true)
    controller.containerWidthDidChange(width)
    // エンジンと同じ: 設定で有効、かつ Provider があるときだけ候補を持つ
    update(controller, store: store, with: text, isActive: isActive ?? (provider != nil))
    return (controller, store)
}

@MainActor
private func update(_ controller: LinkPreviewController, store: LinkPreviewStore, with text: String, isActive: Bool = true) {
    let plan = MarkdownParser().highlightPlan(for: text)
    let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
    retainedStorages.append(storage)
    controller.update(plan: plan, storage: storage, text: text as NSString, store: store, isActive: isActive)
}

@MainActor private var retainedStorages: [NSTextStorage] = []

// MARK: - コントローラと Store

@MainActor @Test func aCandidateCollapsesOnlyOnceTheProviderAnswersAndStaysAURLWhileLoadingOrUnavailable() async throws {
    let provider = StubLinkPreviewProvider(previews: [sampleURL.absoluteString: samplePreview])
    provider.holds = true
    let (controller, store) = makeController(sample, provider: provider)
    #expect(controller.linkPreviewCandidates.map(\.range) == [NSRange(location: 5, length: 22)])
    await settle { provider.requested == [sampleURL] }
    // 取得中: URL のまま(折りたたまない)
    #expect(controller.collapsedLocations.isEmpty)
    #expect(store.states[sampleURL.absoluteString] == .loading)

    provider.answer(sampleURL, with: samplePreview)
    await settle { controller.isCollapsed(linkPreviewAt: 5) }
    #expect(controller.collapsedLocations == [5])
    // 作り直す範囲は段落(改行まで)
    #expect(controller.takePendingDirtyRanges() == [NSRange(location: 5, length: 23)])
    let presented = try #require(controller.presentedLinkPreview(at: 5))
    #expect(presented.layout.preview == samplePreview)
    #expect(controller.linkTarget(forLinkPreviewAt: 5)?.destination == "https://a.example/post")
    #expect(controller.linkTarget(forLinkPreviewAt: 5)?.editCaret == 27)
    // 先頭の段落だけ列挙(1 段落のブロックなので隠す段落は無い)、予約高さはカードの高さ
    #expect(controller.shouldEnumerate(paragraphStartingAt: 5))
    #expect(controller.reservedHeight(forParagraph: NSRange(location: 5, length: 23)) == presented.layout.reservedHeight)
    #expect(controller.reservedHeight(forParagraph: NSRange(location: 29, length: 5)) == nil)

    // 取れなかった URL は URL のまま、取り直さない
    let missing = "https://b.example\n\nhttps://a.example/post"
    provider.holds = false
    update(controller, store: store, with: missing)
    await settle { store.states["https://b.example"] == .unavailable }
    #expect(controller.collapsedLocations == [19])
    update(controller, store: store, with: missing)
    #expect(provider.requested.filter { $0.absoluteString == "https://b.example" }.count == 1)
}

@MainActor @Test func theCaretFocusAndTheSettingExpandACard() async throws {
    let provider = StubLinkPreviewProvider(previews: [sampleURL.absoluteString: samplePreview])
    let (controller, _) = makeController(sample, provider: provider)
    await settle { controller.isCollapsed(linkPreviewAt: 5) }
    _ = controller.takePendingDirtyRanges()
    // 段落の中(行頭から行末まで)のキャレットで展開、前後の行では折りたたんだまま
    controller.selectionDidChange([NSRange(location: 4, length: 0)])
    #expect(controller.collapsedLocations == [5])
    controller.selectionDidChange([NSRange(location: 5, length: 0)])
    #expect(controller.collapsedLocations.isEmpty)
    #expect(controller.takePendingDirtyRanges() == [NSRange(location: 5, length: 23)])
    controller.selectionDidChange([NSRange(location: 27, length: 0)])
    #expect(controller.collapsedLocations.isEmpty)
    controller.selectionDidChange([NSRange(location: 28, length: 0)])
    #expect(controller.collapsedLocations == [5])
    _ = controller.takePendingDirtyRanges()
    // 展開中の段落は行単位の Syntax Marker 隠しから除外(Source と同じ見た目)
    controller.selectionDidChange([NSRange(location: 10, length: 0)])
    #expect(controller.isExempt(paragraph: NSRange(location: 5, length: 23)))
    // フォーカスを失うと折りたたむ、戻ると展開
    controller.editorFocusDidChange(false)
    #expect(controller.collapsedLocations == [5])
    controller.editorFocusDidChange(true)
    #expect(controller.collapsedLocations.isEmpty)
    // Live Preview OFF で全部展開
    controller.selectionDidChange([NSRange(location: 30, length: 0)])
    #expect(controller.collapsedLocations == [5])
    controller.setEnabled(false)
    #expect(controller.collapsedLocations.isEmpty)
}

@MainActor @Test func noProviderOrADisabledSettingMeansNoRequestsAndRemovedURLsAreCancelled() async throws {
    // Provider 無し: 候補も要求も無い
    let (noProvider, noStore) = makeController(sample, provider: nil)
    #expect(noProvider.linkPreviewCandidates.isEmpty)
    #expect(noStore.states.isEmpty)

    // 設定で無効: 候補も要求も無い
    let provider = StubLinkPreviewProvider(previews: [sampleURL.absoluteString: samplePreview])
    let (disabled, disabledStore) = makeController(sample, provider: provider, isActive: false)
    await Task.yield()
    #expect(disabled.linkPreviewCandidates.isEmpty)
    #expect(provider.requested.isEmpty)
    #expect(disabledStore.states.isEmpty)

    // 取得中に無効にする / URL が消える: 取り消し
    provider.holds = true
    let (controller, store) = makeController(sample, provider: provider)
    await settle { provider.pendingURLs == [sampleURL] }
    update(controller, store: store, with: sample, isActive: false)
    await settle { provider.cancelled == [sampleURL] }
    #expect(store.states.isEmpty)
    update(controller, store: store, with: "https://c.example")
    await settle { provider.pendingURLs == [URL(string: "https://c.example")!] }
    update(controller, store: store, with: "nothing here")
    await settle { provider.cancelled.count == 2 }
    #expect(store.states.isEmpty)
    // 取り消された答えは届いても反映されない
    #expect(controller.collapsedLocations.isEmpty)
}

@MainActor @Test func onlyTheFirstHundredCandidatesOfADocumentAreFetched() async throws {
    let urls = (0..<120).map { "https://example.com/\($0)" }
    let provider = StubLinkPreviewProvider(previews: Dictionary(uniqueKeysWithValues: urls.map { ($0, LinkPreview(title: $0)) }))
    let (controller, store) = makeController(urls.joined(separator: "\n\n"), provider: provider)
    #expect(controller.linkPreviewCandidates.count == 100)
    await settle { provider.requested.count == 100 }
    await settle { controller.collapsedLocations.count == 100 }
    #expect(store.states.count == 100)
    #expect(provider.requested.map(\.absoluteString) == Array(urls.prefix(100)))
}

@MainActor @Test func theImageLoadsThroughTheImageLoaderAndFollowsTheRemoteImagesSetting() async throws {
    let imageURL = try writeTempPNG(name: "og.png", width: 200, height: 100)
    let preview = LinkPreview(title: "With image", imageURL: imageURL)
    let provider = StubLinkPreviewProvider(previews: [sampleURL.absoluteString: preview])
    let (controller, store) = makeController(sample, provider: provider)
    await settle { controller.isCollapsed(linkPreviewAt: 5) }
    // 折りたたむときに画像を読み始め、読めたらカードが作り直される(高さが変わる)
    await settle { controller.presentedLinkPreview(at: 5)?.layout.image != nil }
    let withImage = try #require(controller.presentedLinkPreview(at: 5)?.layout)
    #expect(withImage.imageFrame?.size == CGSize(width: 88, height: 88))
    #expect(withImage.size.height == 88 + LinkPreviewLayout.padding * 2)
    #expect(withImage.imageFrame?.maxX == withImage.size.width - LinkPreviewLayout.padding)

    // http(s) の画像は「リモート画像を読む」が OFF なら読まない(画像無しのカード)
    let remote = LinkPreview(title: "Remote", imageURL: URL(string: "https://img.example/a.png")!)
    provider.previews[sampleURL.absoluteString] = remote
    store.resetLoads()
    await settle { controller.presentedLinkPreview(at: 5)?.layout.preview == remote }
    #expect(controller.presentedLinkPreview(at: 5)?.layout.image == nil)
    #expect(store.images[remote.imageURL!] == .failed)
}

// MARK: - レイアウト

@MainActor @Test func theCardIsOneTitleLineTwoDescriptionLinesAHostLineAndASquareImageUpTo560Wide() throws {
    let appearance = LinkPreviewLayout.Appearance(theme: .default)
    let long = LinkPreview(
        title: "A very long title that keeps going well past the width of the card so it has to be cut off",
        description: String(repeating: "A long description that wraps onto many lines. ", count: 10), siteName: nil)
    let narrow = LinkPreviewLayout.make(preview: long, image: nil, host: "a.example", maxWidth: 300, appearance: appearance)
    #expect(narrow.size.width == 300)
    let titleHeight = FrontMatterTableLayout.lineHeight(of: appearance.titleFont)
    let detailHeight = FrontMatterTableLayout.lineHeight(of: appearance.detailFont)
    #expect(narrow.titleFrame.height == titleHeight)
    #expect(narrow.descriptionFrame?.height == detailHeight * 2)
    #expect(narrow.hostText?.string == "a.example")
    #expect(narrow.hostFrame?.height == detailHeight)
    #expect(narrow.size.height == ceil(titleHeight + detailHeight * 3 + LinkPreviewLayout.lineGap * 2 + LinkPreviewLayout.padding * 2))
    #expect(narrow.imageFrame == nil)
    // 幅はコンテナ幅まで、上限 560
    #expect(LinkPreviewLayout.make(preview: long, image: nil, host: nil, maxWidth: 900, appearance: appearance).size.width == 560)
    #expect(LinkPreviewLayout.make(preview: long, image: nil, host: nil, maxWidth: 0, appearance: appearance).size.width == LinkPreviewLayout.fallbackWidth)
    // 説明もサイト名も無ければタイトルとホスト名だけで低い。サイト名があればホスト名より優先
    let short = LinkPreviewLayout.make(preview: LinkPreview(title: "T", siteName: "Site"), image: nil, host: "a.example", maxWidth: 300, appearance: appearance)
    #expect(short.descriptionFrame == nil)
    #expect(short.hostText?.string == "Site")
    #expect(short.size.height == ceil(titleHeight + detailHeight + LinkPreviewLayout.lineGap + LinkPreviewLayout.padding * 2))
    // 画像があれば右に 88pt 四方、文字の列はその左
    let image = NSImage(size: NSSize(width: 10, height: 10))
    let withImage = LinkPreviewLayout.make(preview: long, image: image, host: nil, maxWidth: 300, appearance: appearance)
    #expect(withImage.imageFrame == CGRect(x: 300 - 10 - 88, y: 10, width: 88, height: 88))
    #expect(withImage.titleFrame.maxX == 300 - 10 - 88 - LinkPreviewLayout.imageGap)
    #expect(withImage.size.height == 88 + LinkPreviewLayout.padding * 2)
    // Theme の既存の項目だけを使う
    #expect(appearance.background == MarkdownTheme.default.codeBlockBackgroundColor)
    #expect(appearance.titleColor == MarkdownTheme.default.style(for: .link)?.foregroundColor)
}

// MARK: - テキストビュー

@MainActor
private func makeTextView(_ markdown: String, provider: (any LinkPreviewProvider)?) -> (NSWindow, MarkdownTextView) {
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    scrollView.frame = CGRect(x: 0, y: 0, width: 500, height: 400)
    let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = scrollView
    textView.linkPreviewProvider = provider
    textView.string = markdown
    textView.highlightAll()
    textView.isLivePreviewEnabled = true
    return (window, textView)
}

@MainActor
private func layoutViewport(_ textView: MarkdownTextView) {
    textView.layoutSubtreeIfNeeded()
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
}

@MainActor @Test func theTextViewDrawsTheCardOpensTheWrittenURLOnClickAndExpandsFromTheMenu() async throws {
    let provider = StubLinkPreviewProvider(previews: [sampleURL.absoluteString: samplePreview])
    let (window, textView) = makeTextView(sample, provider: provider)
    defer { withExtendedLifetime(window) {} }
    #expect(window.makeFirstResponder(textView))
    textView.setSelectedRange(NSRange(location: 31, length: 0))  // after
    await settle { textView.linkPreviewController.isCollapsed(linkPreviewAt: 5) }
    layoutViewport(textView)
    let entry = try #require(textView.debugLinkPreviewEntries.first)
    #expect(entry.location == 5)
    #expect(entry.frame.minX == textView.textContainerOrigin.x + textView.textContainer!.lineFragmentPadding)
    #expect(entry.frame.width == min(560, textView.imageContainerWidth))
    #expect(entry.layout.preview == samplePreview)

    // カードのクリック: 書いた URL を onOpenLink に渡す(展開しない)
    var opened: [URL] = []
    textView.onOpenLink = { opened.append($0); return true }
    let onCard = CGPoint(x: entry.frame.midX, y: entry.frame.midY)
    let hit = try #require(textView.linkHit(atPoint: onCard))
    #expect(hit.target == .url(destination: "https://a.example/post"))
    #expect(hit.isRendered)
    #expect(hit.editCaret == NSRange(location: 27, length: 0))
    #expect(textView.openRenderedLink(atPoint: onCard))
    #expect(opened == [sampleURL])
    #expect(textView.linkPreviewController.collapsedLocations == [5])
    // カードの外は何も無い
    #expect(textView.linkHit(atPoint: CGPoint(x: entry.frame.midX, y: entry.frame.maxY + 30)) == nil)

    // メニューの「編集」: キャレットが URL の末尾に置かれて展開する
    let menu = textView.linkMenu(for: hit, appendingItemsOf: nil)
    #expect(menu.items.map(\.title) == [LinkMenuTitle.open, LinkMenuTitle.copy, LinkMenuTitle.edit])
    #expect(menu.items[1].representedObject as? String == "https://a.example/post")
    _ = menu.items[2].target?.perform(menu.items[2].action)
    #expect(textView.selectedRange() == NSRange(location: 27, length: 0))
    #expect(textView.linkPreviewController.collapsedLocations.isEmpty)
    layoutViewport(textView)
    #expect(textView.debugLinkPreviewEntries.isEmpty)
    #expect(textView.string == sample, "the card never rewrites the text")

    // 隣の行から矢印キーで入ると展開、出ると折りたたむ
    textView.setSelectedRange(NSRange(location: 4, length: 0))
    layoutViewport(textView)
    #expect(textView.linkPreviewController.collapsedLocations == [5])
    textView.moveDown(nil)
    #expect(NSLocationInRange(textView.selectedRange().location, NSRange(location: 5, length: 23)))
    #expect(textView.linkPreviewController.collapsedLocations.isEmpty)
    textView.moveDown(nil)
    #expect(textView.linkPreviewController.collapsedLocations == [5])
    // 次の行頭の Backspace は段落を繋げる = 候補に触る編集: 展開され、次のパースで候補でなくなる
    textView.setSelectedRange(NSRange(location: 28, length: 0))
    textView.deleteBackward(nil)
    #expect(textView.linkPreviewController.collapsedLocations.isEmpty)
    textView.highlightNow()
    #expect(textView.linkPreviewController.linkPreviewCandidates.isEmpty, "the URL line now continues into the next paragraph")
    textView.undoManager?.undo()
    textView.highlightNow()
    textView.setSelectedRange(NSRange(location: 31, length: 0))
    // 候補が消えた間に取得の状態は捨てられているので、戻ると取り直してから折りたたむ
    await settle { textView.linkPreviewController.isCollapsed(linkPreviewAt: 5) }
    #expect(textView.linkPreviewController.collapsedLocations == [5])

    // Source では出ない、戻すと出る
    textView.isLivePreviewEnabled = false
    #expect(textView.linkPreviewController.collapsedLocations.isEmpty)
    textView.isLivePreviewEnabled = true
    #expect(textView.linkPreviewController.collapsedLocations == [5])
    // 描かれたリンクのクリックを切ると、カードのクリックはキャレットを置く(通常の mouseDown に流れる)
    textView.linkOptions.opensRenderedLinksOnClick = false
    #expect(!textView.openRenderedLink(atPoint: onCard))
    #expect(opened.count == 1)
}

@MainActor @Test func theSettingTurnsTheFeatureOffWithoutRequestsAndTheProviderCanBeSwapped() async throws {
    let provider = StubLinkPreviewProvider(previews: [sampleURL.absoluteString: samplePreview])
    let (window, textView) = makeTextView(sample, provider: nil)
    defer { withExtendedLifetime(window) {} }
    await Task.yield()
    #expect(textView.linkPreviewController.linkPreviewCandidates.isEmpty)
    textView.linkPreviewOptions = LinkPreviewOptions(isEnabled: false)
    textView.linkPreviewProvider = provider
    await Task.yield()
    #expect(provider.requested.isEmpty)
    #expect(textView.linkPreviewController.linkPreviewCandidates.isEmpty)
    textView.linkPreviewOptions = LinkPreviewOptions(isEnabled: true)
    await settle { textView.linkPreviewController.isCollapsed(linkPreviewAt: 5) }
    #expect(provider.requested == [sampleURL])
    // 無効に戻すと展開して、要求の状態も捨てる
    textView.linkPreviewOptions = LinkPreviewOptions(isEnabled: false)
    #expect(textView.linkPreviewController.collapsedLocations.isEmpty)
    #expect(textView.engine.linkPreviewStore.states.isEmpty)
    // 別の Provider に差し替えると取り直す
    textView.linkPreviewOptions = LinkPreviewOptions(isEnabled: true)
    let other = StubLinkPreviewProvider(previews: [sampleURL.absoluteString: LinkPreview(title: "Other")])
    textView.linkPreviewProvider = other
    await settle { textView.linkPreviewController.presentedLinkPreview(at: 5)?.layout.preview.title == "Other" }
    #expect(other.requested == [sampleURL])
}
#endif
