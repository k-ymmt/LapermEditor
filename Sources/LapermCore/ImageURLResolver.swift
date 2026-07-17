import Foundation

/// 画像記法の URL 文字列を読み込み可能な URL へ解決する純粋関数。
public enum ImageURLResolver {
    /// - http / https / file スキーム付き → そのまま
    /// - "/" 始まりの絶対パス → file URL
    /// - 相対パス → baseURL に対して解決(baseURL が nil なら解決不能)
    /// - 空文字列・未対応スキーム → nil
    public static func resolve(destination: String, baseURL: URL?) -> URL? {
        URLDestinationResolver.resolve(
            destination: destination, baseURL: baseURL,
            allowedSchemes: ["http", "https", "file"])
    }
}
