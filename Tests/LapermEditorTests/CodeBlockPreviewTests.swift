#if os(macOS)
import AppKit
import Testing
@testable import LapermEditor
@testable import LapermCore

// テキスト: "# T\n"(0-3) "\n"(4) "Before\n"(5-11) "\n"(12) "```swift\n"(13-21) "let x = 1\n"(22-31) "print(x)\n"(32-40)
// "```"(41-43) "\n"(44) "\n"(45) "after"(46-50)
// ブロックのレンジは 13..<44、段落は 13..<45、本文は 22..<40("let x = 1\nprint(x)")
private let sample = "# T\n\nBefore\n\n```swift\nlet x = 1\nprint(x)\n```\n\nafter"

// 2 つのブロック: "```\n"(0-3) "a\n"(4-5) "```\n"(6-9) "\n"(10) "text\n"(11-15) "\n"(16) "    b\n"(17-22) "    c"(23-27)
// ブロック 1 は 0..<9(段落 0..<10)、インデント型のブロック 2 は 21..<28(先頭はインデントの後。段落 17..<28)
private let two = "```\na\n```\n\ntext\n\n    b\n    c"

@MainActor
private func makeController(_ text: String, width: CGFloat = 400, enabled: Bool = true) -> CodeBlockPreviewController {
    let controller = CodeBlockPreviewController(theme: .default)
    controller.setEnabled(enabled)
    controller.containerWidthDidChange(width)
    update(controller, with: text)
    return controller
}

@MainActor
private func update(_ controller: CodeBlockPreviewController, with text: String) {
    let plan = MarkdownParser().highlightPlan(for: text)
    let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
    retainedStorages.append(storage)
    controller.update(plan: plan, storage: storage, text: text as NSString)
}

@MainActor private var retainedStorages: [NSTextStorage] = []

// MARK: - CodeBlockPreviewController

@MainActor @Test func codeBlockControllerCollapsesEachBlockUnlessTheCaretTouchesIt() throws {
    let controller = makeController(two)
    #expect(controller.codeBlocks.map(\.range) == [NSRange(location: 0, length: 9), NSRange(location: 21, length: 7)])
    #expect(controller.collapsedLocations == [0, 21])
    // 作り直す範囲はブロックの段落(インデント型は行頭から)
    #expect(controller.takePendingDirtyRanges() == [NSRange(location: 0, length: 10), NSRange(location: 17, length: 11)])

    controller.selectionDidChange([NSRange(location: 12, length: 0)])
    #expect(controller.collapsedLocations == [0, 21])
    // ブロック 1 の中(フェンス行を含む): そのブロックだけ展開
    controller.selectionDidChange([NSRange(location: 2, length: 0)])
    #expect(controller.collapsedLocations == [21])
    #expect(controller.takePendingDirtyRanges() == [NSRange(location: 0, length: 10)])
    // 終了フェンスの行末(9)は触れる、次の行頭(10)は触れない
    controller.selectionDidChange([NSRange(location: 9, length: 0)])
    #expect(controller.collapsedLocations == [21])
    controller.selectionDidChange([NSRange(location: 10, length: 0)])
    #expect(controller.collapsedLocations == [0, 21])
    _ = controller.takePendingDirtyRanges()
    // インデント型: 文末(28)のキャレットで展開、インデントの中(18)でも展開
    controller.selectionDidChange([NSRange(location: 28, length: 0)])
    #expect(controller.collapsedLocations == [0])
    controller.selectionDidChange([NSRange(location: 18, length: 0)])
    #expect(controller.collapsedLocations == [0], "the caret in the indentation of the first line is inside the block's paragraph")
    _ = controller.takePendingDirtyRanges()

    // フォーカスを失うとキャレットがブロック内でも折りたたむ、戻ると展開
    controller.editorFocusDidChange(false)
    #expect(controller.collapsedLocations == [0, 21])
    controller.editorFocusDidChange(true)
    #expect(controller.collapsedLocations == [0])
    _ = controller.takePendingDirtyRanges()

    // 無効化で全部展開
    controller.setEnabled(false)
    #expect(controller.collapsedLocations.isEmpty)
    #expect(controller.takePendingDirtyRanges() == [NSRange(location: 0, length: 10), NSRange(location: 17, length: 11)])
}

