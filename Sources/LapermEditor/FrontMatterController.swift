#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import LapermCore

/// Live Preview で Front Matter を Property の表に折りたたむ状態機械(ADR 0016)。
///
/// 折りたたみ中は、開きの `---` の段落だけを残して(文字は Live Preview と同じ極小フォントで幅ゼロ・
/// 高さほぼゼロにし、段落の後ろに表の高さを予約する)、残りの段落を列挙から外す(セクション折りたたみと
/// 同じ仕組み。テキストストレージには触らない)。表はオーバーレイが予約領域に描く。
///
/// フォーカスの単位はブロック: エディタが first responder で、選択範囲(キャレット)がブロック
/// (閉じの `---` の行末まで)に触れている間は展開され、Source と同じ見た目で編集できる。Property が
/// 0 件なら折りたたまない(空の表はクリックできず編集へ戻れない)。
@MainActor
final class FrontMatterController {
    /// Live Preview の有効 / 無効(Source では常に展開)。
    private(set) var isEnabled = false
    private(set) var frontMatter: FrontMatter?
    /// ブロックの段落全体(閉じの `---` の改行まで)。折りたたみの切替で作り直す範囲。
    private(set) var blockParagraphsRange = NSRange(location: 0, length: 0)
    private(set) var isEditorFocused = true
    private(set) var selectedRanges: [NSRange] = []
    private(set) var containerWidth: CGFloat = 0
    private(set) var appearance: FrontMatterTableLayout.Appearance
    private(set) var isCollapsed = false
    /// 折りたたみ中の表(幅・テーマ・Front Matter から計算)。展開中は nil。
    private(set) var layout: FrontMatterTableLayout?
    private var pendingDirtyRanges: [NSRange] = []
    /// 表の見た目だけが変わった(高さは同じ)ときに再描画を求めるフラグ。
    private(set) var needsRedraw = false

    init(theme: MarkdownTheme) {
        appearance = .init(theme: theme)
    }

    // MARK: - 入力

    /// パース確定後の同期。`text` は現在の文書。
    func update(frontMatter newValue: FrontMatter?, text: NSString) {
        frontMatter = newValue
        blockParagraphsRange = newValue.map { NSRange(location: 0, length: $0.endIncludingNewline(in: text)) }
            ?? NSRange(location: 0, length: 0)
        recompute()
    }

    func selectionDidChange(_ ranges: [NSRange]) {
        guard ranges != selectedRanges else { return }
        selectedRanges = ranges
        recompute()
    }

    func editorFocusDidChange(_ focused: Bool) {
        guard isEditorFocused != focused else { return }
        isEditorFocused = focused
        recompute()
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        recompute()
    }

    func containerWidthDidChange(_ width: CGFloat) {
        guard width != containerWidth else { return }
        containerWidth = width
        recompute()
    }

    func themeDidChange(_ theme: MarkdownTheme) {
        let newAppearance = FrontMatterTableLayout.Appearance(theme: theme)
        guard newAppearance != appearance else { return }
        appearance = newAppearance
        recompute()
    }

    /// 編集(didProcessEditing)からの座標追従。ブロックに触る編集はキャレットがブロック内にある
    /// (= 展開中)ときしか起きないので状態は変えず、Front Matter の消失は次の `update` で反映する。
    /// ブロックより前の編集は無い(ブロックは文書先頭)。
    func noteEdit(editedRange: NSRange, changeInLength delta: Int) {
        pendingDirtyRanges = pendingDirtyRanges.map { range in
            let preEdit = NSRange(location: editedRange.location, length: max(0, editedRange.length - delta))
            if NSMaxRange(range) <= preEdit.location { return range }
            if range.location >= NSMaxRange(preEdit) { return NSRange(location: range.location + delta, length: range.length) }
            let start = min(range.location, editedRange.location)
            let end = max(NSMaxRange(editedRange), NSMaxRange(range) + delta)
            return NSRange(location: start, length: max(0, end - start))
        }
    }

