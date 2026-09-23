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
///
/// 入力(有効 / 無効、Front Matter、選択、フォーカス、幅、テーマ)から「望む表示」を計算し、TextKit に見せる
/// 「現在の表示」(`isCollapsed` / `layout` / 列挙の除外)へは `canPresent()` が true のときだけ移す。エンジンは
/// IME 変換中に false を返し(段落の作り直しが変換セッションを乱すため)、確定後の flush で改めて移す。
/// 望む表示と現在の表示がずれている間、列挙・予約高さ・表示用段落はすべて現在の表示に従う(半適用にならない)。
@MainActor
final class FrontMatterController {
    /// TextKit に見せている表示。
    struct Presentation: Equatable {
        var isCollapsed = false
        var frontMatter: FrontMatter?
        var layout: FrontMatterTableLayout?
        /// ブロックの段落全体(閉じの `---` の改行まで)。切替時に作り直す範囲。編集で追従させる。
        var blockParagraphsRange = NSRange(location: 0, length: 0)
    }

    // MARK: 入力

    /// Live Preview の有効 / 無効(Source では常に展開)。
    private(set) var isEnabled = false
    private(set) var frontMatter: FrontMatter?
    /// ブロックの段落全体(閉じの `---` の改行まで)。
    private(set) var blockParagraphsRange = NSRange(location: 0, length: 0)
    /// 直近の `update` 時の文書の長さ(文末の空行がブロックの段落に属するかの判定に使う)。編集で追従させる。
    private(set) var documentLength = 0
    /// 直近の `update` の後、ブロック(とその直後)に触る編集があった。モデル(Property の位置、ブロックの終端)
    /// は次のパースまで信用できないので、その間は折りたたまず、表のクリックも受け付けない。
    private(set) var isModelStale = false
    private(set) var isEditorFocused = true
    private(set) var selectedRanges: [NSRange] = []
    private(set) var containerWidth: CGFloat = 0
    private(set) var appearance: FrontMatterTableLayout.Appearance
    /// 今 TextKit の表示を変えてよいか(IME 変換中は false)。既定は常に true。
    var canPresent: () -> Bool = { true }

    // MARK: 表示

    private(set) var presented = Presentation()
    var isCollapsed: Bool { presented.isCollapsed }
    /// 折りたたみ中の表(幅・テーマ・Front Matter から計算)。展開中は nil。
    var layout: FrontMatterTableLayout? { presented.layout }
    /// `layout` を作ったときの入力。同じなら文字の計測をやり直さない(キャレット移動のたびに呼ばれる)。
    private var layoutCache: (frontMatter: FrontMatter, width: CGFloat, appearance: FrontMatterTableLayout.Appearance, layout: FrontMatterTableLayout)?
    private var pendingDirtyRanges: [NSRange] = []
    /// 表の見た目だけが変わった(高さは同じ)ときに再描画を求めるフラグ。
    private var needsRedraw = false

    init(theme: MarkdownTheme) {
        appearance = .init(theme: theme)
    }

    // MARK: - 入力の更新

    /// パース確定後の同期。`text` は現在の文書。
    func update(frontMatter newValue: FrontMatter?, text: NSString) {
        frontMatter = newValue
        blockParagraphsRange = newValue.map { NSRange(location: 0, length: $0.endIncludingNewline(in: text)) }
            ?? NSRange(location: 0, length: 0)
        documentLength = text.length
        isModelStale = false
        present()
    }

    func selectionDidChange(_ ranges: [NSRange]) {
        guard ranges != selectedRanges else { return }
        selectedRanges = ranges
        present()
    }

    func editorFocusDidChange(_ focused: Bool) {
        guard isEditorFocused != focused else { return }
        isEditorFocused = focused
        present()
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        present()
    }

    func containerWidthDidChange(_ width: CGFloat) {
        guard width != containerWidth else { return }
        containerWidth = width
        present()
    }

    func themeDidChange(_ theme: MarkdownTheme) {
        let newAppearance = FrontMatterTableLayout.Appearance(theme: theme)
        guard newAppearance != appearance else { return }
        appearance = newAppearance
        present()
    }

    /// 編集(didProcessEditing)からの座標追従。ブロック(閉じの改行の直後まで)に触る編集はモデルを失効させ、
    /// 次の `update` まで展開する。ブロックより後の編集は文書の長さだけ追従する(ブロックは文書先頭なので
    /// 平行移動は無い)。現在の表示のブロック範囲と保留中の作り直し範囲は編集レンジと合併して追従する。
    func noteEdit(editedRange: NSRange, changeInLength delta: Int) {
        let preEdit = NSRange(location: editedRange.location, length: max(0, editedRange.length - delta))
        documentLength = max(0, documentLength + delta)
        pendingDirtyRanges = pendingDirtyRanges.map { Self.shiftMerging($0, editedRange: editedRange, preEdit: preEdit, delta: delta) }
        if presented.blockParagraphsRange.length > 0 {
            presented.blockParagraphsRange = Self.shiftMerging(
                presented.blockParagraphsRange, editedRange: editedRange, preEdit: preEdit, delta: delta)
        }
        if frontMatter != nil, preEdit.location <= NSMaxRange(blockParagraphsRange) {
            isModelStale = true
            present()
        }
    }

