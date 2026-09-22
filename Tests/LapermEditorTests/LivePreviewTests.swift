#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import LapermEditor
@testable import LapermCore

// MARK: - フォーカス判定

@MainActor @Test func focusedParagraphsFollowCaretAndSelection() {
    let text = "# A\nbb\ncc\n" as NSString
    // キャレット: その段落(改行込み)だけ
    #expect(LivePreviewConcealer.focusedParagraphs(for: [NSRange(location: 5, length: 0)], text: text) == [NSRange(location: 4, length: 3)])
    // 選択範囲: 触れる段落をまとめて 1 レンジ。行頭で終わる選択は次の行に触れない
    #expect(LivePreviewConcealer.focusedParagraphs(for: [NSRange(location: 1, length: 6)], text: text) == [NSRange(location: 0, length: 7)])
    #expect(LivePreviewConcealer.focusedParagraphs(for: [NSRange(location: 0, length: 4)], text: text) == [NSRange(location: 0, length: 4)])
    // 文書末尾の改行の後(空の追加行)のキャレットはどの段落にも触れない
    #expect(LivePreviewConcealer.focusedParagraphs(for: [NSRange(location: 10, length: 0)], text: text) == [NSRange(location: 10, length: 0)])
    // 複数選択は複数、文書外は無視
    #expect(LivePreviewConcealer.focusedParagraphs(for: [NSRange(location: 0, length: 0), NSRange(location: 8, length: 0), NSRange(location: 99, length: 0)], text: text)
            == [NSRange(location: 0, length: 4), NSRange(location: 7, length: 3)])
}

@MainActor @Test func concealerTracksFocusAndMarkersAndReportsDirtyParagraphs() {
    let concealer = LivePreviewConcealer()
    concealer.isEnabled = true
    let text = "**a**\nplain\n*b*\n" as NSString
    concealer.update(markers: [NSRange(location: 12, length: 1), NSRange(location: 0, length: 2), NSRange(location: 3, length: 2), NSRange(location: 14, length: 1)])
    #expect(concealer.markers == [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2), NSRange(location: 12, length: 1), NSRange(location: 14, length: 1)])
    #expect(concealer.takePendingDirtyRanges() == concealer.markers)

    concealer.selectionDidChange([NSRange(location: 1, length: 0)], text: text)
    #expect(concealer.isFocused(paragraph: NSRange(location: 0, length: 6)))
    #expect(!concealer.isFocused(paragraph: NSRange(location: 12, length: 4)))
    #expect(concealer.takePendingDirtyRanges() == [NSRange(location: 0, length: 6)])

    // マーカーの無い行へ移動: 元の行だけが無効化対象(新しい行にはマーカーが無い)
    concealer.selectionDidChange([NSRange(location: 7, length: 0)], text: text)
    #expect(concealer.takePendingDirtyRanges() == [NSRange(location: 0, length: 6)])
    // 同じ行の中の移動は何もしない
    concealer.selectionDidChange([NSRange(location: 9, length: 0)], text: text)
    #expect(concealer.takePendingDirtyRanges().isEmpty)
    // 3 行目へ
    concealer.selectionDidChange([NSRange(location: 13, length: 0)], text: text)
    #expect(concealer.takePendingDirtyRanges() == [NSRange(location: 12, length: 4)])
    #expect(concealer.markers(intersecting: NSRange(location: 12, length: 4)).elementsEqual([NSRange(location: 12, length: 1), NSRange(location: 14, length: 1)]))
    #expect(concealer.markers(intersecting: NSRange(location: 6, length: 6)).isEmpty)

    // 無効なら無効化対象を溜めない(状態は追従する)
    concealer.isEnabled = false
    concealer.selectionDidChange([NSRange(location: 0, length: 0)], text: text)
    concealer.update(markers: [])
    #expect(concealer.takePendingDirtyRanges().isEmpty)
    #expect(concealer.markers.isEmpty)
}

