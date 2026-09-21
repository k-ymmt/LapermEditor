#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import LapermCore

/// Live Preview: フォーカスの無い段落(TextKit の段落 = 改行で区切られた 1 行)の Syntax Marker を、
/// 描画時に幅ゼロで隠す。テキストストレージ・パース結果・保存内容には一切触れず、
/// `NSTextContentStorageDelegate.textContentStorage(_:textParagraphWith:)` が返す表示用の段落で、
/// マーカーの文字にだけ極小フォントを付けて幅を潰す(コードブロックの上下余白と同じ仕組み)。
///
/// フォーカスの有無はキャレット位置(選択範囲が触れる段落)だけで決め、first responder には依存しない。
/// 状態の変化で再生成が要る段落は `pendingDirtyRanges` に溜め、`MarkdownEditorEngine` が
/// 段落を作り直させる(`regenerateParagraphs`)。
@MainActor
final class LivePreviewConcealer {
    /// 隠すマーカーに付ける表示用フォント。TextKit 2 は `.expansion` を無視するので、
    /// 極小サイズのフォントで字送りをほぼ 0 にする(高さも 0 に近づくが、行の高さは他の文字が決める)。
    static let hiddenFont = PlatformFont.systemFont(ofSize: 0.01)

    var isEnabled = false

    /// 隠せるマーカー(開始位置で昇順、互いに交差しない)
    private(set) var markers: [NSRange] = []
    /// フォーカスのある段落のレンジ(文書座標、改行を含む)。キャレットだけなら 1 つ、選択範囲は
    /// 触れる段落をまとめて 1 レンジ、複数選択(macOS)は複数。
    private(set) var focusedParagraphs: [NSRange] = []
    /// 状態の変化で再生成が必要になった段落(文書座標)。`takePendingDirtyRanges` で取り出す。
    private var pendingDirtyRanges: [NSRange] = []

    // MARK: - 状態の更新

    /// パース確定後の同期。マーカーの増減があった段落を無効化対象に載せる。
    func update(markers newMarkers: [NSRange]) {
        let sorted = newMarkers.sorted { $0.location < $1.location }
        guard sorted != markers else { return }
        if isEnabled {
            let oldSet = Set(markers)
            let newSet = Set(sorted)
            pendingDirtyRanges += markers.filter { !newSet.contains($0) }
            pendingDirtyRanges += sorted.filter { !oldSet.contains($0) }
        }
        markers = sorted
    }

    /// 選択範囲の変化。フォーカスのある段落が変わったら、古い段落と新しい段落のうち
    /// マーカーを含むものを無効化対象に載せる。`text` は現在の文書。
    func selectionDidChange(_ selectedRanges: [NSRange], text: NSString) {
        let focused = Self.focusedParagraphs(for: selectedRanges, text: text)
        guard focused != focusedParagraphs else { return }
        let previous = focusedParagraphs
        focusedParagraphs = focused
        guard isEnabled else { return }
        for range in previous where !focused.contains(range) && containsMarker(in: range) {
            pendingDirtyRanges.append(range)
        }
        for range in focused where !previous.contains(range) && containsMarker(in: range) {
            pendingDirtyRanges.append(range)
        }
    }

