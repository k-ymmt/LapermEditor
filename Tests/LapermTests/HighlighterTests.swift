import AppKit
import Testing
@testable import Laperm
@testable import LapermCore

/// ビューなしで TextKit2 スタックを組むテストヘルパー
@MainActor
private func makeTextKitStack(_ text: String) -> (NSTextContentStorage, NSTextLayoutManager) {
    let contentStorage = NSTextContentStorage()
    let layoutManager = NSTextLayoutManager()
    contentStorage.addTextLayoutManager(layoutManager)
    let container = NSTextContainer(size: CGSize(width: 400, height: 0))
    layoutManager.textContainer = container
    contentStorage.textStorage?.replaceCharacters(
        in: NSRange(location: 0, length: 0), with: text)
    return (contentStorage, layoutManager)
}

@MainActor
private func renderingColor(at offset: Int, _ layoutManager: NSTextLayoutManager) -> NSColor? {
    guard let contentManager = layoutManager.textContentManager,
          let location = contentManager.location(contentManager.documentRange.location, offsetBy: offset)
    else { return nil }
    var color: NSColor?
    layoutManager.enumerateRenderingAttributes(from: location, reverse: false) { _, attributes, _ in
        color = attributes[.foregroundColor] as? NSColor
        return false  // 最初の run だけ見る
    }
    return color
}

@MainActor @Test func rehighlightAllAppliesHeadingFont() {
    let (contentStorage, layoutManager) = makeTextKitStack("# Title")
    let highlighter = Highlighter(theme: .default)
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)

    let font = contentStorage.textStorage!.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
    #expect(font == MarkdownTheme.default.style(for: .heading(level: 1))?.font)
    // 色は renderingAttributes 側のみ — textStorage には .foregroundColor を書かない(2 層分離の裏面)
    #expect(contentStorage.textStorage!.attribute(.foregroundColor, at: 3, effectiveRange: nil) == nil)
}

@MainActor @Test func rehighlightAllAppliesMarkerRenderingColor() {
    let (contentStorage, layoutManager) = makeTextKitStack("# Title")
    let highlighter = Highlighter(theme: .default)
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)

    // 位置 0 は "# " マーカー → syntaxMarker 色
    #expect(renderingColor(at: 0, layoutManager) == MarkdownTheme.default.renderingColor(for: .syntaxMarker))
}

@MainActor @Test func editUpdatesHighlightDifferentially() {
    let (contentStorage, layoutManager) = makeTextKitStack("plain text")
    let highlighter = Highlighter(theme: .default)
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)

    // 先頭に "# " を挿入して見出し化
    contentStorage.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
    highlighter.noteEdit(editedRange: NSRange(location: 0, length: 2), changeInLength: 2)
    highlighter.flushPendingHighlight(contentStorage: contentStorage, layoutManager: layoutManager)

    let font = contentStorage.textStorage!.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
    #expect(font == MarkdownTheme.default.style(for: .heading(level: 1))?.font)
}

@MainActor @Test func batchedEditsBeforeSingleFlushHighlightCorrectly() {
    let (contentStorage, layoutManager) = makeTextKitStack("plain text here")
    let highlighter = Highlighter(theme: .default)
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)

    let storage = contentStorage.textStorage!
    // 編集 1: 末尾に "**bold**" を追加
    storage.replaceCharacters(in: NSRange(location: 15, length: 0), with: " **bold**")
    highlighter.noteEdit(editedRange: NSRange(location: 15, length: 9), changeInLength: 9)
    // 編集 2: 先頭 6 文字 "plain " を削除(前方の削除で後続レンジがシフト)
    storage.replaceCharacters(in: NSRange(location: 0, length: 6), with: "")
    highlighter.noteEdit(editedRange: NSRange(location: 0, length: 0), changeInLength: -6)

    highlighter.flushPendingHighlight(contentStorage: contentStorage, layoutManager: layoutManager)
    // "text here **bold**" → strong は {10,8}。太字フォントが付いていること
    let font = storage.attribute(.font, at: 12, effectiveRange: nil) as? NSFont
    #expect(font == MarkdownTheme.default.style(for: .strong)?.font)
}

