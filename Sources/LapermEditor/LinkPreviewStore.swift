#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import os

/// Link Preview の取得の状態(Laperm ADR 0046)。URL 文字列(書かれたまま)単位で Provider に問い合わせ、カードの画像は
/// 折りたたむときに初めて `ImageLoader` で読む。画像プレビュー(`ImagePreviewController`)と同じく、レンジではなく URL を
/// 鍵にするので、前方の編集で候補が動いても取り直さない。
@MainActor
final class LinkPreviewStore {
    enum State: Equatable {
        case loading
        case loaded(LinkPreview)
        /// 取れなかった(カードにしない)。URL が文書から消えるまで取り直さない。
        case unavailable
    }

    enum ImageState: Equatable {
        case loading
        case loaded(PlatformImage)
        case failed
    }

    private static let logger = Logger(subsystem: "LapermEditor", category: "LinkPreview")

    /// 注入されていなければ取得しない(機能は無効)。差し替えると全部取り直す。
    var provider: (any LinkPreviewProvider)? {
        didSet {
            guard provider !== oldValue else { return }
            resetLoads()
        }
    }
    /// カードの画像を読むローダー(エディタの画像プレビューと同じもの)。差し替えると画像を読み直す。
    var imageLoader: any ImageLoader = DefaultImageLoader() {
        didSet {
            guard imageLoader !== oldValue else { return }
            resetImages()
        }
    }
    /// http(s) の画像を読むか(`ImagePreviewOptions.allowsRemoteImages`)。
    var allowsRemoteImages = false {
        didSet {
            guard allowsRemoteImages != oldValue else { return }
            resetImages()
        }
    }
    /// 取得(ページの情報、画像)が終わって表示が変わりうるときに、影響する URL(書かれたまま)の集合で呼ばれる(エンジンが
    /// その候補のカードだけ作り直す)。空の集合は「全部」(ローダーや設定の変更)。
    var onChange: ((Set<String>) -> Void)?

    private(set) var states: [String: State] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private(set) var images: [URL: ImageState] = [:]
    private var imageTasks: [URL: Task<Void, Never>] = [:]
    /// 直近の `update` の URL(Provider の差し替えで取り直すため)。
    private var destinations: [String] = []

    deinit {
        for task in tasks.values { task.cancel() }
        for task in imageTasks.values { task.cancel() }
    }

    /// パース確定後の候補の URL(出現順)。消えた URL の取得は取り消し、新しい URL の取得を始める。
    func update(destinations newDestinations: [String]) {
        destinations = newDestinations
        let needed = Set(newDestinations)
        for destination in Array(states.keys) where !needed.contains(destination) {
            tasks[destination]?.cancel()
            tasks[destination] = nil
            states[destination] = nil
        }
        // 使われなくなった画像も捨てる(読み込み中なら取り消す)
        let neededImages = Set(states.values.compactMap { state -> URL? in
            if case .loaded(let preview) = state { return preview.imageURL }
            return nil
        })
        for url in Array(images.keys) where !neededImages.contains(url) {
            imageTasks[url]?.cancel()
            imageTasks[url] = nil
            images[url] = nil
        }
        guard provider != nil else { return }
        for destination in newDestinations where states[destination] == nil {
            startLoad(destination: destination)
        }
    }

    /// 取れたページの情報。取得中・取れなかった・未要求なら nil。
    func preview(for destination: String) -> LinkPreview? {
        if case .loaded(let preview) = states[destination] { return preview }
        return nil
    }

    /// カードの画像。まだ読んでいなければ読み始めて nil(読み終わると `onChange`)。http(s) は `allowsRemoteImages` が
    /// false なら読まない(nil のまま)。
    func image(for url: URL) -> PlatformImage? {
        switch images[url] {
        case .loaded(let image): return image
        case .loading, .failed: return nil
        case .none:
            startImageLoad(url: url)
            return nil
        }
    }

    /// 全部取り直す(Provider の差し替え)。
    func resetLoads() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        states = [:]
        resetImages()
        update(destinations: destinations)
    }

    /// 画像だけ読み直す(ローダー / リモート画像の許可の変更)。
    private func resetImages() {
        for task in imageTasks.values { task.cancel() }
        imageTasks = [:]
        images = [:]
        onChange?([])
    }

    private func startLoad(destination: String) {
        guard let provider, let url = URL(string: destination) else {
            states[destination] = .unavailable
            return
        }
        states[destination] = .loading
        tasks[destination] = Task { [weak self] in
            // 走る前に取り消された(URL が消えた、設定 OFF、Store の解放)Task は Provider を呼ばない: 要求を出さない約束
            guard !Task.isCancelled, self != nil else { return }
            let result = await provider.linkPreview(for: url)
            guard let self, !Task.isCancelled else { return }
            self.tasks[destination] = nil
            // 編集レース対策: この URL がまだ loading のときだけ反映する(update / resetLoads で破棄済みなら何もしない)
            guard self.states[destination] == .loading else { return }
            self.states[destination] = result.map(State.loaded) ?? .unavailable
            self.onChange?([destination])
        }
    }

    private func startImageLoad(url: URL) {
        guard url.isFileURL || allowsRemoteImages else {
            images[url] = .failed
            return
        }
        images[url] = .loading
        let loader = imageLoader
        imageTasks[url] = Task { [weak self] in
            guard !Task.isCancelled, self != nil else { return }
            let result: ImageState
            do {
                result = .loaded(try await loader.loadImage(for: url))
            } catch {
                // `og:image` の URL は署名付きのこともある: 公開ログに出さない
                Self.logger.info("Link Preview の画像を読めません: \(url.absoluteString, privacy: .private) error=\(String(describing: error), privacy: .private)")
                result = .failed
            }
            guard let self, !Task.isCancelled else { return }
            self.imageTasks[url] = nil
            guard self.images[url] == .loading else { return }
            self.images[url] = result
            self.onChange?(self.destinations(usingImage: url))
        }
    }

    /// その画像を使う(取れたページの情報の `imageURL` が一致する)URL の集合。
    func destinations(usingImage url: URL) -> Set<String> {
        Set(states.compactMap { destination, state -> String? in
            if case .loaded(let preview) = state, preview.imageURL == url { return destination }
            return nil
        })
    }

    /// テスト用: 状態を直接注入する。
    func setStateForTesting(_ state: State, destination: String) {
        states[destination] = state
    }
}