    /// 有効 / 無効の切替。マーカーのある文書では全段落の再生成が要る(呼び出し側が文書全体を無効化する)。
    /// 切り替わったら true。
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard isEnabled != enabled else { return false }
        isEnabled = enabled
        return true
    }

    var hasPendingDirtyRanges: Bool { !pendingDirtyRanges.isEmpty }

    /// 溜まった無効化レンジを取り出してクリアする(呼び出し側が段落を再生成させる)。
    func takePendingDirtyRanges() -> [NSRange] {
        defer { pendingDirtyRanges = [] }
        return pendingDirtyRanges
    }

    /// didProcessEditing(.editedCharacters)からの座標追従(HighlightPlan.shifted と同じ規約)。
    /// 編集と交差するマーカーは落とす(次の update で再生成される)。フォーカス段落と保留レンジは
    /// 交差したら編集レンジと合併して拡張する。
    func noteEdit(editedRange: NSRange, changeInLength delta: Int) {
        let preEdit = NSRange(location: editedRange.location, length: max(0, editedRange.length - delta))
        if !markers.isEmpty {
            markers = markers.compactMap { marker in
                if NSMaxRange(marker) <= preEdit.location { return marker }
                if marker.location >= NSMaxRange(preEdit) {
                    return NSRange(location: marker.location + delta, length: marker.length)
                }
                return nil
            }
        }
        focusedParagraphs = focusedParagraphs.map { Self.shiftMerging($0, editedRange: editedRange, preEdit: preEdit, delta: delta) }
        pendingDirtyRanges = pendingDirtyRanges.map { Self.shiftMerging($0, editedRange: editedRange, preEdit: preEdit, delta: delta) }
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

    // MARK: - 判定

    /// 選択範囲が触れる段落(改行を含む)。文書末尾の改行の後(空の追加行)にあるキャレットは
    /// どの段落にも触れない(空レンジ)。文書外を指す選択は無視する。
    static func focusedParagraphs(for selectedRanges: [NSRange], text: NSString) -> [NSRange] {
        var result: [NSRange] = []
        for range in selectedRanges where range.location != NSNotFound && NSMaxRange(range) <= text.length {
            let paragraphs = text.paragraphRange(for: range)
            if !result.contains(paragraphs) { result.append(paragraphs) }
        }
        return result
    }

    /// 段落にフォーカスがあるか。段落と交差する選択、または段落内(空レンジなら先頭を含む)のキャレット。
    func isFocused(paragraph: NSRange) -> Bool {
        focusedParagraphs.contains { focused in
            if focused.length == 0 { return NSLocationInRange(focused.location, paragraph) }
            return NSIntersectionRange(focused, paragraph).length > 0
        }
    }

    /// range と交差するマーカー(昇順)。二分探索で先頭候補を絞る。
    func markers(intersecting range: NSRange) -> ArraySlice<NSRange> {
        guard !markers.isEmpty else { return [] }
        var low = 0
        var high = markers.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(markers[mid]) <= range.location { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < markers.count, markers[end].location < NSMaxRange(range) { end += 1 }
        return markers[low..<end]
    }

    func containsMarker(in range: NSRange) -> Bool {
        !markers(intersecting: range).isEmpty
    }

    // MARK: - 表示用段落

    /// 段落 `range` の表示用段落。`base` は他の仕組み(コードブロックの余白)が作った表示用段落
    /// (無ければ storage から作る)。隠すものが無ければ `base` をそのまま返す。
    func textParagraph(with range: NSRange, base: NSTextParagraph?, in contentStorage: NSTextContentStorage) -> NSTextParagraph? {
        guard isEnabled, range.length > 0, !isFocused(paragraph: range),
              let storage = contentStorage.textStorage, NSMaxRange(range) <= storage.length
        else { return base }
        let hidden = markers(intersecting: range)
        guard !hidden.isEmpty else { return base }
        let text = NSMutableAttributedString(
            attributedString: base?.attributedString ?? storage.attributedSubstring(from: range))
        guard text.length == range.length else { return base }
        var hiddenLength = 0
        for marker in hidden {
            let clipped = NSIntersectionRange(marker, range)
            guard clipped.length > 0 else { continue }
            text.addAttribute(
                .font, value: Self.hiddenFont,
                range: NSRange(location: clipped.location - range.location, length: clipped.length))
            hiddenLength += clipped.length
        }
        // 見える文字が全部マーカーの段落(">" だけの引用行など)は、TextKit 2 が改行のフォントを
        // 行の高さに使わず 0 に潰れるので、元のフォントの行の高さを最低値として付ける。
        if hiddenLength >= Self.visibleLength(of: text.string as NSString) {
            let style = (text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.minimumLineHeight = Self.lineHeight(of: base?.attributedString ?? storage.attributedSubstring(from: range))
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        }
        return NSTextParagraph(attributedString: text)
    }

    /// 段落の改行を除いた長さ。
    static func visibleLength(of paragraph: NSString) -> Int {
        var contentsEnd = 0
        paragraph.getParagraphStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: 0, length: 0))
        return contentsEnd
    }

    /// 段落に付いているフォントのうち最も高い行の高さ(隠す前の自然な高さの近似)。
    static func lineHeight(of paragraph: NSAttributedString) -> CGFloat {
        var height: CGFloat = 0
        paragraph.enumerateAttribute(.font, in: NSRange(location: 0, length: paragraph.length)) { value, _, _ in
            guard let font = value as? PlatformFont else { return }
            height = max(height, (font.ascender - font.descender + font.leading).rounded(.up))
        }
        return height
    }
}
