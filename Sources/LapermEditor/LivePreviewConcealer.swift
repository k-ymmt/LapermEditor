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
/// フォーカスのある段落 = エディタがフォーカス(first responder)を持っていて、選択範囲(キャレット)が
/// 触れる段落。エディタがフォーカスを失うと(iOS でキーボードを閉じる、macOS でサイドバーをクリックする)
/// フォーカスのある段落は無くなり、全行のマーカーが隠れる(閲覧表示)。
/// 状態の変化で再生成が要る段落は `pendingDirtyRanges` に溜め、`MarkdownEditorEngine` が
/// 段落を作り直させる(`regenerateParagraphs`)。
@MainActor
final class LivePreviewConcealer {
    /// 隠すマーカーに付ける表示用フォント。TextKit 2 は `.expansion` を無視するので、
    /// 極小サイズのフォントで字送りをほぼ 0 にする(高さも 0 に近づくが、行の高さは他の文字が決める)。
    /// 字送りはサイズに比例して残る(0.01pt では 10 万文字の URL で約 390pt、1e-6pt なら約 0.06pt)ので、
    /// data URL のような極端に長いマーカーでも後続の文字が動かない大きさにする。
    static let hiddenFontSize: CGFloat = 0.000_001
    static let hiddenFont = PlatformFont.systemFont(ofSize: hiddenFontSize)

    var isEnabled = false

