import Foundation

/// Link Preview のカードに描くページの情報(Laperm ADR 0046)。`LinkPreviewProvider` が返す。
public struct LinkPreview: Hashable, Sendable {
    /// ページのタイトル(1 行)。
    public var title: String
    /// 説明(2 行まで)。無ければ nil。
    public var description: String?
    /// サイト名(1 行)。無ければカードは URL のホスト名を見せる。
    public var siteName: String?
    /// 画像(`og:image`)。エディタの `ImageLoader` で読む(http(s) は `ImagePreviewOptions.allowsRemoteImages` に従う)。
    public var imageURL: URL?

    public init(title: String, description: String? = nil, siteName: String? = nil, imageURL: URL? = nil) {
        self.title = title
        self.description = description
        self.siteName = siteName
        self.imageURL = imageURL
    }
}

/// URL からページの情報を取る(ホストが注入する。Laperm ADR 0046)。エディタは取得の方法(ネットワーク、キャッシュ、
/// 取りに行かないホストの規則)を知らず、注入されなければ Link Preview は無効。
///
/// nil は「カードにしない」(取れなかった、タイトルが無い)。取得中は await で待つ(エディタはその間 URL のまま見せ、
/// Note を閉じる / URL が消えると Task を取り消す)。
public protocol LinkPreviewProvider: AnyObject, Sendable {
    func linkPreview(for url: URL) async -> LinkPreview?
}

/// Link Preview の設定(`ImagePreviewOptions` と並ぶ)。
public struct LinkPreviewOptions: Equatable, Sendable {
    /// カードの有効 / 無効。無効なら取得もしない(外への要求はゼロ)。
    public var isEnabled: Bool

    public init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }
}