@MainActor @Test func selectionGrowthOnlyDirtiesTheChangedLines() {
    let concealer = LivePreviewConcealer()
    concealer.isEnabled = true
    let text = "*a*\n*b*\n*c*\n*d*\n" as NSString
    concealer.update(markers: [0, 2, 4, 6, 8, 10, 12, 14].map { NSRange(location: $0, length: 1) })
    _ = concealer.takePendingDirtyRanges()
    concealer.selectionDidChange([NSRange(location: 0, length: 8)], text: text)      // 1〜2 行目
    #expect(concealer.takePendingDirtyRanges() == [NSRange(location: 0, length: 8)])
    concealer.selectionDidChange([NSRange(location: 0, length: 12)], text: text)     // 3 行目まで伸ばす
    #expect(concealer.takePendingDirtyRanges() == [NSRange(location: 8, length: 4)])
    concealer.selectionDidChange([NSRange(location: 4, length: 8)], text: text)      // 先頭を 1 行縮める
    #expect(concealer.takePendingDirtyRanges() == [NSRange(location: 0, length: 4)])
    #expect(LivePreviewConcealer.subtracting([NSRange(location: 2, length: 2)], from: [NSRange(location: 0, length: 6)])
            == [NSRange(location: 0, length: 2), NSRange(location: 4, length: 2)])
    #expect(concealer.containsMarker(in: NSRange(location: 1, length: 1)) == false)
    #expect(concealer.containsMarker(in: NSRange(location: 1, length: 2)))
}

@MainActor @Test func togglingLivePreviewQueuesAFullRegeneration() {
    let concealer = LivePreviewConcealer()
    concealer.update(markers: [NSRange(location: 0, length: 1)])
    #expect(concealer.setEnabled(true, documentLength: 10))
    #expect(concealer.takePendingDirtyRanges() == [NSRange(location: 0, length: 10)])
    #expect(!concealer.setEnabled(true, documentLength: 10))
    #expect(concealer.setEnabled(false, documentLength: 0))
    #expect(concealer.takePendingDirtyRanges().isEmpty)
}

@MainActor @Test func losingEditorFocusHidesTheCaretLineAndRegainingItShowsItAgain() {
    let concealer = LivePreviewConcealer()
    concealer.isEnabled = true
    let text = "*a*\nplain\n*c*\n" as NSString
    concealer.update(markers: [0, 2, 10, 12].map { NSRange(location: $0, length: 1) })
    concealer.selectionDidChange([NSRange(location: 1, length: 0)], text: text)
    _ = concealer.takePendingDirtyRanges()
    #expect(concealer.isEditorFocused)
    #expect(concealer.isFocused(paragraph: NSRange(location: 0, length: 4)))

    // フォーカスを失う: キャレットの段落だけ作り直し、以後はどの段落にもフォーカスが無い
    #expect(concealer.editorFocusDidChange(false))
    #expect(concealer.takePendingDirtyRanges() == [NSRange(location: 0, length: 4)])
    #expect(!concealer.isFocused(paragraph: NSRange(location: 0, length: 4)))
    #expect(concealer.focusedParagraphs == [NSRange(location: 0, length: 4)], "the selection is still tracked")
    #expect(!concealer.editorFocusDidChange(false))

    // フォーカスの無い間の選択変更は追従するだけで、作り直す段落は無い(全行が隠れている)
    concealer.selectionDidChange([NSRange(location: 11, length: 0)], text: text)
    #expect(concealer.focusedParagraphs == [NSRange(location: 10, length: 4)])
    #expect(concealer.takePendingDirtyRanges().isEmpty)
    #expect(!concealer.isFocused(paragraph: NSRange(location: 10, length: 4)))

    // 戻る: そのときのキャレットの段落だけ作り直す
    #expect(concealer.editorFocusDidChange(true))
    #expect(concealer.takePendingDirtyRanges() == [NSRange(location: 10, length: 4)])
    #expect(concealer.isFocused(paragraph: NSRange(location: 10, length: 4)))

    // マーカーの無い行にキャレットがあれば、フォーカスの変化で作り直す段落は無い
    concealer.selectionDidChange([NSRange(location: 5, length: 0)], text: text)
    _ = concealer.takePendingDirtyRanges()
    concealer.editorFocusDidChange(false)
    #expect(concealer.takePendingDirtyRanges().isEmpty)

    // 無効なら状態だけ追従する
    concealer.isEnabled = false
    concealer.selectionDidChange([NSRange(location: 1, length: 0)], text: text)
    #expect(concealer.editorFocusDidChange(true))
    #expect(concealer.takePendingDirtyRanges().isEmpty)
}

