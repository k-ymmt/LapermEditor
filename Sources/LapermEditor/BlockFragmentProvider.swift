#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import LapermCore

enum BlockDecoration: Equatable {
    case codeBlock
    case blockquote
    case thematicBreak
    case table
}

struct Decoration: Hashable {
    var range: NSRange
    var kind: BlockDecoration
}

/// HighlightPlan のブロック情報に基づき、装飾付き NSTextLayoutFragment を供給する。
@MainActor
final class BlockFragmentProvider: NSObject, NSTextLayoutManagerDelegate {
    var theme: MarkdownTheme
    /// NSTextView が内部で delegate を持っていた場合に備えて転送先を保持。
    /// nonisolated(unsafe): この delegate は AppKit のメインスレッド上のテキストレイアウト機構から
    /// responds(to:)/forwardingTarget(for:) 経由で同期的にのみ参照されるため安全。
    nonisolated(unsafe) weak var fallbackDelegate: NSTextLayoutManagerDelegate?
    private var decorations: [Decoration] = []

    init(theme: MarkdownTheme) {
        self.theme = theme
    }

    /// didProcessEditing(.editedCharacters)からの座標追従。HighlightPlan.shifted と同じ規約で
    /// 装飾レンジを平行移動し、編集と交差する装飾は落とす(次の update で再生成される)。
    /// これを怠ると、装飾より前で長さの変わる編集(ほぼ全キーストローク)のたびに
    /// 旧装飾と新装飾がすべて不一致になり、update が全装飾を無効化してしまう
    /// (10k 行で 1 キーストローク 200ms 超)。
    func noteEdit(editedRange: NSRange, changeInLength delta: Int) {
        guard !decorations.isEmpty else { return }
        let preEditRange = NSRange(
            location: editedRange.location,
            length: max(0, editedRange.length - delta))
        decorations = decorations.compactMap { decoration in
            if NSMaxRange(decoration.range) <= preEditRange.location {
                return decoration
            }
            if decoration.range.location >= NSMaxRange(preEditRange) {
                var moved = decoration
                moved.range.location += delta
                return moved
            }
            return nil
        }
    }

    /// 新しい計画から装飾リストを作り直し、変化したレンジのレイアウトを無効化する。
    func update(
        plan: HighlightPlan,
        contentManager: NSTextContentManager,
        layoutManager: NSTextLayoutManager
    ) {
        let new = plan.spans.compactMap { span -> Decoration? in
            switch span.kind {
            case .codeBlock: Decoration(range: span.range, kind: .codeBlock)
            case .blockquote: Decoration(range: span.range, kind: .blockquote)
            case .thematicBreak: Decoration(range: span.range, kind: .thematicBreak)
            case .table: Decoration(range: span.range, kind: .table)
            default: nil
            }
        }
        guard new != decorations else { return }
        // 消えた装飾・増えた装飾のレンジだけ無効化してフラグメントを再生成させる
        // (位置・種類が同じ装飾のフラグメントはそのまま使える)
        let oldSet = Set(decorations)
        let newSet = Set(new)
        let dirtyRanges = decorations.filter { !newSet.contains($0) }.map(\.range)
            + new.filter { !oldSet.contains($0) }.map(\.range)
        decorations = new
        let textRanges = dirtyRanges.compactMap { contentManager.textRange(for: $0) }
        // NSTextContentStorage は、実際に文字/属性が変化していないレンジについては
        // 既存の NSTextParagraph(と、それに紐づく NSTextLayoutFragment)を使い回してしまい、
        // invalidateLayout(for:) だけではデリゲートへの再問い合わせが起きない。
        // recordEditAction(in:newTextRange:) で「このレンジは編集された」と明示的に記録することで
        // 要素の再生成を強制し、その上で invalidateLayout してフラグメントを再取得させる。
        contentManager.performEditingTransaction {
            for textRange in textRanges {
                contentManager.recordEditAction(in: textRange, newTextRange: textRange)
            }
        }
        for textRange in textRanges {
            layoutManager.invalidateLayout(for: textRange)
        }
    }