    private static func shiftMerging(_ range: NSRange, editedRange: NSRange, preEdit: NSRange, delta: Int) -> NSRange {
        if NSMaxRange(range) <= preEdit.location { return range }
        if range.location >= NSMaxRange(preEdit) {
            return NSRange(location: range.location + delta, length: range.length)
        }
        let start = min(range.location, editedRange.location)
        let end = max(NSMaxRange(editedRange), NSMaxRange(range) + delta)
        return NSRange(location: start, length: max(0, end - start))
    }

    // MARK: - 望む表示

    /// 選択範囲がブロック(閉じの `---` の行末まで)に触れているか。ブロックは文書先頭なので、
    /// 選択の開始位置が閉じの行末以下なら触れている。文書が閉じの `---` の改行で終わるとき、その後ろ
    /// (文末の空行)のキャレットは閉じの段落のフラグメントに描かれる(TextKit 2 の追加行)ので、隠すと
    /// キャレットが消える。この位置も触れているものとして扱う。
    func selectionTouchesBlock(_ frontMatter: FrontMatter) -> Bool {
        let blockEnd = NSMaxRange(frontMatter.range)
        let trailingEmptyLine = NSMaxRange(blockParagraphsRange) > blockEnd && NSMaxRange(blockParagraphsRange) == documentLength
            ? documentLength : nil
        return selectedRanges.contains {
            $0.location != NSNotFound && ($0.location <= blockEnd || $0.location == trailingEmptyLine)
        }
    }

    /// 入力から計算した、望む表示。
    private func desiredPresentation() -> Presentation {
        guard isEnabled, !isModelStale, let frontMatter, !frontMatter.properties.isEmpty,
              !(isEditorFocused && selectionTouchesBlock(frontMatter))
        else { return Presentation() }
        return Presentation(
            isCollapsed: true, frontMatter: frontMatter, layout: cachedLayout(for: frontMatter),
            blockParagraphsRange: blockParagraphsRange)
    }

    private func cachedLayout(for frontMatter: FrontMatter) -> FrontMatterTableLayout {
        if let cache = layoutCache, cache.frontMatter == frontMatter, cache.width == containerWidth, cache.appearance == appearance {
            return cache.layout
        }
        let layout = FrontMatterTableLayout.make(frontMatter: frontMatter, width: containerWidth, appearance: appearance)
        layoutCache = (frontMatter, containerWidth, appearance, layout)
        return layout
    }

    /// 望む表示と現在の表示がずれているか(`canPresent` が false で移せていない)。
    var hasPendingPresentation: Bool { desiredPresentation() != presented }

    /// 望む表示を TextKit に見せる表示へ移す(`canPresent()` が true のとき)。変わった分の作り直し範囲を溜める。
    @discardableResult
    func present() -> Bool {
        let desired = desiredPresentation()
        guard desired != presented, canPresent() else { return false }
        let old = presented
        presented = desired
        if old.isCollapsed != desired.isCollapsed {
            // 折りたたみの切替: 旧・新のブロックの段落全体を作り直す(列挙の除外と開きの段落の表示用段落)。
            // Front Matter が消えた(update(nil))ときは旧範囲だけが残るので、それを必ず載せる。
            appendDirty(old.blockParagraphsRange)
            appendDirty(desired.blockParagraphsRange)
        } else if desired.isCollapsed {
            if old.blockParagraphsRange != desired.blockParagraphsRange
                || old.layout?.reservedHeight != desired.layout?.reservedHeight
                || old.frontMatter?.closingFenceRange != desired.frontMatter?.closingFenceRange {
                // ブロックの範囲や表の高さが変わった: 旧・新の範囲を作り直す
                appendDirty(old.blockParagraphsRange)
                appendDirty(desired.blockParagraphsRange)
            } else if old.layout != desired.layout {
                needsRedraw = true
            }
        }
        return true
    }

    private func appendDirty(_ range: NSRange) {
        guard range.length > 0, pendingDirtyRanges.last != range else { return }
        pendingDirtyRanges.append(range)
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

    // MARK: - TextKit への供給(現在の表示に従う)

    /// 折りたたみ中、開きの `---` の段落以外のブロックの段落は列挙から外す(= レイアウトされず見えない)。
    func shouldEnumerate(paragraphStartingAt offset: Int) -> Bool {
        guard presented.isCollapsed, let frontMatter = presented.frontMatter else { return true }
        return !(offset > frontMatter.range.location && offset <= frontMatter.closingFenceRange.location)
    }

    /// 折りたたみ中の開きの `---` の段落に予約する表の高さ。該当しなければ nil。
    func reservedHeight(forParagraph paragraph: NSRange) -> CGFloat? {
        guard presented.isCollapsed, let frontMatter = presented.frontMatter, let layout = presented.layout,
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

    /// 表座標の点に対応する Property の行(文書座標)。表の外、またはモデルが失効中(次のパース待ち)なら nil。
    func lineRange(atTablePoint point: CGPoint) -> NSRange? {
        guard !isModelStale else { return nil }
        return presented.layout?.row(at: point)?.lineRange
    }
}