    /// 隠せるマーカー(開始位置で昇順、互いに交差しない)
    private(set) var markers: [NSRange] = []
    /// 選択範囲が触れる段落のレンジ(文書座標、改行を含む)。キャレットだけなら 1 つ、選択範囲は
    /// 触れる段落をまとめて 1 レンジ、複数選択(macOS)は複数。エディタのフォーカスとは独立に追従し、
    /// `isEditorFocused` と合わせて「フォーカスのある段落」になる(`isFocused(paragraph:)`)。
    private(set) var focusedParagraphs: [NSRange] = []
    /// エディタ(テキストビュー)が first responder か。ビューが `editorFocusDidChange` で流し込む。
    /// false の間はどの段落にもフォーカスが無い。ビュー無しの既定は true(選択範囲だけで決まる)。
    private(set) var isEditorFocused = true
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
        // エディタにフォーカスが無い間は選択がどこにあっても全行が隠れているので、作り直す段落は無い
        //(フォーカスが戻るときに `editorFocusDidChange` がそのときの段落を無効化する)。
        guard isEnabled, isEditorFocused else { return }
        // 新旧の対称差だけを無効化する: 大きな選択を 1 行伸縮しても、重なっている部分は作り直さない。
        for range in Self.subtracting(focused, from: previous) + Self.subtracting(previous, from: focused)
        where containsMarker(in: range) {
            pendingDirtyRanges.append(range)
        }
    }

    /// `ranges` の各レンジから `others` と重なる部分を取り除いた残り(空レンジは落とす)。
    static func subtracting(_ others: [NSRange], from ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges {
            var pieces = [range]
            for other in others {
                pieces = pieces.flatMap { piece -> [NSRange] in
                    let overlap = NSIntersectionRange(piece, other)
                    guard overlap.length > 0 else { return [piece] }
                    var remainder: [NSRange] = []
                    if overlap.location > piece.location {
                        remainder.append(NSRange(location: piece.location, length: overlap.location - piece.location))
                    }
                    if NSMaxRange(overlap) < NSMaxRange(piece) {
                        remainder.append(NSRange(location: NSMaxRange(overlap), length: NSMaxRange(piece) - NSMaxRange(overlap)))
                    }
                    return remainder
                }
            }
            result += pieces.filter { $0.length > 0 }
        }
        return result
    }

    /// エディタのフォーカス(first responder)の変化。変わったら、選択範囲が触れる段落のうちマーカーを
    /// 含むものを無効化対象に載せる(失えば隠す、戻れば見せる)。変わったら true。
    @discardableResult
    func editorFocusDidChange(_ focused: Bool) -> Bool {
        guard isEditorFocused != focused else { return false }
        isEditorFocused = focused
        guard isEnabled else { return true }
        for range in focusedParagraphs where containsMarker(in: range) {
            pendingDirtyRanges.append(range)
        }
        return true
    }

    /// 有効 / 無効の切替。切り替わったら、それまでの保留を捨てて文書全体(`documentLength`)を
    /// 無効化対象にする(全段落の表示用段落を作り直す。IME 変換中なら呼び出し側が確定後まで保留する)。
    /// 切り替わったら true。
    @discardableResult
    func setEnabled(_ enabled: Bool, documentLength: Int) -> Bool {
        guard isEnabled != enabled else { return false }
        isEnabled = enabled
        pendingDirtyRanges = documentLength > 0 ? [NSRange(location: 0, length: documentLength)] : []
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

    /// 段落にフォーカスがあるか。エディタがフォーカスを持ち、段落と交差する選択、または段落内
    /// (空レンジなら先頭を含む)のキャレットがあるとき。
    func isFocused(paragraph: NSRange) -> Bool {
        guard isEditorFocused else { return false }
        return focusedParagraphs.contains { focused in
            if focused.length == 0 { return NSLocationInRange(focused.location, paragraph) }
            return NSIntersectionRange(focused, paragraph).length > 0
        }
    }

    /// range と交差するマーカー(昇順)。二分探索で先頭候補を絞る。
    func markers(intersecting range: NSRange) -> ArraySlice<NSRange> {
        guard let low = firstMarkerIndex(endingAfter: range.location) else { return [] }
        var end = low
        while end < markers.count, markers[end].location < NSMaxRange(range) { end += 1 }
        return markers[low..<end]
    }

    /// range と交差するマーカーがあるか(二分探索の先頭候補だけで判定できる)。
    func containsMarker(in range: NSRange) -> Bool {
        guard let first = firstMarkerIndex(endingAfter: range.location) else { return false }
        return markers[first].location < NSMaxRange(range)
    }

    /// 終端が location より後ろにある最初のマーカーの添字(無ければ nil)。
    private func firstMarkerIndex(endingAfter location: Int) -> Int? {
        var low = 0
        var high = markers.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(markers[mid]) <= location { low = mid + 1 } else { high = mid }
        }
        return low < markers.count ? low : nil
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
        let original = base?.attributedString ?? storage.attributedSubstring(from: range)
        let text = NSMutableAttributedString(attributedString: original)
        guard text.length == range.length else { return base }
        let string = text.string as NSString
        var hiddenLength = 0
        var hidesTab = false
        for marker in hidden {
            let clipped = NSIntersectionRange(marker, range)
            guard clipped.length > 0 else { continue }
            let local = NSRange(location: clipped.location - range.location, length: clipped.length)
            text.addAttribute(.font, value: Self.hiddenFont, range: local)
            hiddenLength += clipped.length
            if string.rangeOfCharacter(from: .init(charactersIn: "\t"), options: [], range: local).location != NSNotFound {
                hidesTab = true
            }
        }
        let visibleLength = Self.visibleLength(of: string)
        let allHidden = hiddenLength >= visibleLength
        if allHidden || hidesTab {
            let style = (text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            // 見える文字が全部マーカーの段落(">" だけの引用行など)は、TextKit 2 が改行のフォントを
            // 行の高さに使わず 0 に潰れるので、隠す前の見える文字(改行を除く)のフォントから
            // 行の高さを求めて最低値として付ける。
            if allHidden {
                style.minimumLineHeight = Self.lineHeight(
                    of: original, in: NSRange(location: 0, length: max(visibleLength, 0)))
            }
            // タブ("#\tTitle" の見出しマーカー)は字送りではなくタブ位置で幅が決まるので、
            // 表示用段落ではタブ幅も潰す(タブを含むマーカーは見出しの開きだけで、本文にタブは残らない)。
            if hidesTab {
                style.tabStops = []
                style.defaultTabInterval = Self.hiddenFontSize
            }
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

    /// `range`(見える文字。改行は含めない: 通常の行高計算は改行のフォントを使わない)に付いている
    /// フォントのうち最も高い行の高さ(隠す前の自然な高さの近似)。
    static func lineHeight(of paragraph: NSAttributedString, in range: NSRange) -> CGFloat {
        var height: CGFloat = 0
        let clipped = NSIntersectionRange(range, NSRange(location: 0, length: paragraph.length))
        guard clipped.length > 0 else { return 0 }
        paragraph.enumerateAttribute(.font, in: clipped) { value, _, _ in
            guard let font = value as? PlatformFont else { return }
            height = max(height, (font.ascender - font.descender + font.leading).rounded(.up))
        }
        return height
    }
}
