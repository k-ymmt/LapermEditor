#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import LapermCore

/// Live Preview で裸の URL だけの段落を Link Preview のカードに折りたたむ(Laperm ADR 0046)。折りたたみの状態機械は
/// `BlockPreviewController`、ここは Link Preview 固有の部分: 候補(`HighlightPlan.linkPreviews` の先頭 `maxCandidates`
/// 件)、取得の状態(`LinkPreviewStore`)、カードのレイアウト(`LinkPreviewLayout`)、カードのクリック先。
///
/// 取得中と取れなかった候補はレイアウトが作れない(`makeLayout` が nil)ので折りたたまれず、URL のまま見える。取得が
/// 終わると Store の `onChange` → エンジンが `invalidateLayouts()` で表示を取り直す。
typealias LinkPreviewController = BlockPreviewController<LinkPreviewSource>

extension LinkPreviewCandidate: PreviewableBlock {}

/// 候補 1 つの材料: パース結果 + 取得の状態(Store、エンジンが持つ)。
struct LinkPreviewSource: BlockPreviewSource {
    /// 内容が同じかを位置に依らず判定する鍵。取得結果と画像は Store にあり、変わったときはエンジンがレイアウトを捨てる。
    struct Key: Hashable {
        var destination: String
        var themeGeneration: Int
    }

    var block: LinkPreviewCandidate
    var key: Key
    let store: LinkPreviewStore

    /// 取得結果は Store が持つ(ここに作るモデルは無い): 「作られている」= 取得が済んでいる、で答える。
    var isModelBuilt: Bool { MainActor.assumeIsolated { store.preview(for: block.destination) != nil } }

    func shifted(by delta: Int) -> LinkPreviewSource {
        var moved = self
        moved.block = block.shifted(by: delta)
        return moved
    }

    mutating func adoptCache(from previous: LinkPreviewSource) {}

    @MainActor
    mutating func makeLayout(
        width: CGFloat, appearance: LinkPreviewLayout.Appearance, storage: NSTextStorage, theme: MarkdownTheme
    ) -> LinkPreviewLayout? {
        guard NSMaxRange(block.range) <= storage.length, let preview = store.preview(for: block.destination) else { return nil }
        let image = preview.imageURL.flatMap { store.image(for: $0) }
        return LinkPreviewLayout.make(
            preview: preview, image: image, host: URL(string: block.destination)?.host(), maxWidth: width, appearance: appearance)
    }
}

extension BlockPreviewController where Source == LinkPreviewSource {
    typealias PresentedLinkPreview = PresentedBlock

    /// 1 文書につき取得する候補の上限(先頭から)。一覧の Note を開くたびに数百の要求が飛ぶのを防ぐ。
    static var maxCandidates: Int { 100 }

    /// モデルにある候補(テスト用)。
    var linkPreviewCandidates: [LinkPreviewCandidate] { blocks }

    func isCollapsed(linkPreviewAt location: Int) -> Bool { isCollapsed(blockAt: location) }

    /// パース確定後の同期。`isActive` が false(設定で無効、Provider 無し)なら候補を持たず、Store の取得も全部取り消す。
    func update(plan: HighlightPlan, storage: NSTextStorage, text: NSString, store: LinkPreviewStore, isActive: Bool) {
        let candidates = isActive
            ? Array(plan.linkPreviews.lazy.filter { NSMaxRange($0.range) <= text.length && $0.urlRange.length > 0 }.prefix(Self.maxCandidates))
            : []
        store.update(destinations: candidates.map(\.destination))
        let sources = candidates.map { candidate in
            LinkPreviewSource(
                block: candidate, key: LinkPreviewSource.Key(destination: candidate.destination, themeGeneration: themeGeneration),
                store: store)
        }
        update(sources: sources, storage: storage, text: text)
    }

    /// `location` から始まる折りたたまれた候補の表示(ビューポートレイアウトパスがカードを置くために使う)。
    func presentedLinkPreview(at location: Int) -> PresentedLinkPreview? { presentedBlock(at: location) }

    /// `location` から始まる折りたたまれた候補の、書かれた URL と「編集」でキャレットを置く位置(URL の末尾)。
    /// その候補に触る編集の後(次のパース待ち)なら nil。
    func linkTarget(forLinkPreviewAt location: Int) -> (destination: String, editCaret: Int)? {
        guard let item = presentedBlock(at: location), hasBlock(at: location) else { return nil }
        return (item.block.destination, NSMaxRange(item.block.urlRange))
    }
}

extension BlockPreviewController.PresentedBlock where Source == LinkPreviewSource {
    var candidate: LinkPreviewCandidate { block }
}
