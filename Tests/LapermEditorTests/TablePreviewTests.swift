#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import LapermEditor
@testable import LapermCore

// テキスト: "# T\n"(0-3) "\n"(4) "| a | b |\n"(5-14) "|---|:-:|\n"(15-24) "| 1 | 2 |\n"(25-34) "\n"(35) "after"(36-40)
// テーブルのレンジは 5..<34、ブロックの段落は 5..<35。セル: a=7, b=11, 1=27, 2=31(内容の末尾は +1)
private let sample = "# T\n\n| a | b |\n|---|:-:|\n| 1 | 2 |\n\nafter"

// 2 つのテーブル: "| a |\n"(0-5) "|---|\n"(6-11) "| 1 |\n"(12-17) "\n"(18) "text\n"(19-23) "\n"(24) "| b |\n"(25-30) "|:-:|\n"(31-36) "| 2 |"(37-41)
// テーブル 1 のレンジは 0..<17(ブロック 0..<18)、テーブル 2 は 25..<42(改行無しで文末。ブロックも 25..<42)
private let two = "| a |\n|---|\n| 1 |\n\ntext\n\n| b |\n|:-:|\n| 2 |"

@MainActor
private func makeController(_ text: String, width: CGFloat = 400, enabled: Bool = true) -> TablePreviewController {
    let controller = TablePreviewController(theme: .default)
    controller.setEnabled(enabled)
    controller.containerWidthDidChange(width)
    update(controller, with: text)
    return controller
}

@MainActor
private func update(_ controller: TablePreviewController, with text: String) {
    let plan = MarkdownParser().highlightPlan(for: text)
    let storage = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
    controller.update(plan: plan, storage: storage, text: text as NSString)
}

// MARK: - TablePreviewController

@MainActor @Test func tableControllerCollapsesEachTableUnlessTheCaretTouchesIt() throws {
    let controller = makeController(two)
    #expect(controller.tables.count == 2)
    #expect(controller.collapsedLocations == [0, 25])
    #expect(controller.takePendingDirtyRanges() == [NSRange(location: 0, length: 18), NSRange(location: 25, length: 17)])

    // 本文にキャレット: 両方折りたたみのまま
    controller.selectionDidChange([NSRange(location: 20, length: 0)])
    #expect(controller.collapsedLocations == [0, 25])
    #expect(controller.takePendingDirtyRanges().isEmpty)
    // テーブル 1 の中: そのテーブルだけ展開
    controller.selectionDidChange([NSRange(location: 3, length: 0)])
    #expect(controller.collapsedLocations == [25])
    #expect(controller.takePendingDirtyRanges() == [NSRange(location: 0, length: 18)])
    // 最後の行の行末(17)は触れる、次の行頭(18)は触れない
    controller.selectionDidChange([NSRange(location: 17, length: 0)])
    #expect(controller.collapsedLocations == [25])
    controller.selectionDidChange([NSRange(location: 18, length: 0)])
    #expect(controller.collapsedLocations == [0, 25])
    _ = controller.takePendingDirtyRanges()
    // テーブルの直前で終わる選択は触れない、テーブルに入る選択は触れる
    controller.selectionDidChange([NSRange(location: 19, length: 6)])
    #expect(controller.collapsedLocations == [0, 25])
    controller.selectionDidChange([NSRange(location: 19, length: 7)])
    #expect(controller.collapsedLocations == [0])
    // 改行無しで文末に終わるテーブル 2 は、文末(42)のキャレットで展開
    controller.selectionDidChange([NSRange(location: 42, length: 0)])
    #expect(controller.collapsedLocations == [0])
    _ = controller.takePendingDirtyRanges()

    // フォーカスを失うとキャレットがテーブル内でも折りたたむ、戻ると展開
    controller.editorFocusDidChange(false)
    #expect(controller.collapsedLocations == [0, 25])
    #expect(controller.takePendingDirtyRanges() == [NSRange(location: 25, length: 17)])
    controller.editorFocusDidChange(true)
    #expect(controller.collapsedLocations == [0])
    _ = controller.takePendingDirtyRanges()

    // 無効化で全部展開
    controller.setEnabled(false)
    #expect(controller.collapsedLocations.isEmpty)
    #expect(controller.takePendingDirtyRanges() == [NSRange(location: 0, length: 18)])
}