@MainActor @Test func concealerNoteEditShiftsMarkersAndFocus() {
    let concealer = LivePreviewConcealer()
    concealer.isEnabled = true
    let text = "**a**\n*b*\n" as NSString
    concealer.update(markers: [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2), NSRange(location: 6, length: 1), NSRange(location: 8, length: 1)])
    concealer.selectionDidChange([NSRange(location: 7, length: 0)], text: text)
    _ = concealer.takePendingDirtyRanges()
    // 位置 2 に 1 文字挿入: 交差する "**"(3,2) は残り、後ろは +1、編集と交差するものは落ちる
    concealer.noteEdit(editedRange: NSRange(location: 2, length: 1), changeInLength: 1)
    #expect(concealer.markers == [NSRange(location: 0, length: 2), NSRange(location: 4, length: 2), NSRange(location: 7, length: 1), NSRange(location: 9, length: 1)])
    #expect(concealer.focusedParagraphs == [NSRange(location: 7, length: 4)])
    concealer.noteEdit(editedRange: NSRange(location: 1, length: 0), changeInLength: -1)
    #expect(concealer.markers == [NSRange(location: 3, length: 2), NSRange(location: 6, length: 1), NSRange(location: 8, length: 1)])
}

// MARK: - 表示(ヘッドレスの TextKit 2 スタック)

@MainActor
private func makeTextKitStack(_ text: String) -> (NSTextContentStorage, NSTextLayoutManager) {
    let contentStorage = NSTextContentStorage()
    let layoutManager = NSTextLayoutManager()
    contentStorage.addTextLayoutManager(layoutManager)
    let container = NSTextContainer(size: CGSize(width: 400, height: 0))
    layoutManager.textContainer = container
    contentStorage.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
    return (contentStorage, layoutManager)
}

/// 全段落の表示用段落を作り直させる(エンジンの regenerateParagraphs と同じ経路)。
@MainActor
private func regenerateAllParagraphs(in contentStorage: NSTextContentStorage) {
    let storage = contentStorage.textStorage!
    contentStorage.performEditingTransaction {
        storage.edited(.editedAttributes, range: NSRange(location: 0, length: storage.length), changeInLength: 0)
    }
}

/// range の表示矩形(折り返しがあれば合成)。
@MainActor
func segmentFrame(of range: NSRange, in layoutManager: NSTextLayoutManager) -> CGRect {
    let contentManager = layoutManager.textContentManager!
    layoutManager.ensureLayout(for: layoutManager.documentRange)
    let start = contentManager.location(contentManager.documentRange.location, offsetBy: range.location)!
    let end = contentManager.location(start, offsetBy: range.length)!
    var frame = CGRect.null
    layoutManager.enumerateTextSegments(in: NSTextRange(location: start, end: end)!, type: .standard, options: []) { _, segment, _, _ in
        frame = frame.union(segment)
        return true
    }
    // セグメントが無い(レイアウト欠落・レンジ対応の不具合)ときに「幅 0 = 隠れた」と誤認しないよう失敗にする
    if frame.isNull { Issue.record("no text segment for \(range)") }
    return frame
}