    // MARK: - 状態

    /// 選択範囲がブロック(閉じの `---` の行末まで)に触れているか。ブロックは文書先頭なので、
    /// 選択の開始位置が閉じの行末以下なら触れている。
    func selectionTouchesBlock(_ frontMatter: FrontMatter) -> Bool {
        selectedRanges.contains { $0.location != NSNotFound && $0.location <= NSMaxRange(frontMatter.range) }
    }

    private func recompute() {
        let wasCollapsed = isCollapsed
        let oldHeight = layout?.reservedHeight
        let oldLayout = layout
        if isEnabled, let frontMatter, !frontMatter.properties.isEmpty,
           !(isEditorFocused && selectionTouchesBlock(frontMatter)) {
            isCollapsed = true
            layout = FrontMatterTableLayout.make(frontMatter: frontMatter, width: containerWidth, appearance: appearance)
        } else {
            isCollapsed = false
            layout = nil
        }
        if wasCollapsed != isCollapsed {
            // 折りたたみの切替: ブロックの段落全体を作り直す(列挙の除外と開きの段落の表示用段落)
            if blockParagraphsRange.length > 0 { pendingDirtyRanges.append(blockParagraphsRange) }
        } else if isCollapsed, let layout, layout.reservedHeight != oldHeight, let frontMatter {
            // 幅やテーマで表の高さだけが変わった: 開きの段落(予約高さ)だけ作り直す
            pendingDirtyRanges.append(NSRange(location: 0, length: NSMaxRange(frontMatter.openingFenceRange)))
        } else if isCollapsed, layout != oldLayout {
            needsRedraw = true
        }
    }

    var hasPendingDirtyRanges: Bool { !pendingDirtyRanges.isEmpty }

    func takePendingDirtyRanges() -> [NSRange] {
        defer { pendingDirtyRanges = [] }
        return pendingDirtyRanges
    }

    func takeNeedsRedraw() -> Bool {
        defer { needsRedraw = false }
        return needsRedraw
    }

    // MARK: - TextKit への供給

    /// 折りたたみ中、開きの `---` の段落以外のブロックの段落は列挙から外す(= レイアウトされず見えない)。
    func shouldEnumerate(paragraphStartingAt offset: Int) -> Bool {
        guard isCollapsed, let frontMatter else { return true }
        return !(offset > frontMatter.range.location && offset <= frontMatter.closingFenceRange.location)
    }

    /// 折りたたみ中の開きの `---` の段落に予約する表の高さ。該当しなければ nil。
    func reservedHeight(forParagraph paragraph: NSRange) -> CGFloat? {
        guard isCollapsed, let frontMatter, let layout,
              paragraph.location == frontMatter.range.location else { return nil }
        return layout.reservedHeight
    }

    /// 折りたたみ中の開きの `---` の段落の表示用段落: 全文字を極小フォントで隠し(行の高さもほぼ 0)、
    /// 段落の後ろに表の高さを予約する。それ以外の段落は nil(他の仕組みに任せる)。
    func textParagraph(with range: NSRange, in contentStorage: NSTextContentStorage) -> NSTextParagraph? {
        guard let height = reservedHeight(forParagraph: range), range.length > 0,
              let storage = contentStorage.textStorage, NSMaxRange(range) <= storage.length else { return nil }
        let text = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        let full = NSRange(location: 0, length: text.length)
        text.addAttribute(.font, value: LivePreviewConcealer.hiddenFont, range: full)
        let style = (text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.paragraphSpacing = height
        style.paragraphSpacingBefore = 0
        style.lineSpacing = 0
        style.maximumLineHeight = LivePreviewConcealer.hiddenFontSize
        text.addAttribute(.paragraphStyle, value: style, range: full)
        return NSTextParagraph(attributedString: text)
    }

    /// 表座標の点に対応する Property の行(文書座標)。表の外なら nil。
    func lineRange(atTablePoint point: CGPoint) -> NSRange? {
        layout?.row(at: point)?.lineRange
    }
}
