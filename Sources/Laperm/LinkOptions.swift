import Foundation

/// リンク操作の設定。
public struct LinkOptions: Equatable, Sendable {
    /// Cmd+クリックでリンクを開く(ホバーフィードバックも連動)
    public var opensOnCommandClick: Bool
    /// 相対パスの解決基準(ImagePreviewOptions.baseURL と同じ役割)
    public var baseURL: URL?

    public init(opensOnCommandClick: Bool = true, baseURL: URL? = nil) {
        self.opensOnCommandClick = opensOnCommandClick
        self.baseURL = baseURL
    }
}