@MainActor @Test func concealedMarkersHaveZeroWidthAndFocusedLineShowsThem() {
    let markdown = "**bold** text\nplain\n"
    let (contentStorage, layoutManager) = makeTextKitStack(markdown)
    let engine = MarkdownEditorEngine(theme: .default)
    let highlighter = engine.highlighter
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)
    let concealer = engine.livePreview
    concealer.isEnabled = true
    concealer.update(markers: highlighter.currentPlan.concealableMarkers)
    concealer.selectionDidChange([NSRange(location: 15, length: 0)], text: markdown as NSString)
    _ = concealer.takePendingDirtyRanges()
    // NSTextContentStorage の delegate は weak なので、テスト中は強参照で保持する
    let delegate = EditorContentStorageDelegate(
        foldingController: engine.foldingController, fragmentProvider: engine.fragmentProvider, livePreview: concealer)
    contentStorage.delegate = delegate
    defer { withExtendedLifetime(delegate) {} }
    regenerateAllParagraphs(in: contentStorage)

    let markerWidth = segmentFrame(of: NSRange(location: 0, length: 2), in: layoutManager).width
    let bold = segmentFrame(of: NSRange(location: 2, length: 4), in: layoutManager)
    let plain = segmentFrame(of: NSRange(location: 14, length: 5), in: layoutManager)
    #expect(markerWidth < 0.1)
    // 隠れた "**" の直後の文字が行頭(lineFragmentPadding)から始まる
    #expect(abs(bold.minX - plain.minX) < 0.1)
    #expect(bold.height == plain.height)
    // ストレージは変換されていない
    #expect(contentStorage.textStorage!.string == markdown)
    #expect((contentStorage.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == MarkdownTheme.default.bodyFont.pointSize)

    // キャレットを 1 行目へ: 段落を作り直すと "**" が見える
    concealer.selectionDidChange([NSRange(location: 3, length: 0)], text: markdown as NSString)
    #expect(concealer.takePendingDirtyRanges() == [NSRange(location: 0, length: 14)])
    regenerateAllParagraphs(in: contentStorage)
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: layoutManager).width > 5)
}

@MainActor @Test func markerOnlyLineKeepsItsHeightWhenConcealed() {
    let markdown = "> a\n>\n> b\n"
    let (contentStorage, layoutManager) = makeTextKitStack(markdown)
    let engine = MarkdownEditorEngine(theme: .default)
    engine.highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)
    let concealer = engine.livePreview
    concealer.isEnabled = true
    concealer.update(markers: engine.highlighter.currentPlan.concealableMarkers)
    concealer.selectionDidChange([NSRange(location: 10, length: 0)], text: markdown as NSString)
    // NSTextContentStorage の delegate は weak なので、テスト中は強参照で保持する
    let delegate = EditorContentStorageDelegate(
        foldingController: engine.foldingController, fragmentProvider: engine.fragmentProvider, livePreview: concealer)
    contentStorage.delegate = delegate
    defer { withExtendedLifetime(delegate) {} }
    regenerateAllParagraphs(in: contentStorage)

    var heights: [CGFloat] = []
    layoutManager.ensureLayout(for: layoutManager.documentRange)
    layoutManager.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
        heights.append(fragment.layoutFragmentFrame.height)
        return true
    }
    // "> a" / ">" / "> b" の 3 段落(+ 末尾の空行)。">" だけの行も他の行と同じ高さ
    #expect(heights.count >= 3)
    #expect(heights[1] > 10)
    #expect(abs(heights[1] - heights[0]) < 0.5)
    // ">" は幅ゼロ
    #expect(segmentFrame(of: NSRange(location: 4, length: 1), in: layoutManager).width < 0.1)
}

@MainActor @Test func veryLongConcealedMarkerLeavesNoVisibleWidthAndDoesNotWrap() {
    // data URL のような 1 万文字超のリンク先も、隠れれば後続の文字は行頭のすぐ隣に来て、行も増えない
    let destination = "https://example.com/" + String(repeating: "a", count: 20_000)
    let markdown = "[t](\(destination)) end\nplain\n"
    let (contentStorage, layoutManager) = makeTextKitStack(markdown)
    let engine = MarkdownEditorEngine(theme: .default)
    engine.highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)
    let concealer = engine.livePreview
    concealer.isEnabled = true
    concealer.update(markers: engine.highlighter.currentPlan.concealableMarkers)
    let length = (markdown as NSString).length
    concealer.selectionDidChange([NSRange(location: length - 3, length: 0)], text: markdown as NSString)
    let delegate = EditorContentStorageDelegate(
        foldingController: engine.foldingController, fragmentProvider: engine.fragmentProvider, livePreview: concealer)
    contentStorage.delegate = delegate
    defer { withExtendedLifetime(delegate) {} }
    regenerateAllParagraphs(in: contentStorage)

    let t = segmentFrame(of: NSRange(location: 1, length: 1), in: layoutManager)
    let endWord = segmentFrame(of: NSRange(location: length - 10, length: 3), in: layoutManager)  // "end"
    #expect(abs(endWord.minX - t.maxX - t.width) < 0.5, "\(endWord) vs \(t)")  // "t" + 空白 1 文字ぶんだけ右
    #expect(endWord.minY == t.minY, "the hidden destination must not wrap the line")
    var lineCount = 0
    layoutManager.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
        lineCount += fragment.textLineFragments.count
        return true
    }
    #expect(lineCount <= 3, "one line for the link, one for plain, at most one trailing empty line: \(lineCount)")
}

