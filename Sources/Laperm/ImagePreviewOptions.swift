import Foundation

/// 画像プレビューの設定。
public struct ImagePreviewOptions: Equatable, Sendable {
    /// プレビュー表示の有効/無効(無効時は構文ハイライトのみ)
    public var isEnabled: Bool
    /// 相対パスの解決基準ディレクトリ。nil の場合、相対パスの画像は失敗表示になる。
    public var baseURL: URL?
    /// プレビューの最大高さ(pt)。原寸がこれを超える場合はアスペクト比を保って縮小。
    public var maxHeight: CGFloat
    /// http(s) 画像のロード許可。プライバシー配慮でデフォルト false(不許可時は失敗表示)。
    public var allowsRemoteImages: Bool

    public init(
        isEnabled: Bool = true,
        baseURL: URL? = nil,
        maxHeight: CGFloat = 320,
        allowsRemoteImages: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.maxHeight = maxHeight
        self.allowsRemoteImages = allowsRemoteImages
    }
}