@MainActor @Test func tableControllerKeepsTheCaretVisibleOnTheTrailingEmptyLineAfterATable() {
    // テーブルの改行で終わる文書: 文末(18)の空行は最後の行の段落に描かれるので、そこにキャレットがあれば展開
    let text = "| a |\n|---|\n| 1 |\n"
    let controller = makeController(text)
    controller.selectionDidChange([NSRange(location: 18, length: 0)])
    #expect(controller.collapsedLocations.isEmpty)
    controller.selectionDidChange([NSRange(location: 17, length: 0)])
    #expect(controller.collapsedLocations.isEmpty)
    // 空行を挟んで本文が続くなら、その空行(18)は触れない(空行無しの "b" は GFM ではテーブルの行になる)
    let withBody = "| a |\n|---|\n| 1 |\n\nb"
    update(controller, with: withBody)
    #expect(controller.tables.first?.range == NSRange(location: 0, length: 17))
    #expect(controller.collapsedLocations.isEmpty, "the caret (17) is still at the end of the last row")
    controller.selectionDidChange([NSRange(location: 18, length: 0)])
    #expect(controller.collapsedLocations == [0])
}

@MainActor @Test func tableControllerNeverCollapsesATableThatDoesNotStartAtALineStart() {
    // 引用やリスト項目の中のテーブルは段落の先頭がテーブルの先頭ではないので、折りたたまない
    let listed = "- | a |\n  |---|\n  | 1 |"
    #expect(MarkdownParser().highlightPlan(for: listed).tables.first?.range.location == 2)
    let controller = makeController(listed)
    #expect(controller.tables.isEmpty)
    #expect(controller.collapsedLocations.isEmpty)
    #expect(controller.takePendingDirtyRanges().isEmpty)
    let quoted = "> | a |\n> |---|\n> | 1 |"
    update(controller, with: quoted)
    #expect(controller.tables.isEmpty)
    #expect(controller.collapsedLocations.isEmpty)
}