@MainActor @Test func tabInHeadingMarkerIsConcealedToo() {
    let markdown = "#\tTitle\nplain\n"
    let (contentStorage, layoutManager) = makeTextKitStack(markdown)
    let engine = MarkdownEditorEngine(theme: .default)
    engine.highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)
    let concealer = engine.livePreview
    concealer.isEnabled = true
    concealer.update(markers: engine.highlighter.currentPlan.concealableMarkers)
    #expect(concealer.markers == [NSRange(location: 0, length: 2)])
    concealer.selectionDidChange([NSRange(location: 10, length: 0)], text: markdown as NSString)
    let delegate = EditorContentStorageDelegate(
        foldingController: engine.foldingController, fragmentProvider: engine.fragmentProvider, livePreview: concealer)
    contentStorage.delegate = delegate
    defer { withExtendedLifetime(delegate) {} }
    regenerateAllParagraphs(in: contentStorage)
    let title = segmentFrame(of: NSRange(location: 2, length: 5), in: layoutManager)
    let plain = segmentFrame(of: NSRange(location: 8, length: 5), in: layoutManager)
    #expect(abs(title.minX - plain.minX) < 0.1, "the tab after # must not advance to a tab stop: \(title) vs \(plain)")
}

@MainActor @Test func markerOnlyLineHeightFollowsTheMarkerFontNotTheNewline() {
    // syntaxMarker のフォントが本文より小さいテーマ: ">" だけの行は Source でも隠しても同じ高さ
    var theme = MarkdownTheme.default
    theme.styles[.syntaxMarker] = MarkdownTheme.Style(font: .systemFont(ofSize: 8), foregroundColor: .gray)
    let markdown = ">\nplain\n"
    func lineHeights(concealed: Bool) -> [CGFloat] {
        let (contentStorage, layoutManager) = makeTextKitStack(markdown)
        let engine = MarkdownEditorEngine(theme: theme)
        engine.highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)
        let concealer = engine.livePreview
        concealer.isEnabled = concealed
        concealer.update(markers: engine.highlighter.currentPlan.concealableMarkers)
        concealer.selectionDidChange([NSRange(location: 4, length: 0)], text: markdown as NSString)
        let delegate = EditorContentStorageDelegate(
            foldingController: engine.foldingController, fragmentProvider: engine.fragmentProvider, livePreview: concealer)
        contentStorage.delegate = delegate
        regenerateAllParagraphs(in: contentStorage)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var heights: [CGFloat] = []
        layoutManager.enumerateTextLayoutFragments(from: nil, options: []) { heights.append($0.layoutFragmentFrame.height); return true }
        withExtendedLifetime(delegate) {}
        return heights
    }
    let source = lineHeights(concealed: false)
    let hidden = lineHeights(concealed: true)
    #expect(source.count >= 2 && hidden.count >= 2)
    #expect(abs(source[0] - hidden[0]) < 0.5, "source \(source) vs hidden \(hidden)")
}