@MainActor @Test func deletionAtDocumentEndDoesNotTrap() {
    let (contentStorage, layoutManager) = makeTextKitStack("abc **bold**")
    let highlighter = Highlighter(theme: .default)
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)

    let storage = contentStorage.textStorage!
    // 末尾 8 文字("**bold**")を削除 — 旧スパンのレンジが新文書長を超えないこと(assert 非発火)
    storage.replaceCharacters(in: NSRange(location: 4, length: 8), with: "")
    highlighter.noteEdit(editedRange: NSRange(location: 4, length: 0), changeInLength: -8)
    highlighter.flushPendingHighlight(contentStorage: contentStorage, layoutManager: layoutManager)
    #expect(storage.string == "abc ")
}

@MainActor @Test func flushWithoutEditsDoesNothing() {
    let (contentStorage, layoutManager) = makeTextKitStack("# Title")
    let highlighter = Highlighter(theme: .default)
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)
    let planBefore = highlighter.currentPlan
    highlighter.flushPendingHighlight(contentStorage: contentStorage, layoutManager: layoutManager)
    #expect(highlighter.currentPlan == planBefore)
}

@MainActor @Test func backgroundFlushAppliesHighlightAsynchronously() async {
    let (contentStorage, layoutManager) = makeTextKitStack("plain")
    let highlighter = Highlighter(theme: .default)
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)
    highlighter.backgroundParseThreshold = .zero  // 常にバックグラウンド経路

    let storage = contentStorage.textStorage!
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
    highlighter.noteEdit(editedRange: NSRange(location: 0, length: 2), changeInLength: 2)
    highlighter.flushPendingHighlight(contentStorage: contentStorage, layoutManager: layoutManager)

    // 同期経路では適用されない(タスクが進行中)
    #expect(highlighter.activeBackgroundParse != nil)
    await highlighter.activeBackgroundParse?.value

    let font = storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
    #expect(font == MarkdownTheme.default.style(for: .heading(level: 1))?.font)
}

@MainActor @Test func editDuringBackgroundParseTriggersReflush() async {
    let (contentStorage, layoutManager) = makeTextKitStack("plain")
    let highlighter = Highlighter(theme: .default)
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)
    highlighter.backgroundParseThreshold = .zero

    let storage = contentStorage.textStorage!
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
    highlighter.noteEdit(editedRange: NSRange(location: 0, length: 2), changeInLength: 2)
    highlighter.flushPendingHighlight(contentStorage: contentStorage, layoutManager: layoutManager)

    // パース中に追加編集(世代が進む → 最初の結果は破棄され再フラッシュ)
    storage.replaceCharacters(in: NSRange(location: 7, length: 0), with: "!")
    highlighter.noteEdit(editedRange: NSRange(location: 7, length: 1), changeInLength: 1)

    while let task = highlighter.activeBackgroundParse {
        await task.value
    }
    #expect(highlighter.currentPlan == MarkdownParser().highlightPlan(for: storage.string))
}

@MainActor @Test func rehighlightAllInvalidatesInFlightBackgroundParse() async {
    let (contentStorage, layoutManager) = makeTextKitStack("plain")
    let highlighter = Highlighter(theme: .default)
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)
    highlighter.backgroundParseThreshold = .zero

    let storage = contentStorage.textStorage!
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
    highlighter.noteEdit(editedRange: NSRange(location: 0, length: 2), changeInLength: 2)
    highlighter.flushPendingHighlight(contentStorage: contentStorage, layoutManager: layoutManager)
    #expect(highlighter.activeBackgroundParse != nil)

    // パース進行中に全文置換 + rehighlightAll(テーマ変更相当)
    storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "**changed**")
    // 全文置換も文字編集なので noteEdit 経路が世代を進めるが、このテストでは
    // rehighlightAll 単独でも無効化されることを検証したいので直接呼ぶ
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)

    while let task = highlighter.activeBackgroundParse { await task.value }
    // 古い "# plain" の計画が適用されていないこと: currentPlan は新テキストの計画のまま
    #expect(highlighter.currentPlan == MarkdownParser().highlightPlan(for: storage.string))
    let font = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
    #expect(font == MarkdownTheme.default.style(for: .strong)?.font)
}

