import AppKit
import LapermCore

enum BlockDecoration: Equatable {
    case codeBlock
    case blockquote
    case thematicBreak
    case table
}

struct Decoration: Equatable {
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
        // 旧・新の装飾レンジを無効化してフラグメントを再生成させる
        let dirtyRanges = (decorations + new).map(\.range)
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

    private func decoration(at location: NSTextLocation, in contentManager: NSTextContentManager) -> BlockDecoration? {
        let offset = contentManager.offset(from: contentManager.documentRange.location, to: location)
        return decorations.first { NSLocationInRange(offset, $0.range) }?.kind
    }

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        guard let contentManager = textLayoutManager.textContentManager,
              let kind = decoration(at: location, in: contentManager) else {
            // 画像段落(spacing マーカー付き)は末尾でも予約領域を確保する専用フラグメントにする
            if hasImageSpacing(textElement) {
                return ImageParagraphFragment(textElement: textElement, range: textElement.elementRange)
            }
            return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
        switch kind {
        case .codeBlock:
            let fragment = CodeBlockFragment(textElement: textElement, range: textElement.elementRange)
            fragment.fillColor = theme.codeBlockBackgroundColor
            return fragment
        case .blockquote:
            let fragment = BlockquoteFragment(textElement: textElement, range: textElement.elementRange)
            fragment.barColor = theme.blockquoteBarColor
            return fragment
        case .thematicBreak:
            let fragment = ThematicBreakFragment(textElement: textElement, range: textElement.elementRange)
            fragment.lineColor = theme.thematicBreakLineColor
            return fragment
        case .table:
            let fragment = TableBackgroundFragment(textElement: textElement, range: textElement.elementRange)
            fragment.fillColor = theme.tableBackgroundColor
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