@MainActor @Test func enablingLivePreviewOnAHugeSingleLineIsNotQuadratic() {
    // 1 行に 16,000 個の強調(マーカー 32,000 個)。段落の算出がマーカーごとだと数秒かかる。
    let markdown = String(repeating: "a*b*", count: 16_000) + "\n"
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    scrollView.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = markdown
    textView.highlightAll()
    textView.setSelectedRange(NSRange(location: (markdown as NSString).length, length: 0))
    let clock = ContinuousClock()
    let elapsed = clock.measure { textView.isLivePreviewEnabled = true }
    #expect(elapsed < .seconds(1), "\(elapsed)")
}

@MainActor @Test func disabledConcealerLeavesDisplayParagraphsAlone() {
    let markdown = "**bold**\n"
    let (contentStorage, layoutManager) = makeTextKitStack(markdown)
    let engine = MarkdownEditorEngine(theme: .default)
    engine.highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)
    let concealer = engine.livePreview
    concealer.update(markers: engine.highlighter.currentPlan.concealableMarkers)
    concealer.selectionDidChange([NSRange(location: 9, length: 0)], text: markdown as NSString)
    #expect(concealer.textParagraph(with: NSRange(location: 0, length: 9), base: nil, in: contentStorage) == nil)
    // NSTextContentStorage の delegate は weak なので、テスト中は強参照で保持する
    let delegate = EditorContentStorageDelegate(
        foldingController: engine.foldingController, fragmentProvider: engine.fragmentProvider, livePreview: concealer)
    contentStorage.delegate = delegate
    defer { withExtendedLifetime(delegate) {} }
    regenerateAllParagraphs(in: contentStorage)
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: layoutManager).width > 5)
}

// MARK: - MarkdownTextView(AppKit)

/// ウィンドウに載せて first responder にした text view(フォーカスのある行のマーカーが見える前提)。
/// 呼び出し側はウィンドウを生かしておく(`withExtendedLifetime`)。
@MainActor
private func makeFocusedTextView(_ markdown: String) -> (NSWindow, MarkdownTextView) {
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    scrollView.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = scrollView
    textView.string = markdown
    textView.highlightAll()
    #expect(window.makeFirstResponder(textView))
    return (window, textView)
}

@MainActor @Test func textViewLivePreviewFollowsCaretAndKeepsString() {
    let markdown = "# Title\n\nsome **bold** [link](https://x.y)\n"
    let (window, textView) = makeFocusedTextView(markdown)
    defer { withExtendedLifetime(window) {} }
    textView.isLivePreviewEnabled = true
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    let layoutManager = textView.textLayoutManager!

    // キャレットは見出し行: 見出しのマーカーは見え、3 行目のマーカーは隠れる
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: layoutManager).width > 5)
    #expect(segmentFrame(of: NSRange(location: 14, length: 2), in: layoutManager).width < 0.1)
    #expect(segmentFrame(of: NSRange(location: 23, length: 1), in: layoutManager).width < 0.1)   // "["
    #expect(segmentFrame(of: NSRange(location: 28, length: 14), in: layoutManager).width < 0.1)  // "](https://x.y)"
    #expect(segmentFrame(of: NSRange(location: 24, length: 4), in: layoutManager).width > 5)     // "link"

    // キャレットを 3 行目へ
    textView.setSelectedRange(NSRange(location: 12, length: 0))
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: layoutManager).width < 0.1)
    #expect(segmentFrame(of: NSRange(location: 14, length: 2), in: layoutManager).width > 5)
    #expect(segmentFrame(of: NSRange(location: 28, length: 14), in: layoutManager).width > 5)

    // 選択範囲が 1 行目と 3 行目に触れる: 両方見える
    textView.setSelectedRange(NSRange(location: 2, length: 12))
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: layoutManager).width > 5)
    #expect(segmentFrame(of: NSRange(location: 14, length: 2), in: layoutManager).width > 5)

    // 切ると全部見える。文字列は終始そのまま
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    textView.isLivePreviewEnabled = false
    #expect(segmentFrame(of: NSRange(location: 14, length: 2), in: layoutManager).width > 5)
    #expect(textView.string == markdown)
}

