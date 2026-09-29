import Foundation

/// リンク操作の設定。
public struct LinkOptions: Equatable, Sendable {
    /// Cmd+クリックでリンクを開く(ホバーフィードバックも連動)
    public var opensOnCommandClick: Bool
    /// 相対パスの解決基準(ImagePreviewOptions.baseURL と同じ役割)
    public var baseURL: URL?
    /// Live Preview でリンクとして描かれたリンク(キャレットの無い段落、表の格子、Front Matter の表の URL)を
    /// 修飾キー無しのクリック / タップで開く(Laperm ADR 0031)。長押し / 右クリックのリンクのメニューはこの設定に依らない。
    public var opensRenderedLinksOnClick: Bool

    public init(opensOnCommandClick: Bool = true, baseURL: URL? = nil, opensRenderedLinksOnClick: Bool = true) {
        self.opensOnCommandClick = opensOnCommandClick
        self.baseURL = baseURL
        self.opensRenderedLinksOnClick = opensRenderedLinksOnClick
    }
}