    /// 画像プレビューの予約(spacing マーカー)が付いた段落かどうか。
    private func hasImageSpacing(_ textElement: NSTextElement) -> Bool {
        guard let paragraph = textElement as? NSTextParagraph else { return false }
        let attributed = paragraph.attributedString
        guard attributed.length > 0 else { return false }
        return attributed.attribute(
            ImagePreviewController.spacingAttribute, at: 0, effectiveRange: nil) != nil
    }

    /// 画像プレビューの予約が付いた段落について、`ReservingTextLayoutFragment` に
    /// 設定すべき追加の高さ(= その段落の paragraphSpacing)を返す。
    /// マーカーが無い場合(通常の段落・コードブロック・テーブルなど)は nil を返し、
    /// フラグメントは通常の `NSTextLayoutFragment` と同じ高さ計算のままになる。
    private func reservedBottomHeight(for textElement: NSTextElement) -> CGFloat? {
        guard hasImageSpacing(textElement),
              let paragraph = textElement as? NSTextParagraph,
              paragraph.attributedString.length > 0,
              let style = paragraph.attributedString.attribute(
                .paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        else { return nil }
        return style.paragraphSpacing
    }

    /// 段落(textElement)に適用する装飾。段落レンジと装飾レンジの交差で判定する。
    /// 段落の先頭オフセットだけで判定すると、インデントされたコードブロック(`\tcode`)や
    /// リスト項目内の引用(`- > quote`)のように装飾レンジがインデント後から始まる場合に
    /// 先頭行だけ装飾されない。
    private func decoration(
        for textElement: NSTextElement, in contentManager: NSTextContentManager
    ) -> BlockDecoration? {
        guard let elementRange = textElement.elementRange else { return nil }
        let start = contentManager.offset(from: contentManager.documentRange.location, to: elementRange.location)
        let end = contentManager.offset(from: contentManager.documentRange.location, to: elementRange.endLocation)
        let paragraph = NSRange(location: start, length: max(0, end - start))
        return decorations.first {
            NSLocationInRange(start, $0.range) || NSIntersectionRange(paragraph, $0.range).length > 0
        }?.kind
    }

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        // 画像段落(spacing マーカー付き)は装飾の有無によらず、末尾でも予約領域を
        // 確保できるよう `reservedBottomHeight` を設定する(下記いずれの分岐でも共通)。
        let reservation = reservedBottomHeight(for: textElement)
        guard let contentManager = textLayoutManager.textContentManager,
              let kind = decoration(for: textElement, in: contentManager) else {
            let fragment = ReservingTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
            fragment.reservedBottomHeight = reservation
            return fragment
        }
        switch kind {
        case .codeBlock:
            let fragment = CodeBlockFragment(textElement: textElement, range: textElement.elementRange)
            fragment.fillColor = theme.codeBlockBackgroundColor
            fragment.reservedBottomHeight = reservation
            return fragment
        case .blockquote:
            let fragment = BlockquoteFragment(textElement: textElement, range: textElement.elementRange)
            fragment.barColor = theme.blockquoteBarColor
            fragment.reservedBottomHeight = reservation
            return fragment
        case .thematicBreak:
            let fragment = ThematicBreakFragment(textElement: textElement, range: textElement.elementRange)
            fragment.lineColor = theme.thematicBreakLineColor
            fragment.reservedBottomHeight = reservation
            return fragment
        case .table:
            let fragment = TableBackgroundFragment(textElement: textElement, range: textElement.elementRange)
            fragment.fillColor = theme.tableBackgroundColor
            fragment.reservedBottomHeight = reservation
            return fragment
        }
    }

    // 未実装のデリゲートメソッドは既存デリゲートへ転送する。
    // これらの NSObject メソッドはオーバーライド元が nonisolated 扱いとなるため
    // MainActor 隔離プロパティへのアクセスは警告になるが、AppKit ランタイムからは
    // 常にメインスレッドで同期的に呼ばれるため実害はない(このクラスは @MainActor)。
    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (fallbackDelegate?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if super.responds(to: aSelector) { return nil }
        return fallbackDelegate
    }
}