@MainActor @Test func codeBlockControllerNeverCollapsesUnclosedOrNestedBlocks() {
    // 閉じていないフェンスは書きかけ: Source のまま
    let unclosed = makeController("```\nstill typing")
    #expect(unclosed.codeBlocks.isEmpty)
    #expect(unclosed.collapsedLocations.isEmpty)
    // リスト項目 / 引用の中は段落の先頭がブロックの先頭ではない(リスト項目の継続行にあるものも)
    let listed = makeController("- ```\n  x\n  ```")
    #expect(listed.codeBlocks.isEmpty)
    let continued = makeController("- item\n\n  ~~~\n  x\n  ~~~\n\n      deeper")
    #expect(continued.codeBlocks.isEmpty)
    let quoted = makeController("> ```\n> x\n> ```")
    #expect(quoted.codeBlocks.isEmpty)
    // 空白だけの接頭辞(インデントされたフェンス)は折りたたむ
    let indentedFence = makeController("  ```\n  x\n  ```")
    #expect(indentedFence.collapsedLocations == [2])
}

@MainActor @Test func codeBlockControllerHidesLinesBuildsTheHeadDisplayParagraphAndMapsClicks() throws {
    let controller = makeController(two)
    // 先頭の行の段落(インデント型は行頭 17)だけ列挙、残りは隠す
    for offset in [0, 10, 11, 16, 17] { #expect(controller.shouldEnumerate(paragraphStartingAt: offset), "\(offset)") }
    for offset in [4, 6, 23] { #expect(!controller.shouldEnumerate(paragraphStartingAt: offset), "\(offset)") }
    let first = try #require(controller.presentedCodeBlock(at: 0))
    #expect(controller.reservedHeight(forParagraph: NSRange(location: 0, length: 4)) == first.layout.reservedHeight)
    #expect(controller.reservedHeight(forParagraph: NSRange(location: 4, length: 2)) == nil)
    let second = try #require(controller.presentedCodeBlock(at: 21))
    #expect(controller.reservedHeight(forParagraph: NSRange(location: 17, length: 6)) == second.layout.reservedHeight)

    let contentStorage = NSTextContentStorage()
    contentStorage.textStorage?.setAttributedString(NSAttributedString(string: two, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
    let paragraph = try #require(controller.textParagraph(with: NSRange(location: 17, length: 6), in: contentStorage))
    #expect(paragraph.attributedString.string == "    b\n")
    #expect((paragraph.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == LivePreviewConcealer.hiddenFontSize)
    #expect(controller.textParagraph(with: NSRange(location: 23, length: 5), in: contentStorage) == nil)

    // 箱座標 → 文字の間。ブロック 1 の本文 "a" は 4..<5: 左端で 4、右端で 5。本文より上は先頭の行の先頭、下は最後の行の末尾
    let content = first.layout.contentFrame
    #expect(controller.caretLocation(inCodeBlockAt: 0, point: CGPoint(x: content.minX, y: content.midY)) == 4)
    #expect(controller.caretLocation(inCodeBlockAt: 0, point: CGPoint(x: content.maxX, y: content.midY)) == 5)
    #expect(controller.caretLocation(inCodeBlockAt: 0, point: CGPoint(x: 2, y: 2)) == 4)
    #expect(controller.caretLocation(inCodeBlockAt: 0, point: CGPoint(x: 2, y: first.layout.size.height + 2)) == 5)
    #expect(controller.caretLocation(inCodeBlockAt: 0, point: CGPoint(x: 5, y: first.layout.size.height + 50)) == nil)
    #expect(controller.caretLocation(inCodeBlockAt: 4, point: .zero) == nil, "not a block start")
    // インデント型: 表示はインデントを除いた "b" / "c"(21..<22, 27..<28)。2 行目の左端は 27
    let secondContent = second.layout.contentFrame
    let lineHeight = secondContent.height / 2
    #expect(controller.caretLocation(inCodeBlockAt: 21, point: CGPoint(x: secondContent.minX, y: secondContent.minY + lineHeight * 1.5)) == 27)
    #expect(controller.caretLocation(inCodeBlockAt: 21, point: CGPoint(x: secondContent.maxX, y: secondContent.minY + lineHeight * 0.5)) == 22)
    // コピーする本文はインデント無し
    #expect(controller.copyText(forCodeBlockAt: 21) == "b\nc")
    #expect(controller.copyText(forCodeBlockAt: 0) == "a")
    // コピーボタンは右上
    let button = first.layout.buttonFrame
    #expect(controller.isOnCopyButton(inCodeBlockAt: 0, point: CGPoint(x: button.midX, y: button.midY)))
    #expect(!controller.isOnCopyButton(inCodeBlockAt: 0, point: CGPoint(x: content.minX, y: content.midY)))
    #expect(button.maxX <= first.layout.size.width - CodeBlockPreviewLayout.horizontalPadding + 0.5)
}

@MainActor @Test func codeBlockControllerShiftsBlocksAfterEditsAndExpandsATouchedOneUntilTheNextParse() throws {
    let controller = makeController(two)
    _ = controller.takePendingDirtyRanges()
    // ブロック 1 の前("text" ではなく先頭)に 2 文字挿入: 先頭の段落の先頭を含む編集なので表示から外れる、後ろのブロックは平行移動
    controller.noteEdit(editedRange: NSRange(location: 0, length: 2), changeInLength: 2)
    #expect(controller.collapsedLocations == [23])
    #expect(controller.codeBlocks.map(\.range.location) == [23])
    // "text" の後ろに 1 文字挿入: ブロック 1 は消えたまま、ブロック 2 は平行移動
    controller.noteEdit(editedRange: NSRange(location: 17, length: 1), changeInLength: 1)
    #expect(controller.collapsedLocations == [24])
    #expect(controller.presentedCodeBlock(at: 24)?.blockParagraphsRange == NSRange(location: 20, length: 11))
    // インデント型ブロックの行頭(段落の先頭 20、ブロックの先頭 24 より前)への挿入: 触れる編集としてモデルから外す
    controller.noteEdit(editedRange: NSRange(location: 20, length: 1), changeInLength: 1)
    #expect(controller.codeBlocks.isEmpty)
    #expect(controller.collapsedLocations.isEmpty)
    #expect(controller.exemptRanges.isEmpty)
    // 次のパースで戻る
    update(controller, with: "xx```\na\n```\n\ntext!\n\nx    b\n    c")
    #expect(controller.codeBlocks.isEmpty, "the block is broken by the edits; nothing to collapse")
    update(controller, with: two)
    #expect(controller.collapsedLocations == [0, 21])
}

@MainActor @Test func codeBlockControllerDropsAPresentedBlockWhoseStartIsTouchedEvenWhileItCannotPresent() {
    let controller = makeController(two)
    _ = controller.takePendingDirtyRanges()
    controller.canPresent = { false }
    // IME 変換中にブロック 1 の先頭(0)へ 1 文字挿入: 先頭の段落は 0 のまま(挿入した文字がその段落に入る)なので、
    // 表示を平行移動せずに外す(残すと本当の先頭の段落が列挙され、残りの段落だけ隠れたままになる)
    controller.noteEdit(editedRange: NSRange(location: 0, length: 1), changeInLength: 1)
    #expect(controller.collapsedLocations == [22])
    #expect(controller.shouldEnumerate(paragraphStartingAt: 0))
    #expect(controller.shouldEnumerate(paragraphStartingAt: 5), "the body line of the dropped block is enumerated again")
    #expect(controller.takePendingDirtyRanges().first == NSRange(location: 0, length: 11))
    // インデント型(段落 18..<29、ブロック 22..<29)の直前の改行(17)を消す: 同じく外す
    controller.noteEdit(editedRange: NSRange(location: 17, length: 0), changeInLength: -1)
    #expect(controller.collapsedLocations.isEmpty)
    // 先頭の行の前の行への挿入は触れない: 平行移動するだけ
    update(controller, with: two)
    controller.canPresent = { true }
    controller.present()
    #expect(controller.collapsedLocations == [0, 21])
    controller.canPresent = { false }
    controller.noteEdit(editedRange: NSRange(location: 16, length: 1), changeInLength: 1)
    #expect(controller.collapsedLocations == [0, 22])
}

@MainActor @Test func codeBlockControllerBuildsContentOnlyForBlocksItCollapsesAndReusesLayouts() throws {
    let controller = makeController(two)
    #expect(controller.isModelBuilt(forBlockAt: 0) && controller.isModelBuilt(forBlockAt: 21))
    controller.selectionDidChange([NSRange(location: 2, length: 0)])
    update(controller, with: "```\na!\n```\n\ntext\n\n    b\n    c")
    #expect(!controller.isModelBuilt(forBlockAt: 0), "the expanded block's content is not rebuilt")
    #expect(controller.isModelBuilt(forBlockAt: 22), "the collapsed block reuses the content it built before")
    // 同じ内容の再パース(他の場所の編集)ではレイアウトも使い回す(描き直しも作り直しも無い)
    let kept = try #require(controller.presentedCodeBlock(at: 22)?.layout)
    _ = controller.takePendingDirtyRanges()
    _ = controller.takeNeedsRedraw()
    update(controller, with: "```\na!\n```\n\ntext\n\n    b\n    c")
    #expect(controller.presentedCodeBlock(at: 22)?.layout.text === kept.text)
    #expect(!controller.takeNeedsRedraw())
    #expect(controller.takePendingDirtyRanges().isEmpty)
    // 幅が変わっても高さが変わらなければ描き直しだけ
    let before = try #require(controller.presentedCodeBlock(at: 22)?.layout)
    _ = controller.takePendingDirtyRanges()
    controller.containerWidthDidChange(500)
    let after = try #require(controller.presentedCodeBlock(at: 22)?.layout)
    #expect(after.size.width == 500 && before.size.width == 400)
    if after.reservedHeight == before.reservedHeight {
        #expect(controller.takePendingDirtyRanges().isEmpty)
        #expect(controller.takeNeedsRedraw())
    } else {
        #expect(!controller.takePendingDirtyRanges().isEmpty)
    }
}

@MainActor @Test func codeBlockControllerExemptsExpandedBlocksFromLineLevelConcealing() {
    let controller = makeController(two)
    #expect(controller.exemptRanges.isEmpty)
    controller.selectionDidChange([NSRange(location: 25, length: 0)])
    #expect(controller.exemptRanges == [NSRange(location: 17, length: 11)])
    #expect(controller.isExempt(paragraph: NSRange(location: 23, length: 5)))
    #expect(!controller.isExempt(paragraph: NSRange(location: 11, length: 5)))
}

// MARK: - CodeBlockPreviewModel / Layout

@Test func modelStripsTheIndentAndKeepsOffsets() throws {
    let text = "para\n\n    let x = 1\n\ty\n      z" as NSString
    let block = try #require(MarkdownParser().highlightPlan(for: text as String).codeBlocks.first)
    let model = try #require(CodeBlockPreviewModel.make(block: block, text: text))
    #expect(model.language == nil)
    #expect(model.lines.map(\.text) == ["let x = 1", "y", "  z"])
    #expect(model.lines.map(\.displayOffset) == [0, 11, 17])
    #expect(model.copyText == "let x = 1\ny\n  z")
    let fenced = try #require(MarkdownParser().highlightPlan(for: sample).codeBlocks.first)
    let fencedModel = try #require(CodeBlockPreviewModel.make(block: fenced, text: sample as NSString))
    #expect(fencedModel.language == "swift")
    #expect(fencedModel.lines.map(\.displayOffset) == [9, 19])
    #expect(fencedModel.lines.map(\.lineEndOffset) == [18, 27])
}

@MainActor @Test func layoutFloatsTheLabelAndButtonOnTheFirstLineWithEqualPaddingAndWrapsLongLines() throws {
    let appearance = CodeBlockPreviewLayout.Appearance(theme: .default)
    let long = CodeBlockPreviewModel(language: "swift", lines: [
        .init(text: String(repeating: "word ", count: 40), displayOffset: 0, lineEndOffset: 200),
        .init(text: "b", displayOffset: 201, lineEndOffset: 202),
    ])
    let layout = CodeBlockPreviewLayout.make(model: long, maxWidth: 300, appearance: appearance)
    #expect(layout.size.width == 300)
    let label = try #require(layout.labelFrame)
    #expect(label.maxX < layout.buttonFrame.minX)
    #expect(layout.label?.string == "swift")
    // 上下の余白は同じ(帯のぶん上だけ広がらない)
    let pad = appearance.verticalPadding
    #expect(pad >= CodeBlockPreviewLayout.horizontalPadding)
    #expect(layout.contentFrame.minY == pad)
    #expect(layout.size.height - layout.contentFrame.maxY == pad, "\(layout.size.height) vs \(layout.contentFrame.maxY)")
    // 言語名とボタンは本文の最初の行の高さの中央に浮く
    let lineHeight = FrontMatterTableLayout.lineHeight(of: appearance.codeFont)
    #expect(abs(layout.buttonFrame.midY - (pad + lineHeight / 2)) <= 0.5)
    #expect(abs(label.midY - (pad + lineHeight / 2)) <= 0.5)
    // 最初の行の文字はその下に入らず手前で折り返し、2 段目からは全幅を使う
    let text = layout.text
    let firstRow = text.layoutManager.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil)
    #expect(firstRow.minY == 0)
    #expect(layout.contentFrame.minX + firstRow.maxX <= label.minX - CodeBlockPreviewLayout.labelGap + 0.5, "\(firstRow)")
    let secondRowGlyph = text.layoutManager.glyphIndex(for: CGPoint(x: 1, y: lineHeight * 1.5), in: text.container)
    let secondRow = text.layoutManager.lineFragmentRect(forGlyphAt: secondRowGlyph, effectiveRange: nil)
    #expect(secondRow.minY > 0 && secondRow.width == layout.contentFrame.width, "\(secondRow)")
    // 短い 1 行のブロックでは本文の右にボタンが並ぶだけで、行は 1 つのまま
    let short = CodeBlockPreviewModel(language: "swift", lines: [.init(text: "x", displayOffset: 0, lineEndOffset: 1)])
    let shortLayout = CodeBlockPreviewLayout.make(model: short, maxWidth: 300, appearance: appearance)
    #expect(shortLayout.contentFrame.height == lineHeight)
    #expect(shortLayout.size.height == ceil(pad * 2 + lineHeight))
    // ボタンの脇の空きをクリックすると最初の行の末尾
    #expect(shortLayout.caretOffset(at: CGPoint(x: shortLayout.buttonFrame.minX - 20, y: pad + lineHeight / 2)) == 1)
    #expect(layout.contentFrame.height > lineHeight * 3, "the long line wraps: \(layout.contentFrame.height)")
    #expect(layout.reservedHeight == layout.size.height)
    // 折り返した 1 行目の 2 段目の左端は 1 行目の途中の文字、2 行目は最後
    let wrappedSecondRow = CGPoint(x: layout.contentFrame.minX + 1, y: layout.contentFrame.minY + lineHeight * 1.5)
    let offset = try #require(layout.caretOffset(at: wrappedSecondRow))
    #expect(offset > 0 && offset < 200)
    #expect(layout.caretOffset(at: CGPoint(x: layout.contentFrame.maxX, y: layout.contentFrame.maxY - 1)) == 202)
    // 絵文字の右半分をクリックしても合成文字の内部(UTF-16 の途中)にはならない
    let emoji = CodeBlockPreviewModel(language: nil, lines: [.init(text: "😀b", displayOffset: 0, lineEndOffset: 3)])
    let emojiLayout = CodeBlockPreviewLayout.make(model: emoji, maxWidth: 300, appearance: appearance)
    let emojiRect = emojiLayout.text.layoutManager.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: emojiLayout.text.container)
    let rightHalf = CGPoint(x: emojiLayout.contentFrame.minX + emojiRect.maxX - 1, y: emojiLayout.contentFrame.minY + emojiRect.midY)
    #expect(emojiLayout.caretOffset(at: rightHalf) == 2)
    let leftHalf = CGPoint(x: emojiLayout.contentFrame.minX + emojiRect.minX + 1, y: emojiLayout.contentFrame.minY + emojiRect.midY)
    #expect(emojiLayout.caretOffset(at: leftHalf) == 0)
    // 言語無し・本文無し: ボタンの行だけの箱
    let empty = CodeBlockPreviewLayout.make(model: .init(language: nil, lines: []), maxWidth: 300, appearance: appearance)
    #expect(empty.labelFrame == nil)
    #expect(empty.size.height == ceil(appearance.verticalPadding * 2 + max(lineHeight, CodeBlockPreviewLayout.buttonSize)))
    #expect(empty.buttonFrame.minY >= appearance.verticalPadding - 0.5)
    #expect(empty.caretOffset(at: CGPoint(x: 10, y: 10)) == 0)
    #expect(empty.caretOffset(at: CGPoint(x: 10, y: 200)) == nil)
    // 幅が無いときは既定の幅
    #expect(CodeBlockPreviewLayout.make(model: long, maxWidth: 0, appearance: appearance).size.width == CodeBlockPreviewLayout.fallbackWidth)
}

// MARK: - MarkdownTextView(AppKit)

@MainActor
private func makeFocusedTextView(_ markdown: String, livePreview: Bool = true) -> (NSWindow, MarkdownTextView) {
    let scrollView = MarkdownTextView.scrollableMarkdownEditor()
    let textView = scrollView.documentView as! MarkdownTextView
    scrollView.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = scrollView
    textView.string = markdown
    textView.highlightAll()
    textView.isLivePreviewEnabled = livePreview
    #expect(window.makeFirstResponder(textView))
    return (window, textView)
}

@MainActor
private func enumeratedOffsets(_ textView: MarkdownTextView) -> [Int] {
    let contentManager = textView.textLayoutManager!.textContentManager!
    var offsets: [Int] = []
    contentManager.enumerateTextElements(from: contentManager.documentRange.location) { element in
        if let location = element.elementRange?.location {
            offsets.append(contentManager.offset(from: contentManager.documentRange.location, to: location))
        }
        return true
    }
    return offsets
}

@MainActor
private func fragmentOffset(_ fragment: NSTextLayoutFragment, in textView: MarkdownTextView) -> Int {
    let contentManager = textView.textLayoutManager!.textContentManager!
    return contentManager.offset(from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
}

@MainActor
private func layoutFragments(_ textView: MarkdownTextView) -> [NSTextLayoutFragment] {
    let layoutManager = textView.textLayoutManager!
    layoutManager.ensureLayout(for: layoutManager.documentRange)
    var fragments: [NSTextLayoutFragment] = []
    layoutManager.enumerateTextLayoutFragments(from: nil, options: []) { fragments.append($0); return true }
    return fragments
}

@MainActor @Test func textViewCollapsesACodeBlockIntoABoxAndExpandsAtTheClickedCharacter() throws {
    let (window, textView) = makeFocusedTextView(sample)
    defer { withExtendedLifetime(window) {} }
    textView.setSelectedRange(NSRange(location: 48, length: 0))  // after
    textView.layoutSubtreeIfNeeded()
    let controller = textView.codeBlockPreviewController
    #expect(controller.collapsedLocations == [13])

    // 開始フェンスの段落以外のブロックの段落は列挙されない
    let offsets = enumeratedOffsets(textView)
    #expect(offsets.contains(13))
    #expect(!offsets.contains(22) && !offsets.contains(32) && !offsets.contains(41))
    #expect(offsets.contains(46))

    // 開始フェンスのフラグメントは高さほぼ 0 の行 + 箱の予約高さ、コードブロックの装飾は無い
    let fragments = layoutFragments(textView)
    let head = try #require(fragments.first { fragmentOffset($0, in: textView) == 13 })
    let reserved = try #require(controller.presentedCodeBlock(at: 13)?.layout.reservedHeight)
    let textLinesBottom = head.textLineFragments.reduce(0) { max($0, $1.typographicBounds.maxY) }
    #expect(textLinesBottom < 1)
    #expect(abs(head.layoutFragmentFrame.height - (textLinesBottom + reserved)) < 1)
    #expect(!(head is CodeBlockFragment), "the hidden fence line is not decorated")

    // ビューポートレイアウトで箱が置かれる: テキストコンテナの全幅、その下に本文が続く
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    let entry = try #require(textView.debugCodeBlockEntries.first)
    #expect(textView.debugCodeBlockEntries.count == 1)
    #expect(entry.location == 13)
    #expect(entry.frame.minX == textView.textContainerOrigin.x)
    #expect(entry.frame.width == textView.textContainer!.size.width)
    #expect(entry.layout.label?.string == "swift")
    #expect(!entry.showsCopied)
    let headTop = head.layoutFragmentFrame.minY + textView.textContainerOrigin.y
    #expect(abs(entry.frame.minY - (headTop + textLinesBottom + CodeBlockPreviewLayout.topMargin)) < 1)
    let after = try #require(fragments.first { fragmentOffset($0, in: textView) == 45 })
    let afterTop = after.layoutFragmentFrame.minY + textView.textContainerOrigin.y
    #expect(abs(afterTop - (entry.frame.maxY + CodeBlockPreviewLayout.bottomMargin)) < 1, "body \(afterTop) follows the box \(entry.frame.maxY)")

    // 2 行目 "print(x)" の "(" の前(文字 5)をクリック: キャレットは 32 + 5 = 37、ブロックが展開される
    let text = entry.layout.text
    let glyphRect = text.layoutManager.boundingRect(forGlyphRange: NSRange(location: 10 + 5, length: 1), in: text.container)
    let content = entry.layout.contentFrame
    let clickPoint = CGPoint(x: entry.frame.minX + content.minX + glyphRect.minX + 1, y: entry.frame.minY + content.minY + glyphRect.midY)
    #expect(!textView.copyCodeBlock(atPoint: clickPoint))
    #expect(textView.expandCodeBlock(atPoint: clickPoint))
    #expect(textView.selectedRange() == NSRange(location: 37, length: 0))
    #expect(controller.collapsedLocations.isEmpty)
    #expect(Set(enumeratedOffsets(textView)).isSuperset(of: [13, 22, 32, 41, 46]))
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    #expect(textView.debugCodeBlockEntries.isEmpty)
    // 展開中は開始フェンスが Source と同じ高さと装飾で見える
    let expanded = try #require(layoutFragments(textView).first { fragmentOffset($0, in: textView) == 13 })
    #expect(expanded.textLineFragments.first!.typographicBounds.height > 5)
    #expect(expanded is CodeBlockFragment)
    // 箱の外のクリックは何もしない
    #expect(!textView.expandCodeBlock(atPoint: CGPoint(x: 10, y: 290)))

    // キャレットが本文へ戻ると再び折りたたまれる
    textView.setSelectedRange(NSRange(location: 48, length: 0))
    #expect(controller.collapsedLocations == [13])
    #expect(!enumeratedOffsets(textView).contains(22))
    #expect(textView.string == sample, "テキストは終始そのまま")
}

@MainActor @Test func textViewCopiesTheCodeFromTheButtonWithoutExpanding() throws {
    let (window, textView) = makeFocusedTextView(sample)
    defer { withExtendedLifetime(window) {} }
    textView.setSelectedRange(NSRange(location: 48, length: 0))
    textView.layoutSubtreeIfNeeded()
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    let entry = try #require(textView.debugCodeBlockEntries.first)
    let button = entry.layout.buttonFrame
    let point = CGPoint(x: entry.frame.minX + button.midX, y: entry.frame.minY + button.midY)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    #expect(textView.copyCodeBlock(atPoint: point))
    #expect(pasteboard.string(forType: .string) == "let x = 1\nprint(x)")
    #expect(textView.codeBlockPreviewController.collapsedLocations == [13], "copying does not expand")
    #expect(textView.selectedRange() == NSRange(location: 48, length: 0))
    // ボタンはしばらくチェックマーク
    #expect(textView.engine.copiedCodeBlockLocation == 13)
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    #expect(textView.debugCodeBlockEntries.first?.showsCopied == true)
    // ボタンの上のクリックは展開しない(mouseDown はコピーを先に試す)
    #expect(textView.engine.codeBlockCaretRange(atPoint: point) == nil)
    // 編集の後、次のビューポートレイアウトまでは前回の矩形で当たり判定しない(動いたブロックに古いボタンを当てない)
    textView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
    #expect(!textView.copyCodeBlock(atPoint: point))
    #expect(textView.engine.codeBlockCaretRange(atPoint: CGPoint(x: entry.frame.minX + 20, y: entry.frame.midY)) == nil)
}

@MainActor @Test func textViewShowsEveryFenceOfAnExpandedBlockAndCollapsesOnFocusLoss() throws {
    let (window, textView) = makeFocusedTextView(sample)
    defer { withExtendedLifetime(window) {} }
    let contentManager = textView.textLayoutManager!.textContentManager!
    func displayFontSize(atOffset offset: Int) -> CGFloat? {
        let location = contentManager.location(contentManager.documentRange.location, offsetBy: offset)!
        var size: CGFloat?
        contentManager.enumerateTextElements(from: location) { element in
            guard let paragraph = element as? NSTextParagraph, let start = element.elementRange?.location else { return false }
            let local = contentManager.offset(from: start, to: location)
            size = (paragraph.attributedString.attribute(.font, at: local, effectiveRange: nil) as? NSFont)?.pointSize
            return false
        }
        return size
    }
    // キャレットが本文の行(2 行目)にある: 開始フェンス(13)と終了フェンス(41)は Source と同じ大きさで見える
    textView.setSelectedRange(NSRange(location: 25, length: 0))
    textView.layoutSubtreeIfNeeded()
    #expect(textView.codeBlockPreviewController.collapsedLocations.isEmpty)
    #expect(displayFontSize(atOffset: 13) ?? 0 > 1)
    #expect(displayFontSize(atOffset: 41) ?? 0 > 1)
    // フォーカスを失うと折りたたまれる、戻ると展開
    #expect(window.makeFirstResponder(nil))
    #expect(textView.codeBlockPreviewController.collapsedLocations == [13])
    #expect(!enumeratedOffsets(textView).contains(22))
    #expect(window.makeFirstResponder(textView))
    #expect(textView.codeBlockPreviewController.collapsedLocations.isEmpty)
}

@MainActor @Test func textViewNeverCollapsesCodeBlocksInSourceAndFollowsTheToggle() throws {
    let (window, textView) = makeFocusedTextView(sample, livePreview: false)
    defer { withExtendedLifetime(window) {} }
    textView.setSelectedRange(NSRange(location: 48, length: 0))
    #expect(textView.codeBlockPreviewController.collapsedLocations.isEmpty)
    #expect(enumeratedOffsets(textView).contains(22))
    textView.isLivePreviewEnabled = true
    #expect(textView.codeBlockPreviewController.collapsedLocations == [13])
    #expect(!enumeratedOffsets(textView).contains(22))
    textView.isLivePreviewEnabled = false
    #expect(textView.codeBlockPreviewController.collapsedLocations.isEmpty)
    #expect(enumeratedOffsets(textView).contains(22))
}

@MainActor @Test func textViewFollowsEditsThatChangeOrDestroyTheCodeBlock() throws {
    let (window, textView) = makeFocusedTextView(sample)
    defer { withExtendedLifetime(window) {} }
    textView.setSelectedRange(NSRange(location: 48, length: 0))
    let controller = textView.codeBlockPreviewController
    #expect(controller.collapsedLocations == [13])
    // 折りたたみ中に外部更新で本文が変わる: 再パース後も折りたたまれ、箱の中身が変わる
    textView.textStorage!.replaceCharacters(in: NSRange(location: 30, length: 1), with: "9")
    #expect(controller.collapsedLocations.isEmpty, "expanded until the next parse")
    textView.highlightNow()
    #expect(controller.collapsedLocations == [13])
    #expect(controller.presentedCodeBlock(at: 13)?.layout.model.lines.first?.text == "let x = 9")
    // 終了フェンスを消す(キャレットをブロック内に置いてから): 閉じていないので Source のまま
    textView.setSelectedRange(NSRange(location: 25, length: 0))
    textView.textStorage!.replaceCharacters(in: NSRange(location: 41, length: 3), with: "")
    textView.highlightNow()
    #expect(textView.markdownHighlighter.currentPlan.codeBlocks.first?.isClosed == false)
    textView.setSelectedRange(NSRange(location: 5, length: 0))
    #expect(controller.collapsedLocations.isEmpty)
    #expect(enumeratedOffsets(textView).contains(22))
    // 閉じ直すと折りたたまれる
    textView.textStorage!.replaceCharacters(in: NSRange(location: 41, length: 0), with: "```")
    textView.highlightNow()
    #expect(controller.collapsedLocations == [13])
}

@MainActor @Test func textViewCollapsesBothAFencedAndAnIndentedBlock() throws {
    let (window, textView) = makeFocusedTextView(two)
    defer { withExtendedLifetime(window) {} }
    textView.setSelectedRange(NSRange(location: 13, length: 0))  // text
    textView.layoutSubtreeIfNeeded()
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    #expect(textView.debugCodeBlockEntries.map(\.location) == [0, 21])
    let second = try #require(textView.debugCodeBlockEntries.last)
    #expect(second.frame.minY > textView.debugCodeBlockEntries[0].frame.maxY)
    #expect(second.layout.label == nil)
    #expect(second.layout.model.lines.map(\.text) == ["b", "c"])
    // インデント型の 1 行目の左端をクリック: 表示の先頭 = インデントの後(21)
    let content = second.layout.contentFrame
    #expect(textView.expandCodeBlock(atPoint: CGPoint(x: second.frame.minX + content.minX, y: second.frame.minY + content.minY + 2)))
    #expect(textView.selectedRange() == NSRange(location: 21, length: 0))
    #expect(textView.codeBlockPreviewController.collapsedLocations == [0])
}
#endif
