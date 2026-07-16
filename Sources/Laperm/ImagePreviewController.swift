import AppKit
import LapermCore

/// 画像プレビューの状態機械。destination(URL 文字列)単位でロードを管理し、
/// 出現箇所(ImageReference)単位で表示サイズ・予約高さを提供する。
/// レンジではなく destination をロードのキーにするのは、画像より前方の編集で
/// レンジが平行移動するたびに再ロードが走るのを避けるため。
@MainActor
final class ImagePreviewController {
    enum State: Equatable {
        case loading
        case loaded(NSImage)
        case failed
    }

    static let loadingHeight: CGFloat = 80
    static let failedHeight: CGFloat = 44
    /// 画像 1 枚あたりの上下パディング合計
    static let padding: CGFloat = 8
    /// プレースホルダー(loading / failed)の幅上限
    static let placeholderMaxWidth: CGFloat = 240

    var options = ImagePreviewOptions()
    var loader: any ImageLoader = DefaultImageLoader()
    /// ロード完了・失敗で予約高さが変わりうるときに呼ばれる(view が spacing を再適用する)
    var onStateChange: (() -> Void)?

    /// 現在プレビュー対象の参照(isEnabled かつテーブル外のみ)
    private(set) var references: [ImageReference] = []
    private var states: [String: State] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    /// flush 後に最新の参照一覧を渡す。destination 集合の差分でロードを開始/破棄する。
    func update(references newReferences: [ImageReference]) {
        references = options.isEnabled ? newReferences.filter { !$0.isInsideTable } : []
        let needed = Set(references.map(\.destination))
        for destination in Array(states.keys) where !needed.contains(destination) {
            tasks[destination]?.cancel()
            tasks[destination] = nil
            states[destination] = nil
        }
        for destination in needed where states[destination] == nil {
            startLoad(destination: destination)
        }
    }

    /// baseURL / allowsRemoteImages / loader 変更後に呼ぶ。全状態を破棄して再ロードする。
    func resetLoads() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        states = [:]
        let current = references
        references = []
        update(references: current)
    }

    func state(for reference: ImageReference) -> State? {
        states[reference.destination]
    }

    /// 1 画像ぶんの表示サイズ(パディング除く)。containerWidth と maxHeight にフィット。
    func displaySize(for reference: ImageReference, containerWidth: CGFloat) -> CGSize {
        switch states[reference.destination] {
        case .loading, .none:
            return CGSize(
                width: min(containerWidth, Self.placeholderMaxWidth),
                height: Self.loadingHeight)
        case .failed:
            return CGSize(
                width: min(containerWidth, Self.placeholderMaxWidth),
                height: Self.failedHeight)
        case .loaded(let image):
            let size = image.size
            guard size.width > 0, size.height > 0, containerWidth > 0 else {
                return CGSize(
                    width: min(containerWidth, Self.placeholderMaxWidth),
                    height: Self.failedHeight)
            }
            let scale = min(1, containerWidth / size.width, options.maxHeight / size.height)
            return CGSize(width: size.width * scale, height: size.height * scale)
        }
    }

    /// 段落レンジごとの予約高さ(paragraphSpacing 値)。段落内の全画像 + 各 padding。
    func reservedHeights(containerWidth: CGFloat) -> [NSRange: CGFloat] {
        var result: [NSRange: CGFloat] = [:]
        for reference in references {
            let height = displaySize(for: reference, containerWidth: containerWidth).height
            result[reference.paragraphRange, default: 0] += height + Self.padding
        }
        return result
    }

    private func startLoad(destination: String) {
        guard let url = ImageURLResolver.resolve(
                destination: destination, baseURL: options.baseURL),
              url.isFileURL || options.allowsRemoteImages
        else {
            states[destination] = .failed
            return
        }
        states[destination] = .loading
        let loader = self.loader
        tasks[destination] = Task { [weak self] in
            let result: State
            do {
                result = .loaded(try await loader.loadImage(for: url))
            } catch {
                result = .failed
            }
            guard let self, !Task.isCancelled else { return }
            self.tasks[destination] = nil
            // 編集レース対策: この destination がまだ loading のときだけ反映する
            // (update / resetLoads で破棄済みなら何もしない)
            guard self.states[destination] == .loading else { return }
            self.states[destination] = result
            self.onStateChange?()
        }
    }

    /// テスト用: 状態を直接注入する
    func setStateForTesting(_ state: State, destination: String) {
        states[destination] = state
    }

    /// 適用済みスペーシングの発見用マーカー属性。除去時に「どこに適用したか」を
    /// 座標追跡なしで storage 自身から取り出せるようにする(属性は編集に自動追随する)。
    static let spacingAttribute = NSAttributedString.Key("laperm.imageSpacing")

    /// 予約高さを paragraphSpacing として textStorage に反映する。
    /// 実属性編集なので TextKit2 の通常経路で再レイアウトされる
    /// (BlockFragment のような recordEditAction ワークアラウンドは不要)。
    /// 属性のみの編集は .editedAttributes しか発火しないため didProcessEditing の
    /// 文字編集ガードと組み合わせて再入しない。
    func applySpacings(contentStorage: NSTextContentStorage, containerWidth: CGFloat) {
        guard let storage = contentStorage.textStorage else { return }
        var wanted = reservedHeights(containerWidth: containerWidth)
        // 文書外にはみ出た段落レンジは適用しない(パース結果と storage の不整合の防波堤)
        wanted = wanted.filter { NSMaxRange($0.key) <= storage.length }
        var stale: [NSRange] = []
        var unchanged: Set<NSRange> = []
        storage.enumerateAttribute(
            Self.spacingAttribute, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let applied = value as? CGFloat else { return }
            if wanted[range] == applied {
                unchanged.insert(range)
            } else {
                stale.append(range)
            }
        }
        guard !stale.isEmpty || wanted.count > unchanged.count else { return }
        contentStorage.performEditingTransaction {
            for range in stale {
                storage.removeAttribute(.paragraphStyle, range: range)
                storage.removeAttribute(Self.spacingAttribute, range: range)
            }
            for (range, height) in wanted where !unchanged.contains(range) {
                let style = NSMutableParagraphStyle()
                style.paragraphSpacing = height
                storage.addAttribute(.paragraphStyle, value: style, range: range)
                storage.addAttribute(Self.spacingAttribute, value: height, range: range)
            }
        }
    }
}
