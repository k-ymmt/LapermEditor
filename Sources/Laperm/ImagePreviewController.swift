import AppKit
import LapermCore
import os

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

    private static let logger = Logger(subsystem: "Laperm", category: "ImagePreview")

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
                destination: destination, baseURL: options.baseURL)
        else {
            Self.logger.info("画像 URL を解決できません: \(destination, privacy: .public)")
            states[destination] = .failed
            return
        }
        guard url.isFileURL || options.allowsRemoteImages else {
            Self.logger.info(
                "リモート画像はポリシーにより無効化されています: \(destination, privacy: .public)")
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
                Self.logger.error(
                    """
                    画像の読み込みに失敗しました: \(destination, privacy: .public) \
                    error=\(String(describing: error), privacy: .public)
                    """)
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

        // NSAttributedString の enumerateAttribute は「同じ値」の隣接ランを 1 つに
        // 結合して返す。2 つの画像段落がたまたま同じ予約高さ(例: どちらも loading で
        // 88)だと、段落境界をまたいだ 1 レンジとして報告され、wanted のキー(段落単位の
        // レンジ)とは一致しなくなる。そのレンジを enumerate の戻り値そのものと
        // wanted のキーで単純比較すると常に不一致 = stale 扱いになり、変化がなくても
        // 毎回 remove + re-add の編集トランザクションが走ってしまう。
        // そこで「変化なし」の判定は enumerate の結果ではなく、wanted の各レンジ単位で
        // 個別に行う: そのレンジ全域が同じ値(= 求める高さ)で覆われているかを
        // attribute(at:effectiveRange:) で逐次確認する。
        var unchanged: Set<NSRange> = []
        for (range, height) in wanted where range.length > 0 {
            var covered = true
            var location = range.location
            while location < NSMaxRange(range) {
                var effective = NSRange(location: 0, length: 0)
                let value = storage.attribute(
                    Self.spacingAttribute, at: location, effectiveRange: &effective) as? CGFloat
                guard value == height else {
                    covered = false
                    break
                }
                location = NSMaxRange(effective)
            }
            if covered { unchanged.insert(range) }
        }

        // 既存の spacing 属性のうち、上で「変化なし」と確定した wanted レンジに
        // ちょうど属さない部分を stale として集める。結合ランが unchanged な wanted
        // レンジを複数またぐ場合や、変化した/なくなった段落を含む場合はここで
        // 部分的に取り除かれる(= 隣の unchanged な段落の spacing は保持される)。
        var stale: [NSRange] = []
        storage.enumerateAttribute(
            Self.spacingAttribute, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard value != nil else { return }
            var remaining = [range]
            for claimed in unchanged {
                remaining = remaining.flatMap { Self.subtracting(claimed, from: $0) }
            }
            stale.append(contentsOf: remaining)
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

    /// `range` から `subtract` と重なる部分を取り除いた残り。
    /// `subtract` が `range` の内側にあるときは前後 2 つに分かれうる。
    private static func subtracting(_ subtract: NSRange, from range: NSRange) -> [NSRange] {
        let intersection = NSIntersectionRange(range, subtract)
        guard intersection.length > 0 else { return [range] }
        var result: [NSRange] = []
        if intersection.location > range.location {
            result.append(NSRange(
                location: range.location, length: intersection.location - range.location))
        }
        let intersectionEnd = NSMaxRange(intersection)
        let rangeEnd = NSMaxRange(range)
        if intersectionEnd < rangeEnd {
            result.append(NSRange(location: intersectionEnd, length: rangeEnd - intersectionEnd))
        }
        return result
    }
}