@MainActor @Test func textViewLivePreviewSurvivesEditsAndRehighlight() {
    let (window, textView) = makeFocusedTextView("*a*\n\nplain\n")
    defer { withExtendedLifetime(window) {} }
    textView.isLivePreviewEnabled = true
    textView.setSelectedRange(NSRange(location: 5, length: 0))
    let layoutManager = textView.textLayoutManager!
    #expect(segmentFrame(of: NSRange(location: 0, length: 1), in: layoutManager).width < 0.1)

    // 3 行目を強調にする(キャレットのある行なのでマーカーは見える)。1 行目のマーカーは隠れたまま
    textView.insertText("**", replacementRange: NSRange(location: 5, length: 0))
    textView.insertText("**", replacementRange: NSRange(location: 12, length: 0))
    textView.highlightNow()
    #expect(textView.string == "*a*\n\n**plain**\n")
    #expect(segmentFrame(of: NSRange(location: 5, length: 2), in: layoutManager).width > 5)
    #expect(segmentFrame(of: NSRange(location: 0, length: 1), in: layoutManager).width < 0.1)

    // 別の行へ移すと 3 行目のマーカーも隠れる
    textView.setSelectedRange(NSRange(location: 4, length: 0))
    #expect(segmentFrame(of: NSRange(location: 5, length: 2), in: layoutManager).width < 0.1)
    #expect(abs(segmentFrame(of: NSRange(location: 7, length: 5), in: layoutManager).minX - segmentFrame(of: NSRange(location: 1, length: 1), in: layoutManager).minX) < 0.1)

    // テーマ変更後も隠れたまま
    var theme = MarkdownTheme.default
    theme.lineSpacing = 4
    textView.theme = theme
    #expect(segmentFrame(of: NSRange(location: 5, length: 2), in: layoutManager).width < 0.1)
}

@MainActor @Test func textViewLivePreviewHidesEveryLineWhileTheEditorIsNotFirstResponder() {
    let markdown = "# Title\n\nsome **bold**\n"
    let (window, textView) = makeFocusedTextView(markdown)
    defer { withExtendedLifetime(window) {} }
    textView.isLivePreviewEnabled = true
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    let layoutManager = textView.textLayoutManager!
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: layoutManager).width > 5)

    // サイドバーのクリックなどで first responder を失う: キャレットの行も隠れる(閲覧表示)
    #expect(window.makeFirstResponder(nil))
    #expect(window.firstResponder !== textView)
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: layoutManager).width < 0.1)
    #expect(segmentFrame(of: NSRange(location: 14, length: 2), in: layoutManager).width < 0.1)

    // フォーカスの無い間にキャレットを動かしても全行隠れたまま。戻ると新しいキャレットの行だけ見える
    textView.setSelectedRange(NSRange(location: 14, length: 0))
    #expect(segmentFrame(of: NSRange(location: 14, length: 2), in: layoutManager).width < 0.1)
    #expect(window.makeFirstResponder(textView))
    #expect(segmentFrame(of: NSRange(location: 14, length: 2), in: layoutManager).width > 5)
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: layoutManager).width < 0.1)

    // Source ではフォーカスに関わらず全部見える。文字列はそのまま
    #expect(window.makeFirstResponder(nil))
    textView.isLivePreviewEnabled = false
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: layoutManager).width > 5)
    #expect(textView.string == markdown)

    // ウィンドウから外れた(first responder でない)まま Live Preview を入れると全行隠れる
    let loose = MarkdownTextView.scrollableMarkdownEditor().documentView as! MarkdownTextView
    loose.string = markdown
    loose.highlightAll()
    loose.isLivePreviewEnabled = true
    loose.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(segmentFrame(of: NSRange(location: 0, length: 2), in: loose.textLayoutManager!).width < 0.1)
}

@MainActor @Test func editorViewAppliesLivePreviewSetting() {
    let textView = MarkdownTextView()
    var text = "x"
    let binding = Binding(get: { text }, set: { text = $0 })
    MarkdownEditorView(text: binding).livePreviewEnabled(true).apply(to: textView)
    #expect(textView.isLivePreviewEnabled)
    MarkdownEditorView(text: binding).apply(to: textView)
    #expect(!textView.isLivePreviewEnabled)
}
#endif