@MainActor @Test func backgroundApplyIsDeferredWhileGuardActive() async {
    let (contentStorage, layoutManager) = makeTextKitStack("plain")
    let highlighter = Highlighter(theme: .default)
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)
    highlighter.backgroundParseThreshold = .zero
    var deferApply = true
    var deferredCallbacks = 0
    highlighter.shouldDeferApply = { deferApply }
    highlighter.applyDeferred = { deferredCallbacks += 1 }

    let storage = contentStorage.textStorage!
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
    highlighter.noteEdit(editedRange: NSRange(location: 0, length: 2), changeInLength: 2)
    highlighter.flushPendingHighlight(contentStorage: contentStorage, layoutManager: layoutManager)
    while let task = highlighter.activeBackgroundParse { await task.value }

    // ガード中は適用されず、再スケジュールが要求される
    #expect(deferredCallbacks == 1)
    let fontDuringGuard = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    #expect(fontDuringGuard == MarkdownTheme.default.bodyFont)

    // ガード解除後のフラッシュで適用される
    deferApply = false
    highlighter.flushPendingHighlight(contentStorage: contentStorage, layoutManager: layoutManager)
    while let task = highlighter.activeBackgroundParse { await task.value }
    let font = storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
    #expect(font == MarkdownTheme.default.style(for: .heading(level: 1))?.font)
}

@MainActor @Test func typeThenBackspaceBeforeFlushKeepsRangesConsistent() {
    let (contentStorage, layoutManager) = makeTextKitStack("hello world")
    let highlighter = Highlighter(theme: .default)
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)
    let storage = contentStorage.textStorage!
    // "**" を挿入してから 1 文字バックスペース(交差分岐を通す)
    storage.replaceCharacters(in: NSRange(location: 5, length: 0), with: " **b**")
    highlighter.noteEdit(editedRange: NSRange(location: 5, length: 7), changeInLength: 7)
    storage.replaceCharacters(in: NSRange(location: 11, length: 1), with: "")
    highlighter.noteEdit(editedRange: NSRange(location: 11, length: 0), changeInLength: -1)
    highlighter.flushPendingHighlight(contentStorage: contentStorage, layoutManager: layoutManager)
    // クラッシュ・assert なく、最終テキストの正しい計画が適用されている
    #expect(highlighter.currentPlan == MarkdownParser().highlightPlan(for: storage.string))
}

@MainActor @Test func rehighlightAllAppliesStrikethroughStorageAttribute() {
    let (contentStorage, layoutManager) = makeTextKitStack("a ~~del~~ b")
    let highlighter = Highlighter(theme: .default)
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)
    // 位置 4 は "del" の内部。TextKit2 の renderingAttributes は .strikethroughStyle を
    // 描画しないため、textStorage 側に付いていること(実機検証で確認済みの制約)
    let style = contentStorage.textStorage!
        .attribute(.strikethroughStyle, at: 4, effectiveRange: nil) as? Int
    #expect(style == NSUnderlineStyle.single.rawValue)
}

@MainActor @Test func removingStrikethroughClearsStorageAttribute() {
    let (contentStorage, layoutManager) = makeTextKitStack("~~del~~")
    let highlighter = Highlighter(theme: .default)
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)
    // 開きチルダ 2 個を "xx" に置換して打ち消し線を解除
    contentStorage.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 2), with: "xx")
    highlighter.noteEdit(editedRange: NSRange(location: 0, length: 2), changeInLength: 0)
    highlighter.flushPendingHighlight(contentStorage: contentStorage, layoutManager: layoutManager)
    // "xxdel~~" の 'e'(位置 3)に打ち消し線が残っていないこと
    #expect(contentStorage.textStorage!
        .attribute(.strikethroughStyle, at: 3, effectiveRange: nil) == nil)
}

