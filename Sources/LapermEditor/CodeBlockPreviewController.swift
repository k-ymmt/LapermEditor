#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import LapermCore

/// Live Preview でコードブロックを箱に折りたたむ(Laperm ADR 0020)。折りたたみの状態機械は `BlockPreviewController`、
/// ここはコードブロック固有の部分: 折りたたみ候補(文書直下の閉じたブロック。リスト項目や引用の中のものは段落の
/// 先頭がブロックの先頭ではない(継続行の空白だけの接頭辞も含めてパーサの `isNested` で判定)ので Source のまま、
/// 閉じていないフェンスは書きかけなので Source のまま)、本文(`CodeBlockPreviewModel`)とレイアウト
/// (`CodeBlockPreviewLayout`)、箱のクリック先とコピーする本文。
typealias CodeBlockPreviewController = BlockPreviewController<CodeBlockPreviewSource>

/// コードブロック 1 つの材料: パース結果 + 本文のキャッシュ。本文(`model`)は折りたたむときに初めて作る。
struct CodeBlockPreviewSource: BlockPreviewSource {
    /// 本文が同じかを、位置に依らず判定する鍵(前の編集で位置だけ動いたブロックのモデルを使い回す)。
    struct Key: Hashable {
        var text: String
        var relativeBlock: MarkdownCodeBlock
        var themeGeneration: Int
    }

    var block: MarkdownCodeBlock
    var key: Key
    var model: CodeBlockPreviewModel?

    var isModelBuilt: Bool { model != nil }

    func shifted(by delta: Int) -> CodeBlockPreviewSource {
        var moved = self
        moved.block = block.shifted(by: delta)
        return moved
    }

    mutating func adoptCache(from previous: CodeBlockPreviewSource) {
        model = previous.model
    }

    @MainActor
    mutating func makeLayout(
        width: CGFloat, appearance: CodeBlockPreviewLayout.Appearance, storage: NSTextStorage, theme: MarkdownTheme
    ) -> CodeBlockPreviewLayout? {
        if model == nil {
            model = CodeBlockPreviewModel.make(block: block, text: storage.string as NSString)
        }
        guard let model else { return nil }
        return CodeBlockPreviewLayout.make(model: model, maxWidth: width, appearance: appearance)
    }
}

extension CodeBlockPreviewLayout: BlockPreviewLayout {}

extension BlockPreviewController where Source == CodeBlockPreviewSource {
    typealias PresentedCodeBlock = PresentedBlock

    /// モデルにあるコードブロック(折りたたみ候補。テスト用)。
    var codeBlocks: [MarkdownCodeBlock] { blocks }

    func isCollapsed(codeBlockAt location: Int) -> Bool { isCollapsed(blockAt: location) }

    /// パース確定後の同期。`storage` はハイライト適用済みのテキストストレージ、`text` はその文字列。
    func update(plan: HighlightPlan, storage: NSTextStorage, text: NSString) {
        let blocks = plan.codeBlocks.filter { block in
            block.isClosed && !block.isNested && block.range.length > 0 && NSMaxRange(block.range) <= text.length
                && block.lineStart >= 0 && block.lineStart <= block.range.location
        }
        let sources = blocks.map { block -> CodeBlockPreviewSource in
            CodeBlockPreviewSource(
                block: block,
                key: CodeBlockPreviewSource.Key(
                    text: text.substring(with: block.range), relativeBlock: block.relativeToStart, themeGeneration: themeGeneration),
                model: nil)
        }
        update(sources: sources, storage: storage, text: text)
    }

    /// `location` から始まる折りたたまれたコードブロックの表示(ビューポートレイアウトパスが箱を置くために使う)。
    func presentedCodeBlock(at location: Int) -> PresentedCodeBlock? { presentedBlock(at: location) }

    /// `location` から始まる折りたたまれたコードブロックの箱座標の点に対応するキャレット位置(文書座標)。箱の外、
    /// またはそのブロックに触る編集の後(次のパース待ち)なら nil。
    func caretLocation(inCodeBlockAt location: Int, point: CGPoint) -> Int? {
        guard let item = presentedBlock(at: location), hasBlock(at: location),
              let offset = item.layout.caretOffset(at: point) else { return nil }
        return item.block.range.location + offset
    }

    /// `location` から始まる折りたたまれたコードブロックの箱座標の点がコピーボタンの上か。
    func isOnCopyButton(inCodeBlockAt location: Int, point: CGPoint) -> Bool {
        guard let item = presentedBlock(at: location), hasBlock(at: location) else { return false }
        return item.layout.isOnCopyButton(point)
    }

    /// `location` から始まる折りたたまれたコードブロックのコピーする本文(フェンスとインデントを除く)。
    func copyText(forCodeBlockAt location: Int) -> String? {
        presentedBlock(at: location)?.layout.model.copyText
    }
}

extension BlockPreviewController.PresentedBlock where Source == CodeBlockPreviewSource {
    var codeBlock: MarkdownCodeBlock { block }
}