@MainActor @Test func tableControllerHidesRowsBuildsTheHeaderDisplayParagraphAndMapsClicksToCells() throws {
    let controller = makeController(two)
    for offset in [0, 18, 19, 25] { #expect(controller.shouldEnumerate(paragraphStartingAt: offset), "\(offset)") }
    for offset in [6, 12, 31, 37] { #expect(!controller.shouldEnumerate(paragraphStartingAt: offset), "\(offset)") }
    let first = try #require(controller.presentedTable(at: 0))
    #expect(controller.reservedHeight(forParagraph: NSRange(location: 0, length: 6)) == first.layout.reservedHeight)
    #expect(controller.reservedHeight(forParagraph: NSRange(location: 6, length: 6)) == nil)
    #expect(controller.reservedHeight(forParagraph: NSRange(location: 25, length: 6)) == controller.presentedTable(at: 25)?.layout.reservedHeight)

    let contentStorage = NSTextContentStorage()
    contentStorage.textStorage?.setAttributedString(NSAttributedString(string: two, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
    let paragraph = try #require(controller.textParagraph(with: NSRange(location: 0, length: 6), in: contentStorage))
    #expect(paragraph.attributedString.string == "| a |\n")
    #expect((paragraph.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == LivePreviewConcealer.hiddenFontSize)
    let style = try #require(paragraph.attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
    #expect(style.paragraphSpacing == first.layout.reservedHeight)
    #expect(controller.textParagraph(with: NSRange(location: 6, length: 6), in: contentStorage) == nil)

    // 表座標 → セルの内容の末尾。ヘッダー "a" は 2..<3、ボディ "1" は 14..<15
    let header = first.layout.rows[0]
    let body = first.layout.rows[1]
    #expect(controller.caretLocation(inTableAt: 0, tablePoint: CGPoint(x: header.cells[0].frame.midX, y: header.frame.midY)) == 3)
    #expect(controller.caretLocation(inTableAt: 0, tablePoint: CGPoint(x: body.cells[0].frame.midX, y: body.frame.midY)) == 15)
    #expect(controller.caretLocation(inTableAt: 0, tablePoint: CGPoint(x: 5, y: first.layout.size.height + 50)) == nil)
    #expect(controller.caretLocation(inTableAt: 6, tablePoint: .zero) == nil, "not a table start")
}

@MainActor @Test func tableControllerShiftsTablesAfterEditsAndExpandsATouchedOneUntilTheNextParse() throws {
    let controller = makeController(two)
    _ = controller.takePendingDirtyRanges()
    let secondLayout = try #require(controller.presentedTable(at: 25)).layout

    // "text" の中に 5 文字挿入: テーブル 2 だけ動く。作り直しは無い(表示は同じ)
    controller.noteEdit(editedRange: NSRange(location: 20, length: 5), changeInLength: 5)
    #expect(controller.tables.map(\.range.location) == [0, 30])
    #expect(controller.collapsedLocations == [0, 30])
    #expect(controller.presentedTable(at: 30)?.blockParagraphsRange == NSRange(location: 30, length: 17))
    #expect(controller.presentedTable(at: 30)?.layout == secondLayout, "the layout is carried over")
    #expect(controller.takePendingDirtyRanges().isEmpty)
    #expect(controller.documentLength == (two as NSString).length + 5)

    // テーブル 1 の直後の行頭(18)への挿入はテーブルに触れない(行が増えるかは次のパースが決める)
    controller.noteEdit(editedRange: NSRange(location: 18, length: 1), changeInLength: 1)
    #expect(controller.collapsedLocations == [0, 31])
    #expect(controller.takePendingDirtyRanges().isEmpty)

    // テーブル 1 の中の編集: そのテーブルはモデルから外れ、次のパースまで展開(旧ブロックを作り直す)。クリックも受けない
    controller.noteEdit(editedRange: NSRange(location: 2, length: 1), changeInLength: 1)
    #expect(controller.tables.map(\.range.location) == [32])
    #expect(controller.collapsedLocations == [32])
    #expect(controller.takePendingDirtyRanges() == [NSRange(location: 0, length: 19)])
    #expect(controller.caretLocation(inTableAt: 0, tablePoint: CGPoint(x: 5, y: 5)) == nil)

    // 再パースで戻る(上の 3 つの編集を反映した文書: 18 に入れた 1 文字は空行)
    let edited = "| xa |\n|---|\n| 1 |\n\n\ntexxxxxxt\n\n| b |\n|:-:|\n| 2 |"
    update(controller, with: edited)
    #expect(controller.collapsedLocations == [0, 32])
    #expect(controller.takePendingDirtyRanges() == [NSRange(location: 0, length: 19)])

    // テーブル 2 の直前の改行(31)を消す = 前の行と繋がる: テーブル 2 が外れる
    controller.noteEdit(editedRange: NSRange(location: 31, length: 0), changeInLength: -1)
    #expect(controller.tables.map(\.range.location) == [0])
    // テーブル 1 の先頭(0)への挿入も触れる(ヘッダー行が変わる)
    controller.noteEdit(editedRange: NSRange(location: 0, length: 1), changeInLength: 1)
    #expect(controller.tables.isEmpty)
    #expect(controller.collapsedLocations.isEmpty)
}

@MainActor @Test func tableControllerDefersThePresentationWhileItCannotPresent() {
    let controller = TablePreviewController(theme: .default)
    var canPresent = false
    controller.canPresent = { canPresent }
    controller.setEnabled(true)
    controller.containerWidthDidChange(400)
    update(controller, with: two)
    #expect(controller.collapsedLocations.isEmpty, "nothing is shown to TextKit while presenting is not allowed")
    #expect(controller.hasPendingPresentation)
    #expect(controller.shouldEnumerate(paragraphStartingAt: 6))
    #expect(controller.takePendingDirtyRanges().isEmpty)
    canPresent = true
    #expect(controller.present())
    #expect(controller.collapsedLocations == [0, 25])
    #expect(!controller.hasPendingPresentation)
    #expect(!controller.shouldEnumerate(paragraphStartingAt: 6))
    #expect(controller.takePendingDirtyRanges().count == 2)
    #expect(!controller.present())
}

@MainActor @Test func tableControllerRegeneratesTheBlockWhenTheWidthChangesTheHeightAndReusesLayoutsOtherwise() throws {
    let text = "| a | b |\n|---|---|\n| " + String(repeating: "word ", count: 30) + "| x |"
    let controller = makeController(text, width: 600)
    _ = controller.takePendingDirtyRanges()
    let wide = try #require(controller.presentedTable(at: 0)).layout
    controller.containerWidthDidChange(200)
    let narrow = try #require(controller.presentedTable(at: 0)).layout
    #expect(narrow.reservedHeight > wide.reservedHeight)
    #expect(narrow.size.width <= 200)
    #expect(controller.takePendingDirtyRanges() == [NSRange(location: 0, length: (text as NSString).length)])
    controller.containerWidthDidChange(200)
    #expect(controller.takePendingDirtyRanges().isEmpty)
    #expect(!controller.takeNeedsRedraw())
    // 同じ文書の再パースでもレイアウトは使い回す
    update(controller, with: text)
    #expect(controller.presentedTable(at: 0)?.layout == narrow)
    #expect(controller.takePendingDirtyRanges().isEmpty)
    // テーマが変わるとセルの色が変わる(高さは同じなら再描画だけ)
    var theme = MarkdownTheme.default
    theme.bodyColor = .systemRed
    controller.themeDidChange(theme)
    update(controller, with: text)
    let recoloured = try #require(controller.presentedTable(at: 0)).layout
    #expect(recoloured.rows[0].cells[0].text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemRed)
}

// MARK: - TablePreviewModel

@MainActor @Test func modelStripsMarkersAndEscapedPipesAndAppliesTheThemeColours() throws {
    let (window, textView) = makeFocusedTextView("| **a** \\| b | [l](u) |\n|---|---|\n| `c` | ~~d~~ |", livePreview: false)
    defer { withExtendedLifetime(window) {} }
    let plan = textView.markdownHighlighter.currentPlan
    let table = try #require(plan.tables.first)
    let model = try #require(TablePreviewModel.make(table: table, storage: textView.textStorage!, plan: plan, theme: .default))
    #expect(model.alignments == [.none, .none])
    let header = model.header.cells.map(\.text)
    #expect(header.map(\.string) == ["a | b", "l"])
    let boldFont = try #require(header[0].attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    #expect(boldFont.fontDescriptor.symbolicTraits.contains(.bold), "strong keeps its font from the storage")
    #expect(header[0].attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == MarkdownTheme.default.bodyColor)
    #expect(header[1].attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == MarkdownTheme.default.renderingColor(for: .link))
    let body = model.rows[0].cells.map(\.text)
    #expect(body.map(\.string) == ["c", "d"])
    #expect(body[0].attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == MarkdownTheme.default.renderingColor(for: .inlineCode))
    #expect(body[1].attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
    #expect(model.header.cells[1].caretLocation == NSMaxRange(table.header.cells[1].range))
    #expect(model.rows[0].lineRange == table.rows[0].lineRange)
}

// MARK: - TablePreviewLayout

private func cell(_ string: String, caret: Int = 0) -> TablePreviewModel.Cell {
    .init(text: NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 14)]), caretLocation: caret)
}

@MainActor @Test func layoutUsesNaturalWidthsWhenTheyFitAndWrapsWhenTheyDoNot() throws {
    let model = TablePreviewModel(
        alignments: [.none, .center, .right],
        header: .init(cells: [cell("a"), cell("bb"), cell("ccc")], lineRange: NSRange(location: 0, length: 5)),
        rows: [.init(cells: [cell("1"), cell(""), cell("3")], lineRange: NSRange(location: 10, length: 5))])
    let appearance = TablePreviewLayout.Appearance(theme: .default)
    let compact = TablePreviewLayout.make(model: model, maxWidth: 400, appearance: appearance)
    #expect(compact.rows.count == 2)
    #expect(compact.rows[0].isHeader && !compact.rows[1].isHeader)
    #expect(compact.size.width < 400, "a small table is as wide as its content")
    #expect(compact.size.width == compact.columnWidths.reduce(0, +))
    #expect(compact.columnWidths.allSatisfy { $0 >= TablePreviewLayout.minimumColumnWidth })
    #expect(compact.rows[1].frame.minY == compact.rows[0].frame.maxY)
    #expect(compact.size.height == compact.rows[1].frame.maxY)
    #expect(compact.reservedHeight == TablePreviewLayout.topMargin + compact.size.height + TablePreviewLayout.bottomMargin)
    let lineHeight = FrontMatterTableLayout.lineHeight(of: MarkdownTheme.default.bodyFont)
    #expect(compact.rows.allSatisfy { $0.frame.height == ceil(lineHeight + TablePreviewLayout.cellVerticalPadding * 2) })
    // 揃えは段落スタイルに
    let alignments = compact.rows[0].cells.map { ($0.text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment }
    #expect(alignments == [.left, .center, .right])
    #expect(compact.rows[1].cells[1].text.length == 0, "an empty cell stays empty")
    #expect(compact.rows[1].cells[1].caretLocation == 0)

    // 広いセルは折り返す: 幅は上限どおり、行は 2 行以上の高さ
    let long = TablePreviewModel(
        alignments: [.none, .none],
        header: .init(cells: [cell("k"), cell("v")], lineRange: NSRange(location: 0, length: 5)),
        rows: [.init(cells: [cell("short"), cell(String(repeating: "word ", count: 40))], lineRange: NSRange(location: 10, length: 5))])
    let wrapped = TablePreviewLayout.make(model: long, maxWidth: 300, appearance: appearance)
    #expect(wrapped.size.width == 300)
    #expect(wrapped.rows[1].frame.height > lineHeight * 2)
    #expect(wrapped.rows[1].cells[1].textFrame.maxX <= 300)
    #expect(wrapped.rows[1].cells[0].frame.width >= TablePreviewLayout.minimumColumnWidth)

    // 幅が無いときは既定幅を上限に
    #expect(TablePreviewLayout.make(model: long, maxWidth: 0, appearance: appearance).size.width == TablePreviewLayout.fallbackWidth)
}

@Test func layoutDistributesWidthProportionallyAboveTheMinimum() {
    #expect(TablePreviewLayout.distribute(natural: [100, 50], available: 400) == [100, 50])
    // 公平な取り分(100)に収まる列はそのまま、溢れる列が残りを取る
    #expect(TablePreviewLayout.distribute(natural: [100, 300], available: 200) == [100, 100])
    #expect(TablePreviewLayout.distribute(natural: [60, 70, 400], available: 300) == [60, 70, 170])
    // 溢れる列が複数なら自然な幅に比例して分ける(合計は上限どおり)
    #expect(TablePreviewLayout.distribute(natural: [200, 600], available: 400) == [200, 200])
    #expect(TablePreviewLayout.distribute(natural: [300, 600], available: 300) == [100, 200])
    // 最低幅の合計が上限を超える: 最低幅のまま(はみ出す)
    let tooMany = TablePreviewLayout.distribute(natural: [100, 100, 100, 100], available: 100)
    #expect(tooMany == [CGFloat](repeating: TablePreviewLayout.minimumColumnWidth, count: 4))
    // 自然な幅が最低幅より狭い列はそれ以上縮まない
    let narrow = TablePreviewLayout.distribute(natural: [20, 500], available: 200)
    #expect(narrow[0] == 20 && narrow[1] == 180)
}

@MainActor @Test func layoutHitTestsCellsWithSlackAroundTheEdges() throws {
    let model = TablePreviewModel(
        alignments: [.none, .none],
        header: .init(cells: [cell("a", caret: 1), cell("b", caret: 2)], lineRange: NSRange(location: 0, length: 5)),
        rows: [.init(cells: [cell("1", caret: 3), cell("2", caret: 4)], lineRange: NSRange(location: 10, length: 5))])
    let layout = TablePreviewLayout.make(model: model, maxWidth: 400, appearance: .init(theme: .default))
    let second = layout.rows[1]
    #expect(layout.cell(at: CGPoint(x: second.cells[1].frame.midX, y: second.frame.midY))?.caretLocation == 4)
    #expect(layout.cell(at: CGPoint(x: 1, y: 1))?.caretLocation == 1)
    #expect(layout.cell(at: CGPoint(x: -2, y: -2))?.caretLocation == 1, "just outside the corner still hits the first cell")
    #expect(layout.cell(at: CGPoint(x: layout.size.width + 2, y: layout.size.height + 2))?.caretLocation == 4)
    #expect(layout.cell(at: CGPoint(x: 5, y: layout.size.height + 20)) == nil)
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

@MainActor @Test func textViewCollapsesATableIntoAGridAndExpandsWhenACellIsClicked() throws {
    let (window, textView) = makeFocusedTextView(sample)
    defer { withExtendedLifetime(window) {} }
    textView.setSelectedRange(NSRange(location: 38, length: 0))  // after
    textView.layoutSubtreeIfNeeded()
    let controller = textView.tablePreviewController
    #expect(controller.collapsedLocations == [5])

    // ヘッダー行以外のテーブルの段落は列挙されない
    let offsets = enumeratedOffsets(textView)
    #expect(offsets.contains(5))
    #expect(!offsets.contains(15) && !offsets.contains(25))
    #expect(offsets.contains(36))

    // ヘッダー行のフラグメントは高さほぼ 0 の行 + 表の予約高さ。本文はその下から始まる
    let fragments = layoutFragments(textView)
    let header = try #require(fragments.first { fragmentOffset($0, in: textView) == 5 })
    let reserved = try #require(controller.presentedTable(at: 5)?.layout.reservedHeight)
    let textLinesBottom = header.textLineFragments.reduce(0) { max($0, $1.typographicBounds.maxY) }
    #expect(textLinesBottom < 1, "極小フォントの行は高さほぼ 0")
    #expect(abs(header.layoutFragmentFrame.height - (textLinesBottom + reserved)) < 1)
    #expect(!(header is TableBackgroundFragment), "the hidden header row is not decorated")

    // ビューポートレイアウトで表が置かれる: 左端は本文の左端、その下(余白の後)に本文が続く
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    let entries = textView.debugTableEntries
    #expect(entries.count == 1)
    let entry = try #require(entries.first)
    #expect(entry.location == 5)
    #expect(entry.layout.rows.count == 2)
    #expect(entry.frame.minX == textView.textContainerOrigin.x + textView.textContainer!.lineFragmentPadding)
    #expect(entry.frame.width == entry.layout.size.width)
    #expect(entry.frame.width <= textView.imageContainerWidth)
    let headerTop = header.layoutFragmentFrame.minY + textView.textContainerOrigin.y
    #expect(abs(entry.frame.minY - (headerTop + textLinesBottom + TablePreviewLayout.topMargin)) < 1)
    let after = try #require(fragments.first { fragmentOffset($0, in: textView) == 35 })
    let afterTop = after.layoutFragmentFrame.minY + textView.textContainerOrigin.y
    #expect(abs(afterTop - (entry.frame.maxY + TablePreviewLayout.bottomMargin)) < 1, "body \(afterTop) follows the table \(entry.frame.maxY)")

    // ボディ行の 2 列目をクリック: そのセルの内容の末尾(32)にキャレットが置かれ、ブロックが展開される
    let cell = entry.layout.rows[1].cells[1]
    let clickPoint = CGPoint(x: entry.frame.minX + cell.frame.midX, y: entry.frame.minY + cell.frame.midY)
    #expect(textView.expandTable(atPoint: clickPoint))
    #expect(textView.selectedRange() == NSRange(location: 32, length: 0))
    #expect(controller.collapsedLocations.isEmpty)
    #expect(Set(enumeratedOffsets(textView)).isSuperset(of: [0, 5, 15, 25, 36]))
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    #expect(textView.debugTableEntries.isEmpty)
    // 展開中はヘッダー行が Source と同じ高さと装飾で見える
    let expanded = try #require(layoutFragments(textView).first { fragmentOffset($0, in: textView) == 5 })
    #expect(expanded.textLineFragments.first!.typographicBounds.height > 5)
    #expect(expanded is TableBackgroundFragment)
    // 表の外のクリックは何もしない
    #expect(!textView.expandTable(atPoint: CGPoint(x: 10, y: 280)))

    // キャレットが本文へ戻ると再び折りたたまれる
    textView.setSelectedRange(NSRange(location: 38, length: 0))
    #expect(controller.collapsedLocations == [5])
    #expect(!enumeratedOffsets(textView).contains(15))
    #expect(textView.string == sample, "テキストは終始そのまま")
}

@MainActor @Test func textViewCollapsesTheTableWhenTheEditorLosesFocusEvenWithTheCaretInside() throws {
    let (window, textView) = makeFocusedTextView(sample)
    defer { withExtendedLifetime(window) {} }
    textView.setSelectedRange(NSRange(location: 12, length: 0))
    #expect(textView.tablePreviewController.collapsedLocations.isEmpty)
    #expect(window.makeFirstResponder(nil))
    #expect(textView.tablePreviewController.collapsedLocations == [5])
    #expect(!enumeratedOffsets(textView).contains(15))
    #expect(window.makeFirstResponder(textView))
    #expect(textView.tablePreviewController.collapsedLocations.isEmpty)
}

@MainActor @Test func textViewNeverCollapsesTablesInSourceAndFollowsTheToggle() throws {
    let (window, textView) = makeFocusedTextView(sample, livePreview: false)
    defer { withExtendedLifetime(window) {} }
    textView.setSelectedRange(NSRange(location: 38, length: 0))
    #expect(textView.tablePreviewController.collapsedLocations.isEmpty)
    #expect(enumeratedOffsets(textView).contains(15))
    textView.isLivePreviewEnabled = true
    #expect(textView.tablePreviewController.collapsedLocations == [5])
    #expect(!enumeratedOffsets(textView).contains(15))
    textView.isLivePreviewEnabled = false
    #expect(textView.tablePreviewController.collapsedLocations.isEmpty)
    #expect(enumeratedOffsets(textView).contains(15))
}

@MainActor @Test func textViewFollowsEditsThatChangeOrDestroyTheTable() throws {
    let (window, textView) = makeFocusedTextView(sample)
    defer { withExtendedLifetime(window) {} }
    textView.setSelectedRange(NSRange(location: 38, length: 0))
    let controller = textView.tablePreviewController
    #expect(controller.collapsedLocations == [5])
    // 折りたたみ中に外部更新でセルの内容が変わる(キャレットは本文): 再パース後も折りたたまれ、表の中身が変わる
    textView.textStorage!.replaceCharacters(in: NSRange(location: 27, length: 1), with: "9")
    #expect(controller.collapsedLocations.isEmpty, "expanded until the next parse")
    textView.highlightNow()
    #expect(controller.collapsedLocations == [5])
    #expect(controller.presentedTable(at: 5)?.layout.rows[1].cells[0].text.string == "9")
    // 区切り行を壊す(キャレットをテーブル内に置いてから = 展開中の編集): テーブルが消え、全段落が見える
    textView.setSelectedRange(NSRange(location: 20, length: 0))
    #expect(controller.collapsedLocations.isEmpty)
    textView.textStorage!.replaceCharacters(in: NSRange(location: 15, length: 9), with: "not a row")
    textView.highlightNow()
    #expect(textView.markdownHighlighter.currentPlan.tables.isEmpty)
    textView.setSelectedRange(NSRange(location: 38, length: 0))
    #expect(controller.collapsedLocations.isEmpty)
    #expect(enumeratedOffsets(textView).contains(25))
    // テーブルを書き足す(本文の後ろ): キャレットが外に出たら折りたたまれる
    let length = (textView.string as NSString).length
    textView.textStorage!.replaceCharacters(in: NSRange(location: length, length: 0), with: "\n\n| x |\n|---|\n| y |\n")
    textView.setSelectedRange(NSRange(location: length + 1, length: 0))  // テーブルの前の空行
    textView.highlightNow()
    #expect(controller.collapsedLocations == [length + 2])
}

@MainActor @Test func textViewCollapsesOnlyTheTableTheCaretIsNotIn() throws {
    let (window, textView) = makeFocusedTextView(two)
    defer { withExtendedLifetime(window) {} }
    textView.setSelectedRange(NSRange(location: 39, length: 0))  // テーブル 2 の中
    #expect(textView.tablePreviewController.collapsedLocations == [0])
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    #expect(textView.debugTableEntries.map(\.location) == [0])
    textView.setSelectedRange(NSRange(location: 20, length: 0))
    textView.textLayoutManager!.textViewportLayoutController.layoutViewport()
    #expect(textView.debugTableEntries.map(\.location) == [0, 25])
    // 2 つ目の表の上に 1 つ目の表は無い(座標はテーブルごと)
    let second = try #require(textView.debugTableEntries.last)
    #expect(second.frame.minY > textView.debugTableEntries[0].frame.maxY)
    #expect(textView.expandTable(atPoint: CGPoint(x: second.frame.minX + 5, y: second.frame.minY + 5)))
    #expect(textView.selectedRange() == NSRange(location: 28, length: 0))  // "| b |" の b の末尾
}

@MainActor
private func findTextView(_ view: NSView) -> MarkdownTextView? {
    if let textView = view as? MarkdownTextView { return textView }
    for subview in view.subviews { if let found = findTextView(subview) { return found } }
    return nil
}

@MainActor private final class TextModel: ObservableObject {
    @Published var text = ""
}

private struct Host: View {
    @ObservedObject var model: TextModel
    var body: some View {
        MarkdownEditorView(text: $model.text, theme: .default)
            .showsLineNumbers(true)
            .editorMargins(.readable)
            .livePreviewEnabled(true)
    }
}

/// Laperm と同じ構成(SwiftUI ホスト、読みやすい余白、Live Preview、本文は後から届く)で、表が実際の本文幅で描かれる。
@MainActor @Test func hostedEditorLaysOutTheTableWithTheSettledWidth() throws {
    let model = TextModel()
    model.text = "# Meta\n\n| Name | Description |\n|---|---|\n| alpha | " + String(repeating: "long text ", count: 12) + "|\n| beta | short |\n\nBody after the table.\n"
    let hosting = NSHostingView(rootView: Host(model: model))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hosting
    window.makeFirstResponder(nil)
    hosting.frame = CGRect(x: 0, y: 0, width: 900, height: 450)
    window.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    window.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let textView = try #require(findTextView(hosting))
    let controller = textView.tablePreviewController
    #expect(controller.collapsedLocations == [8])
    #expect(controller.containerWidth == textView.imageContainerWidth)
    let entry = try #require(textView.debugTableEntries.first)
    #expect(entry.frame.width <= textView.imageContainerWidth)
    #expect(entry.frame.width > 200, "table drawn with the settled width, not the initial one: \(entry.frame)")
    #expect(entry.layout.rows.count == 3)
    #expect(entry.layout.size.height < 150, "cells are not wrapped character by character")
    withExtendedLifetime(window) {}
}
#endif