@MainActor @Test func onBackgroundFlushAppliedFiresAfterAsyncApplyOnGenerationMatch() async {
    let (contentStorage, layoutManager) = makeTextKitStack("plain")
    let highlighter = Highlighter(theme: .default)
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)
    highlighter.backgroundParseThreshold = .zero  // 常にバックグラウンド経路

    var fired = 0
    highlighter.onBackgroundFlushApplied = { fired += 1 }

    let storage = contentStorage.textStorage!
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
    highlighter.noteEdit(editedRange: NSRange(location: 0, length: 2), changeInLength: 2)
    highlighter.flushPendingHighlight(contentStorage: contentStorage, layoutManager: layoutManager)

    // 非同期タスクが完了するまではまだ呼ばれない
    #expect(fired == 0)
    await highlighter.activeBackgroundParse?.value
    // 世代一致で applyFlush が走った直後に 1 回だけ呼ばれる
    #expect(fired == 1)
    let font = storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
    #expect(font == MarkdownTheme.default.style(for: .heading(level: 1))?.font)
}

@MainActor @Test func onBackgroundFlushAppliedDoesNotFireOnStaleDiscard() async {
    let (contentStorage, layoutManager) = makeTextKitStack("plain")
    let highlighter = Highlighter(theme: .default)
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)
    highlighter.backgroundParseThreshold = .zero

    var fired = 0
    highlighter.onBackgroundFlushApplied = { fired += 1 }

    let storage = contentStorage.textStorage!
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
    highlighter.noteEdit(editedRange: NSRange(location: 0, length: 2), changeInLength: 2)
    highlighter.flushPendingHighlight(contentStorage: contentStorage, layoutManager: layoutManager)

    // パース中に追加編集(世代が進む → 最初の結果は破棄され再フラッシュされる)
    storage.replaceCharacters(in: NSRange(location: 7, length: 0), with: "!")
    highlighter.noteEdit(editedRange: NSRange(location: 7, length: 1), changeInLength: 1)

    while let task = highlighter.activeBackgroundParse {
        await task.value
    }
    // 破棄経路では applyFlush 自体が呼ばれないので、フックも発火しない。
    // 再フラッシュされた 2 回目(世代一致)の完了で 1 回だけ発火する。
    #expect(fired == 1)
}

@MainActor @Test func onBackgroundFlushAppliedDoesNotFireOnSynchronousPath() {
    let (contentStorage, layoutManager) = makeTextKitStack("plain")
    let highlighter = Highlighter(theme: .default)  // 閾値はデフォルト 16ms → 同期経路
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)

    var fired = 0
    highlighter.onBackgroundFlushApplied = { fired += 1 }

    let storage = contentStorage.textStorage!
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
    highlighter.noteEdit(editedRange: NSRange(location: 0, length: 2), changeInLength: 2)
    highlighter.flushPendingHighlight(contentStorage: contentStorage, layoutManager: layoutManager)

    #expect(highlighter.activeBackgroundParse == nil)
    #expect(fired == 0)
}

@MainActor @Test func fastDocumentsStaySynchronous() {
    let (contentStorage, layoutManager) = makeTextKitStack("plain")
    let highlighter = Highlighter(theme: .default)  // 閾値はデフォルト 16ms
    highlighter.rehighlightAll(contentStorage: contentStorage, layoutManager: layoutManager)

    let storage = contentStorage.textStorage!
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
    highlighter.noteEdit(editedRange: NSRange(location: 0, length: 2), changeInLength: 2)
    highlighter.flushPendingHighlight(contentStorage: contentStorage, layoutManager: layoutManager)

    // 小さい文書は同期適用(バックグラウンドタスクなし)
    #expect(highlighter.activeBackgroundParse == nil)
    let font = storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
    #expect(font == MarkdownTheme.default.style(for: .heading(level: 1))?.font)
}
